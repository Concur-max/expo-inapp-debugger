type NetworkModule = typeof import('../src/internal/network');

type WebSocketCallbacks = {
  connect?: (url: string, protocols: string[] | null, options: unknown, socketId: number) => void;
  send?: (data: unknown, socketId: number) => void;
  close?: (code: number | null, reason: string | null, socketId: number) => void;
  onOpen?: (socketId: number) => void;
  onMessage?: (data: unknown, socketId: number) => void;
  onError?: (payload: { message?: string }, socketId: number) => void;
  onClose?: (payload: { code: number; reason?: string | null }, socketId: number) => void;
};

type XHRCallbacks = {
  open?: (method: string, url: string, xhr: Record<string, unknown>) => void;
  requestHeader?: (header: string, value: string, xhr: Record<string, unknown>) => void;
  send?: (data: unknown, xhr: Record<string, unknown>) => void;
  headerReceived?: (
    responseContentType: string | undefined,
    responseSize: number | undefined,
    responseHeaders: string,
    xhr: Record<string, unknown>
  ) => void;
  response?: (
    status: number,
    timeout: number,
    response: unknown,
    responseURL: string,
    responseType: string,
    xhr: Record<string, unknown>
  ) => void;
};

function loadNetworkCollector() {
  const callbacks: WebSocketCallbacks = {};
  const xhrCallbacks: XHRCallbacks = {};
  const webSocketInterceptor = {
    setConnectCallback: jest.fn((callback?: WebSocketCallbacks['connect']) => {
      callbacks.connect = callback;
    }),
    setSendCallback: jest.fn((callback?: WebSocketCallbacks['send']) => {
      callbacks.send = callback;
    }),
    setCloseCallback: jest.fn((callback?: WebSocketCallbacks['close']) => {
      callbacks.close = callback;
    }),
    setOnOpenCallback: jest.fn((callback?: WebSocketCallbacks['onOpen']) => {
      callbacks.onOpen = callback;
    }),
    setOnMessageCallback: jest.fn((callback?: WebSocketCallbacks['onMessage']) => {
      callbacks.onMessage = callback;
    }),
    setOnErrorCallback: jest.fn((callback?: WebSocketCallbacks['onError']) => {
      callbacks.onError = callback;
    }),
    setOnCloseCallback: jest.fn((callback?: WebSocketCallbacks['onClose']) => {
      callbacks.onClose = callback;
    }),
    enableInterception: jest.fn(),
    disableInterception: jest.fn(),
  };
  const xhrInterceptor = {
    setOpenCallback: jest.fn((callback?: XHRCallbacks['open']) => {
      xhrCallbacks.open = callback;
    }),
    setRequestHeaderCallback: jest.fn((callback?: XHRCallbacks['requestHeader']) => {
      xhrCallbacks.requestHeader = callback;
    }),
    setSendCallback: jest.fn((callback?: XHRCallbacks['send']) => {
      xhrCallbacks.send = callback;
    }),
    setHeaderReceivedCallback: jest.fn((callback?: XHRCallbacks['headerReceived']) => {
      xhrCallbacks.headerReceived = callback;
    }),
    setResponseCallback: jest.fn((callback?: XHRCallbacks['response']) => {
      xhrCallbacks.response = callback;
    }),
    enableInterception: jest.fn(),
    disableInterception: jest.fn(),
  };

  jest.resetModules();
  jest.doMock('react-native', () => ({
    Platform: {
      OS: 'android',
    },
  }));
  jest.doMock('react-native/Libraries/WebSocket/WebSocketInterceptor', () => webSocketInterceptor);
  jest.doMock(
    'react-native/src/private/devsupport/devmenu/elementinspector/XHRInterceptor',
    () => xhrInterceptor
  );

  let NetworkCollector!: NetworkModule['NetworkCollector'];
  jest.isolateModules(() => {
    ({ NetworkCollector } = require('../src/internal/network') as NetworkModule);
  });

  return {
    NetworkCollector,
    callbacks,
    xhrCallbacks,
    xhrInterceptor,
    webSocketInterceptor,
  };
}

