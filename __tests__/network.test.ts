type NetworkModule = typeof import('../src/internal/network');

function flushPromises() {
  return Promise.resolve().then(() => undefined);
}

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
  let materializeNetworkEntry!: NetworkModule['materializeNetworkEntry'];
  jest.isolateModules(() => {
    ({ NetworkCollector, materializeNetworkEntry } = require('../src/internal/network') as NetworkModule);
  });

  return {
    NetworkCollector,
    materializeNetworkEntry,
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
    delete (globalThis as any).FileReader;
  });

  it('tracks Android websocket connections using lifecycle states', () => {
    const { NetworkCollector, callbacks, webSocketInterceptor, materializeNetworkEntry } = loadNetworkCollector();
    const entries: Array<Record<string, unknown>> = [];
    const collector = new NetworkCollector({
      maxRequests: 20,
      onEntry: (entry) => {
        entries.push(entry);
      },
    });
    const latestEntry = () => materializeNetworkEntry(entries[entries.length - 1] as any);

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
      messageCountOut: 1,
      bytesOut: 5,
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
    const { NetworkCollector, callbacks, materializeNetworkEntry } = loadNetworkCollector();
    const entries: Array<Record<string, unknown>> = [];
    const collector = new NetworkCollector({
      maxRequests: 20,
      onEntry: (entry) => {
        entries.push(entry);
      },
    });
    const latestEntry = () => materializeNetworkEntry(entries[entries.length - 1] as any);

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

  it('keeps only the latest websocket messages while preserving order', () => {
    const { NetworkCollector, callbacks, materializeNetworkEntry } = loadNetworkCollector();
    const entries: Array<Record<string, unknown>> = [];
    const collector = new NetworkCollector({
      maxRequests: 20,
      onEntry: (entry) => {
        entries.push(entry);
      },
    });
    const latestEntry = () => materializeNetworkEntry(entries[entries.length - 1] as any);

    collector.enable();

    callbacks.connect?.('wss://echo.example/socket', null, null, 11);
    callbacks.onOpen?.(11);
    for (let index = 0; index < 105; index += 1) {
      callbacks.send?.(`msg-${index}`, 11);
    }

    const messages = latestEntry()?.messages?.split('\n');
    expect(messages).toHaveLength(100);
    expect(messages?.[0]).toBe('>> msg-5');
    expect(messages?.[99]).toBe('>> msg-104');
  });

  it('captures websocket counters together with message previews', () => {
    const { NetworkCollector, callbacks, materializeNetworkEntry } = loadNetworkCollector();
    const entries: Array<Record<string, unknown>> = [];
    const collector = new NetworkCollector({
      maxRequests: 20,
      onEntry: (entry) => {
        entries.push(entry);
      },
    });
    const latestEntry = () => materializeNetworkEntry(entries[entries.length - 1] as any);

    collector.enable();

    callbacks.connect?.('wss://echo.example/socket', null, null, 12);
    callbacks.onOpen?.(12);
    callbacks.send?.('hello', 12);
    callbacks.onMessage?.('world', 12);

    expect(latestEntry()).toMatchObject({
      id: 'ws_12',
      messageCountOut: 1,
      messageCountIn: 1,
      bytesOut: 5,
      bytesIn: 5,
      messages: '>> hello\n<< world',
    });
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

  it('reads Blob JSON responses as full text instead of showing Blob metadata', async () => {
    const { NetworkCollector, xhrCallbacks } = loadNetworkCollector();
    const entries: Array<Record<string, unknown>> = [];
    const collector = new NetworkCollector({
      maxRequests: 20,
      onEntry: (entry) => {
        entries.push({ ...entry });
      },
    });
    const latestEntry = () => entries[entries.length - 1];
    const largeJson = JSON.stringify({
      ok: true,
      items: Array.from({ length: 1500 }, (_, index) => ({ index, id: `item-${index}` })),
    });

    class MockFileReader {
      result: string | null = null;
      error: unknown = null;
      onload: (() => void) | null = null;
      onerror: (() => void) | null = null;
      onabort: (() => void) | null = null;

      readAsText(blob: any) {
        Promise.resolve().then(() => {
          this.result = blob.__text;
          this.onload?.();
        });
      }
    }
    (globalThis as any).FileReader = MockFileReader;

    collector.enable();

    const xhr: Record<string, unknown> = {};
    xhrCallbacks.open?.('GET', 'https://example.com/large-json', xhr);
    xhrCallbacks.send?.(null, xhr);
    xhrCallbacks.headerReceived?.(
      'application/json',
      largeJson.length,
      `content-type: application/json\r\ncontent-length: ${largeJson.length}\r\n`,
      xhr
    );
    xhrCallbacks.response?.(
      200,
      0,
      {
        __text: largeJson,
        _data: {
          size: largeJson.length,
          offset: 0,
          blobId: 'blob-large-json',
          __collector: {},
        },
      },
      'https://example.com/large-json',
      'blob',
      xhr
    );

    expect(latestEntry()).toMatchObject({
      id: 'http_1',
      status: 200,
      responseType: 'blob',
    });
    expect(latestEntry()?.responseBody).toBeUndefined();

    await flushPromises();

    expect(latestEntry()?.responseBody).toBe(largeJson);
    expect(String(latestEntry()?.responseBody)).not.toContain('blobId');
    expect(String(latestEntry()?.responseBody)).not.toContain('...[truncated]');
  });

  it('keeps XHR requests successful when a timeout is configured but the response is 200', () => {
    const { NetworkCollector, xhrCallbacks } = loadNetworkCollector();
    const entries: Array<Record<string, unknown>> = [];
    const collector = new NetworkCollector({
      maxRequests: 20,
      onEntry: (entry) => {
        entries.push(entry);
      },
    });
    const latestEntry = () => entries[entries.length - 1];

    collector.enable();

    const xhr: Record<string, unknown> = {};
    xhrCallbacks.open?.('POST', 'https://example.com/items', xhr);
    xhrCallbacks.send?.('{"name":"demo"}', xhr);
    xhrCallbacks.response?.(200, 60000, '{"ok":true}', 'https://example.com/items', 'json', xhr);

    expect(latestEntry()).toMatchObject({
      id: 'http_1',
      kind: 'http',
      state: 'success',
      status: 200,
      responseBody: '{"ok":true}',
    });
    expect(latestEntry()?.requestBody).toBe('{"name":"demo"}');
    expect(latestEntry()?.error).toBeUndefined();
  });

  it('keeps full oversized XHR text bodies and tolerates circular payloads', () => {
    const { NetworkCollector, xhrCallbacks } = loadNetworkCollector();
    const entries: Array<Record<string, unknown>> = [];
    const collector = new NetworkCollector({
      maxRequests: 20,
      onEntry: (entry) => {
        entries.push(entry);
      },
    });
    const latestEntry = () => entries[entries.length - 1];

    collector.enable();

    const xhr: Record<string, unknown> = {};
    const circular: Record<string, unknown> = { value: 'ok' };
    circular.self = circular;

    xhrCallbacks.open?.('POST', 'https://example.com/items', xhr);
    xhrCallbacks.send?.(circular, xhr);
    xhrCallbacks.response?.(200, 0, 'x'.repeat(40_000), 'https://example.com/items', 'text', xhr);

    expect(latestEntry()).toMatchObject({
      id: 'http_1',
      kind: 'http',
      status: 200,
    });
    expect(String(latestEntry()?.requestBody)).toContain('"self":[Circular]');
    expect(String(latestEntry()?.responseBody)).not.toContain('...[truncated]');
    expect(String(latestEntry()?.responseBody)).toHaveLength(40_000);
  });

  it('marks XHR requests with status 0 as errors', () => {
    const { NetworkCollector, xhrCallbacks } = loadNetworkCollector();
    const entries: Array<Record<string, unknown>> = [];
    const collector = new NetworkCollector({
      maxRequests: 20,
      onEntry: (entry) => {
        entries.push(entry);
      },
    });
    const latestEntry = () => entries[entries.length - 1];

    collector.enable();

    const xhr: Record<string, unknown> = {};
    xhrCallbacks.open?.('GET', 'https://example.com/items', xhr);
    xhrCallbacks.send?.(null, xhr);
    xhrCallbacks.response?.(0, 0, '', '', 'text', xhr);

    expect(latestEntry()).toMatchObject({
      id: 'http_1',
      kind: 'http',
      state: 'error',
      status: 0,
      error: 'XMLHttpRequest failed',
    });
  });
});
