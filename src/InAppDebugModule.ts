import { requireOptionalNativeModule } from 'expo-modules-core';
import type { DebugSnapshot, InAppDebugStrings, ResolvedAndroidNativeLogsConfig } from './types';

export type NativeLogWireEntry = [
  id: string,
  type: string,
  origin: string,
  context: string | null,
  details: string | null,
  message: string,
  timestamp: string,
  fullTimestamp: string,
];

export type NativeErrorWireEntry = [
  id: string,
  source: string,
  message: string,
  timestamp: string,
  fullTimestamp: string,
];

export type NativeNetworkWireEntry = [
  id: string,
  kind: string,
  method: string,
  url: string,
  origin: string,
  state: string,
  startedAt: number,
  updatedAt: number,
  endedAt: number | null,
  durationMs: number | null,
  status: number | null,
  requestHeaders: Record<string, unknown> | null,
  responseHeaders: Record<string, unknown> | null,
  requestBody: string | null,
  responseBody: string | null,
  responseType: string | null,
  responseContentType: string | null,
  responseSize: number | null,
  error: string | null,
  protocol: string | null,
  requestedProtocols: string | null,
  closeReason: string | null,
  closeCode: number | null,
  requestedCloseCode: number | null,
  requestedCloseReason: string | null,
  cleanClose: boolean | null,
  messageCountIn: number | null,
  messageCountOut: number | null,
  bytesIn: number | null,
  bytesOut: number | null,
  events: string | null,
  messages: string | null,
];

export type NativeBatchPayload = {
  logs?: NativeLogWireEntry[];
  errors?: NativeErrorWireEntry[];
  network?: NativeNetworkWireEntry[];
};

export type NativeConfig = {
  enabled: boolean;
  initialVisible: boolean;
  enableNetworkTab: boolean;
  maxLogs: number;
  maxErrors: number;
  maxRequests: number;
  androidNativeLogs: ResolvedAndroidNativeLogsConfig;
  locale: string;
  strings: InAppDebugStrings;
};

export type InAppDebugNativeModuleType = {
  configure(config: NativeConfig): Promise<void>;
  ingestBatch(batch: NativeBatchPayload): Promise<void>;
  clear(kind: 'logs' | 'errors' | 'network' | 'all'): Promise<void>;
  show(): Promise<void>;
  hide(): Promise<void>;
  exportSnapshot(): Promise<DebugSnapshot>;
};

const fallbackModule: InAppDebugNativeModuleType = {
  async configure() {},
  async ingestBatch() {},
  async clear() {},
  async show() {},
  async hide() {},
  async exportSnapshot() {
    return {
      logs: [],
      errors: [],
      network: [],
      exportTime: new Date().toISOString(),
    };
  },
};

export const InAppDebugNativeModule =
  requireOptionalNativeModule<InAppDebugNativeModuleType>('InAppDebugger') ?? fallbackModule;
