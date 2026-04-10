import type {
  NativeBatchPayload,
  NativeConfig,
  NativeErrorWireEntry,
  NativeLogWireEntry,
  NativeNetworkWireEntry,
} from '../InAppDebugModule';
import type {
  AndroidLogcatBuffer,
  AndroidNativeLogsConfig,
  DebugErrorEntry,
  DebugErrorSource,
  DebugLevel,
  DebugLogEntry,
  DebugNetworkEntry,
  InAppDebugStrings,
  ResolvedAndroidNativeLogsConfig,
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
  ingestBatch(
    logs?: NativeLogWireEntry[] | null,
    errors?: NativeErrorWireEntry[] | null,
    network?: NativeNetworkWireEntry[] | null
  ): Promise<void>;
  clear(kind: 'logs' | 'errors' | 'network' | 'all'): Promise<void>;
  show(): Promise<void>;
  hide(): Promise<void>;
  exportSnapshot(): Promise<any>;
  emitDiagnostic?: (source: string, message: string) => Promise<void>;
};

const FLUSH_DELAY_MS = 64;
const MAX_BUFFERED_BATCH_SIZE = 120;
const DEFAULT_ANDROID_LOGCAT_BUFFERS: AndroidLogcatBuffer[] = ['main', 'system', 'crash'];
const VALID_ANDROID_LOGCAT_BUFFERS = new Set<AndroidLogcatBuffer>([
  'main',
  'system',
  'crash',
  'events',
  'radio',
]);
let runtimeEntryCounter = 0;
let cachedTimestampSecond = -1;
let cachedTimestampPrefix = '';

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
    onDiagnostic?: (component: string, message: string) => void;
  }) => { enable(): void; disable(): void; updateOptions(options: { maxRequests: number }): void };
};

function createId(nowValue: number) {
  runtimeEntryCounter += 1;
  return `${nowValue}_${runtimeEntryCounter.toString(36)}`;
}

function stringifyValue(value: unknown) {
  if (typeof value === 'string') {
    return value;
  }
  if (typeof value === 'object' && value != null) {
    try {
      return JSON.stringify(value);
    } catch {
      return String(value);
    }
  }
  return String(value);
}

export function formatMessage(args: unknown[]) {
  let result = '';
  for (let index = 0; index < args.length; index += 1) {
    if (index > 0) {
      result += ' ';
    }
    result += stringifyValue(args[index]);
  }
  return result;
}

function formatTimestamps(nowValue: number) {
  const date = new Date(nowValue);
  const secondBucket = Math.floor(nowValue / 1000);
  if (secondBucket !== cachedTimestampSecond) {
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');
    const seconds = String(date.getSeconds()).padStart(2, '0');
    cachedTimestampPrefix = `${hours}:${minutes}:${seconds}.`;
    cachedTimestampSecond = secondBucket;
  }
  const milliseconds = String(date.getMilliseconds()).padStart(3, '0');
  return {
    timestamp: `${cachedTimestampPrefix}${milliseconds}`,
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
    androidNativeLogs: config.androidNativeLogs,
    locale: config.locale,
    strings: config.strings,
  };
}

function resolveAndroidNativeLogsConfig(
  input?: AndroidNativeLogsConfig
): ResolvedAndroidNativeLogsConfig {
  return {
    enabled: input?.enabled ?? true,
    captureLogcat: input?.captureLogcat ?? true,
    captureStdoutStderr: input?.captureStdoutStderr ?? true,
    captureUncaughtExceptions: input?.captureUncaughtExceptions ?? true,
    logcatScope: input?.logcatScope === 'device' ? 'device' : 'app',
    rootMode: input?.rootMode === 'auto' ? 'auto' : 'off',
    buffers: sanitizeAndroidLogcatBuffers(input?.buffers),
  };
}

