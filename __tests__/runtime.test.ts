import { DebugRuntime, formatMessage, resolveProviderConfig } from '../src/internal/runtime';

jest.useFakeTimers();

function flushPromises() {
  return Promise.resolve().then(() => undefined);
}

describe('formatMessage', () => {
  it('formats objects and strings', () => {
    expect(formatMessage(['hello', { value: 1 }])).toContain('"value":1');
  });
});

describe('resolveProviderConfig', () => {
  it('defaults to disabled until explicitly enabled', () => {
    expect(resolveProviderConfig({}).enabled).toBe(false);
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
    console.log('hello');
    console.info('details');
    console.error('boom');

    jest.advanceTimersByTime(63);
    await flushPromises();
    expect(nativeModule.ingestBatch).not.toHaveBeenCalled();

    jest.advanceTimersByTime(1);
    await flushPromises();

    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);
    expect(consoleRef.info).toHaveBeenCalledWith('details');
    const [batch] = nativeModule.ingestBatch.mock.calls[0];
    expect(batch.logs).toHaveLength(3);
    expect(batch.errors).toHaveLength(1);
    expect(batch.network).toBeUndefined();
    expect(batch.logs[0][5]).toBe('hello');
    expect(batch.errors[0][1]).toBe('console');

    await runtime.disable();
    console.log('after disable');
    jest.advanceTimersByTime(32);
    await flushPromises();
    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);
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
    jest.advanceTimersByTime(64);
    await flushPromises();

    const [batch] = nativeModule.ingestBatch.mock.calls[0];
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
    jest.advanceTimersByTime(64);
    await flushPromises();

    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);

    runtime.log('log', ['second']);
    jest.advanceTimersByTime(64);
    await flushPromises();

    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);

    if (resolveFirstFlush) {
      resolveFirstFlush();
    }
    await flushPromises();
    await flushPromises();

    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(2);
    expect(nativeModule.ingestBatch.mock.calls[1][0].logs).toHaveLength(1);
    expect(nativeModule.ingestBatch.mock.calls[1][0].logs[0][5]).toBe('second');
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
      requestHeaders: {},
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
      requestHeaders: {},
      responseHeaders: {},
      responseBody: '{"ok":true}',
    });

    jest.advanceTimersByTime(64);
    await flushPromises();

    expect(nativeModule.ingestBatch).toHaveBeenCalledTimes(1);
    const [batch] = nativeModule.ingestBatch.mock.calls[0];
    expect(batch.network).toHaveLength(1);
    expect(batch.network[0][5]).toBe('success');
    expect(batch.network[0][10]).toBe(200);
  });
});
