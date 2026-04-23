package expo.modules.inappdebugger

import android.content.Context
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.FrameLayout
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BugReport
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.unit.dp
import kotlin.math.abs

class InAppDebuggerFloatingButtonView(
  context: Context,
  private val onTap: () -> Unit
) : FrameLayout(context) {
  companion object {
    private const val BUTTON_SIZE_DP = 60
  }

  private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
  private var downRawX = 0f
  private var downRawY = 0f
  private var startX = 0f
  private var startY = 0f
  private var moved = false
  private var hasResolvedPosition = false
  private var pendingPreDrawObserver: ViewTreeObserver? = null
  private var pendingPreDrawListener: ViewTreeObserver.OnPreDrawListener? = null

  init {
    clipChildren = false
    clipToPadding = false
    elevation = dp(20f)
    isClickable = true
    isFocusable = true
    visibility = View.INVISIBLE

    addView(
      ComposeView(context).apply {
        isClickable = false
        isFocusable = false
        setContent {
          FloatingButtonContent()
        }
      },
      LayoutParams(dp(BUTTON_SIZE_DP), dp(BUTTON_SIZE_DP))
    )
  }

  override fun onInterceptTouchEvent(event: MotionEvent): Boolean = true

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    visibility = View.INVISIBLE
    positionBeforeFirstDraw()
  }

  override fun onDetachedFromWindow() {
    clearPendingPreDrawListener()
    super.onDetachedFromWindow()
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    val parentView = parent as? ViewGroup ?: return super.onTouchEvent(event)
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        parentView.requestDisallowInterceptTouchEvent(true)
        downRawX = event.rawX
        downRawY = event.rawY
        startX = translationX
        startY = translationY
        moved = false
        return true
      }

      MotionEvent.ACTION_MOVE -> {
        val deltaX = event.rawX - downRawX
        val deltaY = event.rawY - downRawY
        if (!moved && (abs(deltaX) > touchSlop || abs(deltaY) > touchSlop)) {
          moved = true
        }
        translationX = (startX + deltaX).coerceIn(0f, (parentView.width - width).toFloat().coerceAtLeast(0f))
        translationY = (startY + deltaY).coerceIn(0f, (parentView.height - height).toFloat().coerceAtLeast(0f))
        return true
      }

      MotionEvent.ACTION_UP -> {
        parentView.requestDisallowInterceptTouchEvent(false)
        if (!moved) {
          onTap()
        }
        performClick()
        return true
      }

      MotionEvent.ACTION_CANCEL -> {
        parentView.requestDisallowInterceptTouchEvent(false)
        return true
      }
    }
    return super.onTouchEvent(event)
  }

  override fun performClick(): Boolean {
    super.performClick()
    return true
  }

  private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

  private fun dp(value: Float): Float = value * resources.displayMetrics.density

  private fun positionBeforeFirstDraw() {
    clearPendingPreDrawListener()

    val observer = viewTreeObserver
    val listener = object : ViewTreeObserver.OnPreDrawListener {
      override fun onPreDraw(): Boolean {
        if (resolvePositionInParent()) {
          clearPendingPreDrawListener()
          visibility = View.VISIBLE
        }
        return true
      }
    }

    pendingPreDrawObserver = observer
    pendingPreDrawListener = listener
    observer.addOnPreDrawListener(listener)
  }

  private fun resolvePositionInParent(): Boolean {
    val parentView = parent as? ViewGroup ?: return false
    if (parentView.width <= 0 || width <= 0 || height <= 0) {
      return false
    }

    val maxX = (parentView.width - width).toFloat().coerceAtLeast(0f)
    val maxY = (parentView.height - height).toFloat().coerceAtLeast(0f)
    if (!hasResolvedPosition) {
      translationX = (parentView.width - width - dp(20)).toFloat().coerceIn(0f, maxX)
      translationY = dp(96f).coerceIn(0f, maxY)
      hasResolvedPosition = true
    } else {
      translationX = translationX.coerceIn(0f, maxX)
      translationY = translationY.coerceIn(0f, maxY)
    }

    return true
  }

  private fun clearPendingPreDrawListener() {
    val listener = pendingPreDrawListener
    val observer = pendingPreDrawObserver
    if (listener != null && observer?.isAlive == true) {
      observer.removeOnPreDrawListener(listener)
    }
    pendingPreDrawObserver = null
    pendingPreDrawListener = null
  }
}

@Composable
private fun FloatingButtonContent() {
  MaterialTheme {
    Surface(
      modifier = Modifier.size(60.dp),
      shape = CircleShape,
      color = Color(0xFF1E6F5C),
      shadowElevation = 10.dp
    ) {
      Box(contentAlignment = Alignment.Center) {
        Icon(
          imageVector = Icons.Outlined.BugReport,
          contentDescription = "Open debug panel",
          tint = Color.White
        )
      }
    }
  }
}