function normalizeAndroidNativeLogsOverride(
  input: Partial<AndroidNativeLogsConfig>
): Partial<ResolvedAndroidNativeLogsConfig> {
  const next: Partial<ResolvedAndroidNativeLogsConfig> = {};

  if (typeof input.enabled === 'boolean') {
    next.enabled = input.enabled;
  }
  if (typeof input.captureLogcat === 'boolean') {
    next.captureLogcat = input.captureLogcat;
  }
  if (typeof input.captureStdoutStderr === 'boolean') {
    next.captureStdoutStderr = input.captureStdoutStderr;
  }
  if (typeof input.captureUncaughtExceptions === 'boolean') {
    next.captureUncaughtExceptions = input.captureUncaughtExceptions;
  }
  if (input.logcatScope != null) {
    next.logcatScope = input.logcatScope === 'device' ? 'device' : 'app';
  }
  if (input.rootMode != null) {
    next.rootMode = input.rootMode === 'auto' ? 'auto' : 'off';
  }
  if (input.buffers != null) {
    next.buffers = sanitizeAndroidLogcatBuffers(input.buffers);
  }

  return next;
}

function sanitizeAndroidLogcatBuffers(
  buffers: AndroidNativeLogsConfig['buffers']
): AndroidLogcatBuffer[] {
  const values = buffers?.filter((buffer): buffer is AndroidLogcatBuffer =>
    VALID_ANDROID_LOGCAT_BUFFERS.has(buffer)
  );
  if (!values?.length) {
    return [...DEFAULT_ANDROID_LOGCAT_BUFFERS];
  }
  return [...new Set(values)];
}

