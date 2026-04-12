import Foundation

private let nativeLogClockFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "HH:mm:ss.SSS"
  return formatter
}()

private let nativeLogISOFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

private let exportSnapshotISOFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

let inAppDebuggerStoreChangeMaskUserInfoKey = "InAppDebuggerStoreChangeMask"
let inAppDebuggerStoreChangedNetworkIDsUserInfoKey = "InAppDebuggerStoreChangedNetworkIDs"

struct InAppDebuggerStoreChangeMask: OptionSet {
  let rawValue: Int

  static let config = InAppDebuggerStoreChangeMask(rawValue: 1 << 0)
  static let logs = InAppDebuggerStoreChangeMask(rawValue: 1 << 1)
  static let errors = InAppDebuggerStoreChangeMask(rawValue: 1 << 2)
  static let network = InAppDebuggerStoreChangeMask(rawValue: 1 << 3)
  static let all: InAppDebuggerStoreChangeMask = [.config, .logs, .errors, .network]
}

extension Notification.Name {
  static let inAppDebuggerStoreDidChange = Notification.Name("InAppDebuggerStoreDidChange")
}

private func compareDebugNetworkEntries(_ lhs: DebugNetworkEntry, _ rhs: DebugNetworkEntry) -> Int {
  if lhs.startedAt != rhs.startedAt {
    return lhs.startedAt < rhs.startedAt ? -1 : 1
  }

  let lhsSequence = lhs.timelineSequence ?? 0
  let rhsSequence = rhs.timelineSequence ?? 0
  if lhsSequence != rhsSequence {
    return lhsSequence < rhsSequence ? -1 : 1
  }

  if lhs.id == rhs.id {
    return 0
  }
  return lhs.id < rhs.id ? -1 : 1
}

final class InAppDebuggerStore {
  static let shared = InAppDebuggerStore()

  private let lock = NSLock()
  private var config = DebugConfig()
  private var logs = InAppDebuggerRingBuffer<DebugLogEntry>(capacity: DebugConfig().maxLogs)
  private var pendingNativeLogs = InAppDebuggerRingBuffer<DebugLogEntry>(capacity: DebugConfig().maxLogs)
  private var errors = InAppDebuggerRingBuffer<DebugErrorEntry>(capacity: DebugConfig().maxErrors)
  private var network = InAppDebuggerKeyedRingBuffer<String, DebugNetworkEntry>(
    capacity: DebugConfig().maxRequests,
    key: \.id,
    order: compareDebugNetworkEntries
  )
  private var liveUpdatesEnabled = false
  private var notificationScheduled = false
  private var pendingChangeMask: InAppDebuggerStoreChangeMask = []
  private var pendingChangedNetworkIDs: Set<String> = []
  private var nextNativeSequence = 0
  private var cachedNativeTimestampSecond = -1
  private var cachedNativeClockPrefix = ""
  private var cachedNativeISOPrefix = ""

  private init() {}

  func update(config next: DebugConfig) {
    lock.lock()
    let didConfigChange = next != config
    let shouldFlushPendingNativeLogs = next.enabled && !pendingNativeLogs.isEmpty
    config = next
    trimLocked()
    if shouldFlushPendingNativeLogs {
      pendingNativeLogs.moveAll(to: logs)
    }
    lock.unlock()

    var changeMask: InAppDebuggerStoreChangeMask = []
    if didConfigChange {
      changeMask.insert(.config)
    }
    if shouldFlushPendingNativeLogs {
      changeMask.insert(.logs)
    }
    guard !changeMask.isEmpty else {
      return
    }
    notifyChanged(changeMask)
  }

  func setLiveUpdatesEnabled(_ enabled: Bool) {
    lock.lock()
    liveUpdatesEnabled = enabled
    lock.unlock()
  }

  func currentConfig() -> DebugConfig {
    lock.lock()
    defer { lock.unlock() }
    return config
  }

