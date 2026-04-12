import type {
  AndroidLogcatBuffer,
  AndroidNativeLogsConfig,
  InAppDebugStrings,
  ResolvedAndroidNativeLogsConfig,
  ResolvedInAppDebugConfig,
  SupportedLocale,
} from '../types';
import { resolveStrings } from './strings';

const DEFAULT_ANDROID_LOGCAT_BUFFERS: AndroidLogcatBuffer[] = ['main', 'system', 'crash'];
const VALID_ANDROID_LOGCAT_BUFFERS = new Set<AndroidLogcatBuffer>([
  'main',
  'system',
  'crash',
  'events',
  'radio',
]);

export function resolveAndroidNativeLogsConfig(
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

export function normalizeAndroidNativeLogsOverride(
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

export function resolveProviderConfig(input: {
  enabled?: boolean;
  initialVisible?: boolean;
  enableNetworkTab?: boolean;
  maxLogs?: number;
  maxErrors?: number;
  maxRequests?: number;
  androidNativeLogs?: AndroidNativeLogsConfig;
  locale?: SupportedLocale;
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
