describe('setup entry', () => {
  afterEach(() => {
    jest.resetModules();
    jest.clearAllMocks();
    delete (globalThis as any).__EXPO_IN_APP_DEBUGGER_BOOTSTRAP__;
  });

  it('does not enable the debug runtime by default', () => {
    const enableDebugRuntime = jest.fn().mockResolvedValue(undefined);

    jest.doMock('../src/internal/singleton', () => ({
      enableDebugRuntime,
    }));

    jest.isolateModules(() => {
      require('../setup');
    });

    expect(enableDebugRuntime).not.toHaveBeenCalled();
  });

  it('enables the debug runtime when bootstrap state is true', () => {
    const enableDebugRuntime = jest.fn().mockResolvedValue(undefined);

    jest.doMock('../src/internal/singleton', () => ({
      enableDebugRuntime,
    }));

    jest.isolateModules(() => {
      const bootstrap = require('../src/internal/bootstrap') as typeof import('../src/internal/bootstrap');
      bootstrap.configureInAppDebugBootstrap({ enabled: true });
      require('../setup');
    });

    expect(enableDebugRuntime).toHaveBeenCalledTimes(1);
  });

  it('supports synchronous bootstrap predicates', () => {
    const enableDebugRuntime = jest.fn().mockResolvedValue(undefined);

    jest.doMock('../src/internal/singleton', () => ({
      enableDebugRuntime,
    }));

    jest.isolateModules(() => {
      const bootstrap = require('../src/internal/bootstrap') as typeof import('../src/internal/bootstrap');
      bootstrap.configureInAppDebugBootstrap({ enabled: () => true });
      require('../setup');
    });

    expect(enableDebugRuntime).toHaveBeenCalledTimes(1);
  });
});
