package expo.modules.inappdebugger

import android.app.Activity
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.fragment.app.FragmentManager
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.commit
import expo.modules.kotlin.AppContext
import java.lang.ref.WeakReference

object InAppDebuggerOverlayManager {
  private const val PANEL_TAG = "expo.modules.inappdebugger.panel"
  private const val TAG = "InAppDebuggerOverlay"

  private var currentActivityRef: WeakReference<FragmentActivity>? = null
  private var floatingButtonView: InAppDebuggerFloatingButtonView? = null
  private var visible = false

  fun applyConfig(appContext: AppContext, config: DebugConfig) {
    inAppDebuggerTrace(TAG) {
      "applyConfig enabled=${config.enabled} initialVisible=${config.initialVisible} " +
        "network=${config.enableNetworkTab} currentActivity=${appContext.currentActivity?.javaClass?.name}"
    }
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
    inAppDebuggerTrace(TAG) {
      "show visible=$visible currentActivity=${appContext.currentActivity?.javaClass?.name} " +
        "resolvedActivity=${activity?.javaClass?.name}"
    }
    attachTo(activity ?: return)
  }

  fun hide(appContext: AppContext) {
    visible = false
    val activity = appContext.currentActivity as? FragmentActivity
    inAppDebuggerTrace(TAG) {
      "hide currentActivity=${appContext.currentActivity?.javaClass?.name} " +
        "resolvedActivity=${activity?.javaClass?.name}"
    }
    runOnUiThread(activity) {
      detachButton()
      activity?.supportFragmentManager?.dismissPanel()
    }
  }

  fun onActivityForeground(appContext: AppContext) {
    val activity = appContext.currentActivity as? FragmentActivity
    inAppDebuggerTrace(TAG) {
      "onActivityForeground enabled=${InAppDebuggerStore.currentConfig().enabled} visible=$visible " +
        "currentActivity=${appContext.currentActivity?.javaClass?.name} resolvedActivity=${activity?.javaClass?.name}"
    }
    if (!InAppDebuggerStore.currentConfig().enabled || !visible) {
      return
    }
    attachTo(activity ?: return)
  }

  fun onActivityDestroyed() {
    inAppDebuggerTrace(TAG) { "onActivityDestroyed" }
    detachButton()
    currentActivityRef = null
  }

  private fun attachTo(activity: FragmentActivity) {
    currentActivityRef = WeakReference(activity)

    runOnUiThread(activity) {
      val root = activity.findViewById<ViewGroup>(android.R.id.content)
      if (root == null) {
        inAppDebuggerTrace(TAG) {
          "attachTo aborted: android.R.id.content not found for ${activity.javaClass.name}"
        }
        return@runOnUiThread
      }

      root.clipChildren = false
      root.clipToPadding = false

      val existing = floatingButtonView
      if (existing?.parent === root) {
        existing.bringToFront()
        existing.requestLayout()
        inAppDebuggerTrace(TAG) {
          "attachTo reused existing button rootChildren=${root.childCount} " +
            "buttonVisibility=${existing.visibility} alpha=${existing.alpha}"
        }
        return@runOnUiThread
      }

      detachButton()

      val button = InAppDebuggerFloatingButtonView(activity) {
        inAppDebuggerTrace(TAG) {
          "floatingButton tapped stateSaved=${activity.supportFragmentManager.isStateSaved}"
        }
        if (!activity.supportFragmentManager.isStateSaved) {
          showPanel(activity)
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
      inAppDebuggerTrace(TAG) {
        "attachTo added button activity=${activity.javaClass.name} root=${root.javaClass.name} " +
          "rootChildren=${root.childCount}"
      }
    }
  }

  private fun detachButton() {
    val button = floatingButtonView ?: return
    inAppDebuggerTrace(TAG) {
      "detachButton parent=${button.parent?.javaClass?.name} translationX=${button.translationX} " +
        "translationY=${button.translationY}"
    }
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

  private fun showPanel(activity: FragmentActivity) {
    val fragmentManager = activity.supportFragmentManager
    if (fragmentManager.findFragmentByTag(PANEL_TAG) != null) {
      return
    }

    val panelContainer = ensurePanelContainer(activity) ?: return
    fragmentManager.commit {
      setReorderingAllowed(true)
      setCustomAnimations(
        R.anim.expo_in_app_debugger_panel_enter,
        R.anim.expo_in_app_debugger_panel_exit,
        R.anim.expo_in_app_debugger_panel_enter,
        R.anim.expo_in_app_debugger_panel_exit
      )
      add(panelContainer.id, InAppDebuggerPanelDialogFragment(), PANEL_TAG)
      addToBackStack(PANEL_BACK_STACK_NAME)
    }
  }

  private fun ensurePanelContainer(activity: FragmentActivity): ViewGroup? {
    val decorView = activity.window.decorView as? ViewGroup ?: return null
    decorView.findViewById<ViewGroup>(R.id.expo_in_app_debugger_panel_container)?.let { existing ->
      existing.bringToFront()
      return existing
    }

    return FrameLayout(activity).apply {
      id = R.id.expo_in_app_debugger_panel_container
      layoutParams = ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT
      )
      clipChildren = false
      clipToPadding = false
      fitsSystemWindows = false
      importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
      decorView.addView(this)
    }
  }
}

private fun FragmentManager.dismissPanel() {
  (findFragmentByTag("expo.modules.inappdebugger.panel") as? InAppDebuggerPanelDialogFragment)
    ?.let { panel ->
      if (isStateSaved) {
        commit(allowStateLoss = true) {
          setReorderingAllowed(true)
          remove(panel)
        }
      } else {
        popBackStack(PANEL_BACK_STACK_NAME, FragmentManager.POP_BACK_STACK_INCLUSIVE)
      }
    }
}
