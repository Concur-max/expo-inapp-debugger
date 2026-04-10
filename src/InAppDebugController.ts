import type { AndroidNativeLogsConfig, DebugSnapshot } from './types';
import { disableDebugRuntime, enableDebugRuntime, getDebugRuntime } from './internal/singleton';

export const InAppDebugController = {
  show() {
    return getDebugRuntime().show();
  },
  hide() {
    return getDebugRuntime().hide();
  },
  enable() {
    return enableDebugRuntime();
  },
  disable() {
    return disableDebugRuntime();
  },
  clear(kind: 'logs' | 'errors' | 'network' | 'all' = 'all') {
    return getDebugRuntime().clear(kind);
  },
  exportSnapshot(): Promise<DebugSnapshot> {
    return getDebugRuntime().exportSnapshot();
  },
  configureAndroidNativeLogs(options: Partial<AndroidNativeLogsConfig>) {
    return getDebugRuntime().configureAndroidNativeLogs(options);
  },
};
