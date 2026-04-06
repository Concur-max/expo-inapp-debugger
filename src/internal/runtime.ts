import type { NativeConfig, NativeBatchEntry } from '../InAppDebugModule';
import type {
  DebugErrorEntry,
  DebugErrorSource,
  DebugLevel,
  DebugLogEntry,
  DebugNetworkEntry,
  InAppDebugStrings,
  ResolvedInAppDebugConfig,
} from '../types';
import { defaultStrings, resolveStrings } from './strings';
import { NetworkCollector } from './network';

type ConsoleLike = Pick<typeof console, 'log' | 'info' | 'warn' | 'error' | 'debug'>;

type ConsoleMethods = {
  [K in keyof ConsoleLike]: ConsoleLike[K];
};

type ErrorUtilsHandler = (error: Error, isFatal?: boolean) => void;

type ErrorUtilsShape = {
  getGlobalHandler?: () => ErrorUtilsHandler | null | undefined;
  setGlobalHandler?: (handler: ErrorUtilsHandler) => void;
};

type RuntimeGlobal = typeof globalThis & {
  ErrorUtils?: ErrorUtilsShape;
  addEventListener?: (type: string, handler: (event: unknown) => void) => void;
  removeEventListener?: (type: string, handler: (event: unknown) => void) => void;
};

type RuntimeNativeModule = {
  configure(config: NativeConfig): Promise<void>;
  ingestBatch(batch: NativeBatchEntry[]): Promise<void>;
  clear(kind: 'logs' | 'errors' | 'network' | 'all'): Promise<void>;
  show(): Promise<void>;
  hide(): Promise<void>;
  exportSnapshot(): Promise<any>;
};

export type DebugRuntimeDependencies = {
  nativeModule: RuntimeNativeModule;
  now?: () => number;
  setTimeoutFn?: typeof setTimeout;
  clearTimeoutFn?: typeof clearTimeout;
  consoleRef?: ConsoleLike;
  networkFactory?: (options: {
    maxRequests: number;
    onEntry: (entry: DebugNetworkEntry) => void;
    onInternalWarning?: (message: string, error?: unknown) => void;
  }) => { enable(): void; disable(): void; updateOptions(options: { maxRequests: number }): void };
};

function createId(nowValue: number) {
  return `${nowValue}_${Math.random().toString(36).slice(2, 10)}`;
}

export function formatMessage(args: unknown[]) {
  return args
    .map((arg) => {
      if (typeof arg === 'string') {
        return arg;
      }
      if (typeof arg === 'object' && arg != null) {
        try {
          return JSON.stringify(arg, null, 2);
        } catch {
          return String(arg);
        }
      }
      return String(arg);
    })
    .join(' ');
}

function formatTimestamps(nowValue: number) {
  const date = new Date(nowValue);
  return {
    timestamp: date.toLocaleTimeString(),
    fullTimestamp: date.toISOString(),
  };
}

function toNativeConfig(config: ResolvedInAppDebugConfig): NativeConfig {
  return {
    enabled: config.enabled,
    initialVisible: config.initialVisible,
    enableNetworkTab: config.enableNetworkTab,
    maxLogs: config.maxLogs,
    maxErrors: config.maxErrors,
    maxRequests: config.maxRequests,
    locale: config.locale,
    strings: config.strings,
  };
}

export function resolveProviderConfig(input: {
  enabled?: boolean;
  initialVisible?: boolean;
  enableNetworkTab?: boolean;
  maxLogs?: number;
  maxErrors?: number;
  maxRequests?: number;
  locale?: 'auto' | 'en-US' | 'zh-CN' | 'zh-TW' | 'ja';
  strings?: Partial<InAppDebugStrings>;
}): ResolvedInAppDebugConfig {
  const resolved = resolveStrings(input.locale ?? 'zh-CN', input.strings);
  const defaultEnabled = typeof __DEV__ !== 'undefined' ? __DEV__ : false;
  return {
    enabled: input.enabled ?? defaultEnabled,
    initialVisible: input.initialVisible ?? true,
    enableNetworkTab: input.enableNetworkTab ?? true,
    maxLogs: input.maxLogs ?? 2000,
    maxErrors: input.maxErrors ?? 100,
    maxRequests: input.maxRequests ?? 100,
    locale: resolved.locale,
    strings: resolved.strings,
  };
}

