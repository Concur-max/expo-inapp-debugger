package expo.modules.inappdebugger

import android.util.Log

private const val INTERNAL_DEBUG_LOGGING_ENABLED = false

internal inline fun inAppDebuggerTrace(tag: String, message: () -> String) {
  if (INTERNAL_DEBUG_LOGGING_ENABLED) {
    Log.d(tag, message())
  }
}
