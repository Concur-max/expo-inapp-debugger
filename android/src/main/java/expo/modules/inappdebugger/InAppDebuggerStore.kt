package expo.modules.inappdebugger

import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

object InAppDebuggerStore {
  private const val UI_REFRESH_INTERVAL_MS = 150L

  private val uiHandler = Handler(Looper.getMainLooper())
  private val publishVisibleUiRunnable = Runnable { flushVisibleUiState() }

  private var config = DebugConfig()
  private val logs = RingBuffer<DebugLogEntry>(DebugConfig().maxLogs)
  private val pendingNativeLogs = RingBuffer<DebugLogEntry>(DebugConfig().maxLogs)
  private val errors = RingBuffer<DebugErrorEntry>(DebugConfig().maxErrors)
  private val network = KeyedRingBuffer<String, DebugNetworkEntry>(DebugConfig().maxRequests) { it.id }
  private var runtimeInfo = DebugRuntimeInfo()

  private var panelVisible = false
  private var activeFeed = DebugPanelFeed.None
  private var logsVersion = 0L
  private var errorsVersion = 0L
  private var networkVersion = 0L
  private var logsDirty = false
  private var errorsDirty = false
  private var networkDirty = false
  private var visibleUiPublishScheduled = false

  private val _chromeState = MutableStateFlow(DebugPanelChromeState())
  val chromeState = _chromeState.asStateFlow()

  private val _logsWindowState = MutableStateFlow(DebugListWindowState<DebugLogEntry>())
  val logsWindowState = _logsWindowState.asStateFlow()

  private val _errorsWindowState = MutableStateFlow(DebugListWindowState<DebugErrorEntry>())
  val errorsWindowState = _errorsWindowState.asStateFlow()

  private val _networkWindowState = MutableStateFlow(DebugListWindowState<DebugNetworkEntry>())
  val networkWindowState = _networkWindowState.asStateFlow()

  @Synchronized
  fun updateConfig(next: DebugConfig) {
    val shouldFlushPendingNativeLogs = next.enabled && pendingNativeLogs.size > 0

    config = next
    logs.resize(next.maxLogs)
    pendingNativeLogs.resize(next.maxLogs)
    errors.resize(next.maxErrors)
    network.resize(next.maxRequests)

    if (shouldFlushPendingNativeLogs) {
      logs.appendAll(pendingNativeLogs.snapshot())
      pendingNativeLogs.clear()
    }

    markLogsDirtyLocked()
    markErrorsDirtyLocked()
    markNetworkDirtyLocked()
    publishChromeLocked()
    publishVisibleFeedNowLocked()
  }

  @Synchronized
  fun ingestBatch(batch: List<Map<String, Any?>>) {
    var logsChanged = false
    var errorsChanged = false
    var networkChanged = false

    batch.forEach { item ->
      when (item["category"] as? String) {
        "log" -> {
          val entry = parseLog(item["entry"].typedMap())
          if (entry != null && appendLog(entry)) {
            logsChanged = true
          }
        }
        "error" -> {
          val entry = parseError(item["entry"].typedMap())
          if (entry != null && appendError(entry)) {
            errorsChanged = true
          }
        }
        "network" -> {
          val entry = parseNetwork(item["entry"].typedMap())
          if (entry != null && upsertNetwork(entry)) {
            networkChanged = true
          }
        }
      }
    }

    if (logsChanged) {
      markLogsDirtyLocked()
    }
    if (errorsChanged) {
      markErrorsDirtyLocked()
    }
    if (networkChanged) {
      markNetworkDirtyLocked()
    }
    scheduleVisibleFeedPublishLocked()
  }

  @Synchronized
  fun clear(kind: String) {
    var logsChanged = false
    var errorsChanged = false
    var networkChanged = false

    when (kind) {
      "logs" -> {
        logsChanged = logs.clear() || pendingNativeLogs.clear()
      }
      "errors" -> {
        errorsChanged = errors.clear()
      }
      "network" -> {
        networkChanged = network.clear()
      }
      else -> {
        logsChanged = logs.clear() || pendingNativeLogs.clear()
        errorsChanged = errors.clear()
        networkChanged = network.clear()
      }
    }

    if (logsChanged) {
      markLogsDirtyLocked()
    }
    if (errorsChanged) {
      markErrorsDirtyLocked()
    }
    if (networkChanged) {
      markNetworkDirtyLocked()
    }
    publishVisibleFeedNowLocked()
  }

  @Synchronized
  fun exportSnapshot(): Map<String, Any?> = mapOf(
    "logs" to logs.snapshot().map(DebugLogEntry::toMap),
    "errors" to errors.snapshot().map(DebugErrorEntry::toMap),
    "network" to network.snapshot().map(DebugNetworkEntry::toMap),
    "exportTime" to java.time.Instant.now().toString()
  )

  @Synchronized
  fun currentConfig(): DebugConfig = config

  @Synchronized
  fun networkEntry(id: String): DebugNetworkEntry? = network.get(id)

