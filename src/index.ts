export type {
  InAppDebugBoundaryProps,
  InAppDebugProviderProps,
  InAppDebugRootProps,
} from './types';
export type {
  AndroidLogcatBuffer,
  AndroidLogcatScope,
  AndroidNativeLogsConfig,
  AndroidRootLogMode,
  DebugErrorEntry,
  DebugErrorSource,
  DebugLevel,
  DebugLogEntry,
  DebugNetworkEntry,
  DebugNetworkKind,
  DebugNetworkState,
  DebugSnapshot,
  InAppDebugStrings,
  SupportedLocale,
} from './types';

type ReactModule = typeof import('react');
type InAppDebugProviderComponent = typeof import('./InAppDebugProvider').InAppDebugProvider;
type InAppDebugBoundaryComponent = typeof import('./InAppDebugBoundary').InAppDebugBoundary;
type InAppDebugControllerApi = typeof import('./InAppDebugController').InAppDebugController;
type InAppDebugApi = typeof import('./inAppDebug').inAppDebug;
type BootstrapConfig = import('./internal/bootstrap').InAppDebugBootstrapConfig;

let reactModule: ReactModule | null = null;
let inAppDebugProviderImpl: InAppDebugProviderComponent | null = null;
let inAppDebugBoundaryImpl: InAppDebugBoundaryComponent | null = null;
let inAppDebugControllerImpl: InAppDebugControllerApi | null = null;
let inAppDebugImpl: InAppDebugApi | null = null;

function loadReact() {
  if (!reactModule) {
    reactModule = require('react') as ReactModule;
  }
  return reactModule;
}

function loadInAppDebugProvider() {
  if (!inAppDebugProviderImpl) {
    ({ InAppDebugProvider: inAppDebugProviderImpl } = require('./InAppDebugProvider') as typeof import('./InAppDebugProvider'));
  }
  return inAppDebugProviderImpl;
}

function loadInAppDebugBoundary() {
  if (!inAppDebugBoundaryImpl) {
    ({ InAppDebugBoundary: inAppDebugBoundaryImpl } = require('./InAppDebugBoundary') as typeof import('./InAppDebugBoundary'));
  }
  return inAppDebugBoundaryImpl;
}

function loadInAppDebugController() {
  if (!inAppDebugControllerImpl) {
    ({ InAppDebugController: inAppDebugControllerImpl } = require('./InAppDebugController') as typeof import('./InAppDebugController'));
  }
  return inAppDebugControllerImpl;
}

function loadInAppDebug() {
  if (!inAppDebugImpl) {
    ({ inAppDebug: inAppDebugImpl } = require('./inAppDebug') as typeof import('./inAppDebug'));
  }
  return inAppDebugImpl;
}

export function InAppDebugProvider(props: import('./types').InAppDebugProviderProps) {
  return loadReact().createElement(loadInAppDebugProvider(), props);
}

InAppDebugProvider.displayName = 'InAppDebugProvider';

export function InAppDebugBoundary(props: import('./types').InAppDebugBoundaryProps) {
  return loadReact().createElement(loadInAppDebugBoundary(), props);
}

InAppDebugBoundary.displayName = 'InAppDebugBoundary';

export function InAppDebugRoot(props: import('./types').InAppDebugRootProps) {
  const React = loadReact();
  const { children, onError, fallback, showDebugInfo, ...providerProps } = props;

  return React.createElement(
    loadInAppDebugProvider(),
    providerProps as import('./types').InAppDebugProviderProps,
    React.createElement(loadInAppDebugBoundary(), {
      children,
      onError,
      fallback,
      showDebugInfo,
    })
  );
}

InAppDebugRoot.displayName = 'InAppDebugRoot';

export const InAppDebugController: InAppDebugControllerApi = {
  show() {
    return loadInAppDebugController().show();
  },
  hide() {
    return loadInAppDebugController().hide();
  },
  enable() {
    return loadInAppDebugController().enable();
  },
  disable() {
    return loadInAppDebugController().disable();
  },
  clear(kind = 'all') {
    return loadInAppDebugController().clear(kind);
  },
  exportSnapshot() {
    return loadInAppDebugController().exportSnapshot();
  },
  configureAndroidNativeLogs(options) {
    return loadInAppDebugController().configureAndroidNativeLogs(options);
  },
};

export const inAppDebug: InAppDebugApi = {
  log(level, ...args) {
    return loadInAppDebug().log(level, ...args);
  },
  captureError(source, ...args) {
    return loadInAppDebug().captureError(source, ...args);
  },
};

export function configureInAppDebugBootstrap(config: BootstrapConfig) {
  const { configureInAppDebugBootstrap: configure } = require('./internal/bootstrap') as typeof import('./internal/bootstrap');
  configure(config);
}