describe('NetworkCollector WebSocket lifecycle', () => {
  afterEach(() => {
    jest.resetModules();
    jest.clearAllMocks();
  });

  it('tracks Android websocket connections using lifecycle states', () => {
    const { NetworkCollector, callbacks, webSocketInterceptor } = loadNetworkCollector();
    const entries: Array<Record<string, unknown>> = [];
    const collector = new NetworkCollector({
      maxRequests: 20,
      onEntry: (entry) => {
        entries.push(entry);
      },
    });
    const latestEntry = () => entries[entries.length - 1];

    collector.enable();

    expect(webSocketInterceptor.enableInterception).toHaveBeenCalledTimes(1);

    callbacks.connect?.('wss://echo.example/socket', ['chat'], null, 7);
    expect(latestEntry()).toMatchObject({
      id: 'ws_7',
      kind: 'websocket',
      state: 'connecting',
      url: 'wss://echo.example/socket',
    });

    callbacks.onOpen?.(7);
    expect(latestEntry()).toMatchObject({
      id: 'ws_7',
      state: 'open',
    });

    callbacks.send?.('hello', 7);
    expect(latestEntry()).toMatchObject({
      id: 'ws_7',
      state: 'open',
      messages: '>> hello',
    });

    callbacks.close?.(1000, 'done', 7);
    expect(latestEntry()).toMatchObject({
      id: 'ws_7',
      state: 'closing',
      requestedCloseCode: 1000,
      requestedCloseReason: 'done',
    });
    expect(latestEntry()?.endedAt).toBeUndefined();

    callbacks.onClose?.({ code: 1000, reason: 'done' }, 7);
    expect(latestEntry()).toMatchObject({
      id: 'ws_7',
      state: 'closed',
      closeCode: 1000,
      closeReason: 'done',
    });
    expect(latestEntry()?.endedAt).toEqual(expect.any(Number));
  });

  it('keeps the final websocket state as error when close follows a failure', () => {
    const { NetworkCollector, callbacks } = loadNetworkCollector();
    const entries: Array<Record<string, unknown>> = [];
    const collector = new NetworkCollector({
      maxRequests: 20,
      onEntry: (entry) => {
        entries.push(entry);
      },
    });
    const latestEntry = () => entries[entries.length - 1];

    collector.enable();

    callbacks.connect?.('wss://echo.example/socket', null, null, 9);
    callbacks.onOpen?.(9);
    callbacks.onError?.({ message: 'Socket failed' }, 9);

    expect(latestEntry()).toMatchObject({
      id: 'ws_9',
      state: 'error',
      error: 'Socket failed',
    });

    callbacks.onClose?.({ code: 1006, reason: 'abnormal closure' }, 9);
    expect(latestEntry()).toMatchObject({
      id: 'ws_9',
      state: 'error',
      error: 'Socket failed',
      closeCode: 1006,
      closeReason: 'abnormal closure',
    });
    expect(latestEntry()?.endedAt).toEqual(expect.any(Number));
  });

  it('normalizes Android XHR raw response headers into a header map', () => {
    const { NetworkCollector, xhrCallbacks, xhrInterceptor } = loadNetworkCollector();
    const entries: Array<Record<string, unknown>> = [];
    const collector = new NetworkCollector({
      maxRequests: 20,
      onEntry: (entry) => {
        entries.push(entry);
      },
    });
    const latestEntry = () => entries[entries.length - 1];

    collector.enable();

    expect(xhrInterceptor.enableInterception).toHaveBeenCalledTimes(1);

    const xhr: Record<string, unknown> = {};
    xhrCallbacks.open?.('GET', 'https://example.com/items', xhr);
    xhrCallbacks.requestHeader?.('accept', 'application/json', xhr);
    xhrCallbacks.send?.(null, xhr);
    xhrCallbacks.headerReceived?.(
      'application/json',
      19,
      'content-type: application/json\r\nx-trace-id: abc123\r\nset-cookie: a=1\r\nset-cookie: b=2\r\n',
      xhr
    );
    xhrCallbacks.response?.(200, 0, '{"ok":true}', 'https://example.com/items', 'text', xhr);

    expect(latestEntry()).toMatchObject({
      id: 'http_1',
      kind: 'http',
      state: 'success',
      status: 200,
      requestHeaders: {
        accept: 'application/json',
      },
      responseHeaders: {
        'content-type': 'application/json',
        'x-trace-id': 'abc123',
        'set-cookie': 'a=1, b=2',
      },
      responseBody: '{"ok":true}',
    });
    expect(latestEntry()?.endedAt).toEqual(expect.any(Number));
  });
});
