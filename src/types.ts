import type * as React from 'react';

export type DebugLevel = 'log' | 'info' | 'warn' | 'error' | 'debug';

export type DebugLogOrigin = 'js' | 'native' | string;

export type DebugErrorSource = 'console' | 'global' | 'promise' | 'react' | string;

export type DebugNetworkKind = 'http' | 'websocket';

export type DebugNetworkState =
  | 'pending'
  | 'success'
  | 'error'
  | 'closed'
  | 'connecting'
  | 'open'
  | 'closing';

export type SupportedLocale = 'auto' | 'en-US' | 'zh-CN' | 'zh-TW' | 'ja';

export type AndroidLogcatBuffer = 'main' | 'system' | 'crash' | 'events' | 'radio';

export type AndroidLogcatScope = 'app' | 'device';

export type AndroidRootLogMode = 'off' | 'auto';

export type AndroidNativeLogsConfig = {
  enabled?: boolean;
  captureLogcat?: boolean;
  captureStdoutStderr?: boolean;
  captureUncaughtExceptions?: boolean;
  logcatScope?: AndroidLogcatScope;
  rootMode?: AndroidRootLogMode;
  buffers?: AndroidLogcatBuffer[];
};

export type DebugLogEntry = {
  id: string;
  type: DebugLevel;
  origin: DebugLogOrigin;
  context?: string;
  details?: string;
  message: string;
  timestamp: string;
  fullTimestamp: string;
  timelineTimestampMillis?: number;
  timelineSequence?: number;
};

export type DebugErrorEntry = {
  id: string;
  source: DebugErrorSource;
  message: string;
  timestamp: string;
  fullTimestamp: string;
  timelineTimestampMillis?: number;
  timelineSequence?: number;
};

export type DebugNetworkEntry = {
  id: string;
  kind: DebugNetworkKind;
  method: string;
  url: string;
  origin: DebugLogOrigin;
  state: DebugNetworkState;
  startedAt: number;
  updatedAt: number;
  endedAt?: number;
  durationMs?: number;
  status?: number;
  requestHeaders?: Record<string, string>;
  responseHeaders?: Record<string, string>;
  requestBody?: string;
  responseBody?: string;
  responseType?: string;
  responseContentType?: string;
  responseSize?: number;
  error?: string;
  protocol?: string;
  requestedProtocols?: string;
  closeReason?: string;
  closeCode?: number;
  requestedCloseCode?: number;
  requestedCloseReason?: string;
  cleanClose?: boolean;
  messageCountIn?: number;
  messageCountOut?: number;
  bytesIn?: number;
  bytesOut?: number;
  events?: string;
  messages?: string;
  timelineSequence?: number;
};

export type DebugSnapshot = {
  logs: DebugLogEntry[];
  errors: DebugErrorEntry[];
  network: DebugNetworkEntry[];
  exportTime: string;
};

export type InAppDebugStrings = {
  title: string;
  logsTab: string;
  networkTab: string;
  jsLogOrigin: string;
  nativeLogOrigin: string;
  close: string;
  searchPlaceholder: string;
  clear: string;
  loading: string;
  noLogs: string;
  noSearchResult: string;
  noNetworkRequests: string;
  networkLoading: string;
  networkUnavailable: string;
  sortAsc: string;
  sortDesc: string;
  copySingleSuccess: string;
  copyVisibleSuccess: string;
  copyFailed: string;
  copySingleA11y: string;
  copyVisibleA11y: string;
  requestDetails: string;
  requestHeaders: string;
  responseHeaders: string;
  requestBody: string;
  responseBody: string;
  messages: string;
  duration: string;
  status: string;
  method: string;
  state: string;
  protocol: string;
  noRequestBody: string;
  noResponseBody: string;
  noMessages: string;
  errorTitle: string;
  errorRetry: string;
  errorDebugInfo: string;
  unknownError: string;
};

export type InAppDebugProviderProps = {
  enabled?: boolean;
  initialVisible?: boolean;
  enableNetworkTab?: boolean;
  maxLogs?: number;
  maxErrors?: number;
  maxRequests?: number;
  androidNativeLogs?: AndroidNativeLogsConfig;
  locale?: SupportedLocale;
  strings?: Partial<InAppDebugStrings>;
  children: React.ReactNode;
};

export type InAppDebugBoundaryProps = {
  children: React.ReactNode;
  onError?: (error: Error, errorInfo: React.ErrorInfo) => void;
  fallback?: (
    error: Error | null,
    errorInfo: React.ErrorInfo | null,
    retry: () => void
  ) => React.ReactNode;
  showDebugInfo?: boolean;
};

export type InAppDebugRootProps = InAppDebugProviderProps &
  Omit<InAppDebugBoundaryProps, 'children'>;

export type ResolvedInAppDebugConfig = {
  enabled: boolean;
  initialVisible: boolean;
  enableNetworkTab: boolean;
  maxLogs: number;
  maxErrors: number;
  maxRequests: number;
  androidNativeLogs: ResolvedAndroidNativeLogsConfig;
  locale: Exclude<SupportedLocale, 'auto'>;
  strings: InAppDebugStrings;
};

export type ResolvedAndroidNativeLogsConfig = {
  enabled: boolean;
  captureLogcat: boolean;
  captureStdoutStderr: boolean;
  captureUncaughtExceptions: boolean;
  logcatScope: AndroidLogcatScope;
  rootMode: AndroidRootLogMode;
  buffers: AndroidLogcatBuffer[];
};
