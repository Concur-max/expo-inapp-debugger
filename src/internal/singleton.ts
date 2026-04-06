import { InAppDebugNativeModule } from '../InAppDebugModule';
import { DebugRuntime } from './runtime';

export const debugRuntime = new DebugRuntime({
  nativeModule: InAppDebugNativeModule,
});
