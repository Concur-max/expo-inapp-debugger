package expo.modules.inappdebugger

import com.facebook.react.bridge.ReadableArray
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class InAppDebuggerModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("InAppDebugger")

    AsyncFunction("configure") { rawConfig: Map<String, Any?> ->
      val rawAndroidNativeLogs = rawConfig["androidNativeLogs"] as? Map<*, *>
      val config = DebugConfig(
        enabled = rawConfig["enabled"] as? Boolean ?: false,
        initialVisible = rawConfig["initialVisible"] as? Boolean ?: true,
        enableNetworkTab = rawConfig["enableNetworkTab"] as? Boolean ?: true,
        maxLogs = (rawConfig["maxLogs"] as? Number)?.toInt() ?: 2000,
        maxErrors = (rawConfig["maxErrors"] as? Number)?.toInt() ?: 100,
        maxRequests = (rawConfig["maxRequests"] as? Number)?.toInt() ?: 100,
        androidNativeLogs = AndroidNativeLogsConfig(
          enabled = rawAndroidNativeLogs?.get("enabled") as? Boolean ?: true,
          captureLogcat = rawAndroidNativeLogs?.get("captureLogcat") as? Boolean ?: true,
          captureStdoutStderr = rawAndroidNativeLogs?.get("captureStdoutStderr") as? Boolean ?: true,
          captureUncaughtExceptions =
            rawAndroidNativeLogs?.get("captureUncaughtExceptions") as? Boolean ?: true,
          logcatScope = rawAndroidNativeLogs?.get("logcatScope") as? String ?: "app",
          rootMode = rawAndroidNativeLogs?.get("rootMode") as? String ?: "off",
          buffers =
            (rawAndroidNativeLogs?.get("buffers") as? List<*>)?.mapNotNull { it as? String }
              ?.distinct()
              ?.ifEmpty { null } ?: listOf("main", "system", "crash")
        ),
        locale = rawConfig["locale"] as? String ?: "en-US",
        strings = (rawConfig["strings"] as? Map<*, *>)?.entries?.mapNotNull { entry ->
          val key = entry.key as? String ?: return@mapNotNull null
          key to (entry.value?.toString() ?: "")
        }?.toMap() ?: emptyMap()
      )
      inAppDebuggerTrace("InAppDebuggerModule") {
        "configure enabled=${config.enabled} initialVisible=${config.initialVisible} " +
          "currentActivity=${appContext.currentActivity?.javaClass?.name} " +
          "nativeLogs=${config.androidNativeLogs.enabled}/${config.androidNativeLogs.logcatScope}/" +
          "${config.androidNativeLogs.rootMode}"
      }
      InAppDebuggerOverlayManager.applyConfig(appContext, config)
      InAppDebuggerNativeLogCapture.applyConfig(appContext.currentActivity?.applicationContext, config)
      InAppDebuggerNativeNetworkCapture.applyConfig(appContext.currentActivity?.applicationContext, config)
    }

    AsyncFunction("ingestBatch") { logs: ReadableArray?, errors: ReadableArray?, network: ReadableArray? ->
      inAppDebuggerDiagnostic("NativeModule") {
        "ingestBatch logsType=${logs?.javaClass?.name ?: "null"} " +
          "errorsType=${errors?.javaClass?.name ?: "null"} " +
          "networkType=${network?.javaClass?.name ?: "null"} " +
          "logsSize=${logs?.size() ?: 0} errorsSize=${errors?.size() ?: 0} networkSize=${network?.size() ?: 0}"
      }
      InAppDebuggerStore.ingestBatch(
        mapOf(
          "logs" to logs?.toArrayList(),
          "errors" to errors?.toArrayList(),
          "network" to network?.toArrayList()
        )
      )
    }

    AsyncFunction("emitDiagnostic") { source: String, message: String ->
      inAppDebuggerDiagnostic(source) { message }
    }

    AsyncFunction("clear") { kind: String ->
      InAppDebuggerStore.clear(kind)
    }

    AsyncFunction("show") {
      inAppDebuggerTrace("InAppDebuggerModule") {
        "show currentActivity=${appContext.currentActivity?.javaClass?.name}"
      }
      InAppDebuggerOverlayManager.show(appContext)
    }

    AsyncFunction("hide") {
      inAppDebuggerTrace("InAppDebuggerModule") {
        "hide currentActivity=${appContext.currentActivity?.javaClass?.name}"
      }
      InAppDebuggerOverlayManager.hide(appContext)
    }

    AsyncFunction("exportSnapshot") {
      return@AsyncFunction InAppDebuggerStore.exportSnapshot()
    }

    OnActivityEntersForeground {
      InAppDebuggerNativeLogCapture.updateContext(appContext.currentActivity?.applicationContext)
      InAppDebuggerNativeNetworkCapture.applyConfig(
        appContext.currentActivity?.applicationContext,
        InAppDebuggerStore.currentConfig()
      )
      InAppDebuggerOverlayManager.onActivityForeground(appContext)
    }

    OnActivityDestroys {
      InAppDebuggerOverlayManager.onActivityDestroyed()
    }

    OnDestroy {
      InAppDebuggerNativeLogCapture.shutdown()
      InAppDebuggerNativeNetworkCapture.shutdown()
      InAppDebuggerOverlayManager.hide(appContext)
    }
  }
}
