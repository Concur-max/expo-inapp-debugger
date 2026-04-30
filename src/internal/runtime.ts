import type {
  NativeBatchPayload,
  NativeConfig,
  NativeErrorWireEntry,
  NativeLogWireEntry,
  NativeNetworkWireEntry,
  NativePanelStateEvent,
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
import {
  normalizeAndroidNativeLogsOverride,
  resolveAndroidNativeLogsConfig,
  resolveProviderConfig,
} from './config';
import { formatDebugMessage } from './preview';
import { defaultStrings } from './strings';
import { materializeNetworkEntry, NetworkCollector } from './network';

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
  addListener?: (
    eventName: 'onPanelStateChange',
    listener: (event: NativePanelStateEvent) => void
  ) => { remove(): void };
};

const ACTIVE_FLUSH_DELAY_MS = 64;
const BACKGROUND_FLUSH_DELAY_MS = 400;
const MAX_BUFFERED_BATCH_SIZE = 120;
const MAX_QUEUE_OVERFLOW_MARGIN = MAX_BUFFERED_BATCH_SIZE;
const MAX_LOG_MESSAGE_LENGTH = 12_000;
const MAX_ERROR_MESSAGE_LENGTH = 12_000;
const JS_PIPELINE_DIAGNOSTICS_ENABLED = false;
let runtimeEntryCounter = 0;
let cachedTimestampSecond = -1;
let cachedTimestampPrefix = '';
let cachedIsoTimestampPrefix = '';

export type DebugRuntimeDependencies = {
  nativeModule: RuntimeNativeModule;
  now?: () => number;
  setTimeoutFn?: typeof setTimeout;
  clearTimeoutFn?: typeof clearTimeout;
  consoleRef?: ConsoleLike;
  networkFactory?: (options: {
    maxRequests: number;
    onEntry: (entry: DebugNetworkEntry) => void;
    nextTimelineSequence: () => number;
    onInternalWarning?: (message: string, error?: unknown) => void;
    onDiagnostic?: (component: string, message: string) => void;
  }) => {
    enable(): void;
    disable(): void;
    updateOptions(options: { maxRequests: number }): void;
  };
};

type RuntimeIdentity = {
  id: string;
  sequence: number;
};

function nextRuntimeSequence() {
  runtimeEntryCounter += 1;
  return runtimeEntryCounter;
}

function createRuntimeIdentity(nowValue: number): RuntimeIdentity {
  const sequence = nextRuntimeSequence();
  return {
    id: `${nowValue}_${sequence.toString(36)}`,
    sequence,
  };
}

export function formatMessage(args: unknown[]) {
  if (args.length === 1 && typeof args[0] === 'string' && args[0].length <= MAX_LOG_MESSAGE_LENGTH) {
    return args[0];
  }
  return formatDebugMessage(args, {
    maxLength: MAX_LOG_MESSAGE_LENGTH,
  });
}

function formatErrorMessage(args: unknown[]) {
  if (args.length === 1 && typeof args[0] === 'string' && args[0].length <= MAX_ERROR_MESSAGE_LENGTH) {
    return args[0];
  }
  return formatDebugMessage(args, {
    maxLength: MAX_ERROR_MESSAGE_LENGTH,
  });
}

function formatTimestamps(nowValue: number) {
  const secondBucket = Math.floor(nowValue / 1000);
  if (secondBucket !== cachedTimestampSecond) {
    const date = new Date(secondBucket * 1000);
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');
    const seconds = String(date.getSeconds()).padStart(2, '0');
    cachedTimestampPrefix = `${hours}:${minutes}:${seconds}.`;
    cachedIsoTimestampPrefix = `${date.toISOString().slice(0, 19)}.`;
    cachedTimestampSecond = secondBucket;
  }
  const milliseconds = String(nowValue - secondBucket * 1000).padStart(3, '0');
  return {
    timestamp: `${cachedTimestampPrefix}${milliseconds}`,
    fullTimestamp: `${cachedIsoTimestampPrefix}${milliseconds}Z`,
  };
}

function toNativeConfig(config: ResolvedInAppDebugConfig): NativeConfig {
  return {
    enabled: config.enabled,
    initialVisible: config.initialVisible,
    enableNetworkTab: config.enableNetworkTab,
    enableNativeLogs: config.enableNativeLogs,
    enableNativeNetwork: config.enableNativeNetwork,
    maxLogs: config.maxLogs,
    maxErrors: config.maxErrors,
    maxRequests: config.maxRequests,
    androidNativeLogs: config.androidNativeLogs,
    locale: config.locale,
    strings: config.strings,
  };
}

