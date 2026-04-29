package expo.modules.inappdebugger

import com.facebook.react.bridge.ReadableArray
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

private const val PANEL_STATE_EVENT = "onPanelStateChange"

object InAppDebuggerPanelStateEvents {
  @Volatile
  private var listener: ((Boolean, DebugPanelFeed) -> Unit)? = null

  fun setListener(nextListener: ((Boolean, DebugPanelFeed) -> Unit)?) {
    listener = nextListener
  }

  fun emit(panelVisible: Boolean, activeFeed: DebugPanelFeed) {
    listener?.invoke(panelVisible, activeFeed)
  }
}

class InAppDebuggerModule : Module() {
  @Volatile
  private var nativeRuntimeActive = false

  override fun definition() = ModuleDefinition {
    Name("InAppDebugger")
    Events(PANEL_STATE_EVENT)

    OnCreate {
      InAppDebuggerPanelStateEvents.setListener { panelVisible, activeFeed ->
        sendEvent(
          PANEL_STATE_EVENT,
          mapOf(
            "panelVisible" to panelVisible,
            "activeFeed" to activeFeed.name.lowercase()
          )
        )
      }
    }

    AsyncFunction("configure") { rawConfig: Map<String, Any?> ->
      val rawAndroidNativeLogs = rawConfig["androidNativeLogs"] as? Map<*, *>
      val config = DebugConfig(
        enabled = rawConfig["enabled"] as? Boolean ?: false,
        initialVisible = rawConfig["initialVisible"] as? Boolean ?: true,
        enableNetworkTab = rawConfig["enableNetworkTab"] as? Boolean ?: true,
        enableNativeLogs =
          rawConfig["enableNativeLogs"] as? Boolean
            ?: rawAndroidNativeLogs?.get("enabled") as? Boolean
            ?: false,
        enableNativeNetwork = rawConfig["enableNativeNetwork"] as? Boolean ?: false,
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
          "nativeLogs=${config.enableNativeLogs}/${config.androidNativeLogs.enabled}/" +
          "${config.androidNativeLogs.logcatScope}/${config.androidNativeLogs.rootMode} " +
          "nativeNetwork=${config.enableNativeNetwork}"
      }
      if (!config.enabled && !nativeRuntimeActive) {
        return@AsyncFunction
      }
      if (config.enabled) {
        nativeRuntimeActive = true
      }
      InAppDebuggerOverlayManager.applyConfig(appContext, config)
      InAppDebuggerNativeLogCapture.applyConfigIfNeeded(appContext.currentActivity?.applicationContext, config)
      InAppDebuggerNativeNetworkCapture.applyConfigIfNeeded(appContext.currentActivity?.applicationContext, config)
      if (!config.enabled) {
        InAppDebuggerStore.shutdown()
        nativeRuntimeActive = false
      }
    }

    AsyncFunction("ingestBatch") { logs: ReadableArray?, errors: ReadableArray?, network: ReadableArray? ->
      if (!nativeRuntimeActive) {
        return@AsyncFunction
      }
      inAppDebuggerDiagnostic("NativeModule") {
        "ingestBatch logsSize=${logs?.size() ?: 0} " +
          "errorsSize=${errors?.size() ?: 0} networkSize=${network?.size() ?: 0}"
      }
      InAppDebuggerStore.ingestBatch(logs, errors, network)
    }

    AsyncFunction("emitDiagnostic") { source: String, message: String ->
      if (!nativeRuntimeActive) {
        return@AsyncFunction
      }
      inAppDebuggerDiagnostic(source) { message }
    }

    AsyncFunction("clear") { kind: String ->
      if (!nativeRuntimeActive) {
        return@AsyncFunction
      }
      InAppDebuggerStore.clear(kind)
    }

    AsyncFunction("show") {
      if (!nativeRuntimeActive) {
        return@AsyncFunction null
      }
      inAppDebuggerTrace("InAppDebuggerModule") {
        "show currentActivity=${appContext.currentActivity?.javaClass?.name}"
      }
      InAppDebuggerOverlayManager.show(appContext)
      return@AsyncFunction null
    }

    AsyncFunction("hide") {
      if (!nativeRuntimeActive) {
        return@AsyncFunction null
      }
      inAppDebuggerTrace("InAppDebuggerModule") {
        "hide currentActivity=${appContext.currentActivity?.javaClass?.name}"
      }
      InAppDebuggerOverlayManager.hide(appContext)
      return@AsyncFunction null
    }

    AsyncFunction("exportSnapshot") {
      if (!nativeRuntimeActive) {
        return@AsyncFunction mapOf(
          "logs" to emptyList<Map<String, Any?>>(),
          "errors" to emptyList<Map<String, Any?>>(),
          "network" to emptyList<Map<String, Any?>>(),
          "exportTime" to java.time.Instant.now().toString()
        )
      }
      return@AsyncFunction InAppDebuggerStore.exportSnapshot()
    }

    OnActivityEntersForeground {
      if (!nativeRuntimeActive) {
        return@OnActivityEntersForeground
      }
      InAppDebuggerNativeLogCapture.updateContextIfNeeded(appContext.currentActivity?.applicationContext)
      InAppDebuggerNativeNetworkCapture.applyConfigIfNeeded(
        appContext.currentActivity?.applicationContext,
        InAppDebuggerStore.currentConfig()
      )
      InAppDebuggerOverlayManager.onActivityForeground(appContext)
    }

    OnActivityDestroys {
      if (!nativeRuntimeActive) {
        return@OnActivityDestroys
      }
      InAppDebuggerOverlayManager.onActivityDestroyed()
    }

    OnDestroy {
      InAppDebuggerPanelStateEvents.setListener(null)
      if (!nativeRuntimeActive) {
        return@OnDestroy
      }
      InAppDebuggerNativeLogCapture.shutdown()
      InAppDebuggerNativeNetworkCapture.shutdown()
      InAppDebuggerOverlayManager.hide(appContext)
      InAppDebuggerStore.shutdown()
      nativeRuntimeActive = false
    }
  }
}
