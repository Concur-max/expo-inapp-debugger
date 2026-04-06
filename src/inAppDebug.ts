import type { DebugErrorSource, DebugLevel } from './types';
import { debugRuntime } from './internal/singleton';

export const inAppDebug = {
  log(level: DebugLevel, ...args: unknown[]) {
    debugRuntime.log(level, args);
  },
  captureError(source: DebugErrorSource, ...args: unknown[]) {
    debugRuntime.captureError(source, args);
  },
};