  func nextNativeTimelineSequence() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return nextNativeTimelineSequenceLocked()
  }

  func shutdown() {
    lock.lock()
    config = DebugConfig()
    logs = InAppDebuggerRingBuffer<DebugLogEntry>(capacity: DebugConfig().maxLogs)
    pendingNativeLogs = InAppDebuggerRingBuffer<DebugLogEntry>(capacity: DebugConfig().maxLogs)
    errors = InAppDebuggerRingBuffer<DebugErrorEntry>(capacity: DebugConfig().maxErrors)
    network = InAppDebuggerKeyedRingBuffer<String, DebugNetworkEntry>(
      capacity: DebugConfig().maxRequests,
      key: \.id,
      order: compareDebugNetworkEntries
    )
    liveUpdatesEnabled = false
    notificationScheduled = false
    pendingChangeMask = []
    pendingChangedNetworkIDs.removeAll(keepingCapacity: true)
    nextNativeSequence = 0
    cachedNativeTimestampSecond = -1
    cachedNativeClockPrefix = ""
    cachedNativeISOPrefix = ""
    lock.unlock()
  }

  func snapshotState() -> (DebugConfig, [DebugLogEntry], [DebugErrorEntry], [DebugNetworkEntry]) {
    lock.lock()
    defer { lock.unlock() }
    return (config, logs.snapshot(), errors.snapshot(), network.snapshot())
  }

  func snapshotLogs() -> [DebugLogEntry] {
    lock.lock()
    defer { lock.unlock() }
    return logs.snapshot()
  }

  func snapshotNetwork() -> [DebugNetworkEntry] {
    lock.lock()
    defer { lock.unlock() }
    return network.snapshot()
  }

  func snapshotAppInfo() -> ([DebugLogEntry], [DebugErrorEntry]) {
    lock.lock()
    defer { lock.unlock() }
    return (logs.snapshot(), errors.snapshot())
  }

  func ingest(batch: [[String: Any]]) {
    lock.lock()
    var changeMask: InAppDebuggerStoreChangeMask = []
    var changedNetworkIDs: Set<String> = []
    for item in batch {
      switch item["category"] as? String {
      case "log":
        if let entryMap = item["entry"] as? [String: Any], let entry = DebugLogEntry(map: entryMap) {
          logs.append(entry)
          changeMask.insert(.logs)
        }
      case "error":
        if let entryMap = item["entry"] as? [String: Any], let entry = DebugErrorEntry(map: entryMap) {
          errors.append(entry)
          changeMask.insert(.errors)
        }
      case "network":
        if let entryMap = item["entry"] as? [String: Any], let entry = DebugNetworkEntry(map: entryMap) {
          upsertNetworkLocked(entry)
          changeMask.insert(.network)
          changedNetworkIDs.insert(entry.id)
        }
      default:
        break
      }
    }
    lock.unlock()
    guard !changeMask.isEmpty else {
      return
    }
    notifyChanged(changeMask, changedNetworkIDs: changedNetworkIDs)
  }

  func ingestBatch(logs rawLogs: [[Any]]?, errors rawErrors: [[Any]]?, network rawNetwork: [[Any]]?) {
    lock.lock()
    var changeMask: InAppDebuggerStoreChangeMask = []
    var changedNetworkIDs: Set<String> = []

    if let rawLogs {
      for item in rawLogs {
        guard let entry = DebugLogEntry(wire: item) else {
          continue
        }
        logs.append(entry)
        changeMask.insert(.logs)
      }
    }

    if let rawErrors {
      for item in rawErrors {
        guard let entry = DebugErrorEntry(wire: item) else {
          continue
        }
        errors.append(entry)
        changeMask.insert(.errors)
      }
    }

    if let rawNetwork {
      for item in rawNetwork {
        guard let entry = DebugNetworkEntry(wire: item) else {
          continue
        }
        upsertNetworkLocked(entry)
        changeMask.insert(.network)
        changedNetworkIDs.insert(entry.id)
      }
    }

    lock.unlock()

    guard !changeMask.isEmpty else {
      return
    }
    notifyChanged(changeMask, changedNetworkIDs: changedNetworkIDs)
  }

  func appendNativeLog(type: String, message: String, stream: String, details: String? = nil, date: Date = Date()) {
    lock.lock()
    let formatted = formattedNativeTimestampsLocked(for: date)
    let timelineSequence = nextNativeTimelineSequenceLocked()
    let entry = DebugLogEntry(
      id: "native_\(formatted.timestampMillis)_\(String(timelineSequence, radix: 36))",
      type: type,
      origin: "native",
      context: stream,
      details: details,
      message: message,
      timestamp: formatted.clock,
      fullTimestamp: formatted.iso,
      timelineTimestampMillis: formatted.timestampMillis,
      timelineSequence: timelineSequence
    )

    if config.enabled {
      logs.append(entry)
      trimLogsLocked()
    } else {
      pendingNativeLogs.append(entry)
      trimPendingNativeLogsLocked()
    }
    lock.unlock()
    notifyChanged(.logs)
  }

  func clear(kind: String) {
    lock.lock()
    var changeMask: InAppDebuggerStoreChangeMask = []
    switch kind {
    case "logs":
      if !logs.isEmpty || !pendingNativeLogs.isEmpty {
        logs.clear()
        pendingNativeLogs.clear()
        changeMask.insert(.logs)
      }
    case "errors":
      if !errors.isEmpty {
        errors.clear()
        changeMask.insert(.errors)
      }
    case "network":
      if network.count > 0 {
        network.clear()
        changeMask.insert(.network)
      }
    default:
      if !logs.isEmpty || !pendingNativeLogs.isEmpty {
        logs.clear()
        pendingNativeLogs.clear()
        changeMask.insert(.logs)
      }
      if !errors.isEmpty {
        errors.clear()
        changeMask.insert(.errors)
      }
      if network.count > 0 {
        network.clear()
        changeMask.insert(.network)
      }
    }
    lock.unlock()
    guard !changeMask.isEmpty else {
      return
    }
    notifyChanged(changeMask)
  }

  func upsertNetworkEntry(_ entry: DebugNetworkEntry) {
    lock.lock()
    upsertNetworkLocked(entry)
    lock.unlock()
    notifyChanged(.network, changedNetworkIDs: [entry.id])
  }

  func networkEntry(withID id: String) -> DebugNetworkEntry? {
    lock.lock()
    defer { lock.unlock() }
    return network.value(forKey: id)
  }

  func exportSnapshot() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return [
      "logs": logs.snapshot().map { $0.asDictionary() },
      "errors": errors.snapshot().map { $0.asDictionary() },
      "network": network.snapshot().map { $0.asDictionary() },
      "exportTime": exportSnapshotISOFormatter.string(from: Date()),
    ]
  }

  private func trimLocked() {
    trimLogsLocked()
    trimPendingNativeLogsLocked()
    trimErrorsLocked()
    trimNetworkLocked()
  }

  private func trimLogsLocked() {
    logs.resize(capacity: config.maxLogs)
  }

  private func trimPendingNativeLogsLocked() {
    pendingNativeLogs.resize(capacity: config.maxLogs)
  }

  private func trimErrorsLocked() {
    errors.resize(capacity: config.maxErrors)
  }

  private func trimNetworkLocked() {
    network.resize(capacity: config.maxRequests)
  }

  private func nextNativeTimelineSequenceLocked() -> Int {
    nextNativeSequence += 1
    return nextNativeSequence
  }

  private func formattedNativeTimestampsLocked(for date: Date) -> (timestampMillis: Int, clock: String, iso: String) {
    let timestampMillis = Int(date.timeIntervalSince1970 * 1000)
    let secondBucket = timestampMillis / 1000
    if secondBucket != cachedNativeTimestampSecond {
      let secondDate = Date(timeIntervalSince1970: TimeInterval(secondBucket))
      cachedNativeTimestampSecond = secondBucket
      cachedNativeClockPrefix = String(nativeLogClockFormatter.string(from: secondDate).dropLast(3))
      cachedNativeISOPrefix = String(nativeLogISOFormatter.string(from: secondDate).dropLast(4))
    }

    let millisecond = String(format: "%03d", max(0, timestampMillis - secondBucket * 1000))
    return (
      timestampMillis: timestampMillis,
      clock: cachedNativeClockPrefix + millisecond,
      iso: cachedNativeISOPrefix + millisecond + "Z"
    )
  }

  private func notifyChanged(
    _ changeMask: InAppDebuggerStoreChangeMask,
    changedNetworkIDs: Set<String> = []
  ) {
    lock.lock()
    guard liveUpdatesEnabled || notificationScheduled else {
      lock.unlock()
      return
    }
    pendingChangeMask.formUnion(changeMask)
    pendingChangedNetworkIDs.formUnion(changedNetworkIDs)
    guard liveUpdatesEnabled, !notificationScheduled else {
      lock.unlock()
      return
    }
    notificationScheduled = true
    lock.unlock()

    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }
      self.lock.lock()
      self.notificationScheduled = false
      let shouldNotify = self.liveUpdatesEnabled
      let pendingChangeMask = self.pendingChangeMask
      let pendingChangedNetworkIDs = self.pendingChangedNetworkIDs
      self.pendingChangeMask = []
      self.pendingChangedNetworkIDs.removeAll(keepingCapacity: true)
      self.lock.unlock()
      guard shouldNotify, !pendingChangeMask.isEmpty else {
        return
      }
      var userInfo: [AnyHashable: Any] = [
        inAppDebuggerStoreChangeMaskUserInfoKey: pendingChangeMask.rawValue,
      ]
      if !pendingChangedNetworkIDs.isEmpty {
        userInfo[inAppDebuggerStoreChangedNetworkIDsUserInfoKey] = Array(pendingChangedNetworkIDs)
      }
      NotificationCenter.default.post(name: .inAppDebuggerStoreDidChange, object: nil, userInfo: userInfo)
    }
  }

  private func upsertNetworkLocked(_ entry: DebugNetworkEntry) {
    network.upsert(entry)
  }
}

