import ExpoModulesCore

private var inAppDebuggerNativeRuntimeActive = false

public final class InAppDebuggerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("InAppDebugger")

    AsyncFunction("configure") { (rawConfig: [String: Any]) in
      let config = DebugConfig(
        enabled: rawConfig["enabled"] as? Bool ?? false,
        initialVisible: rawConfig["initialVisible"] as? Bool ?? true,
        enableNetworkTab: rawConfig["enableNetworkTab"] as? Bool ?? true,
        maxLogs: (rawConfig["maxLogs"] as? NSNumber)?.intValue ?? 2000,
        maxErrors: (rawConfig["maxErrors"] as? NSNumber)?.intValue ?? 100,
        maxRequests: (rawConfig["maxRequests"] as? NSNumber)?.intValue ?? 100
      )
      if !config.enabled && !inAppDebuggerNativeRuntimeActive {
        return
      }
      if !config.enabled {
        InAppDebuggerNativeLogCapture.shared.shutdown()
        InAppDebuggerNativeNetworkCapture.shared.setEnabled(false)
        InAppDebuggerNativeWebSocketCapture.shared.setEnabled(false)
        InAppDebuggerOverlayManager.shared.shutdown()
        InAppDebuggerStore.shared.shutdown()
        inAppDebuggerNativeRuntimeActive = false
        return
      }

      inAppDebuggerNativeRuntimeActive = true
      InAppDebuggerNativeLogCapture.shared.setEnabled(config.enabled)
      InAppDebuggerNativeNetworkCapture.shared.setEnabled(config.enabled && config.enableNetworkTab)
      InAppDebuggerNativeWebSocketCapture.shared.setEnabled(config.enabled && config.enableNetworkTab)
      InAppDebuggerOverlayManager.shared.apply(config: config)
    }

    AsyncFunction("ingestBatch") { (logs: [[Any]]?, errors: [[Any]]?, network: [[Any]]?) in
      guard inAppDebuggerNativeRuntimeActive else {
        return
      }
      InAppDebuggerStore.shared.ingestBatch(logs: logs, errors: errors, network: network)
    }

    AsyncFunction("clear") { (kind: String) in
      guard inAppDebuggerNativeRuntimeActive else {
        return
      }
      InAppDebuggerStore.shared.clear(kind: kind)
    }

    AsyncFunction("show") {
      guard inAppDebuggerNativeRuntimeActive else {
        return
      }
      InAppDebuggerOverlayManager.shared.show()
    }

    AsyncFunction("hide") {
      guard inAppDebuggerNativeRuntimeActive else {
        return
      }
      InAppDebuggerOverlayManager.shared.hide()
    }

    AsyncFunction("exportSnapshot") {
      guard inAppDebuggerNativeRuntimeActive else {
        return [
          "logs": [[String: Any]](),
          "errors": [[String: Any]](),
          "network": [[String: Any]](),
          "exportTime": ISO8601DateFormatter().string(from: Date()),
        ] as [String: Any]
      }
      return InAppDebuggerStore.shared.exportSnapshot()
    }

    OnDestroy {
      guard inAppDebuggerNativeRuntimeActive else {
        return
      }
      InAppDebuggerNativeLogCapture.shared.shutdown()
      InAppDebuggerNativeNetworkCapture.shared.setEnabled(false)
      InAppDebuggerNativeWebSocketCapture.shared.setEnabled(false)
      InAppDebuggerOverlayManager.shared.shutdown()
      InAppDebuggerStore.shared.shutdown()
      inAppDebuggerNativeRuntimeActive = false
    }
  }
}
