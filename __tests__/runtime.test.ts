import { DebugRuntime, formatMessage, resolveProviderConfig } from '../src/internal/runtime';

jest.useFakeTimers();

function flushPromises() {
  return Promise.resolve().then(() => undefined);
}

describe('formatMessage', () => {
  it('formats objects and strings', () => {
    expect(formatMessage(['hello', { value: 1 }])).toContain('"value": 1');
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
    expect(batch).toHaveLength(4);
    expect(batch[0].category).toBe('log');
    expect(batch[1].category).toBe('log');
    expect(batch[2].category).toBe('log');
    expect(batch[3].category).toBe('error');

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
    expect(batch).toHaveLength(2);
    expect(batch[0].entry.source).toBe('global');
    expect(batch[1].entry.source).toBe('promise');
  });
});