private final class InAppDebuggerRingBuffer<Element> {
  private var storage: [Element?]
  private var head = 0
  private(set) var count = 0

  var isEmpty: Bool {
    count == 0
  }

  init(capacity: Int) {
    storage = Array(repeating: nil, count: max(0, capacity))
  }

  @discardableResult
  func append(_ element: Element) -> Bool {
    guard !storage.isEmpty else {
      return false
    }

    if count < storage.count {
      storage[(head + count) % storage.count] = element
      count += 1
      return true
    }

    storage[head] = element
    head = (head + 1) % storage.count
    return true
  }

  @discardableResult
  func append(contentsOf elements: [Element]) -> Bool {
    var didChange = false
    for element in elements {
      didChange = append(element) || didChange
    }
    return didChange
  }

  @discardableResult
  func moveAll(to target: InAppDebuggerRingBuffer<Element>) -> Bool {
    guard count > 0 else {
      return false
    }

    var didChange = false
    if !storage.isEmpty {
      for offset in 0..<count {
        let index = (head + offset) % storage.count
        if let element = storage[index] {
          didChange = target.append(element) || didChange
          storage[index] = nil
        }
      }
    }

    head = 0
    count = 0
    return didChange
  }

  func snapshot() -> [Element] {
    guard count > 0 else {
      return []
    }

    var result: [Element] = []
    result.reserveCapacity(count)
    for offset in 0..<count {
      let index = (head + offset) % storage.count
      if let element = storage[index] {
        result.append(element)
      }
    }
    return result
  }

