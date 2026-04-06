package expo.modules.inappdebugger

data class DebugConfig(
  val enabled: Boolean = false,
  val initialVisible: Boolean = true,
  val enableNetworkTab: Boolean = true,
  val maxLogs: Int = 2000,
  val maxErrors: Int = 100,
  val maxRequests: Int = 100,
  val locale: String = "zh-CN",
  val strings: Map<String, String> = emptyMap()
)

data class DebugLogEntry(
  val id: String,
  val type: String,
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
  val closeReason: String? = null,
  val messages: String? = null
)

data class DebugPanelState(
  val config: DebugConfig = DebugConfig(),
  val logs: List<DebugLogEntry> = emptyList(),
  val errors: List<DebugErrorEntry> = emptyList(),
  val network: List<DebugNetworkEntry> = emptyList()
)

fun DebugLogEntry.toMap(): Map<String, Any?> = mapOf(
  "id" to id,
  "type" to type,
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
  "closeReason" to closeReason,
  "messages" to messages
)
