import { DebugRuntime, formatMessage, resolveProviderConfig } from '../src/internal/runtime';

jest.useFakeTimers();

const ACTIVE_FLUSH_DELAY_MS = 64;
const BACKGROUND_FLUSH_DELAY_MS = 400;

function flushPromises() {
  return Promise.resolve().then(() => undefined);
}

describe('formatMessage', () => {
  it('formats objects and strings', () => {
    expect(formatMessage(['hello', { value: 1 }])).toContain('"value":1');
  });

  it('caps large previews and handles circular references', () => {
    const circular: Record<string, unknown> = { ok: true };
    circular.self = circular;

    const message = formatMessage([circular, 'x'.repeat(20_000)]);

    expect(message).toContain('"self":[Circular]');
    expect(message).toContain('...[truncated]');
    expect(message.length).toBeLessThanOrEqual(12_000);
  });
});

describe('resolveProviderConfig', () => {
  it('defaults to disabled until explicitly enabled', () => {
    expect(resolveProviderConfig({}).enabled).toBe(false);
  });

  it('keeps native collectors disabled by default', () => {
    expect(resolveProviderConfig({ enabled: true })).toMatchObject({
      enableNativeLogs: false,
      enableNativeNetwork: false,
    });
    expect(resolveProviderConfig({ enabled: true, androidNativeLogs: { enabled: true } }).enableNativeLogs).toBe(true);
  });
});