export { resolveProviderConfig } from './config';

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
    enableNativeLogs: false,
    enableNativeNetwork: false,
    maxLogs: 2000,
    maxErrors: 100,
    maxRequests: 100,
    androidNativeLogs: resolveAndroidNativeLogsConfig(),
    locale: 'zh-CN',
    strings: defaultStrings,
  };
  private androidNativeLogsOverride: Partial<ResolvedAndroidNativeLogsConfig> | null = null;
  private logQueue: NativeLogWireEntry[] = [];
  private errorQueue: NativeErrorWireEntry[] = [];
  private networkQueue = new Map<string, DebugNetworkEntry>();
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private flushInFlight: Promise<void> | null = null;
  private configured = false;
  private captureActive = false;
  private consolePatched = false;
  private lastAppliedConfig: ResolvedInAppDebugConfig | null = null;
  private originalGlobalHandler: ErrorUtilsHandler | null = null;
  private unhandledRejectionHandler: ((event: unknown) => void) | null = null;
  private panelStateSubscription: { remove(): void } | null = null;
  private panelVisible = false;
  private activeFeed = 'none';

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
        nextTimelineSequence: () => nextRuntimeSequence(),
        onInternalWarning: (message, error) => this.internalWarn(message, error),
        onDiagnostic: JS_PIPELINE_DIAGNOSTICS_ENABLED
          ? (component, message) => this.emitDiagnostic(component, message)
          : undefined,
      }) ??
      new NetworkCollector({
        maxRequests: this.providerConfig.maxRequests,
        onEntry: (entry) => this.captureNetwork(entry),
        nextTimelineSequence: () => nextRuntimeSequence(),
        onInternalWarning: (message, error) => this.internalWarn(message, error),
        onDiagnostic: JS_PIPELINE_DIAGNOSTICS_ENABLED
          ? (component, message) => this.emitDiagnostic(component, message)
          : undefined,
      });
  }

  primeProviderConfig(config: ResolvedInAppDebugConfig) {
    this.providerConfig = config;
    this.updateNetworkCollectorOptions(config);
  }

  async registerProvider(config: ResolvedInAppDebugConfig) {
    this.providerConfig = config;
    if (JS_PIPELINE_DIAGNOSTICS_ENABLED) {
      this.emitDiagnostic(
        'JSRuntime',
        `registerProvider enabled=${config.enabled} network=${config.enableNetworkTab} ` +
          `maxLogs=${config.maxLogs} maxRequests=${config.maxRequests}`
      );
    }
    this.updateNetworkCollectorOptions(config);
    await this.applyConfig();
  }

  async unregisterProvider() {
    this.providerConfig = {
      ...this.providerConfig,
      enabled: false,
    };
    await this.applyConfig();
  }

  async enable() {
    await this.registerProvider({
      ...this.providerConfig,
      enabled: true,
    });
  }

  async disable() {
    await this.registerProvider({
      ...this.providerConfig,
      enabled: false,
    });
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
    if (!this.isCaptureActive()) {
      return;
    }
    if (level === 'error') {
      this.captureConsoleError(args);
      return;
    }

    const nowValue = this.now();
    const identity = createRuntimeIdentity(nowValue);
    const entry: DebugLogEntry = {
      id: identity.id,
      type: level,
      origin: 'js',
      context: 'console',
      message: formatMessage(args),
      ...formatTimestamps(nowValue),
      timelineTimestampMillis: nowValue,
      timelineSequence: identity.sequence,
    };
    this.enqueueLog(entry);
  }

  captureError(source: DebugErrorSource, args: unknown[]) {
    if (!this.isCaptureActive()) {
      return;
    }
    const nowValue = this.now();
    const identity = createRuntimeIdentity(nowValue);
    const entry: DebugErrorEntry = {
      id: identity.id,
      source,
      message: formatErrorMessage(args),
      ...formatTimestamps(nowValue),
      timelineTimestampMillis: nowValue,
      timelineSequence: identity.sequence,
    };
    this.enqueueError(entry);
  }

  captureNetwork(entry: DebugNetworkEntry) {
    if (!this.isCaptureActive()) {
      return;
    }
    this.enqueueNetwork(entry);
  }

  private captureConsoleError(args: unknown[]) {
    if (!this.isCaptureActive()) {
      return;
    }
    const nowValue = this.now();
    const formattedMessage = formatErrorMessage(args);
    const timestamps = formatTimestamps(nowValue);
    const logIdentity = createRuntimeIdentity(nowValue);
    const errorIdentity = createRuntimeIdentity(nowValue);

    this.enqueueLog({
      id: logIdentity.id,
      type: 'error',
      origin: 'js',
      context: 'console',
      message: formattedMessage,
      ...timestamps,
      timelineTimestampMillis: nowValue,
      timelineSequence: logIdentity.sequence,
    });

    this.enqueueError({
      id: errorIdentity.id,
      source: 'console',
      message: formattedMessage,
      ...timestamps,
      timelineTimestampMillis: nowValue,
      timelineSequence: errorIdentity.sequence,
    });
  }

  private async applyConfig() {
    const mergedConfig = this.getMergedConfig();
    const nextConfig = {
      ...mergedConfig,
      enabled: mergedConfig.enabled,
    };
    if (this.configured && this.lastAppliedConfig && areResolvedConfigsEqual(this.lastAppliedConfig, nextConfig)) {
      return;
    }

    if (JS_PIPELINE_DIAGNOSTICS_ENABLED) {
      this.emitDiagnostic(
        'JSRuntime',
        `applyConfig start enabled=${nextConfig.enabled} network=${nextConfig.enableNetworkTab} ` +
          `initialVisible=${nextConfig.initialVisible}`
      );
    }

    if (nextConfig.enabled) {
      this.captureActive = true;
      this.installPanelStateListener();
      this.installCollectors(nextConfig.enableNetworkTab);
    } else {
      this.captureActive = false;
      this.removeCollectors();
    }

    await this.dependencies.nativeModule.configure(toNativeConfig(nextConfig));
    this.configured = true;
    if (JS_PIPELINE_DIAGNOSTICS_ENABLED) {
      this.emitDiagnostic('JSRuntime', 'applyConfig native configure resolved');
    }

    if (nextConfig.enabled && this.pendingEntryCount() > 0) {
      this.cancelScheduledFlush();
      this.scheduleFlushIfNeeded();
    }

    this.lastAppliedConfig = nextConfig;
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

    if (JS_PIPELINE_DIAGNOSTICS_ENABLED) {
      this.emitDiagnostic(
        'JSRuntime',
        `installCollectors consolePatched=${this.consolePatched} network=${enableNetworkCapture}`
      );
    }
    this.installGlobalErrorHandler();
    this.installUnhandledRejectionHandler();
    this.updateNetworkCollectorOptions(this.providerConfig);
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
    this.removePanelStateListener();
    this.panelVisible = false;
    this.activeFeed = 'none';

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
    this.networkQueue.clear();
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
    if (!this.isCaptureActive()) {
      return;
    }
    this.logQueue.push(encodeLogEntry(entry))
    this.trimPendingLogQueue(false)
    if (this.pendingEntryCount() > 0) {
      this.scheduleFlushIfNeeded()
    }
  }

  private enqueueError(entry: DebugErrorEntry) {
    if (!this.isCaptureActive()) {
      return;
    }
    this.errorQueue.push(encodeErrorEntry(entry))
    this.trimPendingErrorQueue(false)
    if (this.pendingEntryCount() > 0) {
      this.scheduleFlushIfNeeded()
    }
  }

  private enqueueNetwork(entry: DebugNetworkEntry) {
    if (!this.isCaptureActive()) {
      return;
    }

    this.networkQueue.set(entry.id, entry)
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
    }, this.currentFlushDelayMs());
  }

  private installPanelStateListener() {
    if (this.panelStateSubscription || !this.dependencies.nativeModule.addListener) {
      return;
    }

    this.panelStateSubscription = this.dependencies.nativeModule.addListener('onPanelStateChange', (event) => {
      const wasFull = this.isNetworkFeedActive();
      this.panelVisible = event.panelVisible === true;
      this.activeFeed = typeof event.activeFeed === 'string' ? event.activeFeed.toLowerCase() : 'none';
      const isFull = this.isNetworkFeedActive();
      this.updateNetworkCollectorOptions(this.providerConfig);
      if (!wasFull && isFull && this.pendingEntryCount() > 0) {
        this.cancelScheduledFlush();
        this.scheduleFlushIfNeeded();
      }
    });
  }

  private removePanelStateListener() {
    this.panelStateSubscription?.remove();
    this.panelStateSubscription = null;
  }

  private updateNetworkCollectorOptions(config: ResolvedInAppDebugConfig) {
    this.networkCollector.updateOptions({
      maxRequests: config.maxRequests,
    });
  }

  private currentFlushDelayMs() {
    return this.isNetworkFeedActive() ? ACTIVE_FLUSH_DELAY_MS : BACKGROUND_FLUSH_DELAY_MS;
  }

  private isNetworkFeedActive() {
    return this.panelVisible && this.activeFeed === 'network';
  }

  private pendingEntryCount(): number {
    return this.logQueue.length + this.errorQueue.length + this.networkQueue.size
  }

  private cancelScheduledFlush() {
    if (this.flushTimer) {
      this.clearTimeoutFn(this.flushTimer);
      this.flushTimer = null;
    }
  }

  private requestFlush() {
    if (!this.configured) {
      return;
    }
    if (this.flushInFlight) {
      return;
    }
    void this.flush();
  }

  private async flush() {
    if (this.flushInFlight) {
      return this.flushInFlight;
    }
    this.trimPendingLogQueue(true);
    this.trimPendingErrorQueue(true);
    if (this.pendingEntryCount() === 0) {
      return;
    }
    const queuedNetworkEntries = this.networkQueue;
    const batch: NativeBatchPayload = {}
    if (this.logQueue.length > 0) {
      batch.logs = this.logQueue
    }
    if (this.errorQueue.length > 0) {
      batch.errors = this.errorQueue
    }
    if (queuedNetworkEntries.size > 0) {
      batch.network = Array.from(queuedNetworkEntries.values(), (entry) =>
        encodeNetworkEntry(materializeNetworkEntry(entry))
      )
    }
    if (JS_PIPELINE_DIAGNOSTICS_ENABLED) {
      this.emitDiagnostic(
        'JSRuntime',
        `flush logs=${this.logQueue.length} errors=${this.errorQueue.length} network=${queuedNetworkEntries.size}`
      );
    }
    this.logQueue = [];
    this.errorQueue = [];
    this.networkQueue = new Map<string, DebugNetworkEntry>();
    const flushPromise = (async () => {
      try {
        await this.dependencies.nativeModule.ingestBatch(
          batch.logs ?? null,
          batch.errors ?? null,
          batch.network ?? null
        );
        if (JS_PIPELINE_DIAGNOSTICS_ENABLED) {
          this.emitDiagnostic('JSRuntime', 'flush ingestBatch resolved');
        }
      } catch (error) {
        if (JS_PIPELINE_DIAGNOSTICS_ENABLED) {
          this.emitDiagnostic('JSRuntime', `flush ingestBatch failed error=${String(error)}`);
        }
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
    if (JS_PIPELINE_DIAGNOSTICS_ENABLED) {
      this.emitDiagnostic('JSRuntime', `warning message=${message} error=${String(error ?? '')}`);
    }
    this.originalConsole.warn(`[expo-inapp-debugger] ${message}`, error ?? '');
  }

  private emitDiagnostic(source: string, message: string) {
    if (!JS_PIPELINE_DIAGNOSTICS_ENABLED) {
      return;
    }
    void this.dependencies.nativeModule.emitDiagnostic?.(source, message).catch(() => undefined);
  }

  private isCaptureActive() {
    return this.captureActive && this.providerConfig.enabled;
  }

  private trimPendingLogQueue(exact: boolean) {
    trimPendingQueue(this.logQueue, this.providerConfig.maxLogs, exact);
  }

  private trimPendingErrorQueue(exact: boolean) {
    trimPendingQueue(this.errorQueue, this.providerConfig.maxErrors, exact);
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
  const timelineTimestampMillis = entry.timelineTimestampMillis ?? resolveTimelineTimestampMillis(entry.fullTimestamp);
  const timelineSequence = entry.timelineSequence ?? resolveTimelineSequence(entry.id);
  return [
    entry.id,
    entry.type,
    entry.origin,
    entry.context ?? null,
    entry.details ?? null,
    entry.message,
    entry.timestamp,
    entry.fullTimestamp,
    timelineTimestampMillis,
    timelineSequence,
  ]
}

function trimPendingQueue<T>(queue: T[], maxCount: number, exact: boolean) {
  const sanitizedMaxCount = sanitizeNonNegativeInteger(maxCount);
  if (sanitizedMaxCount <= 0) {
    queue.length = 0;
    return;
  }

  const allowedCount = exact
    ? sanitizedMaxCount
    : sanitizedMaxCount + MAX_QUEUE_OVERFLOW_MARGIN;
  if (queue.length <= allowedCount) {
    return;
  }

  queue.splice(0, queue.length - sanitizedMaxCount);
}

function sanitizeNonNegativeInteger(value: number) {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.max(0, Math.floor(value));
}

function encodeErrorEntry(entry: DebugErrorEntry): NativeErrorWireEntry {
  const timelineTimestampMillis = entry.timelineTimestampMillis ?? resolveTimelineTimestampMillis(entry.fullTimestamp);
  const timelineSequence = entry.timelineSequence ?? resolveTimelineSequence(entry.id);
  return [
    entry.id,
    entry.source,
    entry.message,
    entry.timestamp,
    entry.fullTimestamp,
    timelineTimestampMillis,
    timelineSequence,
  ]
}

function encodeNetworkEntry(entry: DebugNetworkEntry): NativeNetworkWireEntry {
  const timelineSequence = entry.timelineSequence ?? resolveTimelineSequence(entry.id);
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
    timelineSequence,
  ]
}

function resolveTimelineTimestampMillis(fullTimestamp: string): number | null {
  if (!fullTimestamp) {
    return null;
  }
  const parsed = Date.parse(fullTimestamp);
  return Number.isFinite(parsed) ? parsed : null;
}

function resolveTimelineSequence(id: string): number | null {
  const suffix = id.slice(id.lastIndexOf('_') + 1);
  if (!suffix) {
    return null;
  }

  if (/^\d+$/.test(suffix)) {
    const decimalValue = Number.parseInt(suffix, 10);
    return Number.isFinite(decimalValue) ? decimalValue : null;
  }

  let value = 0;
  for (const char of suffix.toLowerCase()) {
    const digit = Number.parseInt(char, 36);
    if (!Number.isFinite(digit) || digit < 0 || digit >= 36) {
      return null;
    }
    value = value * 36 + digit;
  }
  return Number.isFinite(value) ? value : null;
}

function encodeHeaderMap(headers: DebugNetworkEntry['requestHeaders']): string[] | null {
  if (!headers) {
    return null;
  }

  const entries = Object.entries(headers);
  if (entries.length === 0) {
    return null;
  }

  const result = new Array<string>(entries.length * 2);
  let writeIndex = 0;
  for (const [key, value] of entries) {
    result[writeIndex] = key;
    result[writeIndex + 1] = value;
    writeIndex += 2;
  }
  return result;
}

function areResolvedConfigsEqual(
  lhs: ResolvedInAppDebugConfig,
  rhs: ResolvedInAppDebugConfig
): boolean {
  return (
    lhs.enabled === rhs.enabled &&
    lhs.initialVisible === rhs.initialVisible &&
    lhs.enableNetworkTab === rhs.enableNetworkTab &&
    lhs.enableNativeLogs === rhs.enableNativeLogs &&
    lhs.enableNativeNetwork === rhs.enableNativeNetwork &&
    lhs.maxLogs === rhs.maxLogs &&
    lhs.maxErrors === rhs.maxErrors &&
    lhs.maxRequests === rhs.maxRequests &&
    lhs.locale === rhs.locale &&
    areAndroidNativeLogsConfigsEqual(lhs.androidNativeLogs, rhs.androidNativeLogs) &&
    areStringRecordsEqual(lhs.strings, rhs.strings)
  );
}

function areAndroidNativeLogsConfigsEqual(
  lhs: ResolvedAndroidNativeLogsConfig,
  rhs: ResolvedAndroidNativeLogsConfig
): boolean {
  return (
    lhs.enabled === rhs.enabled &&
    lhs.captureLogcat === rhs.captureLogcat &&
    lhs.captureStdoutStderr === rhs.captureStdoutStderr &&
    lhs.captureUncaughtExceptions === rhs.captureUncaughtExceptions &&
    lhs.logcatScope === rhs.logcatScope &&
    lhs.rootMode === rhs.rootMode &&
    areStringArraysEqual(lhs.buffers, rhs.buffers)
  );
}

function areStringRecordsEqual(lhs: Record<string, string>, rhs: Record<string, string>): boolean {
  if (lhs === rhs) {
    return true;
  }

  const lhsKeys = Object.keys(lhs);
  if (lhsKeys.length !== Object.keys(rhs).length) {
    return false;
  }

  for (const key of lhsKeys) {
    if (lhs[key] !== rhs[key]) {
      return false;
    }
  }

  return true;
}

function areStringArraysEqual(lhs: string[], rhs: string[]): boolean {
  if (lhs === rhs) {
    return true;
  }

  if (lhs.length !== rhs.length) {
    return false;
  }

  for (let index = 0; index < lhs.length; index += 1) {
    if (lhs[index] !== rhs[index]) {
      return false;
    }
  }

  return true;
}