  @Synchronized
  fun upsertNetworkEntry(entry: DebugNetworkEntry) {
    if (upsertNetwork(entry)) {
      markNetworkDirtyLocked()
      scheduleVisibleFeedPublishLocked()
    }
  }

  @Synchronized
  fun appendNativeLog(entry: DebugLogEntry) {
    if (appendNativeLogLocked(entry)) {
      markLogsDirtyLocked()
      scheduleVisibleFeedPublishLocked()
    }
  }

  @Synchronized
  fun appendNativeLogs(entries: List<DebugLogEntry>) {
    if (entries.isEmpty()) {
      return
    }

    var changed = false
    entries.forEach { entry ->
      if (appendNativeLogLocked(entry)) {
        changed = true
      }
    }

    if (changed) {
      markLogsDirtyLocked()
      scheduleVisibleFeedPublishLocked()
    }
  }

  @Synchronized
  fun updateRuntimeInfo(next: DebugRuntimeInfo) {
    runtimeInfo = next
    publishChromeLocked()
  }

  @Synchronized
  fun setPanelVisible(visible: Boolean) {
    if (panelVisible == visible) {
      return
    }

    panelVisible = visible
    if (!visible) {
      activeFeed = DebugPanelFeed.None
      cancelVisibleFeedPublishLocked()
      return
    }

    publishVisibleFeedNowLocked()
  }

  @Synchronized
  fun setActiveFeed(feed: DebugPanelFeed) {
    if (activeFeed == feed) {
      if (panelVisible && feed != DebugPanelFeed.None) {
        publishVisibleFeedNowLocked()
      }
      return
    }

    activeFeed = feed
    if (feed == DebugPanelFeed.None) {
      cancelVisibleFeedPublishLocked()
      return
    }

    if (panelVisible) {
      publishVisibleFeedNowLocked()
    }
  }

  private fun appendLog(entry: DebugLogEntry): Boolean = logs.append(entry)

  private fun appendError(entry: DebugErrorEntry): Boolean = errors.append(entry)

  private fun upsertNetwork(entry: DebugNetworkEntry): Boolean = network.upsert(entry)

  private fun publishChromeLocked() {
    _chromeState.value = DebugPanelChromeState(
      config = config,
      runtimeInfo = runtimeInfo
    )
  }

  private fun markLogsDirtyLocked() {
    logsVersion += 1
    logsDirty = true
  }

  private fun markErrorsDirtyLocked() {
    errorsVersion += 1
    errorsDirty = true
  }

  private fun markNetworkDirtyLocked() {
    networkVersion += 1
    networkDirty = true
  }

  private fun scheduleVisibleFeedPublishLocked() {
    if (!panelVisible || visibleUiPublishScheduled) {
      return
    }

    val shouldPublish =
      when (activeFeed) {
        DebugPanelFeed.Logs -> logsDirty
        DebugPanelFeed.Network -> networkDirty
        DebugPanelFeed.AppInfo -> errorsDirty
        DebugPanelFeed.None -> false
      }

    if (!shouldPublish) {
      return
    }

    visibleUiPublishScheduled = true
    uiHandler.postDelayed(publishVisibleUiRunnable, UI_REFRESH_INTERVAL_MS)
  }

  private fun cancelVisibleFeedPublishLocked() {
    visibleUiPublishScheduled = false
    uiHandler.removeCallbacks(publishVisibleUiRunnable)
  }

  private fun publishVisibleFeedNowLocked() {
    if (!panelVisible) {
      return
    }

    cancelVisibleFeedPublishLocked()
    when (activeFeed) {
      DebugPanelFeed.Logs -> publishLogsWindowLocked()
      DebugPanelFeed.Network -> publishNetworkWindowLocked()
      DebugPanelFeed.AppInfo -> publishErrorsWindowLocked()
      DebugPanelFeed.None -> Unit
    }
  }

  private fun flushVisibleUiState() {
    synchronized(this) {
      visibleUiPublishScheduled = false
      if (!panelVisible) {
        return
      }

      when (activeFeed) {
        DebugPanelFeed.Logs -> {
          if (logsDirty) {
            publishLogsWindowLocked()
          }
        }
        DebugPanelFeed.Network -> {
          if (networkDirty) {
            publishNetworkWindowLocked()
          }
        }
        DebugPanelFeed.AppInfo -> {
          if (errorsDirty) {
            publishErrorsWindowLocked()
          }
        }
        DebugPanelFeed.None -> Unit
      }
    }
  }

  private fun publishLogsWindowLocked() {
    logsDirty = false
    _logsWindowState.value = DebugListWindowState(
      version = logsVersion,
      totalSize = logs.size,
      items = logs.snapshot()
    )
  }

  private fun publishErrorsWindowLocked() {
    errorsDirty = false
    _errorsWindowState.value = DebugListWindowState(
      version = errorsVersion,
      totalSize = errors.size,
      items = errors.snapshot()
    )
  }

  private fun publishNetworkWindowLocked() {
    networkDirty = false
    _networkWindowState.value = DebugListWindowState(
      version = networkVersion,
      totalSize = network.size,
      items = network.snapshot()
    )
  }