export class DebugRuntime {
  private readonly now: () => number;
  private readonly setTimeoutFn: typeof setTimeout;
  private readonly clearTimeoutFn: typeof clearTimeout;
  private readonly originalConsole: ConsoleMethods;
  private readonly networkCollector: {
    enable(): void;
    disable(): void;
    updateOptions(options: { maxRequests: number }): void;
  };
  private providerConfig: ResolvedInAppDebugConfig = {
    enabled: false,
    initialVisible: true,
    enableNetworkTab: true,
    maxLogs: 2000,
    maxErrors: 100,
    maxRequests: 100,
    locale: 'zh-CN',
    strings: defaultStrings,
  };
  private manualEnabledOverride: boolean | null = null;
  private queue: NativeBatchEntry[] = [];
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private configured = false;
  private consolePatched = false;
  private originalGlobalHandler: ErrorUtilsHandler | null = null;
  private unhandledRejectionHandler: ((event: unknown) => void) | null = null;

  constructor(private readonly dependencies: DebugRuntimeDependencies) {
    this.now = dependencies.now ?? Date.now;
    this.setTimeoutFn = dependencies.setTimeoutFn ?? setTimeout;
    this.clearTimeoutFn = dependencies.clearTimeoutFn ?? clearTimeout;
    const consoleRef = dependencies.consoleRef ?? console;
    this.originalConsole = {
      log: consoleRef.log.bind(consoleRef),
      info: consoleRef.info.bind(consoleRef),
      warn: consoleRef.warn.bind(consoleRef),
      error: consoleRef.error.bind(consoleRef),
      debug: consoleRef.debug.bind(consoleRef),
    };
    this.networkCollector =
      dependencies.networkFactory?.({
        maxRequests: this.providerConfig.maxRequests,
        onEntry: (entry) => this.captureNetwork(entry),
        onInternalWarning: (message, error) => this.internalWarn(message, error),
      }) ??
      new NetworkCollector({
        maxRequests: this.providerConfig.maxRequests,
        onEntry: (entry) => this.captureNetwork(entry),
        onInternalWarning: (message, error) => this.internalWarn(message, error),
      });
  }

  async registerProvider(config: ResolvedInAppDebugConfig) {
    this.providerConfig = config;
    this.networkCollector.updateOptions({ maxRequests: config.maxRequests });
    await this.applyConfig();
  }

  async unregisterProvider() {
    this.manualEnabledOverride = null;
    this.providerConfig = {
      ...this.providerConfig,
      enabled: false,
    };
    await this.applyConfig();
  }

  async enable() {
    this.manualEnabledOverride = true;
    await this.applyConfig();
  }

  async disable() {
    this.manualEnabledOverride = false;
    await this.applyConfig();
  }

  async show() {
    await this.dependencies.nativeModule.show();
  }

  async hide() {
    await this.dependencies.nativeModule.hide();
  }

  async clear(kind: 'logs' | 'errors' | 'network' | 'all' = 'all') {
    await this.dependencies.nativeModule.clear(kind);
  }

  async exportSnapshot() {
    return this.dependencies.nativeModule.exportSnapshot();
  }

  log(level: DebugLevel, args: unknown[]) {
    const nowValue = this.now();
    const entry: DebugLogEntry = {
      id: createId(nowValue),
      type: level,
      message: formatMessage(args),
      ...formatTimestamps(nowValue),
    };
    this.enqueue({
      category: 'log',
      entry,
    });
    if (level === 'error') {
      this.captureError('console', args);
    }
  }

  captureError(source: DebugErrorSource, args: unknown[]) {
    const nowValue = this.now();
    const entry: DebugErrorEntry = {
      id: createId(nowValue),
      source,
      message: formatMessage(args),
      ...formatTimestamps(nowValue),
    };
    this.enqueue({
      category: 'error',
      entry,
    });
  }

  captureNetwork(entry: DebugNetworkEntry) {
    this.enqueue({
      category: 'network',
      entry,
    });
  }

