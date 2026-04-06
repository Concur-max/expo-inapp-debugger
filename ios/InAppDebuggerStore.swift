import Foundation

extension Notification.Name {
  static let inAppDebuggerStoreDidChange = Notification.Name("InAppDebuggerStoreDidChange")
}

final class InAppDebuggerStore {
  static let shared = InAppDebuggerStore()

  private let lock = NSLock()
  private var config = DebugConfig()
  private var logs: [DebugLogEntry] = []
  private var errors: [DebugErrorEntry] = []
  private var network: [DebugNetworkEntry] = []

  private init() {}

  func update(config next: DebugConfig) {
    lock.lock()
    config = next
    trimLocked()
    lock.unlock()
    notifyChanged()
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
          logs.insert(entry, at: 0)
          while logs.count > config.maxLogs {
            logs.removeLast()
          }
        }
      case "error":
        if let entryMap = item["entry"] as? [String: Any], let entry = DebugErrorEntry(map: entryMap) {
          errors.insert(entry, at: 0)
          while errors.count > config.maxErrors {
            errors.removeLast()
          }
        }
      case "network":
        if let entryMap = item["entry"] as? [String: Any], let entry = DebugNetworkEntry(map: entryMap) {
          network.removeAll(where: { $0.id == entry.id })
          network.insert(entry, at: 0)
          while network.count > config.maxRequests {
            network.removeLast()
          }
        }
      default:
        break
      }
    }
    lock.unlock()
    notifyChanged()
  }

  func clear(kind: String) {
    lock.lock()
    switch kind {
    case "logs":
      logs.removeAll()
    case "errors":
      errors.removeAll()
    case "network":
      network.removeAll()
    default:
      logs.removeAll()
      errors.removeAll()
      network.removeAll()
    }
    lock.unlock()
    notifyChanged()
  }

  func exportSnapshot() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return [
      "logs": logs.map { $0.asDictionary() },
      "errors": errors.map { $0.asDictionary() },
      "network": network.map { $0.asDictionary() },
      "exportTime": ISO8601DateFormatter().string(from: Date()),
    ]
  }

  private func trimLocked() {
    if logs.count > config.maxLogs {
      logs = Array(logs.prefix(config.maxLogs))
    }
    if errors.count > config.maxErrors {
      errors = Array(errors.prefix(config.maxErrors))
    }
    if network.count > config.maxRequests {
      network = Array(network.prefix(config.maxRequests))
    }
  }

  private func notifyChanged() {
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .inAppDebuggerStoreDidChange, object: nil)
    }
  }
}