  private fun appendNativeLogLocked(entry: DebugLogEntry): Boolean {
    return if (config.enabled) {
      logs.append(entry)
    } else {
      pendingNativeLogs.append(entry)
      false
    }
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
}

private class RingBuffer<T>(initialCapacity: Int) {
  private var storage = arrayOfNulls<Any?>(initialCapacity.coerceAtLeast(0))
  private var head = 0

  var size: Int = 0
    private set

  fun append(item: T): Boolean {
    if (storage.isEmpty()) {
      return false
    }

    if (size < storage.size) {
      storage[(head + size) % storage.size] = item
      size += 1
      return true
    }

    storage[head] = item
    head = (head + 1) % storage.size
    return true
  }

  fun appendAll(items: Iterable<T>): Boolean {
    var changed = false
    items.forEach { item ->
      if (append(item)) {
        changed = true
      }
    }
    return changed
  }

  fun snapshot(): List<T> {
    if (size == 0) {
      return emptyList()
    }

    val result = ArrayList<T>(size)
    repeat(size) { index ->
      result += elementAt(index)
    }
    return result
  }

  fun clear(): Boolean {
    if (size == 0) {
      return false
    }

    storage.fill(null)
    head = 0
    size = 0
    return true
  }

  fun resize(nextCapacity: Int): Boolean {
    val normalizedCapacity = nextCapacity.coerceAtLeast(0)
    if (normalizedCapacity == storage.size) {
      return false
    }

    val preserved = if (normalizedCapacity == 0) emptyList() else snapshot().takeLast(normalizedCapacity)
    storage = arrayOfNulls(normalizedCapacity)
    head = 0
    size = 0
    appendAll(preserved)
    return true
  }

  @Suppress("UNCHECKED_CAST")
  private fun elementAt(index: Int): T {
    val slot = (head + index) % storage.size
    return storage[slot] as T
  }
}

private class KeyedRingBuffer<K, T>(
  initialCapacity: Int,
  private val keySelector: (T) -> K
) {
  private var storage = arrayOfNulls<Any?>(initialCapacity.coerceAtLeast(0))
  private var head = 0
  private val slotByKey = mutableMapOf<K, Int>()

  var size: Int = 0
    private set

  fun upsert(item: T): Boolean {
    if (storage.isEmpty()) {
      return false
    }

    val key = keySelector(item)
    val existingSlot = slotByKey[key]
    if (existingSlot != null) {
      storage[existingSlot] = item
      return true
    }

    if (size < storage.size) {
      val tail = (head + size) % storage.size
      storage[tail] = item
      slotByKey[key] = tail
      size += 1
      return true
    }

    @Suppress("UNCHECKED_CAST")
    val evicted = storage[head] as T
    slotByKey.remove(keySelector(evicted))
    storage[head] = item
    slotByKey[key] = head
    head = (head + 1) % storage.size
    return true
  }

  fun get(key: K): T? {
    val slot = slotByKey[key] ?: return null
    @Suppress("UNCHECKED_CAST")
    return storage[slot] as? T
  }

  fun snapshot(): List<T> {
    if (size == 0) {
      return emptyList()
    }

    val result = ArrayList<T>(size)
    repeat(size) { index ->
      result += elementAt(index)
    }
    return result
  }

  fun clear(): Boolean {
    if (size == 0) {
      return false
    }

    storage.fill(null)
    head = 0
    size = 0
    slotByKey.clear()
    return true
  }

  fun resize(nextCapacity: Int): Boolean {
    val normalizedCapacity = nextCapacity.coerceAtLeast(0)
    if (normalizedCapacity == storage.size) {
      return false
    }

    val preserved = if (normalizedCapacity == 0) emptyList() else snapshot().takeLast(normalizedCapacity)
    storage = arrayOfNulls(normalizedCapacity)
    head = 0
    size = 0
    slotByKey.clear()
    preserved.forEach(::upsert)
    return true
  }

  @Suppress("UNCHECKED_CAST")
  private fun elementAt(index: Int): T {
    val slot = (head + index) % storage.size
    return storage[slot] as T
  }
}

private fun Map<String, Any?>.string(key: String): String? = this[key] as? String

@Suppress("UNCHECKED_CAST")
private fun Any?.typedMap(): Map<String, Any?>? = this as? Map<String, Any?>

private fun Map<String, Any?>.int(key: String): Int? = (this[key] as? Number)?.toInt()

private fun Map<String, Any?>.long(key: String): Long? = (this[key] as? Number)?.toLong()

private fun Map<String, Any?>.bool(key: String): Boolean? = this[key] as? Boolean

private fun Map<String, Any?>.stringMap(key: String): Map<String, String> {
  val raw = this[key] as? Map<*, *> ?: return emptyMap()
  return raw.entries.mapNotNull { entry ->
    val mapKey = entry.key as? String ?: return@mapNotNull null
    mapKey to (entry.value?.toString() ?: "")
  }.toMap()
}