  private async applyConfig() {
    const resolvedEnabled = this.manualEnabledOverride ?? this.providerConfig.enabled;
    const nextConfig = {
      ...this.providerConfig,
      enabled: resolvedEnabled,
    };

    await this.dependencies.nativeModule.configure(toNativeConfig(nextConfig));
    this.configured = true;

    if (resolvedEnabled) {
      this.installCollectors();
      if (nextConfig.initialVisible) {
        await this.dependencies.nativeModule.show();
      } else {
        await this.dependencies.nativeModule.hide();
      }
      return;
    }

    this.removeCollectors();
    await this.dependencies.nativeModule.hide();
  }

  private installCollectors() {
    if (!this.consolePatched) {
      this.consolePatched = true;
      console.log = (...args: unknown[]) => {
        this.originalConsole.log(...args);
        this.log('log', args);
      };
      console.info = (...args: unknown[]) => {
        this.originalConsole.info(...args);
        this.log('info', args);
      };
      console.warn = (...args: unknown[]) => {
        this.originalConsole.warn(...args);
        this.log('warn', args);
      };
      console.error = (...args: unknown[]) => {
        this.originalConsole.error(...args);
        this.log('error', args);
      };
      console.debug = (...args: unknown[]) => {
        this.originalConsole.debug(...args);
        this.log('debug', args);
      };
    }

    this.installGlobalErrorHandler();
    this.installUnhandledRejectionHandler();
    this.networkCollector.enable();
  }

  private removeCollectors() {
    if (this.consolePatched) {
      console.log = this.originalConsole.log;
      console.info = this.originalConsole.info;
      console.warn = this.originalConsole.warn;
      console.error = this.originalConsole.error;
      console.debug = this.originalConsole.debug;
      this.consolePatched = false;
    }

    this.networkCollector.disable();

    const globalScope = globalThis as RuntimeGlobal;
    if (globalScope.ErrorUtils?.setGlobalHandler && this.originalGlobalHandler) {
      globalScope.ErrorUtils.setGlobalHandler(this.originalGlobalHandler);
    }
    this.originalGlobalHandler = null;

    if (globalScope.removeEventListener && this.unhandledRejectionHandler) {
      globalScope.removeEventListener('unhandledrejection', this.unhandledRejectionHandler);
    }
    this.unhandledRejectionHandler = null;

    if (this.flushTimer) {
      this.clearTimeoutFn(this.flushTimer);
      this.flushTimer = null;
    }
    this.queue = [];
  }

  private installGlobalErrorHandler() {
    const globalScope = globalThis as RuntimeGlobal;
    if (!globalScope.ErrorUtils?.getGlobalHandler || !globalScope.ErrorUtils?.setGlobalHandler) {
      return;
    }
    if (this.originalGlobalHandler) {
      return;
    }

    const original = globalScope.ErrorUtils.getGlobalHandler?.() ?? null;
    this.originalGlobalHandler = original;
    globalScope.ErrorUtils.setGlobalHandler((error, isFatal) => {
      this.captureError('global', [`${isFatal ? '[FATAL] ' : ''}${error.message}`, error.stack]);
      original?.(error, isFatal);
    });
  }

  private installUnhandledRejectionHandler() {
    const globalScope = globalThis as RuntimeGlobal;
    if (!globalScope.addEventListener || this.unhandledRejectionHandler) {
      return;
    }

    this.unhandledRejectionHandler = (event: unknown) => {
      const reason =
        typeof event === 'object' && event != null && 'reason' in event
          ? (event as { reason?: unknown }).reason
          : event;
      this.captureError('promise', ['Unhandled Promise Rejection:', reason]);
    };
    globalScope.addEventListener('unhandledrejection', this.unhandledRejectionHandler);
  }

  private enqueue(entry: NativeBatchEntry) {
    if (!this.configured || !(this.manualEnabledOverride ?? this.providerConfig.enabled)) {
      return;
    }
    this.queue.push(entry);
    if (this.flushTimer) {
      return;
    }
    this.flushTimer = this.setTimeoutFn(() => {
      this.flushTimer = null;
      void this.flush();
    }, 16);
  }

  private async flush() {
    if (this.queue.length === 0) {
      return;
    }
    const batch = this.queue.splice(0, this.queue.length);
    try {
      await this.dependencies.nativeModule.ingestBatch(batch);
    } catch (error) {
      this.internalWarn('Failed to ingest debug batch', error);
    }
  }

  private internalWarn(message: string, error?: unknown) {
    this.originalConsole.warn(`[expo-inapp-debugger] ${message}`, error ?? '');
  }
}
