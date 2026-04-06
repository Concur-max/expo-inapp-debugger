import type * as React from 'react';

export type DebugLevel = 'log' | 'info' | 'warn' | 'error' | 'debug';

export type DebugErrorSource = 'console' | 'global' | 'promise' | 'react' | string;

export type DebugNetworkKind = 'http' | 'websocket';

export type DebugNetworkState = 'pending' | 'success' | 'error' | 'closed';

export type SupportedLocale = 'auto' | 'en-US' | 'zh-CN' | 'zh-TW' | 'ja';

export type DebugLogEntry = {
  id: string;
  type: DebugLevel;
  message: string;
  timestamp: string;
  fullTimestamp: string;
};

export type DebugErrorEntry = {
  id: string;
  source: DebugErrorSource;
  message: string;
  timestamp: string;
  fullTimestamp: string;
};

export type DebugNetworkEntry = {
  id: string;
  kind: DebugNetworkKind;
  method: string;
  url: string;
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
  closeReason?: string;
  messages?: string;
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

export type ResolvedInAppDebugConfig = {
  enabled: boolean;
  initialVisible: boolean;
  enableNetworkTab: boolean;
  maxLogs: number;
  maxErrors: number;
  maxRequests: number;
  locale: Exclude<SupportedLocale, 'auto'>;
  strings: InAppDebugStrings;
};
