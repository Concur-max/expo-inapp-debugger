package expo.modules.inappdebugger

import android.os.Handler
import android.os.HandlerThread
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableType
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

object InAppDebuggerStore {
  private const val UI_REFRESH_INTERVAL_MS = 150L

  private var visibleUiHandlerThread: HandlerThread? = null
  private var uiHandler: Handler? = null
  private val publishVisibleUiRunnable = Runnable { flushVisibleUiState() }

  private var config = DebugConfig()
  private val logs = TimelineBuffer(DebugConfig().maxLogs, DebugLogEntry::timelineSortKey)
  private val pendingNativeLogs = TimelineBuffer(DebugConfig().maxLogs, DebugLogEntry::timelineSortKey)
  private val errors = TimelineBuffer(DebugConfig().maxErrors, DebugErrorEntry::timelineSortKey)
  private val network = KeyedTimelineBuffer(DebugConfig().maxRequests, { it.id }, DebugNetworkEntry::timelineSortKey)
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

  fun updateConfig(next: DebugConfig) {
    var nextChromeState: DebugPanelChromeState? = null

    synchronized(this) {
      val shouldFlushPendingNativeLogs = next.enabled && pendingNativeLogs.size > 0
      if (config == next && !shouldFlushPendingNativeLogs) {
        return
      }

      config = next
      var logsChanged = logs.resize(next.maxLogs)
      pendingNativeLogs.resize(next.maxLogs)
      val errorsChanged = errors.resize(next.maxErrors)
      val networkChanged = network.resize(next.maxRequests)

      if (shouldFlushPendingNativeLogs) {
        if (pendingNativeLogs.moveAllTo(logs)) {
          logsChanged = true
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
      nextChromeState = buildChromeStateLocked()
      if (logsChanged || errorsChanged || networkChanged) {
        publishVisibleFeedNowLocked()
      }
    }

    nextChromeState?.let(::publishChromeState)
  }

  fun ingestBatch(
    logs: ReadableArray?,
    errors: ReadableArray?,
    network: ReadableArray?
  ) {
    inAppDebuggerDiagnostic("Store") {
      "ingestBatch raw logs=${logs?.size() ?: 0} " +
        "errors=${errors?.size() ?: 0} network=${network?.size() ?: 0}"
    }
    val parsedBatch = parseBatch(logs, errors, network)
    inAppDebuggerDiagnostic("Store") {
      "ingestBatch parsed logs=${parsedBatch.logs.size} " +
        "errors=${parsedBatch.errors.size} network=${parsedBatch.network.size}"
    }
    if (
      parsedBatch.logs.isEmpty() &&
      parsedBatch.errors.isEmpty() &&
      parsedBatch.network.isEmpty()
    ) {
      return
    }

    synchronized(this) {
      var logsChanged = false
      var errorsChanged = false
      var networkChanged = false

      if (parsedBatch.logs.isNotEmpty() && logs.appendAll(parsedBatch.logs)) {
        logsChanged = true
      }
      if (parsedBatch.errors.isNotEmpty() && errors.appendAll(parsedBatch.errors)) {
        errorsChanged = true
      }
      if (parsedBatch.network.isNotEmpty() && network.upsertAll(parsedBatch.network)) {
        networkChanged = true
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
      if (logsChanged || errorsChanged || networkChanged) {
        scheduleVisibleFeedPublishLocked()
      }
    }
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
    if (logsChanged || errorsChanged || networkChanged) {
      publishVisibleFeedNowLocked()
    }
  }

  fun exportSnapshot(): Map<String, Any?> {
    val logsSnapshot: List<DebugLogEntry>
    val errorsSnapshot: List<DebugErrorEntry>
    val networkSnapshot: List<DebugNetworkEntry>

    synchronized(this) {
      logsSnapshot = logs.snapshot()
      errorsSnapshot = errors.snapshot()
      networkSnapshot = network.snapshot()
    }

    return mapOf(
      "logs" to logsSnapshot.map(DebugLogEntry::toMap),
      "errors" to errorsSnapshot.map(DebugErrorEntry::toMap),
      "network" to networkSnapshot.map(DebugNetworkEntry::toMap),
      "exportTime" to java.time.Instant.now().toString()
    )
  }

  @Synchronized
  fun currentConfig(): DebugConfig = config

  @Synchronized
  fun shutdown() {
    cancelVisibleFeedPublishLocked()
    config = DebugConfig()
    logs.clear()
    pendingNativeLogs.clear()
    errors.clear()
    network.clear()
    runtimeInfo = DebugRuntimeInfo()
    panelVisible = false
    activeFeed = DebugPanelFeed.None
    logsVersion = 0L
    errorsVersion = 0L
    networkVersion = 0L
    logsDirty = false
    errorsDirty = false
    networkDirty = false
    _chromeState.value = DebugPanelChromeState()
    _logsWindowState.value = DebugListWindowState()
    _errorsWindowState.value = DebugListWindowState()
    _networkWindowState.value = DebugListWindowState()
    visibleUiHandlerThread?.quitSafely()
    visibleUiHandlerThread = null
    uiHandler = null
  }

  @Synchronized
  fun networkEntry(id: String): DebugNetworkEntry? = network.get(id)

  @Synchronized
  fun upsertNetworkEntry(entry: DebugNetworkEntry) {
    if (network.upsert(entry)) {
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

    val changed =
      if (config.enabled) {
        logs.appendAll(entries)
      } else {
        pendingNativeLogs.appendAll(entries)
        false
      }

    if (!changed) {
      return
    }

    markLogsDirtyLocked()
    scheduleVisibleFeedPublishLocked()
  }

  fun updateRuntimeInfo(next: DebugRuntimeInfo) {
    var nextChromeState: DebugPanelChromeState? = null

    synchronized(this) {
      if (runtimeInfo == next) {
        return
      }
      runtimeInfo = next
      nextChromeState = buildChromeStateLocked()
    }

    nextChromeState?.let(::publishChromeState)
  }

  @Synchronized
  fun setPanelVisible(visible: Boolean) {
    if (panelVisible == visible) {
      return
    }

    panelVisible = visible
    inAppDebuggerDiagnostic("Store") {
      "setPanelVisible visible=$visible activeFeed=$activeFeed " +
        "dirty=logs:$logsDirty errors:$errorsDirty network:$networkDirty"
    }
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
    inAppDebuggerDiagnostic("Store") {
      "setActiveFeed feed=$feed panelVisible=$panelVisible " +
        "dirty=logs:$logsDirty errors:$errorsDirty network:$networkDirty"
    }
    if (feed == DebugPanelFeed.None) {
      cancelVisibleFeedPublishLocked()
      return
    }

    if (panelVisible) {
      publishVisibleFeedNowLocked()
    }
  }

  private fun buildChromeStateLocked(): DebugPanelChromeState {
    return DebugPanelChromeState(
      config = config,
      runtimeInfo = runtimeInfo
    )
  }

  private fun publishChromeState(nextState: DebugPanelChromeState) {
    if (_chromeState.value != nextState) {
      _chromeState.value = nextState
    }
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
    uiHandlerLocked().postDelayed(publishVisibleUiRunnable, UI_REFRESH_INTERVAL_MS)
  }

  private fun cancelVisibleFeedPublishLocked() {
    visibleUiPublishScheduled = false
    uiHandler?.removeCallbacks(publishVisibleUiRunnable)
  }

  private fun publishVisibleFeedNowLocked() {
    if (!panelVisible) {
      return
    }

    cancelVisibleFeedPublishLocked()
    val shouldPublish =
      when (activeFeed) {
        DebugPanelFeed.Logs -> logsDirty
        DebugPanelFeed.Network -> networkDirty
        DebugPanelFeed.AppInfo -> errorsDirty
        DebugPanelFeed.None -> false
      }

    if (shouldPublish) {
      visibleUiPublishScheduled = true
      uiHandlerLocked().post(publishVisibleUiRunnable)
    }
  }

  private fun uiHandlerLocked(): Handler {
    val existing = uiHandler
    if (existing != null) {
      return existing
    }

    val thread = HandlerThread("InAppDebugger-visible-feed").apply { start() }
    val handler = Handler(thread.looper)
    visibleUiHandlerThread = thread
    uiHandler = handler
    return handler
  }

  private fun flushVisibleUiState() {
    var logsState: DebugListWindowState<DebugLogEntry>? = null
    var networkState: DebugListWindowState<DebugNetworkEntry>? = null
    var errorsState: DebugListWindowState<DebugErrorEntry>? = null

    synchronized(this) {
      visibleUiPublishScheduled = false
      if (!panelVisible) {
        return
      }

      when (activeFeed) {
        DebugPanelFeed.Logs -> {
          if (logsDirty) {
            logsState = createLogsWindowStateLocked()
          }
        }
        DebugPanelFeed.Network -> {
          if (networkDirty) {
            networkState = createNetworkWindowStateLocked()
          }
        }
        DebugPanelFeed.AppInfo -> {
          if (errorsDirty) {
            errorsState = createErrorsWindowStateLocked()
          }
        }
        DebugPanelFeed.None -> Unit
      }
    }

    logsState?.let { _logsWindowState.value = it }
    networkState?.let { _networkWindowState.value = it }
    errorsState?.let { _errorsWindowState.value = it }
    if (logsState != null || networkState != null || errorsState != null) {
      inAppDebuggerDiagnostic("Store") {
        "flushVisibleUiState activeFeed=$activeFeed " +
          "logs=${logsState?.items?.size ?: -1}/${logsState?.totalSize ?: -1} " +
          "network=${networkState?.items?.size ?: -1}/${networkState?.totalSize ?: -1} " +
          "errors=${errorsState?.items?.size ?: -1}/${errorsState?.totalSize ?: -1}"
      }
    }
  }

  private fun createLogsWindowStateLocked(): DebugListWindowState<DebugLogEntry> {
    logsDirty = false
    return DebugListWindowState(
      version = logsVersion,
      totalSize = logs.size,
      items = logs.snapshot()
    )
  }

  private fun createErrorsWindowStateLocked(): DebugListWindowState<DebugErrorEntry> {
    errorsDirty = false
    return DebugListWindowState(
      version = errorsVersion,
      totalSize = errors.size,
      items = errors.snapshot()
    )
  }

  private fun createNetworkWindowStateLocked(): DebugListWindowState<DebugNetworkEntry> {
    networkDirty = false
    return DebugListWindowState(
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

  private fun parseLog(raw: ReadableArray): DebugLogEntry? {
    val id = raw.string(0) ?: return null
    val fullTimestamp = raw.string(7) ?: ""
    return DebugLogEntry(
      id = id,
      type = raw.string(1) ?: "log",
      origin = raw.string(2) ?: "js",
      context = raw.string(3),
      details = raw.string(4),
      message = raw.string(5) ?: "",
      timestamp = raw.string(6) ?: "",
      fullTimestamp = fullTimestamp,
      timelineTimestampMillis =
        raw.long(8) ?: resolveTimelineTimestampMillis(fullTimestamp, id = id),
      timelineSequence = raw.long(9) ?: resolveTimelineSequence(id)
    )
  }

  private fun parseError(raw: ReadableArray): DebugErrorEntry? {
    val id = raw.string(0) ?: return null
    val fullTimestamp = raw.string(4) ?: ""
    return DebugErrorEntry(
      id = id,
      source = raw.string(1) ?: "console",
      message = raw.string(2) ?: "",
      timestamp = raw.string(3) ?: "",
      fullTimestamp = fullTimestamp,
      timelineTimestampMillis =
        raw.long(5) ?: resolveTimelineTimestampMillis(fullTimestamp, id = id),
      timelineSequence = raw.long(6) ?: resolveTimelineSequence(id)
    )
  }

  private fun parseNetwork(raw: ReadableArray): DebugNetworkEntry? {
    val id = raw.string(0) ?: return null
    val startedAt = raw.long(6) ?: 0L
    return DebugNetworkEntry(
      id = id,
      kind = raw.string(1) ?: "http",
      method = raw.string(2) ?: "GET",
      url = raw.string(3) ?: "",
      origin = raw.string(4) ?: "js",
      state = raw.string(5) ?: "pending",
      startedAt = startedAt,
      updatedAt = raw.long(7) ?: startedAt,
      endedAt = raw.long(8),
      durationMs = raw.long(9),
      status = raw.int(10),
      requestHeaders = raw.stringMap(11),
      responseHeaders = raw.stringMap(12),
      requestBody = raw.string(13),
      responseBody = raw.string(14),
      responseType = raw.string(15),
      responseContentType = raw.string(16),
      responseSize = raw.int(17),
      error = raw.string(18),
      protocol = raw.string(19),
      requestedProtocols = raw.string(20),
      closeReason = raw.string(21),
      closeCode = raw.int(22),
      requestedCloseCode = raw.int(23),
      requestedCloseReason = raw.string(24),
      cleanClose = raw.bool(25),
      messageCountIn = raw.int(26),
      messageCountOut = raw.int(27),
      bytesIn = raw.int(28),
      bytesOut = raw.int(29),
      events = raw.string(30),
      messages = raw.string(31),
      timelineSequence = raw.long(32) ?: resolveTimelineSequence(id)
    )
  }

  private fun parseBatch(
    logs: ReadableArray?,
    errors: ReadableArray?,
    network: ReadableArray?
  ): ParsedBatch {
    return ParsedBatch(
      logs = parseBatchItems(logs, ::parseLog),
      errors = parseBatchItems(errors, ::parseError),
      network = parseBatchItems(network, ::parseNetwork)
    )
  }
}

private class TimelineBuffer<T>(
  initialCapacity: Int,
  private val sortKeySelector: (T) -> TimelineSortKey
) {
  private var capacity = initialCapacity.coerceAtLeast(0)
  private val items = ArrayList<T>(capacity.coerceAtLeast(0))

  val size: Int
    get() = items.size

  fun append(item: T): Boolean {
    if (capacity == 0) {
      return false
    }

    val sortKey = sortKeySelector(item)
    if (items.size >= capacity) {
      val oldestSortKey = sortKeySelector(items[0])
      if (compareTimelineSortKeys(sortKey, oldestSortKey) <= 0) {
        return false
      }
    }

    val insertionIndex =
      if (items.isEmpty()) {
        0
      } else {
        val tailSortKey = sortKeySelector(items[items.lastIndex])
        if (compareTimelineSortKeys(tailSortKey, sortKey) <= 0) {
          items.size
        } else {
          insertionIndexFor(sortKey)
        }
      }
    if (insertionIndex == items.size) {
      items.add(item)
    } else {
      items.add(insertionIndex, item)
    }
    if (items.size > capacity) {
      items.removeAt(0)
    }
    return true
  }

  fun appendAll(values: Iterable<T>): Boolean {
    var changed = false
    values.forEach { value ->
      if (append(value)) {
        changed = true
      }
    }
    return changed
  }

  fun moveAllTo(target: TimelineBuffer<T>): Boolean {
    if (items.isEmpty()) {
      return false
    }

    var targetChanged = false
    items.forEach { item ->
      if (target.append(item)) {
        targetChanged = true
      }
    }
    items.clear()
    return targetChanged
  }

  fun snapshot(): List<T> {
    if (items.isEmpty()) {
      return emptyList()
    }
    return ArrayList(items)
  }

  fun clear(): Boolean {
    if (items.isEmpty()) {
      return false
    }

    items.clear()
    return true
  }

  fun resize(nextCapacity: Int): Boolean {
    val normalizedCapacity = nextCapacity.coerceAtLeast(0)
    if (normalizedCapacity == capacity) {
      return false
    }

    capacity = normalizedCapacity
    trimToCapacity()
    return true
  }

  private fun trimToCapacity() {
    if (capacity <= 0) {
      items.clear()
      return
    }

    val overflow = items.size - capacity
    if (overflow > 0) {
      items.subList(0, overflow).clear()
    }
  }

  private fun insertionIndexFor(sortKey: TimelineSortKey): Int {
    var low = 0
    var high = items.size
    while (low < high) {
      val mid = (low + high) ushr 1
      val comparison = compareTimelineSortKeys(sortKeySelector(items[mid]), sortKey)
      if (comparison <= 0) {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }
}

private class KeyedTimelineBuffer<T>(
  initialCapacity: Int,
  private val keySelector: (T) -> String,
  private val sortKeySelector: (T) -> TimelineSortKey
) {
  private var capacity = initialCapacity.coerceAtLeast(0)
  private val itemsByKey = HashMap<String, T>(capacity.coerceAtLeast(16))
  private val sortKeysByKey = HashMap<String, TimelineSortKey>(capacity.coerceAtLeast(16))
  private val orderedKeys = ArrayList<String>(capacity.coerceAtLeast(0))

  val size: Int
    get() = orderedKeys.size

  fun upsert(item: T): Boolean {
    if (capacity == 0) {
      return false
    }

    val key = keySelector(item)
    val sortKey = sortKeySelector(item)
    if (!itemsByKey.containsKey(key) && orderedKeys.size >= capacity) {
      val oldestKey = orderedKeys.firstOrNull()
      val oldestSortKey = oldestKey?.let(sortKeysByKey::get)
      if (oldestSortKey != null && compareTimelineSortKeys(sortKey, oldestSortKey) <= 0) {
        return false
      }
    }

    orderedKeys.remove(key)
    itemsByKey[key] = item
    sortKeysByKey[key] = sortKey

    val insertionIndex =
      if (orderedKeys.isEmpty()) {
        0
      } else {
        val tailKey = orderedKeys[orderedKeys.lastIndex]
        val tailSortKey = sortKeysByKey[tailKey]
        if (tailSortKey != null && compareTimelineSortKeys(tailSortKey, sortKey) <= 0) {
          orderedKeys.size
        } else {
          insertionIndexFor(sortKey)
        }
      }
    if (insertionIndex == orderedKeys.size) {
      orderedKeys.add(key)
    } else {
      orderedKeys.add(insertionIndex, key)
    }
    if (orderedKeys.size > capacity) {
      val removedKey = orderedKeys.removeAt(0)
      itemsByKey.remove(removedKey)
      sortKeysByKey.remove(removedKey)
      return removedKey != key
    }
    return true
  }

  fun get(key: String): T? {
    return itemsByKey[key]
  }

  fun upsertAll(values: Iterable<T>): Boolean {
    var changed = false
    values.forEach { value ->
      if (upsert(value)) {
        changed = true
      }
    }
    return changed
  }

  fun snapshot(): List<T> {
    if (orderedKeys.isEmpty()) {
      return emptyList()
    }

    val result = ArrayList<T>(orderedKeys.size)
    orderedKeys.forEach { key ->
      itemsByKey[key]?.let(result::add)
    }
    return result
  }

  fun clear(): Boolean {
    if (orderedKeys.isEmpty()) {
      return false
    }

    itemsByKey.clear()
    sortKeysByKey.clear()
    orderedKeys.clear()
    return true
  }

  fun resize(nextCapacity: Int): Boolean {
    val normalizedCapacity = nextCapacity.coerceAtLeast(0)
    if (normalizedCapacity == capacity) {
      return false
    }

    capacity = normalizedCapacity
    trimToCapacity()
    return true
  }

  private fun trimToCapacity() {
    if (capacity <= 0) {
      itemsByKey.clear()
      sortKeysByKey.clear()
      orderedKeys.clear()
      return
    }

    while (orderedKeys.size > capacity) {
      val removedKey = orderedKeys.removeAt(0)
      itemsByKey.remove(removedKey)
      sortKeysByKey.remove(removedKey)
    }
  }

  private fun insertionIndexFor(sortKey: TimelineSortKey): Int {
    var low = 0
    var high = orderedKeys.size
    while (low < high) {
      val mid = (low + high) ushr 1
      val currentKey = orderedKeys[mid]
      val currentSortKey = sortKeysByKey[currentKey] ?: break
      val comparison = compareTimelineSortKeys(currentSortKey, sortKey)
      if (comparison <= 0) {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }
}

private fun compareTimelineSortKeys(lhs: TimelineSortKey, rhs: TimelineSortKey): Int {
  val primaryComparison = lhs.primaryTimeMillis.compareTo(rhs.primaryTimeMillis)
  if (primaryComparison != 0) {
    return primaryComparison
  }

  val secondaryComparison = lhs.secondaryTimeMillis.compareTo(rhs.secondaryTimeMillis)
  if (secondaryComparison != 0) {
    return secondaryComparison
  }

  val sequenceComparison = lhs.sequence.compareTo(rhs.sequence)
  if (sequenceComparison != 0) {
    return sequenceComparison
  }

  return lhs.stableId.compareTo(rhs.stableId)
}

private data class ParsedBatch(
  val logs: List<DebugLogEntry>,
  val errors: List<DebugErrorEntry>,
  val network: List<DebugNetworkEntry>
)

private fun <T> parseBatchItems(
  raw: ReadableArray?,
  parser: (ReadableArray) -> T?
): List<T> {
  raw ?: return emptyList()
  if (raw.size() == 0) {
    return emptyList()
  }

  val result = ArrayList<T>(raw.size())
  for (index in 0 until raw.size()) {
    raw.array(index)?.let { item ->
      parser(item)?.let(result::add)
    }
  }
  return result
}

private fun ReadableArray.typeAt(index: Int): ReadableType? {
  if (index < 0 || index >= size()) {
    return null
  }
  return getType(index)
}

private fun ReadableArray.string(index: Int): String? {
  return if (typeAt(index) == ReadableType.String) {
    getString(index)
  } else {
    null
  }
}

private fun ReadableArray.stringValue(index: Int): String? {
  return when (typeAt(index)) {
    ReadableType.String -> getString(index)
    ReadableType.Number -> {
      val value = getDouble(index)
      if (value == value.toLong().toDouble()) {
        value.toLong().toString()
      } else {
        value.toString()
      }
    }
    ReadableType.Boolean -> getBoolean(index).toString()
    else -> null
  }
}

private fun ReadableArray.int(index: Int): Int? {
  return if (typeAt(index) == ReadableType.Number) {
    getDouble(index).toInt()
  } else {
    null
  }
}

private fun ReadableArray.long(index: Int): Long? {
  return if (typeAt(index) == ReadableType.Number) {
    getDouble(index).toLong()
  } else {
    null
  }
}

private fun ReadableArray.bool(index: Int): Boolean? {
  return if (typeAt(index) == ReadableType.Boolean) {
    getBoolean(index)
  } else {
    null
  }
}

private fun ReadableArray.array(index: Int): ReadableArray? {
  return if (typeAt(index) == ReadableType.Array) {
    getArray(index)
  } else {
    null
  }
}

private fun ReadableArray.stringMap(index: Int): Map<String, String> {
  return array(index).stringMapValue()
}

private fun ReadableArray?.stringMapValue(): Map<String, String> {
  this ?: return emptyMap()
  if (size() == 0) {
    return emptyMap()
  }

  val result = LinkedHashMap<String, String>(size() / 2)
  var index = 0
  while (index + 1 < size()) {
    val key = string(index)
    if (key != null) {
      result[key] = stringValue(index + 1) ?: ""
    }
    index += 2
  }
  return result
}
