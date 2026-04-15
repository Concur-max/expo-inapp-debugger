import { requireOptionalNativeModule } from 'expo-modules-core';

export type NativeRequestMethod = 'GET' | 'POST';

export type NativeRequestOptions = {
  url: string;
  method?: NativeRequestMethod;
  body?: string;
  headers?: Record<string, string>;
};

type NativeRequestTriggerModuleType = {
  sendHttpRequest(options: NativeRequestOptions): Promise<void>;
};

const NativeRequestTriggerModule =
  requireOptionalNativeModule<NativeRequestTriggerModuleType>('NativeRequestTrigger');

function getModule() {
  if (!NativeRequestTriggerModule) {
    throw new Error(
      'NativeRequestTrigger is unavailable. Rebuild the example app so the local Expo module is autolinked.'
    );
  }
  return NativeRequestTriggerModule;
}

export const NativeRequestTrigger = {
  sendHttpRequest(options: NativeRequestOptions) {
    const method = options.method?.toUpperCase() as NativeRequestMethod | undefined;
    return getModule().sendHttpRequest({
      ...options,
      method,
    });
  },
};
