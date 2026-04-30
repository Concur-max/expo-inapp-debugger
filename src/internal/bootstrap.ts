import { enableDebugRuntime } from './singleton';

const GLOBAL_BOOTSTRAP_KEY = '__EXPO_IN_APP_DEBUGGER_BOOTSTRAP__';

export type InAppDebugBootstrapConfig = {
  enabled?: boolean | (() => boolean);
};

type BootstrapGlobal = typeof globalThis & {
  [GLOBAL_BOOTSTRAP_KEY]?: InAppDebugBootstrapConfig;
};

export function configureInAppDebugBootstrap(config: InAppDebugBootstrapConfig) {
  const globalScope = globalThis as BootstrapGlobal;
  globalScope[GLOBAL_BOOTSTRAP_KEY] = {
    ...(globalScope[GLOBAL_BOOTSTRAP_KEY] ?? {}),
    ...config,
  };
}

export function maybeEnableInAppDebugFromBootstrap() {
  const globalScope = globalThis as BootstrapGlobal;
  const enabled = globalScope[GLOBAL_BOOTSTRAP_KEY]?.enabled;
  const shouldEnable = typeof enabled === 'function' ? enabled() : enabled === true;

  if (shouldEnable) {
    void enableDebugRuntime();
  }
}
