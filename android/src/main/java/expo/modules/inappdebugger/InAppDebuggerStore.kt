package expo.modules.inappdebugger

import android.os.Handler
import android.os.HandlerThread
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

  fun ingestBatch(batch: Map<String, Any?>) {
    inAppDebuggerDiagnostic("Store") {
      "ingestBatch raw logs=${describeBatchPayload(batch["logs"])} " +
        "errors=${describeBatchPayload(batch["errors"])} " +
        "network=${describeBatchPayload(batch["network"])}"
    }
    val parsedBatch = parseBatch(batch)
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

  private fun parseLog(raw: Any?): DebugLogEntry? {
    val map = raw.typedMap()
    if (map != null) {
      val id = map.string("id") ?: return null
      val fullTimestamp = map.string("fullTimestamp") ?: ""
      return DebugLogEntry(
        id = id,
        type = map.string("type") ?: "log",
        origin = map.string("origin") ?: "js",
        context = map.string("context"),
        details = map.string("details"),
        message = map.string("message") ?: "",
        timestamp = map.string("timestamp") ?: "",
        fullTimestamp = fullTimestamp,
        timelineTimestampMillis =
          map.long("timelineTimestampMillis")
            ?: map.long("timestampMillis")
            ?: resolveTimelineTimestampMillis(fullTimestamp, id = id),
        timelineSequence = map.long("timelineSequence") ?: resolveTimelineSequence(id)
      )
    }

    val list = raw.typedList() ?: return null
    val id = list.string(0) ?: return null
    val fullTimestamp = list.string(7) ?: ""
    return DebugLogEntry(
      id = id,
      type = list.string(1) ?: "log",
      origin = list.string(2) ?: "js",
      context = list.string(3),
      details = list.string(4),
      message = list.string(5) ?: "",
      timestamp = list.string(6) ?: "",
      fullTimestamp = fullTimestamp,
      timelineTimestampMillis =
        list.long(8) ?: resolveTimelineTimestampMillis(fullTimestamp, id = id),
      timelineSequence = list.long(9) ?: resolveTimelineSequence(id)
    )
  }

  private fun parseError(raw: Any?): DebugErrorEntry? {
    val map = raw.typedMap()
    if (map != null) {
      val id = map.string("id") ?: return null
      val fullTimestamp = map.string("fullTimestamp") ?: ""
      return DebugErrorEntry(
        id = id,
        source = map.string("source") ?: "console",
        message = map.string("message") ?: "",
        timestamp = map.string("timestamp") ?: "",
        fullTimestamp = fullTimestamp,
        timelineTimestampMillis =
          map.long("timelineTimestampMillis")
            ?: map.long("timestampMillis")
            ?: resolveTimelineTimestampMillis(fullTimestamp, id = id),
        timelineSequence = map.long("timelineSequence") ?: resolveTimelineSequence(id)
      )
    }

    val list = raw.typedList() ?: return null
    val id = list.string(0) ?: return null
    val fullTimestamp = list.string(4) ?: ""
    return DebugErrorEntry(
      id = id,
      source = list.string(1) ?: "console",
      message = list.string(2) ?: "",
      timestamp = list.string(3) ?: "",
      fullTimestamp = fullTimestamp,
      timelineTimestampMillis =
        list.long(5) ?: resolveTimelineTimestampMillis(fullTimestamp, id = id),
      timelineSequence = list.long(6) ?: resolveTimelineSequence(id)
    )
  }

  private fun parseNetwork(raw: Any?): DebugNetworkEntry? {
    val map = raw.typedMap()
    if (map != null) {
      val id = map.string("id") ?: return null
      return DebugNetworkEntry(
        id = id,
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
        messages = map.string("messages"),
        timelineSequence = map.long("timelineSequence") ?: resolveTimelineSequence(id)
      )
    }

    val list = raw.typedList() ?: return null
    val id = list.string(0) ?: return null
    val startedAt = list.long(6) ?: 0L
    return DebugNetworkEntry(
      id = id,
      kind = list.string(1) ?: "http",
      method = list.string(2) ?: "GET",
      url = list.string(3) ?: "",
      origin = list.string(4) ?: "js",
      state = list.string(5) ?: "pending",
      startedAt = startedAt,
      updatedAt = list.long(7) ?: startedAt,
      endedAt = list.long(8),
      durationMs = list.long(9),
      status = list.int(10),
      requestHeaders = list.stringMap(11),
      responseHeaders = list.stringMap(12),
      requestBody = list.string(13),
      responseBody = list.string(14),
      responseType = list.string(15),
      responseContentType = list.string(16),
      responseSize = list.int(17),
      error = list.string(18),
      protocol = list.string(19),
      requestedProtocols = list.string(20),
      closeReason = list.string(21),
      closeCode = list.int(22),
      requestedCloseCode = list.int(23),
      requestedCloseReason = list.string(24),
      cleanClose = list.bool(25),
      messageCountIn = list.int(26),
      messageCountOut = list.int(27),
      bytesIn = list.int(28),
      bytesOut = list.int(29),
      events = list.string(30),
      messages = list.string(31),
      timelineSequence = list.long(32) ?: resolveTimelineSequence(id)
    )
  }

  private fun parseBatch(batch: Map<String, Any?>): ParsedBatch {
    return ParsedBatch(
      logs = parseBatchItems(batch["logs"], ::parseLog),
      errors = parseBatchItems(batch["errors"], ::parseError),
      network = parseBatchItems(batch["network"], ::parseNetwork)
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

    val insertionIndex = insertionIndexFor(sortKeySelector(item))
    items.add(insertionIndex, item)
    if (items.size > capacity) {
      if (insertionIndex == 0) {
        items.removeAt(0)
        return false
      }
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
    orderedKeys.remove(key)
    itemsByKey[key] = item
    val sortKey = sortKeySelector(item)
    sortKeysByKey[key] = sortKey

    val insertionIndex = insertionIndexFor(sortKey)
    orderedKeys.add(insertionIndex, key)
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

private fun Map<String, Any?>.string(key: String): String? = this[key] as? String

@Suppress("UNCHECKED_CAST")
private fun Any?.typedMap(): Map<String, Any?>? = this as? Map<String, Any?>

@Suppress("UNCHECKED_CAST")
private fun Any?.typedList(): List<Any?>? = this as? List<Any?>

private fun Map<String, Any?>.int(key: String): Int? = (this[key] as? Number)?.toInt()

private fun Map<String, Any?>.long(key: String): Long? = (this[key] as? Number)?.toLong()

private fun Map<String, Any?>.bool(key: String): Boolean? = this[key] as? Boolean

private fun List<Any?>.string(index: Int): String? = getOrNull(index) as? String

private fun List<Any?>.int(index: Int): Int? = (getOrNull(index) as? Number)?.toInt()

private fun List<Any?>.long(index: Int): Long? = (getOrNull(index) as? Number)?.toLong()

private fun List<Any?>.bool(index: Int): Boolean? = getOrNull(index) as? Boolean

private fun Map<String, Any?>.stringMap(key: String): Map<String, String> {
  return this[key].stringMapValue()
}

private fun List<Any?>.stringMap(index: Int): Map<String, String> {
  return getOrNull(index).stringMapValue()
}

private fun Any?.stringMapValue(): Map<String, String> {
  when (this) {
    is Map<*, *> -> {
      if (isEmpty()) {
        return emptyMap()
      }

      val result = LinkedHashMap<String, String>(size)
      forEach { (entryKey, entryValue) ->
        val mapKey = entryKey as? String ?: return@forEach
        result[mapKey] = entryValue?.toString() ?: ""
      }
      return result
    }

    is List<*> -> {
      if (isEmpty()) {
        return emptyMap()
      }

      val result = LinkedHashMap<String, String>(size / 2)
      var index = 0
      while (index + 1 < size) {
        val mapKey = get(index) as? String
        if (mapKey != null) {
          result[mapKey] = get(index + 1)?.toString() ?: ""
        }
        index += 2
      }
      return result
    }

    else -> return emptyMap()
  }
}

private data class ParsedBatch(
  val logs: List<DebugLogEntry>,
  val errors: List<DebugErrorEntry>,
  val network: List<DebugNetworkEntry>
)

private fun <T> parseBatchItems(
  raw: Any?,
  parser: (Any?) -> T?
): List<T> {
  val items = raw.batchItems() ?: return emptyList()
  if (items.isEmpty()) {
    return emptyList()
  }

  val result = ArrayList<T>(items.size)
  items.forEach { item ->
    parser(item)?.let(result::add)
  }
  return result
}

private fun Any?.batchItems(): List<Any?>? {
  return when (this) {
    is List<*> -> this
    is Array<*> -> this.asList()
    is Iterable<*> -> this.toList()
    else -> null
  }
}

private fun describeBatchPayload(raw: Any?): String {
  val type = raw?.javaClass?.name ?: "null"
  val size = raw.batchItems()?.size
  return if (size != null) "$type(size=$size)" else type
}
