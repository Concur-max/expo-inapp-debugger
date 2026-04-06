package expo.modules.inappdebugger

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

object InAppDebuggerStore {
  private var config = DebugConfig()
  private val logs = mutableListOf<DebugLogEntry>()
  private val errors = mutableListOf<DebugErrorEntry>()
  private val network = mutableListOf<DebugNetworkEntry>()

  private val _state = MutableStateFlow(DebugPanelState())
  val state = _state.asStateFlow()

  @Synchronized
  fun updateConfig(next: DebugConfig) {
    config = next
    trimLogs()
    trimErrors()
    trimNetwork()
    emit()
  }

  @Synchronized
  fun ingestBatch(batch: List<Map<String, Any?>>) {
    batch.forEach { item ->
      when (item["category"] as? String) {
        "log" -> parseLog(item["entry"] as? Map<String, Any?>)?.let(::appendLog)
        "error" -> parseError(item["entry"] as? Map<String, Any?>)?.let(::appendError)
        "network" -> parseNetwork(item["entry"] as? Map<String, Any?>)?.let(::upsertNetwork)
      }
    }
    emit()
  }

  @Synchronized
  fun clear(kind: String) {
    when (kind) {
      "logs" -> logs.clear()
      "errors" -> errors.clear()
      "network" -> network.clear()
      else -> {
        logs.clear()
        errors.clear()
        network.clear()
      }
    }
    emit()
  }

  @Synchronized
  fun exportSnapshot(): Map<String, Any?> = mapOf(
    "logs" to logs.map(DebugLogEntry::toMap),
    "errors" to errors.map(DebugErrorEntry::toMap),
    "network" to network.map(DebugNetworkEntry::toMap),
    "exportTime" to java.time.Instant.now().toString()
  )

  @Synchronized
  fun currentConfig(): DebugConfig = config

  private fun appendLog(entry: DebugLogEntry) {
    logs.add(0, entry)
    trimLogs()
  }

  private fun appendError(entry: DebugErrorEntry) {
    errors.add(0, entry)
    trimErrors()
  }

  private fun upsertNetwork(entry: DebugNetworkEntry) {
    val existingIndex = network.indexOfFirst { it.id == entry.id }
    if (existingIndex >= 0) {
      network.removeAt(existingIndex)
    }
    network.add(0, entry)
    trimNetwork()
  }

  private fun trimLogs() {
    while (logs.size > config.maxLogs) {
      logs.removeLast()
    }
  }

  private fun trimErrors() {
    while (errors.size > config.maxErrors) {
      errors.removeLast()
    }
  }

  private fun trimNetwork() {
    while (network.size > config.maxRequests) {
      network.removeLast()
    }
  }

  private fun emit() {
    _state.value = DebugPanelState(
      config = config,
      logs = logs.toList(),
      errors = errors.toList(),
      network = network.toList()
    )
  }

  private fun parseLog(map: Map<String, Any?>?): DebugLogEntry? {
    if (map == null) return null
    return DebugLogEntry(
      id = map.string("id") ?: return null,
      type = map.string("type") ?: "log",
      message = map.string("message") ?: "",
      timestamp = map.string("timestamp") ?: "",
      fullTimestamp = map.string("fullTimestamp") ?: ""
    )
  }

  private fun parseError(map: Map<String, Any?>?): DebugErrorEntry? {
    if (map == null) return null
    return DebugErrorEntry(
      id = map.string("id") ?: return null,
      source = map.string("source") ?: "console",
      message = map.string("message") ?: "",
      timestamp = map.string("timestamp") ?: "",
      fullTimestamp = map.string("fullTimestamp") ?: ""
    )
  }

  private fun parseNetwork(map: Map<String, Any?>?): DebugNetworkEntry? {
    if (map == null) return null
    return DebugNetworkEntry(
      id = map.string("id") ?: return null,
      kind = map.string("kind") ?: "http",
      method = map.string("method") ?: "GET",
      url = map.string("url") ?: "",
      state = map.string("state") ?: "pending",
      startedAt = map.long("startedAt") ?: 0L,
      updatedAt = map.long("updatedAt") ?: map.long("startedAt") ?: 0L,
      endedAt = map.long("endedAt"),
      durationMs = map.long("durationMs"),
      status = map.int("status"),
      requestHeaders = map.stringMap("requestHeaders"),
      responseHeaders = map.stringMap("responseHeaders"),
      requestBody = map.string("requestBody"),
      responseBody = map.string("responseBody"),
      responseType = map.string("responseType"),
      responseContentType = map.string("responseContentType"),
      responseSize = map.int("responseSize"),
      error = map.string("error"),
      protocol = map.string("protocol"),
      closeReason = map.string("closeReason"),
      messages = map.string("messages")
    )
  }
}

private fun Map<String, Any?>.string(key: String): String? = this[key] as? String

private fun Map<String, Any?>.int(key: String): Int? = (this[key] as? Number)?.toInt()

private fun Map<String, Any?>.long(key: String): Long? = (this[key] as? Number)?.toLong()

private fun Map<String, Any?>.stringMap(key: String): Map<String, String> {
  val raw = this[key] as? Map<*, *> ?: return emptyMap()
  return raw.entries.mapNotNull { entry ->
    val mapKey = entry.key as? String ?: return@mapNotNull null
    val mapValue = entry.value?.toString() ?: ""
    mapKey to mapValue
  }.toMap()
}