describe('DebugRuntime', () => {
  const originalConsole = { ...console };

  afterEach(() => {
    console.log = originalConsole.log;
    console.info = originalConsole.info;
    console.warn = originalConsole.warn;
    console.error = originalConsole.error;
    console.debug = originalConsole.debug;
    delete (globalThis as any).ErrorUtils;
    delete (globalThis as any).addEventListener;
    delete (globalThis as any).removeEventListener;
    jest.clearAllTimers();
    jest.clearAllMocks();
  });

  it('does not ingest when disabled', async () => {
    const nativeModule = {
      configure: jest.fn().mockResolvedValue(undefined),
      ingestBatch: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
    };
    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory: () => ({
        enable: jest.fn(),
        disable: jest.fn(),
        updateOptions: jest.fn(),
      }),
    });

    await runtime.registerProvider(resolveProviderConfig({ enabled: false }));
    runtime.log('log', ['disabled']);
    jest.advanceTimersByTime(32);
    await flushPromises();

    expect(nativeModule.ingestBatch).not.toHaveBeenCalled();
  });

  it('patches console and batches entries when enabled', async () => {
    const nativeModule = {
      configure: jest.fn().mockResolvedValue(undefined),
      ingestBatch: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
    };
    const networkFactory = () => ({
      enable: jest.fn(),
      disable: jest.fn(),
      updateOptions: jest.fn(),
    });
    const consoleRef = {
      log: jest.fn(),
      info: jest.fn(),
      warn: jest.fn(),
      error: jest.fn(),
      debug: jest.fn(),
    };
    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory,
      consoleRef,
    });

    await runtime.registerProvider(resolveProviderConfig({ enabled: true }));
    expect(nativeModule.configure).toHaveBeenCalledWith(
      expect.objectContaining({
        enableNativeLogs: false,
        enableNativeNetwork: false,
      })
    );
    console.log('hello');
    console.info('details');
    console.error('boom');

    jest.advanceTimersByTime(BACKGROUND_FLUSH_DELAY_MS - 1);
    await flushPromises();
    expect(nativeModule.ingestBatch).not.toHaveBeenCalled();

    jest.advanceTimersByTime(1);
    await flushPromises();

    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);
    expect(consoleRef.info).toHaveBeenCalledWith('details');
    const [logs, errors, network] = nativeModule.ingestBatch.mock.calls[0];
    const batch = { logs, errors, network };
    expect(batch.logs).toHaveLength(3);
    expect(batch.errors).toHaveLength(1);
    expect(batch.network).toBeNull();
    expect(batch.logs[0][5]).toBe('hello');
    expect(typeof batch.logs[0][8]).toBe('number');
    expect(typeof batch.logs[0][9]).toBe('number');
    expect(batch.errors[0][1]).toBe('console');
    expect(typeof batch.errors[0][5]).toBe('number');
    expect(typeof batch.errors[0][6]).toBe('number');

    await runtime.disable();
    console.log('after disable');
    jest.advanceTimersByTime(32);
    await flushPromises();
    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);
  });

  it('buffers console entries emitted before native configure resolves', async () => {
    let resolveConfigure!: () => void;
    const nativeModule = {
      configure: jest.fn(
        () =>
          new Promise<void>((resolve) => {
            resolveConfigure = resolve;
          })
      ),
      ingestBatch: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
    };
    const consoleRef = {
      log: jest.fn(),
      info: jest.fn(),
      warn: jest.fn(),
      error: jest.fn(),
      debug: jest.fn(),
    };
    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory: () => ({
        enable: jest.fn(),
        disable: jest.fn(),
        updateOptions: jest.fn(),
      }),
      consoleRef,
    });

    const registerPromise = runtime.registerProvider(resolveProviderConfig({ enabled: true }));
    console.log('early boot log');

    jest.advanceTimersByTime(BACKGROUND_FLUSH_DELAY_MS);
    await flushPromises();
    expect(nativeModule.ingestBatch).not.toHaveBeenCalled();

    resolveConfigure();
    await registerPromise;
    jest.advanceTimersByTime(BACKGROUND_FLUSH_DELAY_MS);
    await flushPromises();

    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);
    expect(nativeModule.ingestBatch.mock.calls[0][0][0][5]).toBe('early boot log');
  });

  it('enables only the React Native network collector by default', async () => {
    const nativeModule = {
      configure: jest.fn().mockResolvedValue(undefined),
      ingestBatch: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
    };
    const networkCollector = {
      enable: jest.fn(),
      disable: jest.fn(),
      updateOptions: jest.fn(),
    };
    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory: () => networkCollector,
      consoleRef: {
        log: jest.fn(),
        info: jest.fn(),
        warn: jest.fn(),
        error: jest.fn(),
        debug: jest.fn(),
      },
    });

    await runtime.registerProvider(resolveProviderConfig({ enabled: true }));

    expect(networkCollector.enable).toHaveBeenCalledTimes(1);
    expect(networkCollector.disable).not.toHaveBeenCalled();
    expect(networkCollector.updateOptions).toHaveBeenLastCalledWith({ maxRequests: 100 });
    expect(nativeModule.configure).toHaveBeenCalledWith(
      expect.objectContaining({
        enableNetworkTab: true,
        enableNativeLogs: false,
        enableNativeNetwork: false,
      })
    );
  });

  it('uses a shorter flush delay only while the Network panel is active', async () => {
    let panelStateListener: ((event: { panelVisible?: boolean; activeFeed?: string }) => void) | undefined;
    const nativeModule = {
      configure: jest.fn().mockResolvedValue(undefined),
      ingestBatch: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
      addListener: jest.fn((_eventName, listener) => {
        panelStateListener = listener;
        return { remove: jest.fn() };
      }),
    };
    const networkCollector = {
      enable: jest.fn(),
      disable: jest.fn(),
      updateOptions: jest.fn(),
    };
    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory: () => networkCollector,
      consoleRef: {
        log: jest.fn(),
        info: jest.fn(),
        warn: jest.fn(),
        error: jest.fn(),
        debug: jest.fn(),
      },
    });

    await runtime.registerProvider(resolveProviderConfig({ enabled: true }));

    expect(nativeModule.addListener).toHaveBeenCalledWith('onPanelStateChange', expect.any(Function));
    expect(networkCollector.updateOptions).toHaveBeenLastCalledWith({ maxRequests: 100 });

    runtime.log('log', ['background']);
    jest.advanceTimersByTime(ACTIVE_FLUSH_DELAY_MS);
    await flushPromises();
    expect(nativeModule.ingestBatch).not.toHaveBeenCalled();

    panelStateListener?.({ panelVisible: true, activeFeed: 'network' });
    expect(networkCollector.updateOptions).toHaveBeenLastCalledWith({ maxRequests: 100 });

    jest.advanceTimersByTime(ACTIVE_FLUSH_DELAY_MS);
    await flushPromises();
    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);

    panelStateListener?.({ panelVisible: false, activeFeed: 'none' });
    expect(networkCollector.updateOptions).toHaveBeenLastCalledWith({ maxRequests: 100 });
  });

  it('does not install React Native network collection when the network tab is disabled', async () => {
    const nativeModule = {
      configure: jest.fn().mockResolvedValue(undefined),
      ingestBatch: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
    };
    const networkCollector = {
      enable: jest.fn(),
      disable: jest.fn(),
      updateOptions: jest.fn(),
    };
    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory: () => networkCollector,
      consoleRef: {
        log: jest.fn(),
        info: jest.fn(),
        warn: jest.fn(),
        error: jest.fn(),
        debug: jest.fn(),
      },
    });

    await runtime.registerProvider(
      resolveProviderConfig({
        enabled: true,
        enableNetworkTab: false,
        enableNativeNetwork: true,
      })
    );

    expect(networkCollector.enable).not.toHaveBeenCalled();
    expect(networkCollector.disable).toHaveBeenCalledTimes(1);
    expect(nativeModule.configure).toHaveBeenCalledWith(
      expect.objectContaining({
        enableNetworkTab: false,
        enableNativeLogs: false,
        enableNativeNetwork: false,
      })
    );
  });

  it('caps pending JS log batches to the configured log window', async () => {
    const nativeModule = {
      configure: jest.fn().mockResolvedValue(undefined),
      ingestBatch: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
    };
    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory: () => ({
        enable: jest.fn(),
        disable: jest.fn(),
        updateOptions: jest.fn(),
      }),
      consoleRef: {
        log: jest.fn(),
        info: jest.fn(),
        warn: jest.fn(),
        error: jest.fn(),
        debug: jest.fn(),
      },
    });

    await runtime.registerProvider(resolveProviderConfig({ enabled: true, maxLogs: 3 }));
    for (let index = 0; index < 6; index += 1) {
      console.log(`log-${index}`);
    }

    jest.advanceTimersByTime(BACKGROUND_FLUSH_DELAY_MS);
    await flushPromises();

    const [logs] = nativeModule.ingestBatch.mock.calls[0];
    expect(logs.map((entry: any[]) => entry[5])).toEqual(['log-3', 'log-4', 'log-5']);
  });

  it('skips redundant native reconfiguration when the resolved config does not change', async () => {
    const nativeModule = {
      configure: jest.fn().mockResolvedValue(undefined),
      ingestBatch: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
    };
    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory: () => ({
        enable: jest.fn(),
        disable: jest.fn(),
        updateOptions: jest.fn(),
      }),
      consoleRef: {
        log: jest.fn(),
        info: jest.fn(),
        warn: jest.fn(),
        error: jest.fn(),
        debug: jest.fn(),
      },
    });

    await runtime.registerProvider(
      resolveProviderConfig({
        enabled: true,
        maxLogs: 128,
        maxRequests: 32,
        androidNativeLogs: {
          enabled: true,
          buffers: ['main', 'crash'],
        },
      })
    );
    await runtime.registerProvider(
      resolveProviderConfig({
        enabled: true,
        maxLogs: 128,
        maxRequests: 32,
        androidNativeLogs: {
          enabled: true,
          buffers: ['main', 'crash'],
        },
      })
    );

    expect(nativeModule.configure).toHaveBeenCalledTimes(1);
    expect(nativeModule.show).not.toHaveBeenCalled();
    expect(nativeModule.hide).not.toHaveBeenCalled();
  });

  it('captures global errors and unhandled rejections', async () => {
    const nativeModule = {
      configure: jest.fn().mockResolvedValue(undefined),
      ingestBatch: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
    };
    let globalHandler: ((error: Error, isFatal?: boolean) => void) | null = null;
    const listeners = new Map<string, (event: unknown) => void>();

    (globalThis as any).ErrorUtils = {
      getGlobalHandler: () => null,
      setGlobalHandler: (handler: (error: Error, isFatal?: boolean) => void) => {
        globalHandler = handler;
      },
    };
    (globalThis as any).addEventListener = (type: string, handler: (event: unknown) => void) => {
      listeners.set(type, handler);
    };
    (globalThis as any).removeEventListener = (type: string) => {
      listeners.delete(type);
    };

    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory: () => ({
        enable: jest.fn(),
        disable: jest.fn(),
        updateOptions: jest.fn(),
      }),
      consoleRef: {
        log: jest.fn(),
        info: jest.fn(),
        warn: jest.fn(),
        error: jest.fn(),
        debug: jest.fn(),
      },
    });

    await runtime.registerProvider(resolveProviderConfig({ enabled: true }));
    const handler = globalHandler as ((error: Error, isFatal?: boolean) => void) | null;
    handler?.(new Error('fatal crash'), true);
    listeners.get('unhandledrejection')?.({ reason: 'promise failed' });
    jest.advanceTimersByTime(BACKGROUND_FLUSH_DELAY_MS);
    await flushPromises();

    const [logs, errors] = nativeModule.ingestBatch.mock.calls[0];
    const batch = { logs, errors };
    expect(batch.errors).toHaveLength(2);
    expect(batch.errors[0][1]).toBe('global');
    expect(batch.errors[1][1]).toBe('promise');
  });

  it('serializes native batch flushes without dropping queued entries', async () => {
    let resolveFirstFlush: (() => void) | undefined;
    const nativeModule = {
      configure: jest.fn().mockResolvedValue(undefined),
      ingestBatch: jest
        .fn()
        .mockImplementationOnce(
          () =>
            new Promise<void>((resolve) => {
              resolveFirstFlush = resolve;
            })
        )
        .mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
    };
    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory: () => ({
        enable: jest.fn(),
        disable: jest.fn(),
        updateOptions: jest.fn(),
      }),
      consoleRef: {
        log: jest.fn(),
        info: jest.fn(),
        warn: jest.fn(),
        error: jest.fn(),
        debug: jest.fn(),
      },
    });

    await runtime.registerProvider(resolveProviderConfig({ enabled: true }));
    runtime.log('log', ['first']);
    jest.advanceTimersByTime(BACKGROUND_FLUSH_DELAY_MS);
    await flushPromises();

    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);

    runtime.log('log', ['second']);
    jest.advanceTimersByTime(BACKGROUND_FLUSH_DELAY_MS);
    await flushPromises();

    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);

    if (resolveFirstFlush) {
      resolveFirstFlush();
    }
    await flushPromises();
    await flushPromises();

    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(2);
    expect(nativeModule.ingestBatch.mock.calls[1][0]).toHaveLength(1);
    expect(nativeModule.ingestBatch.mock.calls[1][0][0][5]).toBe('second');
  });

  it('coalesces repeated network updates for the same request within one buffered batch', async () => {
    const nativeModule = {
      configure: jest.fn().mockResolvedValue(undefined),
      ingestBatch: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
    };
    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory: () => ({
        enable: jest.fn(),
        disable: jest.fn(),
        updateOptions: jest.fn(),
      }),
      consoleRef: {
        log: jest.fn(),
        info: jest.fn(),
        warn: jest.fn(),
        error: jest.fn(),
        debug: jest.fn(),
      },
    });

    await runtime.registerProvider(resolveProviderConfig({ enabled: true }));
    runtime.captureNetwork({
      id: 'http_1',
      kind: 'http',
      method: 'GET',
      url: 'https://example.com',
      origin: 'js',
      state: 'pending',
      startedAt: 1,
      updatedAt: 1,
      requestHeaders: { accept: 'application/json' },
      responseHeaders: {},
    });
    runtime.captureNetwork({
      id: 'http_1',
      kind: 'http',
      method: 'GET',
      url: 'https://example.com',
      origin: 'js',
      state: 'success',
      startedAt: 1,
      updatedAt: 2,
      endedAt: 2,
      durationMs: 1,
      status: 200,
      requestHeaders: { accept: 'application/json' },
      responseHeaders: { 'content-type': 'application/json' },
      responseBody: '{"ok":true}',
    });

    jest.advanceTimersByTime(BACKGROUND_FLUSH_DELAY_MS);
    await flushPromises();

    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);
    const [logs, errors, network] = nativeModule.ingestBatch.mock.calls[0];
    const batch = { logs, errors, network };
    expect(batch.network).toHaveLength(1);
    expect(batch.network[0][5]).toBe('success');
    expect(batch.network[0][10]).toBe(200);
    expect(batch.network[0][11]).toEqual(['accept', 'application/json']);
    expect(batch.network[0][12]).toEqual(['content-type', 'application/json']);
    expect(batch.network[0][14]).toBe('{"ok":true}');
    expect(typeof batch.network[0][32]).toBe('number');
  });

  it('keeps full network previews while the Network panel is active', async () => {
    let panelStateListener: ((event: { panelVisible?: boolean; activeFeed?: string }) => void) | undefined;
    const nativeModule = {
      configure: jest.fn().mockResolvedValue(undefined),
      ingestBatch: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
      addListener: jest.fn((_eventName, listener) => {
        panelStateListener = listener;
        return { remove: jest.fn() };
      }),
    };
    const runtime = new DebugRuntime({
      nativeModule,
      networkFactory: () => ({
        enable: jest.fn(),
        disable: jest.fn(),
        updateOptions: jest.fn(),
      }),
      consoleRef: {
        log: jest.fn(),
        info: jest.fn(),
        warn: jest.fn(),
        error: jest.fn(),
        debug: jest.fn(),
      },
    });

    await runtime.registerProvider(resolveProviderConfig({ enabled: true }));
    panelStateListener?.({ panelVisible: true, activeFeed: 'network' });
    runtime.captureNetwork({
      id: 'http_full',
      kind: 'http',
      method: 'POST',
      url: 'https://example.com/full',
      origin: 'js',
      state: 'success',
      startedAt: 1,
      updatedAt: 2,
      endedAt: 2,
      durationMs: 1,
      status: 200,
      requestBody: '{"name":"debug"}',
      responseBody: '{"ok":true}',
      messages: '>> hello',
    });

    jest.advanceTimersByTime(ACTIVE_FLUSH_DELAY_MS);
    await flushPromises();

    const network = nativeModule.ingestBatch.mock.calls[0][2];
    expect(network).toHaveLength(1);
    expect(network[0][13]).toBe('{"name":"debug"}');
    expect(network[0][14]).toBe('{"ok":true}');
    expect(network[0][31]).toBe('>> hello');
  });
});
