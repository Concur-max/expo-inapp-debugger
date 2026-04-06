import { requireOptionalNativeModule } from 'expo-modules-core';
import type { DebugSnapshot, InAppDebugStrings } from './types';

export type NativeBatchEntry =
  | {
      category: 'log';
      entry: Record<string, unknown>;
    }
  | {
      category: 'error';
      entry: Record<string, unknown>;
    }
  | {
      category: 'network';
      entry: Record<string, unknown>;
    };

export type NativeConfig = {
  enabled: boolean;
  initialVisible: boolean;
  enableNetworkTab: boolean;
  maxLogs: number;
  maxErrors: number;
  maxRequests: number;
  locale: string;
  strings: InAppDebugStrings;
};

export type InAppDebugNativeModuleType = {
  configure(config: NativeConfig): Promise<void>;
  ingestBatch(batch: NativeBatchEntry[]): Promise<void>;
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
