package expo.modules.inappdebugger

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.UUID

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
  val fullTimestamp: String
)

data class DebugErrorEntry(
  val id: String,
  val source: String,
  val message: String,
  val timestamp: String,
  val fullTimestamp: String
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
  val messages: String? = null
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

data class DebugPanelState(
  val config: DebugConfig = DebugConfig(),
  val logs: List<DebugLogEntry> = emptyList(),
  val errors: List<DebugErrorEntry> = emptyList(),
  val network: List<DebugNetworkEntry> = emptyList(),
  val runtimeInfo: DebugRuntimeInfo = DebugRuntimeInfo()
)

private val nativeLogClockFormatter: DateTimeFormatter =
  DateTimeFormatter.ofPattern("HH:mm:ss.SSS").withZone(ZoneId.systemDefault())

fun createNativeDebugLogEntry(
  type: String,
  message: String,
  context: String? = null,
  details: String? = null,
  timestampMillis: Long = System.currentTimeMillis()
): DebugLogEntry {
  val instant = Instant.ofEpochMilli(timestampMillis)
  return DebugLogEntry(
    id = "native_${timestampMillis}_${UUID.randomUUID()}",
    type = type,
    origin = "native",
    context = context,
    details = details,
    message = message,
    timestamp = nativeLogClockFormatter.format(instant),
    fullTimestamp = instant.toString()
  )
}

fun DebugLogEntry.toMap(): Map<String, Any?> = mapOf(
  "id" to id,
  "type" to type,
  "origin" to origin,
  "context" to context,
  "details" to details,
  "message" to message,
  "timestamp" to timestamp,
  "fullTimestamp" to fullTimestamp
)

fun DebugErrorEntry.toMap(): Map<String, Any?> = mapOf(
  "id" to id,
  "source" to source,
  "message" to message,
  "timestamp" to timestamp,
  "fullTimestamp" to fullTimestamp
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
  "messages" to messages
)
