import { resolveProviderConfig } from '../src/internal/config';

describe('singleton ownership of enabled state', () => {
  afterEach(() => {
    jest.resetModules();
    jest.clearAllMocks();
  });

  it('lets provider config disable a runtime that was enabled imperatively before mount', async () => {
    const runtime = {
      primeProviderConfig: jest.fn(),
      registerProvider: jest.fn().mockResolvedValue(undefined),
      unregisterProvider: jest.fn().mockResolvedValue(undefined),
    };
    const DebugRuntime = jest.fn(() => runtime);

    jest.doMock('../src/internal/runtime', () => ({
      DebugRuntime,
    }));
    jest.doMock('../src/InAppDebugModule', () => ({
      InAppDebugNativeModule: {},
    }));

    let singleton!: typeof import('../src/internal/singleton');
    jest.isolateModules(() => {
      singleton = require('../src/internal/singleton') as typeof import('../src/internal/singleton');
    });

    await singleton.enableDebugRuntime();
    expect(DebugRuntime).toHaveBeenCalledTimes(1);
    expect(runtime.registerProvider).toHaveBeenCalledTimes(1);
    expect(runtime.registerProvider.mock.calls[0][0].enabled).toBe(true);

    await singleton.registerProviderConfig(resolveProviderConfig({ enabled: false }));
    expect(runtime.registerProvider).toHaveBeenCalledTimes(2);
    expect(runtime.registerProvider.mock.calls[1][0].enabled).toBe(false);
  });

  it('ignores imperative enable and disable while a provider is mounted', async () => {
    const runtime = {
      primeProviderConfig: jest.fn(),
      registerProvider: jest.fn().mockResolvedValue(undefined),
      unregisterProvider: jest.fn().mockResolvedValue(undefined),
    };
    const DebugRuntime = jest.fn(() => runtime);

    jest.doMock('../src/internal/runtime', () => ({
      DebugRuntime,
    }));
    jest.doMock('../src/InAppDebugModule', () => ({
      InAppDebugNativeModule: {},
    }));

    let singleton!: typeof import('../src/internal/singleton');
    jest.isolateModules(() => {
      singleton = require('../src/internal/singleton') as typeof import('../src/internal/singleton');
    });

    await singleton.registerProviderConfig(resolveProviderConfig({ enabled: false }));
    await singleton.enableDebugRuntime();
    await singleton.disableDebugRuntime();

    expect(DebugRuntime).not.toHaveBeenCalled();
  });
});
