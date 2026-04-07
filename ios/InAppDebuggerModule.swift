import ExpoModulesCore

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
        maxRequests: (rawConfig["maxRequests"] as? NSNumber)?.intValue ?? 100,
        locale: rawConfig["locale"] as? String ?? "en-US",
        strings: (rawConfig["strings"] as? [String: Any])?.reduce(into: [:]) { partialResult, item in
          partialResult[item.key] = item.value as? String ?? "\(item.value)"
        } ?? [:]
      )
      InAppDebuggerNativeLogCapture.shared.setEnabled(config.enabled)
      InAppDebuggerNativeWebSocketCapture.shared.setEnabled(config.enabled && config.enableNetworkTab)
      InAppDebuggerOverlayManager.shared.apply(config: config)
    }

    AsyncFunction("ingestBatch") { (batch: [[String: Any]]) in
      InAppDebuggerStore.shared.ingest(batch: batch)
    }

    AsyncFunction("clear") { (kind: String) in
      InAppDebuggerStore.shared.clear(kind: kind)
    }

    AsyncFunction("show") {
      InAppDebuggerOverlayManager.shared.show()
    }

    AsyncFunction("hide") {
      InAppDebuggerOverlayManager.shared.hide()
    }

    AsyncFunction("exportSnapshot") {
      InAppDebuggerStore.shared.exportSnapshot()
    }

    OnDestroy {
      InAppDebuggerNativeLogCapture.shared.setEnabled(false)
      InAppDebuggerNativeWebSocketCapture.shared.setEnabled(false)
      InAppDebuggerOverlayManager.shared.hide()
    }
  }
}
