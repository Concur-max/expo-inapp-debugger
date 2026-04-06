package expo.modules.inappdebugger

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class InAppDebuggerModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("InAppDebugger")

    AsyncFunction("configure") { rawConfig: Map<String, Any?> ->
      val config = DebugConfig(
        enabled = rawConfig["enabled"] as? Boolean ?: false,
        initialVisible = rawConfig["initialVisible"] as? Boolean ?: true,
        enableNetworkTab = rawConfig["enableNetworkTab"] as? Boolean ?: true,
        maxLogs = (rawConfig["maxLogs"] as? Number)?.toInt() ?: 2000,
        maxErrors = (rawConfig["maxErrors"] as? Number)?.toInt() ?: 100,
        maxRequests = (rawConfig["maxRequests"] as? Number)?.toInt() ?: 100,
        locale = rawConfig["locale"] as? String ?: "en-US",
        strings = (rawConfig["strings"] as? Map<*, *>)?.entries?.mapNotNull { entry ->
          val key = entry.key as? String ?: return@mapNotNull null
          key to (entry.value?.toString() ?: "")
        }?.toMap() ?: emptyMap()
      )
      InAppDebuggerOverlayManager.applyConfig(appContext, config)
    }

    AsyncFunction("ingestBatch") { batch: List<Map<String, Any?>> ->
      InAppDebuggerStore.ingestBatch(batch)
    }

    AsyncFunction("clear") { kind: String ->
      InAppDebuggerStore.clear(kind)
    }

    AsyncFunction("show") {
      InAppDebuggerOverlayManager.show(appContext)
    }

    AsyncFunction("hide") {
      InAppDebuggerOverlayManager.hide(appContext)
    }

    AsyncFunction("exportSnapshot") {
      return@AsyncFunction InAppDebuggerStore.exportSnapshot()
    }

    OnActivityEntersForeground {
      InAppDebuggerOverlayManager.onActivityForeground(appContext)
    }

    OnActivityDestroys {
      InAppDebuggerOverlayManager.onActivityDestroyed()
    }

    OnDestroy {
      InAppDebuggerOverlayManager.hide(appContext)
    }
  }
}
