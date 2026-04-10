import type { DebugErrorSource, DebugLevel } from './types';
import { getDebugRuntimeIfCreated } from './internal/singleton';

export const inAppDebug = {
  log(level: DebugLevel, ...args: unknown[]) {
    getDebugRuntimeIfCreated()?.log(level, args);
  },
  captureError(source: DebugErrorSource, ...args: unknown[]) {
    getDebugRuntimeIfCreated()?.captureError(source, args);
  },
};
