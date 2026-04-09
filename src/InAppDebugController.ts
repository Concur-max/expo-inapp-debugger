import type { AndroidNativeLogsConfig, DebugSnapshot } from './types';
import { debugRuntime } from './internal/singleton';

export const InAppDebugController = {
  show() {
    return debugRuntime.show();
  },
  hide() {
    return debugRuntime.hide();
  },
  enable() {
    return debugRuntime.enable();
  },
  disable() {
    return debugRuntime.disable();
  },
  clear(kind: 'logs' | 'errors' | 'network' | 'all' = 'all') {
    return debugRuntime.clear(kind);
  },
  exportSnapshot(): Promise<DebugSnapshot> {
    return debugRuntime.exportSnapshot();
  },
  configureAndroidNativeLogs(options: Partial<AndroidNativeLogsConfig>) {
    return debugRuntime.configureAndroidNativeLogs(options);
  },
};
