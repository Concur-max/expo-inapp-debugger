import type { ResolvedInAppDebugConfig } from '../types';
import type { DebugRuntime as DebugRuntimeInstance } from './runtime';

type RuntimeModule = typeof import('./runtime');
type NativeModule = typeof import('../InAppDebugModule');

let debugRuntime: DebugRuntimeInstance | null = null;
let pendingProviderConfig: ResolvedInAppDebugConfig | null = null;

export function getDebugRuntime() {
  if (!debugRuntime) {
    const { DebugRuntime } = require('./runtime') as RuntimeModule;
    const { InAppDebugNativeModule } = require('../InAppDebugModule') as NativeModule;
    debugRuntime = new DebugRuntime({
      nativeModule: InAppDebugNativeModule,
    });

    if (pendingProviderConfig) {
      debugRuntime.primeProviderConfig(pendingProviderConfig);
    }
  }

  return debugRuntime;
}

export function getDebugRuntimeIfCreated() {
  return debugRuntime;
}

export async function registerProviderConfig(config: ResolvedInAppDebugConfig) {
  pendingProviderConfig = config;
  if (!config.enabled && !debugRuntime) {
    return;
  }

  await getDebugRuntime().registerProvider(config);
}

export async function unregisterProviderConfig() {
  pendingProviderConfig = null;
  if (debugRuntime) {
    await debugRuntime.unregisterProvider();
  }
}

export async function enableDebugRuntime() {
  const runtime = getDebugRuntime();
  if (pendingProviderConfig) {
    runtime.primeProviderConfig(pendingProviderConfig);
  }
  await runtime.enable();
}

export async function disableDebugRuntime() {
  if (debugRuntime) {
    await debugRuntime.disable();
  }
}
