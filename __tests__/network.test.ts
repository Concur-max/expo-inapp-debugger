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

function loadNetworkCollector() {
  const callbacks: WebSocketCallbacks = {};
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
    setOpenCallback: jest.fn((_callback?: (...args: unknown[]) => void) => undefined),
    setRequestHeaderCallback: jest.fn((_callback?: (...args: unknown[]) => void) => undefined),
    setSendCallback: jest.fn((_callback?: (...args: unknown[]) => void) => undefined),
    setHeaderReceivedCallback: jest.fn((_callback?: (...args: unknown[]) => void) => undefined),
    setResponseCallback: jest.fn((_callback?: (...args: unknown[]) => void) => undefined),
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
});
