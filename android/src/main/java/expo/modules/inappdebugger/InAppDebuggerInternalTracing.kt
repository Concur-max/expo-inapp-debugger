package expo.modules.inappdebugger

import android.util.Log

private const val INTERNAL_DEBUG_LOGGING_ENABLED = false
private const val PIPELINE_DIAGNOSTICS_ENABLED = false
private const val PIPELINE_DIAGNOSTIC_TAG = "InAppDebuggerDiag"

internal inline fun inAppDebuggerTrace(tag: String, message: () -> String) {
  if (INTERNAL_DEBUG_LOGGING_ENABLED) {
    Log.d(tag, message())
  }
}

internal inline fun inAppDebuggerDiagnostic(component: String, message: () -> String) {
  if (PIPELINE_DIAGNOSTICS_ENABLED) {
    Log.d(PIPELINE_DIAGNOSTIC_TAG, "[$component] ${message()}")
  }
}
