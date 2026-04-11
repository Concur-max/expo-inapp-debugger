package expo.modules.inappdebugger

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.atomic.AtomicLong

data class AndroidNativeLogsConfig(
  val enabled: Boolean = true,
  val captureLogcat: Boolean = true,
  val captureStdoutStderr: Boolean = true,
  val captureUncaughtExceptions: Boolean = true,
  val logcatScope: String = "app",
  val rootMode: String = "off",
  val buffers: List<String> = listOf("main", "system", "crash")
)

data class DebugConfig(
  val enabled: Boolean = false,
  val initialVisible: Boolean = true,
  val enableNetworkTab: Boolean = true,
  val maxLogs: Int = 2000,
  val maxErrors: Int = 100,
  val maxRequests: Int = 100,
  val androidNativeLogs: AndroidNativeLogsConfig = AndroidNativeLogsConfig(),
  val locale: String = "zh-CN",
  val strings: Map<String, String> = emptyMap()
)

data class DebugLogEntry(
  val id: String,
  val type: String,
  val origin: String = "js",
  val context: String? = null,
  val details: String? = null,
  val message: String,
  val timestamp: String,
  val fullTimestamp: String,
  val timelineTimestampMillis: Long = 0L,
  val timelineSequence: Long = 0L
)

data class DebugErrorEntry(
  val id: String,
  val source: String,
  val message: String,
  val timestamp: String,
  val fullTimestamp: String,
  val timelineTimestampMillis: Long = 0L,
  val timelineSequence: Long = 0L
)

data class DebugNetworkEntry(
  val id: String,
  val kind: String,
  val method: String,
  val url: String,
  val origin: String = "js",
  val state: String,
  val startedAt: Long,
  val updatedAt: Long,
  val endedAt: Long? = null,
  val durationMs: Long? = null,
  val status: Int? = null,
  val requestHeaders: Map<String, String> = emptyMap(),
  val responseHeaders: Map<String, String> = emptyMap(),
  val requestBody: String? = null,
  val responseBody: String? = null,
  val responseType: String? = null,
  val responseContentType: String? = null,
  val responseSize: Int? = null,
  val error: String? = null,
  val protocol: String? = null,
  val requestedProtocols: String? = null,
  val closeReason: String? = null,
  val closeCode: Int? = null,
  val requestedCloseCode: Int? = null,
  val requestedCloseReason: String? = null,
  val cleanClose: Boolean? = null,
  val messageCountIn: Int? = null,
  val messageCountOut: Int? = null,
  val bytesIn: Int? = null,
  val bytesOut: Int? = null,
  val events: String? = null,
  val messages: String? = null,
  val timelineSequence: Long = 0L
)

data class DebugRuntimeInfo(
  val appName: String = "",
  val packageName: String = "",
  val versionName: String = "",
  val versionCode: Long? = null,
  val processName: String = "",
  val pid: Int = 0,
  val uid: Int = 0,
  val debuggable: Boolean = false,
  val targetSdk: Int = 0,
  val minSdk: Int = 0,
  val manufacturer: String = "",
  val brand: String = "",
  val deviceModel: String = "",
  val sdkInt: Int = 0,
  val release: String = "",
  val supportedAbis: List<String> = emptyList(),
  val networkTabEnabled: Boolean = false,
  val nativeLogsEnabled: Boolean = false,
  val captureLogcat: Boolean = false,
  val captureStdoutStderr: Boolean = false,
  val captureUncaughtExceptions: Boolean = false,
  val requestedLogcatScope: String = "app",
  val requestedRootMode: String = "off",
  val activeLogcatMode: String = "disabled",
  val rootStatus: String = "not_requested",
  val rootDetails: String? = null,
  val buffers: List<String> = emptyList(),
  val crashRecords: List<DebugCrashRecord> = emptyList()
)

data class DebugCrashRecord(
  val id: String,
  val timestampMillis: Long,
  val threadName: String = "",
  val exceptionClass: String = "",
  val message: String = "",
  val stackTrace: String = ""
)

enum class DebugPanelFeed {
  None,
  Logs,
  Network,
  AppInfo
}

data class DebugPanelChromeState(
  val config: DebugConfig = DebugConfig(),
  val runtimeInfo: DebugRuntimeInfo = DebugRuntimeInfo()
)

data class DebugListWindowState<T>(
  val version: Long = 0,
  val totalSize: Int = 0,
  val items: List<T> = emptyList()
)

data class TimelineSortKey(
  val primaryTimeMillis: Long,
  val secondaryTimeMillis: Long = Long.MIN_VALUE,
  val sequence: Long = 0L,
  val stableId: String
)

private val nativeLogClockFormatter: DateTimeFormatter =
  DateTimeFormatter.ofPattern("HH:mm:ss.SSS").withZone(ZoneId.systemDefault())
private val nativeIsoInstantFormatter: DateTimeFormatter = DateTimeFormatter.ISO_INSTANT
private val nativeEntryIdCounter = AtomicLong(0)