export function resolveProviderConfig(input: {
  enabled?: boolean;
  initialVisible?: boolean;
  enableNetworkTab?: boolean;
  maxLogs?: number;
  maxErrors?: number;
  maxRequests?: number;
  androidNativeLogs?: AndroidNativeLogsConfig;
  locale?: 'auto' | 'en-US' | 'zh-CN' | 'zh-TW' | 'ja';
  strings?: Partial<InAppDebugStrings>;
}): ResolvedInAppDebugConfig {
  const resolved = resolveStrings(input.locale ?? 'zh-CN', input.strings);
  return {
    enabled: input.enabled ?? false,
    initialVisible: input.initialVisible ?? true,
    enableNetworkTab: input.enableNetworkTab ?? true,
    maxLogs: input.maxLogs ?? 2000,
    maxErrors: input.maxErrors ?? 100,
    maxRequests: input.maxRequests ?? 100,
    androidNativeLogs: resolveAndroidNativeLogsConfig(input.androidNativeLogs),
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
    androidNativeLogs: resolveAndroidNativeLogsConfig(),
    locale: 'zh-CN',
    strings: defaultStrings,
  };
  private androidNativeLogsOverride: Partial<ResolvedAndroidNativeLogsConfig> | null = null;
  private manualEnabledOverride: boolean | null = null;
  private logQueue: NativeLogWireEntry[] = [];
  private errorQueue: NativeErrorWireEntry[] = [];
  private networkQueue: NativeNetworkWireEntry[] = [];
  private queuedNetworkEntryIndexes = new Map<string, number>();
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private flushInFlight: Promise<void> | null = null;
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
        onDiagnostic: (component, message) => this.emitDiagnostic(component, message),
      }) ??
      new NetworkCollector({
        maxRequests: this.providerConfig.maxRequests,
        onEntry: (entry) => this.captureNetwork(entry),
        onInternalWarning: (message, error) => this.internalWarn(message, error),
        onDiagnostic: (component, message) => this.emitDiagnostic(component, message),
      });
  }

  async registerProvider(config: ResolvedInAppDebugConfig) {
    this.providerConfig = config;
    this.emitDiagnostic(
      'JSRuntime',
      `registerProvider enabled=${config.enabled} network=${config.enableNetworkTab} ` +
        `maxLogs=${config.maxLogs} maxRequests=${config.maxRequests}`
    );
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

  async configureAndroidNativeLogs(options: Partial<AndroidNativeLogsConfig>) {
    this.androidNativeLogsOverride = {
      ...(this.androidNativeLogsOverride ?? {}),
      ...normalizeAndroidNativeLogsOverride(options),
    };
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
      origin: 'js',
      context: 'console',
      message: formatMessage(args),
      ...formatTimestamps(nowValue),
    };
    this.enqueueLog(entry);
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
    this.enqueueError(entry);
  }

  captureNetwork(entry: DebugNetworkEntry) {
    this.enqueueNetwork(entry);
  }

  private async applyConfig() {
    const mergedConfig = this.getMergedConfig();
    const resolvedEnabled = this.manualEnabledOverride ?? mergedConfig.enabled;
    const nextConfig = {
      ...mergedConfig,
      enabled: resolvedEnabled,
    };
    this.emitDiagnostic(
      'JSRuntime',
      `applyConfig start enabled=${resolvedEnabled} network=${nextConfig.enableNetworkTab} ` +
        `initialVisible=${nextConfig.initialVisible}`
    );

    await this.dependencies.nativeModule.configure(toNativeConfig(nextConfig));
    this.configured = true;
    this.emitDiagnostic('JSRuntime', 'applyConfig native configure resolved');

    if (resolvedEnabled) {
      this.installCollectors(nextConfig.enableNetworkTab);
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

  private installCollectors(enableNetworkCapture: boolean) {
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

    this.emitDiagnostic(
      'JSRuntime',
      `installCollectors consolePatched=${this.consolePatched} network=${enableNetworkCapture}`
    );
    this.installGlobalErrorHandler();
    this.installUnhandledRejectionHandler();
    if (enableNetworkCapture) {
      this.networkCollector.enable();
    } else {
      this.networkCollector.disable();
    }
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
    this.logQueue = [];
    this.errorQueue = [];
    this.networkQueue = [];
    this.queuedNetworkEntryIndexes.clear();
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

  private enqueueLog(entry: DebugLogEntry) {
    if (!this.configured || !(this.manualEnabledOverride ?? this.providerConfig.enabled)) {
      return;
    }
    this.logQueue.push(encodeLogEntry(entry))
    this.scheduleFlushIfNeeded()
  }

  private enqueueError(entry: DebugErrorEntry) {
    if (!this.configured || !(this.manualEnabledOverride ?? this.providerConfig.enabled)) {
      return;
    }
    this.errorQueue.push(encodeErrorEntry(entry))
    this.scheduleFlushIfNeeded()
  }

  private enqueueNetwork(entry: DebugNetworkEntry) {
    if (!this.configured || !(this.manualEnabledOverride ?? this.providerConfig.enabled)) {
      return;
    }

    const encodedEntry = encodeNetworkEntry(entry)
    const entryId = encodedEntry[0]
    const existingIndex = this.queuedNetworkEntryIndexes.get(entryId)
    if (existingIndex != null) {
      this.networkQueue[existingIndex] = encodedEntry
    } else {
      this.queuedNetworkEntryIndexes.set(entryId, this.networkQueue.length)
      this.networkQueue.push(encodedEntry)
    }
    this.scheduleFlushIfNeeded()
  }

  private scheduleFlushIfNeeded() {
    if (this.pendingEntryCount() >= MAX_BUFFERED_BATCH_SIZE) {
      this.cancelScheduledFlush();
      this.requestFlush();
      return;
    }
    if (this.flushTimer || this.flushInFlight) {
      return;
    }
    this.flushTimer = this.setTimeoutFn(() => {
      this.flushTimer = null;
      this.requestFlush();
    }, FLUSH_DELAY_MS);
  }

  private pendingEntryCount(): number {
    return this.logQueue.length + this.errorQueue.length + this.networkQueue.length
  }

  private cancelScheduledFlush() {
    if (this.flushTimer) {
      this.clearTimeoutFn(this.flushTimer);
      this.flushTimer = null;
    }
  }

  private requestFlush() {
    if (this.flushInFlight) {
      return;
    }
    void this.flush();
  }

  private async flush() {
    if (this.flushInFlight) {
      return this.flushInFlight;
    }
    if (this.pendingEntryCount() === 0) {
      return;
    }
    const batch: NativeBatchPayload = {}
    if (this.logQueue.length > 0) {
      batch.logs = this.logQueue
    }
    if (this.errorQueue.length > 0) {
      batch.errors = this.errorQueue
    }
    if (this.networkQueue.length > 0) {
      batch.network = this.networkQueue
    }
    this.emitDiagnostic(
      'JSRuntime',
      `flush logs=${this.logQueue.length} errors=${this.errorQueue.length} network=${this.networkQueue.length}`
    );
    this.logQueue = [];
    this.errorQueue = [];
    this.networkQueue = [];
    this.queuedNetworkEntryIndexes.clear();
    const flushPromise = (async () => {
      try {
        await this.dependencies.nativeModule.ingestBatch(
          batch.logs ?? null,
          batch.errors ?? null,
          batch.network ?? null
        );
        this.emitDiagnostic('JSRuntime', 'flush ingestBatch resolved');
      } catch (error) {
        this.emitDiagnostic('JSRuntime', `flush ingestBatch failed error=${String(error)}`);
        this.internalWarn('Failed to ingest debug batch', error);
      }
    })();
    this.flushInFlight = flushPromise;
    try {
      await flushPromise;
    } finally {
      if (this.flushInFlight === flushPromise) {
        this.flushInFlight = null;
      }
      if (this.pendingEntryCount() > 0) {
        this.requestFlush();
      }
    }
  }

  private internalWarn(message: string, error?: unknown) {
    this.emitDiagnostic('JSRuntime', `warning message=${message} error=${String(error ?? '')}`);
    this.originalConsole.warn(`[expo-inapp-debugger] ${message}`, error ?? '');
  }

  private emitDiagnostic(source: string, message: string) {
    void this.dependencies.nativeModule.emitDiagnostic?.(source, message).catch(() => undefined);
  }

  private getMergedConfig(): ResolvedInAppDebugConfig {
    const overrides = this.androidNativeLogsOverride;
    if (!overrides) {
      return this.providerConfig;
    }

    return {
      ...this.providerConfig,
      androidNativeLogs: {
        ...this.providerConfig.androidNativeLogs,
        ...overrides,
        buffers: overrides.buffers ?? this.providerConfig.androidNativeLogs.buffers,
      },
    };
  }
}

function encodeLogEntry(entry: DebugLogEntry): NativeLogWireEntry {
  return [
    entry.id,
    entry.type,
    entry.origin,
    entry.context ?? null,
    entry.details ?? null,
    entry.message,
    entry.timestamp,
    entry.fullTimestamp,
  ]
}

function encodeErrorEntry(entry: DebugErrorEntry): NativeErrorWireEntry {
  return [
    entry.id,
    entry.source,
    entry.message,
    entry.timestamp,
    entry.fullTimestamp,
  ]
}

function encodeNetworkEntry(entry: DebugNetworkEntry): NativeNetworkWireEntry {
  return [
    entry.id,
    entry.kind,
    entry.method,
    entry.url,
    entry.origin,
    entry.state,
    entry.startedAt,
    entry.updatedAt,
    entry.endedAt ?? null,
    entry.durationMs ?? null,
    entry.status ?? null,
    encodeHeaderMap(entry.requestHeaders),
    encodeHeaderMap(entry.responseHeaders),
    entry.requestBody ?? null,
    entry.responseBody ?? null,
    entry.responseType ?? null,
    entry.responseContentType ?? null,
    entry.responseSize ?? null,
    entry.error ?? null,
    entry.protocol ?? null,
    entry.requestedProtocols ?? null,
    entry.closeReason ?? null,
    entry.closeCode ?? null,
    entry.requestedCloseCode ?? null,
    entry.requestedCloseReason ?? null,
    entry.cleanClose ?? null,
    entry.messageCountIn ?? null,
    entry.messageCountOut ?? null,
    entry.bytesIn ?? null,
    entry.bytesOut ?? null,
    entry.events ?? null,
    entry.messages ?? null,
  ]
}

function encodeHeaderMap(headers: DebugNetworkEntry['requestHeaders']): string[] | null {
  if (!headers) {
    return null;
  }

  const entries = Object.entries(headers);
  if (entries.length === 0) {
    return null;
  }

  const result: string[] = [];
  for (const [key, value] of entries) {
    result.push(key, value);
  }
  return result;
}
