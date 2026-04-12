describe('package entry lazy loading', () => {
  afterEach(() => {
    jest.resetModules();
    jest.clearAllMocks();
  });

  it('does not load public implementations until first use', async () => {
    const providerImpl = jest.fn(() => null);
    const providerFactory = jest.fn(() => ({
      InAppDebugProvider: providerImpl,
    }));
    const boundaryFactory = jest.fn(() => ({
      InAppDebugBoundary: jest.fn(() => null),
    }));
    const controllerImpl = {
      show: jest.fn().mockResolvedValue(undefined),
      hide: jest.fn().mockResolvedValue(undefined),
      enable: jest.fn().mockResolvedValue(undefined),
      disable: jest.fn().mockResolvedValue(undefined),
      clear: jest.fn().mockResolvedValue(undefined),
      exportSnapshot: jest.fn().mockResolvedValue(null),
      configureAndroidNativeLogs: jest.fn().mockResolvedValue(undefined),
    };
    const controllerFactory = jest.fn(() => ({
      InAppDebugController: controllerImpl,
    }));
    const inAppDebugImpl = {
      log: jest.fn(),
      captureError: jest.fn(),
    };
    const inAppDebugFactory = jest.fn(() => ({
      inAppDebug: inAppDebugImpl,
    }));

    jest.doMock('../src/InAppDebugProvider', providerFactory);
    jest.doMock('../src/InAppDebugBoundary', boundaryFactory);
    jest.doMock('../src/InAppDebugController', controllerFactory);
    jest.doMock('../src/inAppDebug', inAppDebugFactory);

    let entry!: typeof import('../src/index');
    jest.isolateModules(() => {
      entry = require('../src/index') as typeof import('../src/index');
    });

    expect(providerFactory).not.toHaveBeenCalled();
    expect(boundaryFactory).not.toHaveBeenCalled();
    expect(controllerFactory).not.toHaveBeenCalled();
    expect(inAppDebugFactory).not.toHaveBeenCalled();

    await entry.InAppDebugController.enable();
    expect(controllerFactory).toHaveBeenCalledTimes(1);
    expect(controllerImpl.enable).toHaveBeenCalledTimes(1);
    expect(providerFactory).not.toHaveBeenCalled();
    expect(boundaryFactory).not.toHaveBeenCalled();
    expect(inAppDebugFactory).not.toHaveBeenCalled();

    entry.inAppDebug.log('info', 'hello');
    expect(inAppDebugFactory).toHaveBeenCalledTimes(1);
    expect(inAppDebugImpl.log).toHaveBeenCalledWith('info', 'hello');
    expect(providerFactory).not.toHaveBeenCalled();
    expect(boundaryFactory).not.toHaveBeenCalled();

    entry.InAppDebugProvider({ enabled: false, children: null });
    expect(providerFactory).toHaveBeenCalledTimes(1);
    expect(providerImpl).not.toHaveBeenCalled();
    expect(boundaryFactory).not.toHaveBeenCalled();
  });
});