  func clear() {
    guard count > 0 else {
      return
    }

    if !storage.isEmpty {
      for offset in 0..<count {
        let index = (head + offset) % storage.count
        storage[index] = nil
      }
    }
    head = 0
    count = 0
  }

  func resize(capacity: Int) {
    let nextCapacity = max(0, capacity)
    guard nextCapacity != storage.count else {
      return
    }

    var nextStorage = Array<Element?>(repeating: nil, count: nextCapacity)
    let elementsToKeep = min(count, nextCapacity)
    if elementsToKeep > 0, !storage.isEmpty {
      let startOffset = count - elementsToKeep
      for position in 0..<elementsToKeep {
        let sourceIndex = (head + startOffset + position) % storage.count
        nextStorage[position] = storage[sourceIndex]
      }
    }

    storage = nextStorage
    head = 0
    count = elementsToKeep
  }
}

private final class InAppDebuggerKeyedRingBuffer<Key: Hashable, Element> {
  private var capacity: Int
  private var itemsByKey: [Key: Element] = [:]
  private var orderedKeys: [Key] = []
  private var indexByKey: [Key: Int] = [:]
  private let key: KeyPath<Element, Key>
  private let order: (Element, Element) -> Int

  var count: Int {
    orderedKeys.count
  }

  init(capacity: Int, key: KeyPath<Element, Key>, order: @escaping (Element, Element) -> Int) {
    self.capacity = max(0, capacity)
    self.key = key
    self.order = order
    itemsByKey.reserveCapacity(max(16, self.capacity))
    indexByKey.reserveCapacity(max(16, self.capacity))
    orderedKeys.reserveCapacity(self.capacity)
  }

