import type { ResolvedInAppDebugConfig } from '../types';
import { resolveProviderConfig } from './config';
import type { DebugRuntime as DebugRuntimeInstance } from './runtime';

type RuntimeModule = typeof import('./runtime');
type NativeModule = typeof import('../InAppDebugModule');

let debugRuntime: DebugRuntimeInstance | null = null;
let pendingProviderConfig: ResolvedInAppDebugConfig | null = null;
let providerRegistered = false;

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
  providerRegistered = true;
  pendingProviderConfig = config;
  if (!config.enabled && !debugRuntime) {
    return;
  }

  await getDebugRuntime().registerProvider(config);
}

export async function unregisterProviderConfig() {
  providerRegistered = false;
  pendingProviderConfig = null;
  if (debugRuntime) {
    await debugRuntime.unregisterProvider();
  }
}

export async function enableDebugRuntime() {
  if (providerRegistered) {
    return;
  }

  const nextConfig = {
    ...(pendingProviderConfig ?? resolveProviderConfig({})),
    enabled: true,
  };
  pendingProviderConfig = nextConfig;
  await getDebugRuntime().registerProvider(nextConfig);
}

export async function disableDebugRuntime() {
  if (providerRegistered) {
    return;
  }

  const nextConfig = {
    ...(pendingProviderConfig ?? resolveProviderConfig({})),
    enabled: false,
  };
  pendingProviderConfig = nextConfig;
  if (debugRuntime) {
    await debugRuntime.registerProvider(nextConfig);
  }
}
