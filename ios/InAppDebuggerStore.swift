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

extension Notification.Name {
  static let inAppDebuggerStoreDidChange = Notification.Name("InAppDebuggerStoreDidChange")
}

final class InAppDebuggerStore {
  static let shared = InAppDebuggerStore()

  private let lock = NSLock()
  private var config = DebugConfig()
  private var logs: [DebugLogEntry] = []
  private var pendingNativeLogs: [DebugLogEntry] = []
  private var errors: [DebugErrorEntry] = []
  private var network: [DebugNetworkEntry] = []
  private var networkIndexByID: [String: Int] = [:]
  private var liveUpdatesEnabled = false
  private var notificationScheduled = false

  private init() {}

  func update(config next: DebugConfig) {
    lock.lock()
    let shouldFlushPendingNativeLogs = next.enabled && !pendingNativeLogs.isEmpty
    config = next
    if shouldFlushPendingNativeLogs {
      logs.append(contentsOf: pendingNativeLogs)
      pendingNativeLogs.removeAll(keepingCapacity: true)
    }
    trimLocked()
    lock.unlock()
    notifyChanged()
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

  func snapshotState() -> (DebugConfig, [DebugLogEntry], [DebugErrorEntry], [DebugNetworkEntry]) {
    lock.lock()
    defer { lock.unlock() }
    return (config, logs, errors, network)
  }

  func ingest(batch: [[String: Any]]) {
    lock.lock()
    for item in batch {
      switch item["category"] as? String {
      case "log":
        if let entryMap = item["entry"] as? [String: Any], let entry = DebugLogEntry(map: entryMap) {
          logs.append(entry)
          trimLogsLocked()
        }
      case "error":
        if let entryMap = item["entry"] as? [String: Any], let entry = DebugErrorEntry(map: entryMap) {
          errors.append(entry)
          trimErrorsLocked()
        }
      case "network":
        if let entryMap = item["entry"] as? [String: Any], let entry = DebugNetworkEntry(map: entryMap) {
          upsertNetworkLocked(entry)
        }
      default:
        break
      }
    }
    lock.unlock()
    notifyChanged()
  }

  func appendNativeLog(type: String, message: String, stream: String, details: String? = nil, date: Date = Date()) {
    lock.lock()
    let entry = DebugLogEntry(
      id: "native_\(Int(date.timeIntervalSince1970 * 1000))_\(UUID().uuidString)",
      type: type,
      origin: "native",
      context: stream,
      details: details,
      message: message,
      timestamp: nativeLogClockFormatter.string(from: date),
      fullTimestamp: nativeLogISOFormatter.string(from: date)
    )

    if config.enabled {
      logs.append(entry)
      trimLogsLocked()
    } else {
      pendingNativeLogs.append(entry)
      trimPendingNativeLogsLocked()
    }
    lock.unlock()
    notifyChanged()
  }

  func clear(kind: String) {
    lock.lock()
    switch kind {
    case "logs":
      logs.removeAll()
      pendingNativeLogs.removeAll()
    case "errors":
      errors.removeAll()
    case "network":
      network.removeAll()
      networkIndexByID.removeAll(keepingCapacity: false)
    default:
      logs.removeAll()
      pendingNativeLogs.removeAll()
      errors.removeAll()
      network.removeAll()
      networkIndexByID.removeAll(keepingCapacity: false)
    }
    lock.unlock()
    notifyChanged()
  }

  func upsertNetworkEntry(_ entry: DebugNetworkEntry) {
    lock.lock()
    upsertNetworkLocked(entry)
    lock.unlock()
    notifyChanged()
  }

  func networkEntry(withID id: String) -> DebugNetworkEntry? {
    lock.lock()
    defer { lock.unlock() }

    if let index = networkIndexByID[id], network.indices.contains(index) {
      return network[index]
    }
    return network.first(where: { $0.id == id })
  }

  func exportSnapshot() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return [
      "logs": logs.map { $0.asDictionary() },
      "errors": errors.map { $0.asDictionary() },
      "network": network.map { $0.asDictionary() },
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
    if logs.count > config.maxLogs {
      logs = Array(logs.suffix(config.maxLogs))
    }
  }

  private func trimPendingNativeLogsLocked() {
    if pendingNativeLogs.count > config.maxLogs {
      pendingNativeLogs = Array(pendingNativeLogs.suffix(config.maxLogs))
    }
  }

  private func trimErrorsLocked() {
    if errors.count > config.maxErrors {
      errors = Array(errors.suffix(config.maxErrors))
    }
  }

  private func trimNetworkLocked() {
    let overflow = network.count - config.maxRequests
    if overflow > 0 {
      network.removeFirst(overflow)
      rebuildNetworkIndexLocked()
    }
  }

  private func notifyChanged() {
    lock.lock()
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
      self.lock.unlock()
      guard shouldNotify else {
        return
      }
      NotificationCenter.default.post(name: .inAppDebuggerStoreDidChange, object: nil)
    }
  }

  private func upsertNetworkLocked(_ entry: DebugNetworkEntry) {
    if let existingIndex = networkIndexByID[entry.id], network.indices.contains(existingIndex) {
      network[existingIndex] = entry
    } else {
      network.append(entry)
      networkIndexByID[entry.id] = network.endIndex - 1
    }
    trimNetworkLocked()
  }

  private func rebuildNetworkIndexLocked() {
    networkIndexByID.removeAll(keepingCapacity: true)
    networkIndexByID.reserveCapacity(network.count)
    for (index, entry) in network.enumerated() {
      networkIndexByID[entry.id] = index
    }
  }
}