  @discardableResult
  func upsert(_ element: Element) -> Bool {
    guard capacity > 0 else {
      return false
    }

    let elementKey = element[keyPath: key]
    let existed = itemsByKey[elementKey] != nil

    if !existed, orderedKeys.count >= capacity,
       let oldestKey = orderedKeys.first,
       let oldestElement = itemsByKey[oldestKey],
       order(element, oldestElement) <= 0 {
      return false
    }

    if let existingIndex = indexByKey[elementKey] {
      orderedKeys.remove(at: existingIndex)
      indexByKey.removeValue(forKey: elementKey)
      reindexRange(start: existingIndex)
    }

    if !existed, orderedKeys.count >= capacity {
      let removedKey = orderedKeys.removeFirst()
      itemsByKey.removeValue(forKey: removedKey)
      indexByKey.removeValue(forKey: removedKey)
      reindexRange(start: 0)
    }

    itemsByKey[elementKey] = element
    let insertionIndex = insertionIndex(for: element)
    orderedKeys.insert(elementKey, at: insertionIndex)
    reindexRange(start: insertionIndex)
    return true
  }

  func value(forKey key: Key) -> Element? {
    itemsByKey[key]
  }

  func snapshot() -> [Element] {
    guard !orderedKeys.isEmpty else {
      return []
    }

    var result: [Element] = []
    result.reserveCapacity(orderedKeys.count)
    for key in orderedKeys {
      if let element = itemsByKey[key] {
        result.append(element)
      }
    }
    return result
  }

  func clear() {
    guard !orderedKeys.isEmpty else {
      return
    }

    itemsByKey.removeAll(keepingCapacity: true)
    orderedKeys.removeAll(keepingCapacity: true)
    indexByKey.removeAll(keepingCapacity: true)
  }

  func resize(capacity: Int) {
    let nextCapacity = max(0, capacity)
    guard nextCapacity != self.capacity else {
      return
    }

    self.capacity = nextCapacity
    trimToCapacity()
  }

  private func trimToCapacity() {
    guard capacity > 0 else {
      clear()
      return
    }

    while orderedKeys.count > capacity {
      let removedKey = orderedKeys.removeFirst()
      itemsByKey.removeValue(forKey: removedKey)
      indexByKey.removeValue(forKey: removedKey)
      reindexRange(start: 0)
    }
  }

  private func insertionIndex(for element: Element) -> Int {
    var low = 0
    var high = orderedKeys.count

    while low < high {
      let mid = (low + high) / 2
      let midKey = orderedKeys[mid]
      guard let current = itemsByKey[midKey] else {
        high = mid
        continue
      }

      if order(current, element) <= 0 {
        low = mid + 1
      } else {
        high = mid
      }
    }

    return low
  }

  private func reindexRange(start: Int) {
    guard start < orderedKeys.count else {
      return
    }

    for index in start..<orderedKeys.count {
      indexByKey[orderedKeys[index]] = index
    }
  }
}
