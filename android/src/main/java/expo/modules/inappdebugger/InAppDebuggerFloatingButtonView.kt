package expo.modules.inappdebugger

import android.content.Context
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.ViewGroup
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
  private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
  private var downRawX = 0f
  private var downRawY = 0f
  private var startX = 0f
  private var startY = 0f
  private var moved = false

  init {
    clipChildren = false
    clipToPadding = false
    elevation = dp(20f)

    addView(
      ComposeView(context).apply {
        setContent {
          FloatingButtonContent()
        }
      },
      LayoutParams(dp(60), dp(60))
    )
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    post {
      val parentView = parent as? ViewGroup ?: return@post
      if (translationX == 0f && translationY == 0f) {
        translationX = (parentView.width - width - dp(20)).coerceAtLeast(0).toFloat()
        translationY = dp(96).toFloat()
      } else {
        translationX = translationX.coerceIn(0f, (parentView.width - width).toFloat().coerceAtLeast(0f))
        translationY = translationY.coerceIn(0f, (parentView.height - height).toFloat().coerceAtLeast(0f))
      }
    }
  }

  override fun onTouchEvent(event: MotionEvent): Boolean {
    val parentView = parent as? ViewGroup ?: return super.onTouchEvent(event)
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
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
        if (!moved) {
          onTap()
        }
        performClick()
        return true
      }
    }
    return super.onTouchEvent(event)
  }

  override fun performClick(): Boolean = super.performClick()

  private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

  private fun dp(value: Float): Float = value * resources.displayMetrics.density
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
