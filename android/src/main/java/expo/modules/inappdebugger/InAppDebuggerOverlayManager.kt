package expo.modules.inappdebugger

import android.view.ViewGroup
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.FragmentManager
import expo.modules.kotlin.AppContext
import java.lang.ref.WeakReference

object InAppDebuggerOverlayManager {
  private const val PANEL_TAG = "expo.modules.inappdebugger.panel"

  private var currentActivityRef: WeakReference<AppCompatActivity>? = null
  private var floatingButtonView: InAppDebuggerFloatingButtonView? = null
  private var visible = false

  fun applyConfig(appContext: AppContext, config: DebugConfig) {
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
    attachTo(appContext.currentActivity as? AppCompatActivity ?: return)
  }

  fun hide(appContext: AppContext) {
    visible = false
    detachButton()
    (appContext.currentActivity as? AppCompatActivity)?.supportFragmentManager?.dismissPanel()
  }

  fun onActivityForeground(appContext: AppContext) {
    if (!InAppDebuggerStore.currentConfig().enabled || !visible) {
      return
    }
    attachTo(appContext.currentActivity as? AppCompatActivity ?: return)
  }

  fun onActivityDestroyed() {
    detachButton()
    currentActivityRef = null
  }

  private fun attachTo(activity: AppCompatActivity) {
    currentActivityRef = WeakReference(activity)

    val root = activity.findViewById<ViewGroup>(android.R.id.content) ?: return
    val existing = floatingButtonView
    if (existing?.parent === root) {
      return
    }

    detachButton()

    val button = InAppDebuggerFloatingButtonView(activity) {
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
    floatingButtonView = button
  }

  private fun detachButton() {
    val button = floatingButtonView ?: return
    (button.parent as? ViewGroup)?.removeView(button)
    floatingButtonView = null
  }
}

private fun FragmentManager.dismissPanel() {
  (findFragmentByTag("expo.modules.inappdebugger.panel") as? InAppDebuggerPanelDialogFragment)
    ?.dismissAllowingStateLoss()
}