fun formatNativeLogClock(timestampMillis: Long): String {
  return formatNativeLogClock(Instant.ofEpochMilli(timestampMillis))
}

private fun formatNativeLogClock(instant: Instant): String = nativeLogClockFormatter.format(instant)

fun createNativeDebugLogEntry(
  type: String,
  message: String,
  context: String? = null,
  details: String? = null,
  timestampMillis: Long = System.currentTimeMillis()
): DebugLogEntry {
  val instant = Instant.ofEpochMilli(timestampMillis)
  val sequence = nativeEntryIdCounter.incrementAndGet()
  return DebugLogEntry(
    id = "native_${timestampMillis}_${sequence}",
    type = type,
    origin = "native",
    context = context,
    details = details,
    message = message,
    timestamp = formatNativeLogClock(instant),
    fullTimestamp = nativeIsoInstantFormatter.format(instant),
    timelineTimestampMillis = timestampMillis,
    timelineSequence = sequence
  )
}

fun DebugLogEntry.timelineSortKey(): TimelineSortKey {
  return TimelineSortKey(
    primaryTimeMillis = timelineTimestampMillis,
    sequence = timelineSequence,
    stableId = id
  )
}

fun DebugErrorEntry.timelineSortKey(): TimelineSortKey {
  return TimelineSortKey(
    primaryTimeMillis = timelineTimestampMillis,
    sequence = timelineSequence,
    stableId = id
  )
}

fun DebugNetworkEntry.timelineSortKey(): TimelineSortKey {
  return TimelineSortKey(
    primaryTimeMillis = startedAt,
    sequence = timelineSequence,
    stableId = id
  )
}

fun resolveTimelineTimestampMillis(
  fullTimestamp: String?,
  fallbackTimestampMillis: Long = 0L,
  id: String? = null
): Long {
  if (!fullTimestamp.isNullOrBlank()) {
    runCatching {
      Instant.parse(fullTimestamp).toEpochMilli()
    }.getOrNull()?.let { parsed ->
      return parsed
    }
  }

  if (fallbackTimestampMillis > 0L) {
    return fallbackTimestampMillis
  }

  extractTimelineTimestampMillisFromId(id)?.let { parsed ->
    return parsed
  }

  return 0L
}

fun resolveTimelineSequence(id: String): Long {
  val suffix = id.substringAfterLast('_', missingDelimiterValue = "")
  if (suffix.isEmpty()) {
    return 0L
  }

  return suffix.toLongOrNull() ?: suffix.toLongOrNull(radix = 36) ?: 0L
}

private fun extractTimelineTimestampMillisFromId(id: String?): Long? {
  val parts = id?.split('_') ?: return null
  for (index in parts.indices.reversed()) {
    val candidate = parts[index]
    if (candidate.length < 10 || !candidate.all(Char::isDigit)) {
      continue
    }
    return candidate.toLongOrNull()
  }
  return null
}

fun DebugLogEntry.toMap(): Map<String, Any?> = mapOf(
  "id" to id,
  "type" to type,
  "origin" to origin,
  "context" to context,
  "details" to details,
  "message" to message,
  "timestamp" to timestamp,
  "fullTimestamp" to fullTimestamp,
  "timelineTimestampMillis" to timelineTimestampMillis,
  "timelineSequence" to timelineSequence
)

fun DebugErrorEntry.toMap(): Map<String, Any?> = mapOf(
  "id" to id,
  "source" to source,
  "message" to message,
  "timestamp" to timestamp,
  "fullTimestamp" to fullTimestamp,
  "timelineTimestampMillis" to timelineTimestampMillis,
  "timelineSequence" to timelineSequence
)

fun DebugNetworkEntry.toMap(): Map<String, Any?> = mapOf(
  "id" to id,
  "kind" to kind,
  "method" to method,
  "url" to url,
  "origin" to origin,
  "state" to state,
  "startedAt" to startedAt,
  "updatedAt" to updatedAt,
  "endedAt" to endedAt,
  "durationMs" to durationMs,
  "status" to status,
  "requestHeaders" to requestHeaders,
  "responseHeaders" to responseHeaders,
  "requestBody" to requestBody,
  "responseBody" to responseBody,
  "responseType" to responseType,
  "responseContentType" to responseContentType,
  "responseSize" to responseSize,
  "error" to error,
  "protocol" to protocol,
  "requestedProtocols" to requestedProtocols,
  "closeReason" to closeReason,
  "closeCode" to closeCode,
  "requestedCloseCode" to requestedCloseCode,
  "requestedCloseReason" to requestedCloseReason,
  "cleanClose" to cleanClose,
  "messageCountIn" to messageCountIn,
  "messageCountOut" to messageCountOut,
  "bytesIn" to bytesIn,
  "bytesOut" to bytesOut,
  "events" to events,
  "messages" to messages,
  "timelineSequence" to timelineSequence
)
