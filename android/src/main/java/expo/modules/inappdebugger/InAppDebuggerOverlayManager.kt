package expo.modules.inappdebugger

import android.app.Activity
import android.os.Looper
import android.util.Log
import android.view.ViewGroup
import androidx.fragment.app.FragmentManager
import androidx.fragment.app.FragmentActivity
import expo.modules.kotlin.AppContext
import java.lang.ref.WeakReference

object InAppDebuggerOverlayManager {
  private const val PANEL_TAG = "expo.modules.inappdebugger.panel"
  private const val TAG = "InAppDebuggerOverlay"

  private var currentActivityRef: WeakReference<FragmentActivity>? = null
  private var floatingButtonView: InAppDebuggerFloatingButtonView? = null
  private var visible = false

  fun applyConfig(appContext: AppContext, config: DebugConfig) {
    Log.d(
      TAG,
      "applyConfig enabled=${config.enabled} initialVisible=${config.initialVisible} " +
        "network=${config.enableNetworkTab} currentActivity=${appContext.currentActivity?.javaClass?.name}"
    )
    InAppDebuggerStore.updateConfig(config)
    if (!config.enabled) {
      visible = false
      hide(appContext)
      return
    }
    if (visible || config.initialVisible) {
      show(appContext)
    }
  }

  fun show(appContext: AppContext) {
    visible = true
    val activity = appContext.currentActivity as? FragmentActivity
    Log.d(
      TAG,
      "show visible=$visible currentActivity=${appContext.currentActivity?.javaClass?.name} " +
        "resolvedActivity=${activity?.javaClass?.name}"
    )
    attachTo(activity ?: return)
  }

  fun hide(appContext: AppContext) {
    visible = false
    val activity = appContext.currentActivity as? FragmentActivity
    Log.d(
      TAG,
      "hide currentActivity=${appContext.currentActivity?.javaClass?.name} " +
        "resolvedActivity=${activity?.javaClass?.name}"
    )
    runOnUiThread(activity) {
      detachButton()
      activity?.supportFragmentManager?.dismissPanel()
    }
  }

  fun onActivityForeground(appContext: AppContext) {
    val activity = appContext.currentActivity as? FragmentActivity
    Log.d(
      TAG,
      "onActivityForeground enabled=${InAppDebuggerStore.currentConfig().enabled} visible=$visible " +
        "currentActivity=${appContext.currentActivity?.javaClass?.name} resolvedActivity=${activity?.javaClass?.name}"
    )
    if (!InAppDebuggerStore.currentConfig().enabled || !visible) {
      return
    }
    attachTo(activity ?: return)
  }

  fun onActivityDestroyed() {
    Log.d(TAG, "onActivityDestroyed")
    detachButton()
    currentActivityRef = null
  }

  private fun attachTo(activity: FragmentActivity) {
    currentActivityRef = WeakReference(activity)

    runOnUiThread(activity) {
      val root = activity.findViewById<ViewGroup>(android.R.id.content)
      if (root == null) {
        Log.w(TAG, "attachTo aborted: android.R.id.content not found for ${activity.javaClass.name}")
        return@runOnUiThread
      }

      root.clipChildren = false
      root.clipToPadding = false

      val existing = floatingButtonView
      if (existing?.parent === root) {
        existing.bringToFront()
        existing.requestLayout()
        Log.d(
          TAG,
          "attachTo reused existing button rootChildren=${root.childCount} " +
            "buttonVisibility=${existing.visibility} alpha=${existing.alpha}"
        )
        return@runOnUiThread
      }

      detachButton()

      val button = InAppDebuggerFloatingButtonView(activity) {
        Log.d(
          TAG,
          "floatingButton tapped stateSaved=${activity.supportFragmentManager.isStateSaved}"
        )
        if (!activity.supportFragmentManager.isStateSaved) {
          InAppDebuggerPanelDialogFragment().show(activity.supportFragmentManager, PANEL_TAG)
        }
      }

      root.addView(
        button,
        ViewGroup.LayoutParams(
          ViewGroup.LayoutParams.WRAP_CONTENT,
          ViewGroup.LayoutParams.WRAP_CONTENT
        )
      )
      button.bringToFront()
      floatingButtonView = button
      Log.d(
        TAG,
        "attachTo added button activity=${activity.javaClass.name} root=${root.javaClass.name} " +
          "rootChildren=${root.childCount}"
      )
    }
  }

  private fun detachButton() {
    val button = floatingButtonView ?: return
    Log.d(
      TAG,
      "detachButton parent=${button.parent?.javaClass?.name} translationX=${button.translationX} " +
        "translationY=${button.translationY}"
    )
    (button.parent as? ViewGroup)?.removeView(button)
    floatingButtonView = null
  }

  private fun runOnUiThread(activity: Activity?, action: () -> Unit) {
    if (Looper.myLooper() == Looper.getMainLooper()) {
      action()
      return
    }
    if (activity != null) {
      activity.runOnUiThread(action)
      return
    }
    currentActivityRef?.get()?.runOnUiThread(action)
  }
}

private fun FragmentManager.dismissPanel() {
  (findFragmentByTag("expo.modules.inappdebugger.panel") as? InAppDebuggerPanelDialogFragment)
    ?.dismissAllowingStateLoss()
}
