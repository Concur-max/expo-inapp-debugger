package expo.modules.inappdebugger

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

object InAppDebuggerStore {
  private var config = DebugConfig()
  private val logs = mutableListOf<DebugLogEntry>()
  private val pendingNativeLogs = mutableListOf<DebugLogEntry>()
  private val errors = mutableListOf<DebugErrorEntry>()
  private val network = mutableListOf<DebugNetworkEntry>()
  private val networkIndexById = mutableMapOf<String, Int>()
  private var runtimeInfo = DebugRuntimeInfo()

  private val _state = MutableStateFlow(DebugPanelState())
  val state = _state.asStateFlow()

  @Synchronized
  fun updateConfig(next: DebugConfig) {
    val shouldFlushPendingNativeLogs = next.enabled && pendingNativeLogs.isNotEmpty()
    config = next
    if (shouldFlushPendingNativeLogs) {
      logs.addAll(pendingNativeLogs)
      pendingNativeLogs.clear()
    }
    trimLogs()
    trimPendingNativeLogs()
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
      "logs" -> {
        logs.clear()
        pendingNativeLogs.clear()
      }
      "errors" -> errors.clear()
      "network" -> {
        network.clear()
        networkIndexById.clear()
      }
      else -> {
        logs.clear()
        pendingNativeLogs.clear()
        errors.clear()
        network.clear()
        networkIndexById.clear()
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

  @Synchronized
  fun networkEntry(id: String): DebugNetworkEntry? {
    val existingIndex = networkIndexById[id]
    if (existingIndex != null && existingIndex in network.indices) {
      return network[existingIndex]
    }
    return network.firstOrNull { it.id == id }
  }

  @Synchronized
  fun appendNativeLog(entry: DebugLogEntry) {
    appendNativeLogLocked(entry)
    emit()
  }

  @Synchronized
  fun appendNativeLogs(entries: List<DebugLogEntry>) {
    if (entries.isEmpty()) {
      return
    }
    entries.forEach(::appendNativeLogLocked)
    emit()
  }

  @Synchronized
  fun updateRuntimeInfo(next: DebugRuntimeInfo) {
    runtimeInfo = next
    emit()
  }

  private fun appendLog(entry: DebugLogEntry) {
    logs.add(entry)
    trimLogs()
  }

  private fun appendError(entry: DebugErrorEntry) {
    errors.add(entry)
    trimErrors()
  }

  private fun upsertNetwork(entry: DebugNetworkEntry) {
    val existingIndex = networkIndexById[entry.id]
    if (existingIndex != null && existingIndex in network.indices) {
      network[existingIndex] = entry
    } else {
      network.add(entry)
      networkIndexById[entry.id] = network.lastIndex
    }
    trimNetwork()
  }

  private fun trimLogs() {
    while (logs.size > config.maxLogs) {
      logs.removeAt(0)
    }
  }

  private fun trimPendingNativeLogs() {
    while (pendingNativeLogs.size > config.maxLogs) {
      pendingNativeLogs.removeAt(0)
    }
  }

  private fun trimErrors() {
    while (errors.size > config.maxErrors) {
      errors.removeAt(0)
    }
  }

  private fun trimNetwork() {
    val overflow = network.size - config.maxRequests
    if (overflow > 0) {
      repeat(overflow) {
        network.removeAt(0)
      }
      rebuildNetworkIndex()
    }
  }

  private fun emit() {
    _state.value = DebugPanelState(
      config = config,
      logs = logs.toList(),
      errors = errors.toList(),
      network = network.toList(),
      runtimeInfo = runtimeInfo
    )
  }

  private fun parseLog(map: Map<String, Any?>?): DebugLogEntry? {
    if (map == null) return null
    return DebugLogEntry(
      id = map.string("id") ?: return null,
      type = map.string("type") ?: "log",
      origin = map.string("origin") ?: "js",
      context = map.string("context"),
      details = map.string("details"),
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
      origin = map.string("origin") ?: "js",
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
      requestedProtocols = map.string("requestedProtocols"),
      closeReason = map.string("closeReason"),
      closeCode = map.int("closeCode"),
      requestedCloseCode = map.int("requestedCloseCode"),
      requestedCloseReason = map.string("requestedCloseReason"),
      cleanClose = map.bool("cleanClose"),
      messageCountIn = map.int("messageCountIn"),
      messageCountOut = map.int("messageCountOut"),
      bytesIn = map.int("bytesIn"),
      bytesOut = map.int("bytesOut"),
      events = map.string("events"),
      messages = map.string("messages")
    )
  }

  private fun rebuildNetworkIndex() {
    networkIndexById.clear()
    network.forEachIndexed { index, entry ->
      networkIndexById[entry.id] = index
    }
  }

  private fun appendNativeLogLocked(entry: DebugLogEntry) {
    if (config.enabled) {
      logs.add(entry)
      trimLogs()
    } else {
      pendingNativeLogs.add(entry)
      trimPendingNativeLogs()
    }
  }
}

private fun Map<String, Any?>.string(key: String): String? = this[key] as? String

private fun Map<String, Any?>.int(key: String): Int? = (this[key] as? Number)?.toInt()

private fun Map<String, Any?>.long(key: String): Long? = (this[key] as? Number)?.toLong()

private fun Map<String, Any?>.bool(key: String): Boolean? = this[key] as? Boolean

private fun Map<String, Any?>.stringMap(key: String): Map<String, String> {
  val raw = this[key] as? Map<*, *> ?: return emptyMap()
  return raw.entries.mapNotNull { entry ->
    val mapKey = entry.key as? String ?: return@mapNotNull null
    val mapValue = entry.value?.toString() ?: ""
    mapKey to mapValue
  }.toMap()
}
