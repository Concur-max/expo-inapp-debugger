package expo.modules.inappdebugger

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.text.format.Formatter
import android.util.JsonReader
import android.util.JsonToken
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.ImageView
import androidx.appcompat.widget.SearchView
import androidx.core.view.WindowInsetsControllerCompat
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInteropFilter
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentManager
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.io.StringReader
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.LinkedHashMap
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

class InAppDebuggerPanelDialogFragment : Fragment() {
  private var previousLightStatusBars: Boolean? = null
  private var previousLightNavigationBars: Boolean? = null

  override fun onCreateView(
    inflater: android.view.LayoutInflater,
    container: ViewGroup?,
    savedInstanceState: Bundle?
  ): View {
    return ComposeView(requireContext()).apply {
      setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
      setContent {
        MaterialTheme(
          colorScheme = lightColorScheme(
            primary = PanelColors.Primary,
            secondary = PanelColors.SurfaceAlt,
            surface = PanelColors.Surface,
            background = PanelColors.Background
          )
        ) {
          Surface(modifier = Modifier.fillMaxSize(), color = PanelColors.Background) {
            DebugPanel(
              onDismiss = ::closePanel,
              onPanelTouch = { event -> dismissSearchFocusOnOutsideTouch(this, event) }
            )
          }
        }
      }
    }
  }

  override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
    super.onViewCreated(view, savedInstanceState)
    view.fitsSystemWindows = false
    view.setBackgroundColor(PanelColors.Background.toArgb())
    view.requestApplyInsets()
  }

  override fun onStart() {
    super.onStart()
    configureWindow()
  }

  override fun onStop() {
    restoreWindowAppearance()
    super.onStop()
  }

  override fun onDestroyView() {
    cleanupPanelContainer()
    super.onDestroyView()
  }

  private fun closePanel() {
    parentFragmentManager.popBackStack(PANEL_BACK_STACK_NAME, FragmentManager.POP_BACK_STACK_INCLUSIVE)
  }

  private fun dismissSearchFocusOnOutsideTouch(hostView: View, event: MotionEvent?) {
    if (event?.actionMasked != MotionEvent.ACTION_DOWN) {
      return
    }
    val focusedView = hostView.findFocus() ?: return
    val searchView = focusedView.findAncestorSearchView() ?: return
    val searchBounds = Rect()
    if (!searchView.getGlobalVisibleRect(searchBounds)) {
      return
    }
    val touchX = event.rawX.roundToInt()
    val touchY = event.rawY.roundToInt()
    if (searchBounds.contains(touchX, touchY)) {
      return
    }
    hideKeyboard(focusedView)
    focusedView.clearFocus()
    searchView.clearFocus()
  }

  private fun configureWindow() {
    val window = activity?.window ?: return
    val insetsController = WindowInsetsControllerCompat(window, window.decorView)
    if (previousLightStatusBars == null) {
      previousLightStatusBars = insetsController.isAppearanceLightStatusBars
    }
    if (previousLightNavigationBars == null) {
      previousLightNavigationBars = insetsController.isAppearanceLightNavigationBars
    }
    insetsController.isAppearanceLightStatusBars = true
    insetsController.isAppearanceLightNavigationBars = true
    @Suppress("DEPRECATION")
    run {
      window.statusBarColor = android.graphics.Color.TRANSPARENT
      window.navigationBarColor = android.graphics.Color.TRANSPARENT
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      window.isNavigationBarContrastEnforced = false
    }
  }

  private fun restoreWindowAppearance() {
    val window = activity?.window ?: return
    val insetsController = WindowInsetsControllerCompat(window, window.decorView)
    previousLightStatusBars?.let {
      insetsController.isAppearanceLightStatusBars = it
    }
    previousLightNavigationBars?.let {
      insetsController.isAppearanceLightNavigationBars = it
    }
    previousLightStatusBars = null
    previousLightNavigationBars = null
  }

  private fun cleanupPanelContainer() {
    val hostActivity = activity ?: return
    val container =
      hostActivity.window.decorView.findViewById<ViewGroup>(R.id.expo_in_app_debugger_panel_container)
        ?: return
    container.post {
      if (container.childCount == 0) {
        (container.parent as? ViewGroup)?.removeView(container)
      }
    }
  }

  private fun hideKeyboard(target: View) {
    val inputMethodManager =
      target.context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager ?: return
    inputMethodManager.hideSoftInputFromWindow(target.windowToken, 0)
  }
}

private fun View.findAncestorSearchView(): SearchView? {
  var current: View? = this
  while (current != null) {
    if (current is SearchView) {
      return current
    }
    current = current.parent as? View
  }
  return null
}

const val PANEL_BACK_STACK_NAME = "expo.modules.inappdebugger.panel.backstack"
private const val LOGS_SEARCH_PLACEHOLDER = "Search logs..."
private const val NETWORK_SEARCH_PLACEHOLDER = "Search network requests..."
private val APP_INFO_SCROLLABLE_DETAIL_MAX_HEIGHT = 280.dp
private val NETWORK_BODY_SCROLLABLE_DETAIL_MAX_HEIGHT = 280.dp
private val LOG_LIST_CHIP_TEXT_SIZE = 10.sp
private val LOG_LIST_CHIP_LINE_HEIGHT = 12.sp
private val LOG_LIST_META_TEXT_SIZE = 11.sp
private val LOG_LIST_META_LINE_HEIGHT = 14.sp
private val LOG_LIST_BODY_TEXT_SIZE = 12.sp
private val LOG_LIST_BODY_LINE_HEIGHT = 16.sp
private val REQUEST_DETAIL_TITLE_TEXT_SIZE = 13.sp
private val REQUEST_DETAIL_TITLE_LINE_HEIGHT = 16.sp
private val REQUEST_DETAIL_BODY_TEXT_SIZE = 12.sp
private val REQUEST_DETAIL_BODY_LINE_HEIGHT = 16.sp

private enum class DebugTab {
  Logs,
  Network,
  AppInfo
}

private fun debugTabForPanelUiState(state: DebugPanelUiState, networkTabEnabled: Boolean): DebugTab {
  return when (state.activeFeed) {
    DebugPanelFeed.Network -> if (networkTabEnabled) DebugTab.Network else DebugTab.Logs
    DebugPanelFeed.AppInfo -> DebugTab.AppInfo
    else -> DebugTab.Logs
  }
}

private enum class SortOrder {
  Asc,
  Desc
}

private enum class NetworkKindFilter(val rawValue: String) {
  Http("http"),
  WebSocket("websocket"),
  Other("other")
}

private enum class NativeCaptureConfirmationTarget {
  Logs,
  Network
}

private object PanelColors {
  val Background = Color(0xFFF3F4F6)
  val Surface = Color(0xFFFFFFFF)
  val SurfaceAlt = Color(0xFFEAF2FF)
  val Border = Color(0xFFE5E7EB)
  val Primary = Color(0xFF2563EB)
  val Text = Color(0xFF111827)
  val MutedText = Color(0xFF6B7280)
  val Control = Color(0xFFEFF1F5)
}

private data class PanelTone(
  val foreground: Color,
  val background: Color
)

private data class DetailItem(
  val title: String,
  val content: String,
  val monospace: Boolean = false,
  val contentMaxHeight: Dp? = null
)

private data class FilterMenuItem(
  val label: String,
  val selected: Boolean,
  val onToggle: () -> Unit
)

private data class FilterMenuSection(
  val title: String,
  val items: List<FilterMenuItem>
)

private val appInfoCrashTimestampFormatter: DateTimeFormatter =
  DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS").withZone(ZoneId.systemDefault())

private object PanelPreferences {
  private const val PREFS_NAME = "expo.modules.inappdebugger.panel"
  private const val SELECTED_LOG_LEVELS_KEY = "selected_levels"
  private const val SELECTED_LOG_ORIGINS_KEY = "selected_log_origins"
  private const val SELECTED_NETWORK_ORIGINS_KEY = "selected_network_origins"
  private const val SELECTED_NETWORK_KINDS_KEY = "selected_network_kinds"

  private val jsOrigins = setOf("js")
  private val allLevels = setOf("log", "info", "warn", "error", "debug")
  private val allOrigins = setOf("js", "native")
  private val allNetworkKinds = NetworkKindFilter.entries.mapTo(linkedSetOf()) { it.rawValue }
  private val defaultOrigins = setOf("js")

  fun loadLogLevels(context: Context): Set<String> {
    return loadSet(context, SELECTED_LOG_LEVELS_KEY, allLevels, allLevels)
  }

  fun loadLogOrigins(context: Context): Set<String> {
    return loadSet(context, SELECTED_LOG_ORIGINS_KEY, allOrigins, defaultOrigins)
  }

  fun loadNetworkOrigins(context: Context): Set<String> {
    return loadSet(context, SELECTED_NETWORK_ORIGINS_KEY, allOrigins, defaultOrigins)
  }

  fun loadNetworkKinds(context: Context): Set<String> {
    return loadSet(context, SELECTED_NETWORK_KINDS_KEY, allNetworkKinds, allNetworkKinds)
  }

  fun saveLogLevels(context: Context, values: Set<String>) {
    saveSet(context, SELECTED_LOG_LEVELS_KEY, values)
  }

  fun saveLogOrigins(context: Context, values: Set<String>) {
    saveSet(context, SELECTED_LOG_ORIGINS_KEY, values)
  }

  fun saveNetworkOrigins(context: Context, values: Set<String>) {
    saveSet(context, SELECTED_NETWORK_ORIGINS_KEY, values)
  }

  fun saveNetworkKinds(context: Context, values: Set<String>) {
    saveSet(context, SELECTED_NETWORK_KINDS_KEY, values)
  }

  fun availableOrigins(nativeEnabled: Boolean): Set<String> {
    return if (nativeEnabled) allOrigins else jsOrigins
  }

  fun originOptions(nativeEnabled: Boolean): List<String> {
    return if (nativeEnabled) listOf("js", "native") else listOf("js")
  }

  fun sanitizeOrigins(values: Set<String>, availableOrigins: Set<String>): Set<String> {
    val next = values.filterTo(linkedSetOf()) { it in availableOrigins }
    if (next.isNotEmpty() || values.isEmpty()) {
      return next
    }
    return defaultOrigins.filterTo(linkedSetOf()) { it in availableOrigins }
  }

  fun hasActiveLogFilters(
    levels: Set<String>,
    origins: Set<String>,
    availableOrigins: Set<String>
  ): Boolean {
    return origins != availableOrigins || levels != allLevels
  }

  fun hasActiveNetworkFilters(
    origins: Set<String>,
    kinds: Set<String>,
    availableOrigins: Set<String>
  ): Boolean {
    return origins != availableOrigins || kinds != allNetworkKinds
  }

  fun isAllLogFiltersSelected(levels: Set<String>, origins: Set<String>): Boolean {
    return levels == allLevels && origins == allOrigins
  }

  fun isAllNetworkFiltersSelected(origins: Set<String>, kinds: Set<String>): Boolean {
    return origins == allOrigins && kinds == allNetworkKinds
  }

  private fun loadSet(
    context: Context,
    key: String,
    allowedValues: Set<String>,
    defaultValues: Set<String>
  ): Set<String> {
    val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    val stored = prefs.getStringSet(key, null) ?: return defaultValues
    return stored.filterTo(linkedSetOf()) { it in allowedValues }
  }

  private fun saveSet(context: Context, key: String, values: Set<String>) {
    val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    prefs.edit().putStringSet(key, values.toSortedSet()).apply()
  }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
private fun DebugPanel(
  onDismiss: () -> Unit,
  onPanelTouch: (MotionEvent) -> Unit
) {
  val chromeState by InAppDebuggerStore.chromeState.collectAsStateWithLifecycle()
  val locale = chromeState.config.locale
  val context = LocalContext.current
  val initialPanelUiState = remember { InAppDebuggerStore.currentPanelUiState() }
  var activeTab by rememberSaveable {
    mutableStateOf(
      debugTabForPanelUiState(
        initialPanelUiState,
        networkTabEnabled = chromeState.config.enableNetworkTab
      )
    )
  }
  var selectedNetworkId by rememberSaveable { mutableStateOf<String?>(null) }
  var logsSearchQuery by rememberSaveable { mutableStateOf("") }
  var logsSortOrder by rememberSaveable { mutableStateOf(SortOrder.Asc) }
  var networkSearchQuery by rememberSaveable { mutableStateOf("") }
  var networkSortOrder by rememberSaveable { mutableStateOf(SortOrder.Asc) }
  var selectedLogLevels by remember { mutableStateOf(PanelPreferences.loadLogLevels(context)) }
  var selectedLogOrigins by remember { mutableStateOf(PanelPreferences.loadLogOrigins(context)) }
  var selectedNetworkOrigins by remember { mutableStateOf(PanelPreferences.loadNetworkOrigins(context)) }
  var selectedNetworkKinds by remember { mutableStateOf(PanelPreferences.loadNetworkKinds(context)) }
  val nativeLogOriginAvailable = chromeState.config.enableNativeLogs
  val nativeNetworkOriginAvailable =
    chromeState.config.enableNetworkTab && chromeState.config.enableNativeNetwork
  val availableLogOrigins = remember(nativeLogOriginAvailable) {
    PanelPreferences.availableOrigins(nativeLogOriginAvailable)
  }
  val availableNetworkOrigins = remember(nativeNetworkOriginAvailable) {
    PanelPreferences.availableOrigins(nativeNetworkOriginAvailable)
  }
  val logOriginOptions = remember(nativeLogOriginAvailable) {
    PanelPreferences.originOptions(nativeLogOriginAvailable)
  }
  val networkOriginOptions = remember(nativeNetworkOriginAvailable) {
    PanelPreferences.originOptions(nativeNetworkOriginAvailable)
  }
  val hasActiveLogFilters = remember(selectedLogLevels, selectedLogOrigins, availableLogOrigins) {
    PanelPreferences.hasActiveLogFilters(selectedLogLevels, selectedLogOrigins, availableLogOrigins)
  }
  val hasActiveNetworkFilters = remember(selectedNetworkOrigins, selectedNetworkKinds, availableNetworkOrigins) {
    PanelPreferences.hasActiveNetworkFilters(selectedNetworkOrigins, selectedNetworkKinds, availableNetworkOrigins)
  }

  DisposableEffect(Unit) {
    InAppDebuggerStore.setPanelVisible(true)
    onDispose {
      InAppDebuggerStore.setActiveFeed(DebugPanelFeed.None)
      InAppDebuggerStore.setPanelVisible(false)
    }
  }

  LaunchedEffect(availableLogOrigins) {
    val nextOrigins = PanelPreferences.sanitizeOrigins(selectedLogOrigins, availableLogOrigins)
    if (nextOrigins != selectedLogOrigins) {
      selectedLogOrigins = nextOrigins
      PanelPreferences.saveLogOrigins(context, nextOrigins)
    }
  }

  LaunchedEffect(availableNetworkOrigins) {
    val nextOrigins = PanelPreferences.sanitizeOrigins(selectedNetworkOrigins, availableNetworkOrigins)
    if (nextOrigins != selectedNetworkOrigins) {
      selectedNetworkOrigins = nextOrigins
      PanelPreferences.saveNetworkOrigins(context, nextOrigins)
    }
  }

  LaunchedEffect(activeTab, selectedNetworkId) {
    val activeFeed =
      when {
        selectedNetworkId != null -> DebugPanelFeed.Network
        activeTab == DebugTab.Logs -> DebugPanelFeed.Logs
        activeTab == DebugTab.Network -> DebugPanelFeed.Network
        else -> DebugPanelFeed.AppInfo
      }
    InAppDebuggerStore.setActiveFeed(activeFeed)
    InAppDebuggerStore.updatePanelUiState(DebugPanelUiState(activeFeed = activeFeed))
  }

  LaunchedEffect(chromeState.config.enableNetworkTab) {
    if (!chromeState.config.enableNetworkTab && activeTab == DebugTab.Network) {
      activeTab = DebugTab.Logs
    }
  }

  if (selectedNetworkId != null) {
    NetworkDetailScreen(
      entryId = selectedNetworkId.orEmpty(),
      onBack = { selectedNetworkId = null },
      onClose = onDismiss,
      onMissing = { selectedNetworkId = null }
    )
    return
  }

  Column(
    modifier = Modifier
      .fillMaxSize()
      .background(PanelColors.Background)
      .pointerInteropFilter { event ->
        onPanelTouch(event)
        false
      }
  ) {
    when (activeTab) {
      DebugTab.Logs -> SearchAndActionRow(
        query = logsSearchQuery,
        placeholder = localizedLogsSearchPlaceholder(),
        menuTitle = localizedMenuTitle(),
        clearLabel = "Clear",
        closeLabel = "Close",
        hasActiveFilters = hasActiveLogFilters,
        filterSections = listOf(
          FilterMenuSection(
            title = localizedSortMenuTitle(),
            items = listOf(
              FilterMenuItem(
                label = localizedSortTitle(ascending = true),
                selected = logsSortOrder == SortOrder.Asc,
                onToggle = { logsSortOrder = SortOrder.Asc }
              ),
              FilterMenuItem(
                label = localizedSortTitle(ascending = false),
                selected = logsSortOrder == SortOrder.Desc,
                onToggle = { logsSortOrder = SortOrder.Desc }
              )
            )
          ),
          FilterMenuSection(
            title = localizedOriginTitleLabel(),
            items = logOriginOptions.map { origin ->
              FilterMenuItem(
                label = localizedOriginTitle(origin),
                selected = origin in selectedLogOrigins,
                onToggle = {
                  selectedLogOrigins =
                    PanelPreferences.sanitizeOrigins(
                      selectedLogOrigins.toggle(origin),
                      availableLogOrigins
                    )
                  PanelPreferences.saveLogOrigins(context, selectedLogOrigins)
                }
              )
            }
          ),
          FilterMenuSection(
            title = localizedLevelTitle(),
            items = listOf("log", "info", "warn", "error", "debug").map { level ->
              FilterMenuItem(
                label = level.uppercase(Locale.ROOT),
                selected = level in selectedLogLevels,
                onToggle = {
                  selectedLogLevels = selectedLogLevels.toggle(level)
                  PanelPreferences.saveLogLevels(context, selectedLogLevels)
                }
              )
            }
          )
        ),
        onQueryChange = { logsSearchQuery = it },
        onClear = { InAppDebuggerStore.clear("logs") },
        onClose = onDismiss
      )

      DebugTab.Network -> SearchAndActionRow(
        query = networkSearchQuery,
        placeholder = localizedNetworkSearchPlaceholder(),
        menuTitle = localizedMenuTitle(),
        clearLabel = "Clear",
        closeLabel = "Close",
        hasActiveFilters = hasActiveNetworkFilters,
        filterSections = listOf(
          FilterMenuSection(
            title = localizedSortMenuTitle(),
            items = listOf(
              FilterMenuItem(
                label = localizedSortTitle(ascending = true),
                selected = networkSortOrder == SortOrder.Asc,
                onToggle = { networkSortOrder = SortOrder.Asc }
              ),
              FilterMenuItem(
                label = localizedSortTitle(ascending = false),
                selected = networkSortOrder == SortOrder.Desc,
                onToggle = { networkSortOrder = SortOrder.Desc }
              )
            )
          ),
          FilterMenuSection(
            title = localizedOriginTitleLabel(),
            items = networkOriginOptions.map { origin ->
              FilterMenuItem(
                label = localizedOriginTitle(origin),
                selected = origin in selectedNetworkOrigins,
                onToggle = {
                  selectedNetworkOrigins =
                    PanelPreferences.sanitizeOrigins(
                      selectedNetworkOrigins.toggle(origin),
                      availableNetworkOrigins
                    )
                  PanelPreferences.saveNetworkOrigins(context, selectedNetworkOrigins)
                }
              )
            }
          ),
          FilterMenuSection(
            title = localizedNetworkTypeTitle(),
            items = NetworkKindFilter.entries.map { kind ->
              FilterMenuItem(
                label = localizedNetworkKindFilterTitle(kind),
                selected = kind.rawValue in selectedNetworkKinds,
                onToggle = {
                  selectedNetworkKinds = selectedNetworkKinds.toggle(kind.rawValue)
                  PanelPreferences.saveNetworkKinds(context, selectedNetworkKinds)
                }
              )
            }
          )
        ),
        onQueryChange = { networkSearchQuery = it },
        onClear = { InAppDebuggerStore.clear("network") },
        onClose = onDismiss
      )

      DebugTab.AppInfo -> AppInfoTopBar(onClose = onDismiss)
    }

    Box(modifier = Modifier.weight(1f)) {
      when (activeTab) {
        DebugTab.Logs -> LogsTab(
          maxLogs = chromeState.config.maxLogs,
          searchQuery = logsSearchQuery,
          sortOrder = logsSortOrder,
          selectedLevels = selectedLogLevels,
          selectedOrigins = selectedLogOrigins,
          nativeOriginAvailable = nativeLogOriginAvailable
        )

        DebugTab.Network -> NetworkTab(
          maxRequests = chromeState.config.maxRequests,
          searchQuery = networkSearchQuery,
          sortOrder = networkSortOrder,
          selectedOrigins = selectedNetworkOrigins,
          selectedKinds = selectedNetworkKinds,
          nativeOriginAvailable = nativeNetworkOriginAvailable,
          onSelectNetwork = { selectedNetworkId = it }
        )

        DebugTab.AppInfo -> AppInfoTab(
          config = chromeState.config,
          runtimeInfo = chromeState.runtimeInfo,
          locale = locale
        )
      }
    }

    PanelTabBar(
      activeTab = activeTab,
      networkEnabled = chromeState.config.enableNetworkTab,
      onSelectTab = { nextTab ->
        if (nextTab != DebugTab.Network || chromeState.config.enableNetworkTab) {
          activeTab = nextTab
        }
      }
    )
  }
}

@Composable
private fun AppInfoTopBar(onClose: () -> Unit) {
  Surface(
    modifier = Modifier.fillMaxWidth(),
    color = PanelColors.Background
  ) {
    Column {
      Row(
        modifier = Modifier
          .fillMaxWidth()
          .statusBarsPadding()
          .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.End,
        verticalAlignment = Alignment.CenterVertically
      ) {
        PanelActionButton(
          imageVector = Icons.Outlined.Close,
          contentDescription = "Close",
          onClick = onClose
        )
      }
      HorizontalDivider(color = PanelColors.Border)
    }
  }
}

@Composable
private fun PanelTabBar(
  activeTab: DebugTab,
  networkEnabled: Boolean,
  onSelectTab: (DebugTab) -> Unit
) {
  Surface(
    modifier = Modifier.fillMaxWidth(),
    color = PanelColors.Surface
  ) {
    Column {
      HorizontalDivider(color = PanelColors.Border)
      NavigationBar(
        modifier = Modifier.fillMaxWidth(),
        containerColor = PanelColors.Surface,
        tonalElevation = 0.dp
      ) {
        NavigationBarItem(
          selected = activeTab == DebugTab.Logs,
          onClick = { onSelectTab(DebugTab.Logs) },
          icon = {
            Icon(
              imageVector = Icons.Outlined.Description,
              contentDescription = null
            )
          },
          label = { Text("Logs") },
          colors = NavigationBarItemDefaults.colors(
            selectedIconColor = PanelColors.Primary,
            selectedTextColor = PanelColors.Primary,
            indicatorColor = PanelColors.SurfaceAlt,
            unselectedIconColor = PanelColors.MutedText,
            unselectedTextColor = PanelColors.MutedText,
            disabledIconColor = PanelColors.MutedText,
            disabledTextColor = PanelColors.MutedText
          )
        )
        NavigationBarItem(
          selected = activeTab == DebugTab.Network,
          onClick = { onSelectTab(DebugTab.Network) },
          enabled = networkEnabled,
          icon = {
            Icon(
              imageVector = Icons.Outlined.Public,
              contentDescription = null
            )
          },
          label = { Text("Network") },
          colors = NavigationBarItemDefaults.colors(
            selectedIconColor = PanelColors.Primary,
            selectedTextColor = PanelColors.Primary,
            indicatorColor = PanelColors.SurfaceAlt,
            unselectedIconColor = PanelColors.MutedText,
            unselectedTextColor = PanelColors.MutedText,
            disabledIconColor = PanelColors.MutedText,
            disabledTextColor = PanelColors.MutedText
          )
        )
        NavigationBarItem(
          selected = activeTab == DebugTab.AppInfo,
          onClick = { onSelectTab(DebugTab.AppInfo) },
          icon = {
            Icon(
              imageVector = Icons.Outlined.Info,
              contentDescription = null
            )
          },
          label = { Text("App Info") },
          colors = NavigationBarItemDefaults.colors(
            selectedIconColor = PanelColors.Primary,
            selectedTextColor = PanelColors.Primary,
            indicatorColor = PanelColors.SurfaceAlt,
            unselectedIconColor = PanelColors.MutedText,
            unselectedTextColor = PanelColors.MutedText,
            disabledIconColor = PanelColors.MutedText,
            disabledTextColor = PanelColors.MutedText
          )
        )
      }
    }
  }
}

@Composable
private fun AppInfoTab(
  config: DebugConfig,
  runtimeInfo: DebugRuntimeInfo,
  locale: String
) {
  val errorsWindowState by InAppDebuggerStore.errorsWindowState.collectAsStateWithLifecycle()
  val context = LocalContext.current
  val scope = rememberCoroutineScope()
  var nativeCaptureTogglePending by remember { mutableStateOf(false) }
  var rootTogglePending by remember { mutableStateOf(false) }
  var nativeLogsEnableArmed by remember { mutableStateOf(false) }
  var nativeNetworkEnableArmed by remember { mutableStateOf(false) }
  var nativeCaptureConfirmationTarget by remember {
    mutableStateOf<NativeCaptureConfirmationTarget?>(null)
  }
  val rootEnhancedEnabled = remember(config.androidNativeLogs.logcatScope, config.androidNativeLogs.rootMode) {
    isRootEnhancedRequested(config)
  }

  LaunchedEffect(Unit) {
    InAppDebuggerNativeLogCapture.refreshRuntimeInfo()
  }

  LaunchedEffect(config.enableNativeLogs) {
    if (config.enableNativeLogs) {
      nativeLogsEnableArmed = false
    }
  }

  LaunchedEffect(config.enableNativeNetwork, config.enableNetworkTab) {
    if (config.enableNativeNetwork || !config.enableNetworkTab) {
      nativeNetworkEnableArmed = false
    }
  }

  val sections by produceState<List<DetailItem>?>(
    initialValue = null,
    runtimeInfo,
    config,
    errorsWindowState.version,
    locale
  ) {
    value =
      withContext(Dispatchers.Default) {
        buildDebuggerInfoSections(
          runtimeInfo = runtimeInfo,
          config = config,
          appErrors = errorsWindowState.items,
          locale = locale
        )
      }
  }

  fun applyNativeCaptureChange(enableNativeLogs: Boolean, enableNativeNetwork: Boolean) {
    if (!nativeCaptureTogglePending) {
      nativeCaptureTogglePending = true
      scope.launch {
        try {
          withContext(Dispatchers.Default) {
            applyPanelNativeCaptureMode(
              context.applicationContext,
              enableNativeLogs = enableNativeLogs,
              enableNativeNetwork = enableNativeNetwork
            )
          }
        } finally {
          nativeCaptureTogglePending = false
        }
      }
    }
  }

  nativeCaptureConfirmationTarget?.let { target ->
    NativeCaptureConfirmationDialog(
      target = target,
      locale = locale,
      onConfirm = {
        nativeCaptureConfirmationTarget = null
        when (target) {
          NativeCaptureConfirmationTarget.Logs -> nativeLogsEnableArmed = true
          NativeCaptureConfirmationTarget.Network -> nativeNetworkEnableArmed = true
        }
      },
      onDismiss = {
        nativeCaptureConfirmationTarget = null
      }
    )
  }

  val readySections = sections
  if (readySections == null) {
    Box(modifier = Modifier.fillMaxSize())
    return
  }

  LazyColumn(
    modifier = Modifier.fillMaxSize(),
    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
    verticalArrangement = Arrangement.spacedBy(10.dp)
  ) {
    items(
      items = readySections,
      key = { it.title }
    ) { section ->
      DetailSection(
        title = section.title,
        content = section.content,
        monospace = section.monospace,
        contentMaxHeight = section.contentMaxHeight
      )
    }
    if (runtimeInfo.rootStatus == "root") {
      item("app_info_root_control") {
        RootEnhancedControlCard(
          checked = rootEnhancedEnabled,
          enabled = config.enableNativeLogs && runtimeInfo.rootStatus != "checking",
          runtimeInfo = runtimeInfo,
          locale = locale,
          onCheckedChange = { enabled ->
            if (!rootTogglePending) {
              rootTogglePending = true
              scope.launch {
                try {
                  withContext(Dispatchers.Default) {
                    applyPanelRootEnhancedMode(context.applicationContext, enabled)
                  }
                } finally {
                  rootTogglePending = false
                }
              }
            }
          }
        )
      }
    }
    item("app_info_native_capture_control") {
      NativeCaptureControlCard(
        nativeLogsChecked = config.enableNativeLogs,
        nativeNetworkChecked = config.enableNativeNetwork,
        nativeNetworkEnabled = config.enableNetworkTab,
        nativeLogsEnableRequiresConfirmation = !config.enableNativeLogs && !nativeLogsEnableArmed,
        nativeNetworkEnableRequiresConfirmation = !config.enableNativeNetwork && !nativeNetworkEnableArmed,
        pending = nativeCaptureTogglePending,
        locale = locale,
        onNativeLogsChange = { enabled ->
          if (enabled) {
            if (nativeLogsEnableArmed) {
              nativeLogsEnableArmed = false
              applyNativeCaptureChange(
                enableNativeLogs = true,
                enableNativeNetwork = config.enableNativeNetwork
              )
            } else {
              nativeCaptureConfirmationTarget = NativeCaptureConfirmationTarget.Logs
            }
          } else {
            nativeLogsEnableArmed = false
            applyNativeCaptureChange(
              enableNativeLogs = false,
              enableNativeNetwork = config.enableNativeNetwork
            )
          }
        },
        onNativeNetworkChange = { enabled ->
          if (enabled) {
            if (nativeNetworkEnableArmed) {
              nativeNetworkEnableArmed = false
              applyNativeCaptureChange(
                enableNativeLogs = config.enableNativeLogs,
                enableNativeNetwork = true
              )
            } else {
              nativeCaptureConfirmationTarget = NativeCaptureConfirmationTarget.Network
            }
          } else {
            nativeNetworkEnableArmed = false
            applyNativeCaptureChange(
              enableNativeLogs = config.enableNativeLogs,
              enableNativeNetwork = false
            )
          }
        },
        onNativeLogsEnableIntercept = {
          nativeCaptureConfirmationTarget = NativeCaptureConfirmationTarget.Logs
        },
        onNativeNetworkEnableIntercept = {
          nativeCaptureConfirmationTarget = NativeCaptureConfirmationTarget.Network
        }
      )
    }
    item("app_info_footer") {
      Spacer(modifier = Modifier.height(12.dp))
    }
  }
}

@Composable
private fun NativeCaptureConfirmationDialog(
  target: NativeCaptureConfirmationTarget,
  locale: String,
  onConfirm: () -> Unit,
  onDismiss: () -> Unit
) {
  AlertDialog(
    onDismissRequest = onDismiss,
    title = {
      Text(
        text = localizedNativeCaptureConfirmationTitle(target, locale),
        color = PanelColors.Text
      )
    },
    text = {
      Text(
        text = localizedNativeCaptureConfirmationMessage(target, locale),
        color = PanelColors.MutedText
      )
    },
    confirmButton = {
      TextButton(onClick = onConfirm) {
        Text(localizedNativeCaptureConfirmationConfirmLabel(locale))
      }
    },
    dismissButton = {
      TextButton(onClick = onDismiss) {
        Text(localizedNativeCaptureConfirmationCancelLabel(locale))
      }
    },
    containerColor = PanelColors.Surface,
    titleContentColor = PanelColors.Text,
    textContentColor = PanelColors.MutedText
  )
}

@Composable
private fun NativeCaptureControlCard(
  nativeLogsChecked: Boolean,
  nativeNetworkChecked: Boolean,
  nativeNetworkEnabled: Boolean,
  nativeLogsEnableRequiresConfirmation: Boolean,
  nativeNetworkEnableRequiresConfirmation: Boolean,
  pending: Boolean,
  locale: String,
  onNativeLogsChange: (Boolean) -> Unit,
  onNativeNetworkChange: (Boolean) -> Unit,
  onNativeLogsEnableIntercept: () -> Unit,
  onNativeNetworkEnableIntercept: () -> Unit
) {
  Card(
    modifier = Modifier.fillMaxWidth(),
    colors = CardDefaults.cardColors(containerColor = PanelColors.Surface),
    shape = RoundedCornerShape(8.dp),
    border = BorderStroke(1.dp, PanelColors.Border),
    elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
  ) {
    Column(modifier = Modifier.padding(12.dp)) {
      Text(
        text = localizedNativeCaptureControlTitle(locale),
        style = MaterialTheme.typography.titleSmall,
        color = PanelColors.Text
      )
      Spacer(modifier = Modifier.height(10.dp))
      NativeCaptureSwitchRow(
        title = localizedNativeLogsControlTitle(locale),
        summary = localizedNativeLogsControlSummary(locale),
        checked = nativeLogsChecked,
        enabled = !pending,
        interceptOffClick = nativeLogsEnableRequiresConfirmation,
        onCheckedChange = onNativeLogsChange,
        onOffClickIntercept = onNativeLogsEnableIntercept
      )
      HorizontalDivider(modifier = Modifier.padding(vertical = 10.dp), color = PanelColors.Border)
      NativeCaptureSwitchRow(
        title = localizedNativeNetworkControlTitle(locale),
        summary = localizedNativeNetworkControlSummary(nativeNetworkEnabled, locale),
        checked = nativeNetworkChecked && nativeNetworkEnabled,
        enabled = !pending && nativeNetworkEnabled,
        interceptOffClick = nativeNetworkEnableRequiresConfirmation,
        onCheckedChange = onNativeNetworkChange,
        onOffClickIntercept = onNativeNetworkEnableIntercept
      )
    }
  }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun NativeCaptureSwitchRow(
  title: String,
  summary: String,
  checked: Boolean,
  enabled: Boolean,
  interceptOffClick: Boolean,
  onCheckedChange: (Boolean) -> Unit,
  onOffClickIntercept: () -> Unit
) {
  Row(
    modifier = Modifier.fillMaxWidth(),
    verticalAlignment = Alignment.CenterVertically
  ) {
    val shouldInterceptOffClick = interceptOffClick && enabled && !checked
    Column(modifier = Modifier.weight(1f)) {
      Text(
        text = title,
        style = MaterialTheme.typography.bodyLarge,
        color = PanelColors.Text
      )
      Spacer(modifier = Modifier.height(4.dp))
      Text(
        text = summary,
        style = MaterialTheme.typography.bodyMedium,
        color = PanelColors.MutedText
      )
    }
    Spacer(modifier = Modifier.width(12.dp))
    Box(contentAlignment = Alignment.Center) {
      Switch(
        checked = checked,
        enabled = enabled,
        onCheckedChange = if (shouldInterceptOffClick) null else onCheckedChange
      )
      if (shouldInterceptOffClick) {
        Box(
          modifier = Modifier
            .matchParentSize()
            .pointerInteropFilter { event ->
              if (event.actionMasked == MotionEvent.ACTION_UP) {
                onOffClickIntercept()
              }
              true
            }
        )
      }
    }
  }
}

@Composable
private fun RootEnhancedControlCard(
  checked: Boolean,
  enabled: Boolean,
  runtimeInfo: DebugRuntimeInfo,
  locale: String,
  onCheckedChange: (Boolean) -> Unit
) {
  val tone = toneForRootEnhancedControl(runtimeInfo, checked)

  Card(
    modifier = Modifier.fillMaxWidth(),
    colors = CardDefaults.cardColors(containerColor = PanelColors.Surface),
    shape = RoundedCornerShape(8.dp),
    border = BorderStroke(1.dp, PanelColors.Border),
    elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
  ) {
    Column(modifier = Modifier.padding(12.dp)) {
      Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
      ) {
        Column(modifier = Modifier.weight(1f)) {
          Text(
            text = localizedRootEnhancedControlTitle(locale),
            style = MaterialTheme.typography.titleSmall,
            color = PanelColors.Text
          )
          Spacer(modifier = Modifier.height(6.dp))
          Text(
            text = localizedRootEnhancedControlSummary(runtimeInfo, checked, locale),
            style = MaterialTheme.typography.bodyMedium,
            color = PanelColors.MutedText
          )
        }
        Spacer(modifier = Modifier.width(12.dp))
        Switch(
          checked = checked,
          enabled = enabled,
          onCheckedChange = onCheckedChange
        )
      }

      Spacer(modifier = Modifier.height(10.dp))
      PanelChip(
        text = localizedRootEnhancedControlStatus(runtimeInfo, checked, locale),
        background = tone.background,
        foreground = tone.foreground
      )

      runtimeInfo.rootDetails?.takeIf { it.isNotBlank() }?.let { details ->
        Spacer(modifier = Modifier.height(10.dp))
        Text(
          text = details,
          color = PanelColors.MutedText,
          style = MaterialTheme.typography.bodySmall,
          fontFamily = FontFamily.Monospace,
          modifier = Modifier.fillMaxWidth()
        )
      }
    }
  }
}

@Composable
private fun LogsTab(
  maxLogs: Int,
  searchQuery: String,
  sortOrder: SortOrder,
  selectedLevels: Set<String>,
  selectedOrigins: Set<String>,
  nativeOriginAvailable: Boolean
) {
  val logsWindowState by InAppDebuggerStore.logsWindowState.collectAsStateWithLifecycle()
  val logSearchCache = remember(maxLogs) {
    SearchTextCache(
      capacity = (maxLogs * 2).coerceAtLeast(256),
      keySelector = DebugLogEntry::id,
      searchTextBuilder = ::buildLogSearchText
    )
  }

  val visibleLogs by produceState(
    initialValue = emptyList<DebugLogEntry>(),
    logsWindowState.version,
    searchQuery,
    sortOrder,
    selectedLevels,
    selectedOrigins
  ) {
    value =
      withContext(Dispatchers.Default) {
        filterLogs(
          source = logsWindowState.items,
          query = searchQuery,
          sortOrder = sortOrder,
          selectedLevels = selectedLevels,
          selectedOrigins = selectedOrigins,
          allFiltersSelected = PanelPreferences.isAllLogFiltersSelected(selectedLevels, selectedOrigins),
          searchCache = logSearchCache
        )
      }
  }

  LaunchedEffect(
    logsWindowState.version,
    logsWindowState.totalSize,
    visibleLogs.size,
    searchQuery,
    selectedLevels,
    selectedOrigins
  ) {
    inAppDebuggerDiagnostic("LogsTab") {
      "version=${logsWindowState.version} total=${logsWindowState.totalSize} " +
        "visible=${visibleLogs.size} query=${searchQuery.trim()} " +
        "levels=${selectedLevels.toList().sorted()} origins=${selectedOrigins.toList().sorted()}"
    }
  }

  if (visibleLogs.isEmpty()) {
    val title = if (searchQuery.isNotBlank() || selectedLevels.isEmpty()) {
      "No matching logs found"
    } else {
      "No logs yet"
    }
    val detail = when {
      selectedOrigins.isEmpty() -> localizedNoLogOriginHint(nativeOriginAvailable)
      selectedLevels.isEmpty() -> localizedNoLevelHint()
      else -> localizedEmptyHint()
    }
    EmptyState(title = title, detail = detail)
  } else {
    LazyColumn(
      modifier = Modifier.fillMaxSize(),
      contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      items(
        items = visibleLogs,
        key = { it.id },
        contentType = { "log" }
      ) { log ->
        LogCard(log = log)
      }
      item("logs_footer") {
        Spacer(modifier = Modifier.height(12.dp))
      }
    }
  }
}

@Composable
private fun NetworkTab(
  maxRequests: Int,
  searchQuery: String,
  sortOrder: SortOrder,
  selectedOrigins: Set<String>,
  selectedKinds: Set<String>,
  nativeOriginAvailable: Boolean,
  onSelectNetwork: (String) -> Unit
) {
  val networkWindowState by InAppDebuggerStore.networkWindowState.collectAsStateWithLifecycle()
  val networkSearchCache = remember(maxRequests) {
    SearchTextCache(
      capacity = (maxRequests * 3).coerceAtLeast(256),
      keySelector = DebugNetworkEntry::id,
      searchTextBuilder = { entry ->
        buildNetworkSearchText(
          entry = entry,
          localizedKindTitle = localizedNetworkKindFilterTitle(normalizedNetworkKind(entry.kind))
        )
      }
    )
  }

  val visibleEntries by produceState(
    initialValue = emptyList<DebugNetworkEntry>(),
    networkWindowState.version,
    searchQuery,
    sortOrder,
    selectedOrigins,
    selectedKinds
  ) {
    value =
      withContext(Dispatchers.Default) {
        filterNetwork(
          source = networkWindowState.items,
          query = searchQuery,
          sortOrder = sortOrder,
          selectedOrigins = selectedOrigins,
          selectedKinds = selectedKinds,
          allFiltersSelected = PanelPreferences.isAllNetworkFiltersSelected(selectedOrigins, selectedKinds),
          searchCache = networkSearchCache
        )
      }
  }

  LaunchedEffect(
    networkWindowState.version,
    networkWindowState.totalSize,
    visibleEntries.size,
    searchQuery,
    selectedOrigins,
    selectedKinds
  ) {
    inAppDebuggerDiagnostic("NetworkTab") {
      "version=${networkWindowState.version} total=${networkWindowState.totalSize} " +
        "visible=${visibleEntries.size} query=${searchQuery.trim()} " +
        "origins=${selectedOrigins.toList().sorted()} kinds=${selectedKinds.toList().sorted()}"
    }
  }

  if (visibleEntries.isEmpty()) {
    val title = if (
      searchQuery.isNotBlank() ||
        selectedOrigins.isEmpty() ||
        selectedKinds.isEmpty()
    ) {
      localizedNoNetworkResultTitle()
    } else {
      "No network requests yet"
    }
    val detail = when {
      selectedOrigins.isEmpty() && selectedKinds.isEmpty() -> localizedNoNetworkFilterHint()
      selectedOrigins.isEmpty() -> localizedNoNetworkOriginHint(nativeOriginAvailable)
      selectedKinds.isEmpty() -> localizedNoNetworkKindHint()
      else -> localizedEmptyHint()
    }
    EmptyState(title = title, detail = detail)
  } else {
    LazyColumn(
      modifier = Modifier.fillMaxSize(),
      contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      items(
        items = visibleEntries,
        key = { it.id },
        contentType = { "network" }
      ) { entry ->
        NetworkCard(
          entry = entry,
          onClick = { onSelectNetwork(entry.id) }
        )
      }
      item("network_footer") {
        Spacer(modifier = Modifier.height(12.dp))
      }
    }
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NetworkDetailScreen(
  entryId: String,
  onBack: () -> Unit,
  onClose: () -> Unit,
  onMissing: () -> Unit
) {
  val networkWindowState by InAppDebuggerStore.networkWindowState.collectAsStateWithLifecycle()
  val context = LocalContext.current
  val entry = remember(entryId, networkWindowState.version) {
    InAppDebuggerStore.networkEntry(entryId)
  }

  LaunchedEffect(entryId, networkWindowState.version) {
    if (entry == null) {
      onMissing()
    }
  }

  val resolvedEntry = entry ?: return
  val sections by produceState(
    initialValue = emptyList<DetailItem>(),
    resolvedEntry,
    context
  ) {
    value =
      withContext(Dispatchers.Default) {
        if (isWebSocketKind(resolvedEntry.kind)) {
          buildWebSocketSections(resolvedEntry, context)
        } else {
          buildHttpSections(resolvedEntry, context)
        }
      }
  }

  Scaffold(
    topBar = {
      TopAppBar(
        title = { Text("Request Details") },
        colors = TopAppBarDefaults.topAppBarColors(
          containerColor = PanelColors.Background,
          titleContentColor = PanelColors.Text,
          navigationIconContentColor = PanelColors.Primary,
          actionIconContentColor = PanelColors.Primary
        ),
        navigationIcon = {
          IconButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
          }
        },
        actions = {
          IconButton(onClick = onClose) {
            Icon(Icons.Outlined.Close, contentDescription = "Close")
          }
        }
      )
    },
    containerColor = PanelColors.Background
  ) { innerPadding ->
    LazyColumn(
      modifier = Modifier
        .fillMaxSize()
        .padding(innerPadding),
      contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      itemsIndexed(sections, key = { index, item -> "${item.title}#$index" }) { _, item ->
        DetailSection(
          title = item.title,
          content = item.content,
          monospace = item.monospace,
          contentMaxHeight = item.contentMaxHeight,
          compact = true
        )
      }
      item("network_detail_footer") {
        Spacer(modifier = Modifier.height(12.dp))
      }
    }
  }
}

@Composable
private fun SearchAndActionRow(
  query: String,
  placeholder: String,
  menuTitle: String,
  clearLabel: String,
  closeLabel: String,
  hasActiveFilters: Boolean,
  filterSections: List<FilterMenuSection>,
  onQueryChange: (String) -> Unit,
  onClear: () -> Unit,
  onClose: () -> Unit
) {
  var filterMenuExpanded by rememberSaveable { mutableStateOf(false) }
  Surface(
    modifier = Modifier.fillMaxWidth(),
    color = PanelColors.Background
  ) {
    Column {
      Row(
        modifier = Modifier
          .fillMaxWidth()
          .statusBarsPadding()
          .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
      ) {
        NativeSearchField(
          query = query,
          placeholder = placeholder,
          onQueryChange = onQueryChange,
          modifier = Modifier
            .weight(1f)
            .heightIn(min = 40.dp)
        )
        Spacer(modifier = Modifier.width(6.dp))
        PanelActionButton(
          imageVector = Icons.Outlined.DeleteOutline,
          contentDescription = clearLabel,
          onClick = onClear,
          tint = Color(0xFFB42318)
        )
        Spacer(modifier = Modifier.width(6.dp))
        Box {
          PanelActionButton(
            imageVector = Icons.Outlined.FilterList,
            contentDescription = menuTitle,
            onClick = { filterMenuExpanded = true },
            active = hasActiveFilters,
            tint = if (hasActiveFilters) Color.White else PanelColors.Primary
          )
          FilterDropdownMenu(
            expanded = filterMenuExpanded,
            onDismissRequest = { filterMenuExpanded = false },
            sections = filterSections
          )
        }
        Spacer(modifier = Modifier.width(6.dp))
        PanelActionButton(
          imageVector = Icons.Outlined.Close,
          contentDescription = closeLabel,
          onClick = onClose
        )
      }
      HorizontalDivider(color = PanelColors.Border)
    }
  }
}

@Composable
private fun NativeSearchField(
  query: String,
  placeholder: String,
  onQueryChange: (String) -> Unit,
  modifier: Modifier = Modifier
) {
  AndroidView(
    modifier = modifier,
    factory = { context ->
      SearchView(context).apply {
        setIconifiedByDefault(false)
        isIconified = false
        isSubmitButtonEnabled = false
        maxWidth = Int.MAX_VALUE
        imeOptions = EditorInfo.IME_ACTION_DONE
        queryHint = placeholder
        minimumHeight = (40f * resources.displayMetrics.density).roundToInt()

        val searchTextView =
          findViewById<SearchView.SearchAutoComplete>(androidx.appcompat.R.id.search_src_text)
        val searchIcon = findViewById<ImageView>(androidx.appcompat.R.id.search_mag_icon)
        val clearIcon = findViewById<ImageView>(androidx.appcompat.R.id.search_close_btn)
        val searchPlate = findViewById<View>(androidx.appcompat.R.id.search_plate)
        val submitArea = findViewById<View>(androidx.appcompat.R.id.submit_area)

        searchTextView?.apply {
          setTextColor(PanelColors.Text.toArgb())
          setHintTextColor(PanelColors.MutedText.toArgb())
          textSize = 16f
          isSingleLine = true
          imeOptions = EditorInfo.IME_ACTION_DONE
          inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
          setBackgroundColor(android.graphics.Color.TRANSPARENT)
        }

        searchIcon?.setColorFilter(PanelColors.MutedText.toArgb())
        clearIcon?.setColorFilter(PanelColors.MutedText.toArgb())
        searchPlate?.background = null
        submitArea?.background = null

        setOnQueryTextFocusChangeListener { _, hasFocus ->
          background = buildNativeSearchFieldBackground(context, hasFocus)
        }
        setOnQueryTextListener(object : SearchView.OnQueryTextListener {
          override fun onQueryTextSubmit(text: String?): Boolean {
            clearFocus()
            return true
          }

          override fun onQueryTextChange(newText: String?): Boolean {
            onQueryChange(newText.orEmpty())
            return true
          }
        })

        background = buildNativeSearchFieldBackground(context, hasFocus = false)
        if (query.isNotEmpty()) {
          setQuery(query, false)
        }
      }
    },
    update = { searchView ->
      if (searchView.query?.toString() != query) {
        searchView.setQuery(query, false)
        searchView.findViewById<SearchView.SearchAutoComplete>(androidx.appcompat.R.id.search_src_text)
          ?.let { textView ->
          textView.setSelection(query.length)
        }
      }
      if (searchView.queryHint?.toString() != placeholder) {
        searchView.queryHint = placeholder
      }
    }
  )
}

private fun buildNativeSearchFieldBackground(
  context: Context,
  hasFocus: Boolean
): GradientDrawable {
  val density = context.resources.displayMetrics.density
  return GradientDrawable().apply {
    shape = GradientDrawable.RECTANGLE
    cornerRadius = 12f * density
    setColor(PanelColors.Surface.toArgb())
    setStroke(
      maxOf(1, density.roundToInt()),
      if (hasFocus) PanelColors.Primary.copy(alpha = 0.45f).toArgb() else PanelColors.Border.toArgb()
    )
  }
}

@Composable
private fun PanelActionButton(
  imageVector: androidx.compose.ui.graphics.vector.ImageVector,
  contentDescription: String,
  onClick: () -> Unit,
  tint: Color = PanelColors.Text,
  active: Boolean = false
) {
  FilledTonalIconButton(
    modifier = Modifier.size(36.dp),
    onClick = onClick,
    colors = IconButtonDefaults.filledTonalIconButtonColors(
      containerColor = if (active) PanelColors.Primary else PanelColors.Control,
      contentColor = if (active) Color.White else tint
    )
  ) {
    Icon(
      imageVector = imageVector,
      contentDescription = contentDescription,
      modifier = Modifier
        .size(18.dp),
      tint = if (active) Color.White else tint
    )
  }
}

@Composable
private fun FilterDropdownMenu(
  expanded: Boolean,
  onDismissRequest: () -> Unit,
  sections: List<FilterMenuSection>
) {
  DropdownMenu(
    expanded = expanded,
    onDismissRequest = onDismissRequest,
    modifier = Modifier.background(PanelColors.Surface)
  ) {
    sections.forEachIndexed { sectionIndex, section ->
      if (sectionIndex > 0) {
        HorizontalDivider(color = PanelColors.Border)
      }
      Text(
        text = section.title,
        style = MaterialTheme.typography.labelSmall,
        color = PanelColors.MutedText,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp)
      )
      section.items.forEach { item ->
        DropdownMenuItem(
          text = {
            Text(
              text = item.label,
              color = PanelColors.Text
            )
          },
          leadingIcon = {
            if (item.selected) {
              Icon(
                imageVector = Icons.Filled.Check,
                contentDescription = null,
                tint = PanelColors.Primary
              )
            } else {
              Spacer(modifier = Modifier.size(24.dp))
            }
          },
          onClick = item.onToggle
        )
      }
    }
  }
}

@Composable
private fun LogCard(
  log: DebugLogEntry
) {
  var expanded by remember(log.id) { mutableStateOf(false) }
  var detailsOverflow by remember(log.id) { mutableStateOf(false) }
  var messageOverflow by remember(log.id) { mutableStateOf(false) }
  val context = LocalContext.current
  val tone = remember(log.type) { toneForLogLevel(log.type) }
  val details = remember(log.context, log.details) {
    combinedLogCardDetails(log.context, log.details)
  }
  val canExpand = expanded || detailsOverflow || messageOverflow

  Card(
    modifier = Modifier.fillMaxWidth(),
    colors = CardDefaults.cardColors(containerColor = PanelColors.Surface),
    shape = RoundedCornerShape(8.dp),
    border = BorderStroke(1.dp, PanelColors.Border),
    elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
  ) {
    Row(modifier = Modifier.fillMaxWidth()) {
      Box(
        modifier = Modifier
          .width(4.dp)
          .fillMaxSize()
          .background(tone.foreground)
      )

      Column(
        modifier = Modifier
          .padding(12.dp)
      ) {
        SelectionContainer(modifier = Modifier.fillMaxWidth()) {
          Column(modifier = Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
              PanelChip(
                text = localizedOriginTitle(log.origin),
                background = if (isNativeOrigin(log.origin)) PanelColors.Primary else PanelColors.Control,
                foreground = if (isNativeOrigin(log.origin)) Color.White else PanelColors.MutedText,
                compact = true
              )
              Spacer(modifier = Modifier.width(8.dp))
              PanelChip(
                text = log.type.uppercase(Locale.ROOT),
                background = tone.background,
                foreground = tone.foreground,
                compact = true
              )
              Spacer(modifier = Modifier.weight(1f))
              Text(
                text = log.timestamp,
                style = MaterialTheme.typography.labelMedium.copy(
                  fontSize = LOG_LIST_META_TEXT_SIZE,
                  lineHeight = LOG_LIST_META_LINE_HEIGHT
                ),
                color = PanelColors.MutedText
              )
              DisableSelection {
                IconButton(onClick = {
                  copyToClipboard(
                    text = formatLogCopyText(log),
                    successMessage = "Copied to clipboard",
                    context = context
                  )
                }) {
                  Icon(
                    imageVector = Icons.Outlined.ContentCopy,
                    contentDescription = "Copy log entry",
                    tint = tone.foreground
                  )
                }
              }
            }

            Column(
              modifier = Modifier
                .fillMaxWidth()
                .padding(top = if (details.isNotBlank()) 6.dp else 8.dp)
            ) {
              if (details.isNotBlank()) {
                Text(
                  text = details,
                  style = MaterialTheme.typography.labelMedium.copy(
                    fontSize = LOG_LIST_META_TEXT_SIZE,
                    lineHeight = LOG_LIST_META_LINE_HEIGHT
                  ),
                  color = PanelColors.MutedText,
                  maxLines = if (expanded) Int.MAX_VALUE else 2,
                  overflow = if (expanded) TextOverflow.Clip else TextOverflow.Ellipsis,
                  modifier = Modifier.fillMaxWidth(),
                  onTextLayout = { layoutResult ->
                    if (!expanded) {
                      detailsOverflow = layoutResult.hasVisualOverflow
                    }
                  }
                )
              }

              Text(
                text = log.message,
                style = MaterialTheme.typography.bodySmall.copy(
                  fontSize = LOG_LIST_BODY_TEXT_SIZE,
                  lineHeight = LOG_LIST_BODY_LINE_HEIGHT
                ),
                color = PanelColors.Text,
                fontFamily = FontFamily.Monospace,
                maxLines = if (expanded) Int.MAX_VALUE else 6,
                overflow = if (expanded) TextOverflow.Clip else TextOverflow.Ellipsis,
                modifier = Modifier
                  .fillMaxWidth()
                  .padding(top = if (details.isNotBlank()) 8.dp else 0.dp),
                onTextLayout = { layoutResult ->
                  if (!expanded) {
                    messageOverflow = layoutResult.hasVisualOverflow
                  }
                }
              )
            }
          }
        }

        if (canExpand) {
          DisableSelection {
            TextButton(onClick = { expanded = !expanded }) {
              Text(
                text = if (expanded) localizedCollapseLabel() else localizedExpandLabel(),
                style = MaterialTheme.typography.labelMedium.copy(
                  fontSize = LOG_LIST_META_TEXT_SIZE,
                  lineHeight = LOG_LIST_META_LINE_HEIGHT
                )
              )
            }
          }
        }
      }
    }
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NetworkCard(
  entry: DebugNetworkEntry,
  onClick: () -> Unit
) {
  val durationLabel = "Duration"
  val tone = remember(entry.state, entry.status) { toneForNetwork(entry) }
  val trailingBadgeText = remember(entry.kind, entry.status, entry.state) { networkTrailingBadgeTitle(entry) }
  val showStateLabel = remember(entry.kind, entry.status) { shouldShowNetworkStateLabel(entry) }
  val durationSummary = remember(
    entry.kind,
    entry.durationMs,
    entry.messageCountIn,
    entry.messageCountOut,
    entry.messages,
    durationLabel
  ) {
    buildNetworkDurationSummary(entry, durationLabel)
  }
  Card(
    modifier = Modifier.fillMaxWidth(),
    colors = CardDefaults.cardColors(containerColor = PanelColors.Surface),
    shape = RoundedCornerShape(8.dp),
    border = BorderStroke(1.dp, PanelColors.Border),
    elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    onClick = onClick
  ) {
    Row(modifier = Modifier.fillMaxWidth()) {
      Box(
        modifier = Modifier
          .width(4.dp)
          .fillMaxSize()
          .background(tone.foreground)
      )

      Column(modifier = Modifier.padding(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
          PanelChip(
            text = localizedOriginTitle(entry.origin),
            background = if (isNativeOrigin(entry.origin)) PanelColors.Primary else PanelColors.Control,
            foreground = if (isNativeOrigin(entry.origin)) Color.White else PanelColors.MutedText
          )
          Spacer(modifier = Modifier.width(8.dp))
          PanelChip(
            text = entry.method.uppercase(Locale.ROOT),
            background = PanelColors.SurfaceAlt,
            foreground = PanelColors.Primary
          )
          trailingBadgeText?.let { badgeText ->
            Spacer(modifier = Modifier.width(8.dp))
            PanelChip(
              text = badgeText,
              background = tone.background,
              foreground = tone.foreground
            )
          }
          Spacer(modifier = Modifier.weight(1f))
          if (showStateLabel) {
            Text(
              text = entry.state.uppercase(Locale.ROOT),
              style = MaterialTheme.typography.labelMedium,
              color = PanelColors.MutedText
            )
          }
        }

        Text(
          text = entry.url,
          style = MaterialTheme.typography.bodyMedium,
          color = PanelColors.Text,
          maxLines = 2,
          overflow = TextOverflow.Ellipsis,
          modifier = Modifier.padding(top = 8.dp)
        )

        Text(
          text = durationSummary,
          style = MaterialTheme.typography.labelMedium,
          color = PanelColors.MutedText,
          modifier = Modifier.padding(top = 6.dp)
        )
      }
    }
  }
}

private fun combinedLogCardDetails(context: String?, details: String?): String {
  val hasContext = !context.isNullOrBlank()
  val hasDetails = !details.isNullOrBlank()
  if (!hasContext && !hasDetails) {
    return ""
  }
  if (!hasContext) {
    return details.orEmpty()
  }
  if (!hasDetails) {
    return context.orEmpty()
  }
  return context + "\n" + details
}

@Composable
private fun DetailSection(
  title: String,
  content: String,
  monospace: Boolean = false,
  contentMaxHeight: Dp? = null,
  compact: Boolean = false
) {
  val scrollState = rememberScrollState()
  val titleStyle = if (compact) {
    MaterialTheme.typography.titleSmall.copy(
      fontSize = REQUEST_DETAIL_TITLE_TEXT_SIZE,
      lineHeight = REQUEST_DETAIL_TITLE_LINE_HEIGHT
    )
  } else {
    MaterialTheme.typography.titleSmall
  }
  val contentStyle = if (compact) {
    MaterialTheme.typography.bodySmall.copy(
      fontSize = REQUEST_DETAIL_BODY_TEXT_SIZE,
      lineHeight = REQUEST_DETAIL_BODY_LINE_HEIGHT
    )
  } else {
    LocalTextStyle.current
  }
  val contentModifier = Modifier.fillMaxWidth().let { modifier ->
    if (contentMaxHeight != null) {
      modifier
        .heightIn(max = contentMaxHeight)
        .verticalScroll(scrollState)
    } else {
      modifier
    }
  }

  Card(
    modifier = Modifier.fillMaxWidth(),
    colors = CardDefaults.cardColors(containerColor = PanelColors.Surface),
    shape = RoundedCornerShape(8.dp),
    border = BorderStroke(1.dp, PanelColors.Border),
    elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
  ) {
    Column(modifier = Modifier.padding(12.dp)) {
      Text(
        text = title,
        style = titleStyle,
        color = PanelColors.Text
      )
      Spacer(modifier = Modifier.height(6.dp))
      SelectionContainer(modifier = Modifier.fillMaxWidth()) {
        Text(
          text = content,
          style = contentStyle,
          color = PanelColors.Text,
          fontFamily = if (monospace) FontFamily.Monospace else FontFamily.Default,
          modifier = contentModifier
        )
      }
    }
  }
}

private fun applyPanelRootEnhancedMode(context: Context?, enabled: Boolean) {
  val currentConfig = InAppDebuggerStore.currentConfig()
  val nextAndroidNativeLogs = currentConfig.androidNativeLogs.copy(
    logcatScope = if (enabled) "device" else "app",
    rootMode = if (enabled) "auto" else "off"
  )

  if (nextAndroidNativeLogs == currentConfig.androidNativeLogs) {
    InAppDebuggerNativeLogCapture.refreshRuntimeInfo()
    return
  }

  val nextConfig = currentConfig.copy(androidNativeLogs = nextAndroidNativeLogs)
  InAppDebuggerStore.updateConfig(nextConfig)
  InAppDebuggerNativeLogCapture.applyConfig(context?.applicationContext, nextConfig)
  InAppDebuggerNativeNetworkCapture.applyConfig(context?.applicationContext, nextConfig)
  InAppDebuggerNativeLogCapture.refreshRuntimeInfo()
}

private fun applyPanelNativeCaptureMode(
  context: Context?,
  enableNativeLogs: Boolean,
  enableNativeNetwork: Boolean
) {
  val currentConfig = InAppDebuggerStore.currentConfig()
  val nextConfig = currentConfig.copy(
    enableNativeLogs = enableNativeLogs,
    enableNativeNetwork = enableNativeNetwork && currentConfig.enableNetworkTab
  )

  if (nextConfig == currentConfig) {
    InAppDebuggerNativeLogCapture.refreshRuntimeInfo()
    return
  }

  InAppDebuggerStore.updateConfig(nextConfig)
  InAppDebuggerNativeLogCapture.applyConfig(context?.applicationContext, nextConfig)
  InAppDebuggerNativeNetworkCapture.applyConfig(context?.applicationContext, nextConfig)
  InAppDebuggerNativeLogCapture.refreshRuntimeInfo()
}

private fun isRootEnhancedRequested(config: DebugConfig): Boolean {
  return config.androidNativeLogs.logcatScope == "device" &&
    config.androidNativeLogs.rootMode == "auto"
}

@Composable
private fun EmptyState(
  title: String,
  detail: String
) {
  Box(
    modifier = Modifier.fillMaxSize(),
    contentAlignment = Alignment.Center
  ) {
    Column(
      horizontalAlignment = Alignment.CenterHorizontally,
      modifier = Modifier.padding(horizontal = 24.dp)
    ) {
      Text(
        text = title,
        style = MaterialTheme.typography.titleMedium,
        color = PanelColors.Text
      )
      Spacer(modifier = Modifier.height(8.dp))
      Text(
        text = detail,
        style = MaterialTheme.typography.bodyMedium,
        color = PanelColors.MutedText
      )
    }
  }
}

@Composable
private fun PanelChip(
  text: String,
  background: Color,
  foreground: Color,
  compact: Boolean = false
) {
  val textStyle = if (compact) {
    MaterialTheme.typography.labelSmall.copy(
      fontSize = LOG_LIST_CHIP_TEXT_SIZE,
      lineHeight = LOG_LIST_CHIP_LINE_HEIGHT
    )
  } else {
    MaterialTheme.typography.labelMedium
  }

  Surface(
    color = background,
    shape = RoundedCornerShape(8.dp)
  ) {
    Text(
      text = text,
      color = foreground,
      style = textStyle,
      modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
    )
  }
}

private fun filterLogs(
  source: List<DebugLogEntry>,
  query: String,
  sortOrder: SortOrder,
  selectedLevels: Set<String>,
  selectedOrigins: Set<String>,
  allFiltersSelected: Boolean = false,
  searchCache: SearchTextCache<DebugLogEntry>? = null
): List<DebugLogEntry> {
  val trimmedQuery = query.trim()
  if (source.isEmpty() || selectedLevels.isEmpty() || selectedOrigins.isEmpty()) {
    return emptyList()
  }

  if (trimmedQuery.isEmpty() && allFiltersSelected) {
    return if (sortOrder == SortOrder.Asc) source else ReversedListView(source)
  }

  val result = ArrayList<DebugLogEntry>(source.size)
  if (sortOrder == SortOrder.Desc) {
    for (index in source.indices.reversed()) {
      val entry = source[index]
      if (entry.type !in selectedLevels || entry.origin !in selectedOrigins) {
        continue
      }
      if (trimmedQuery.isNotEmpty() && !matchesLogQuery(entry, trimmedQuery, searchCache)) {
        continue
      }
      result.add(entry)
    }
  } else {
    for (entry in source) {
      if (entry.type !in selectedLevels || entry.origin !in selectedOrigins) {
        continue
      }
      if (trimmedQuery.isNotEmpty() && !matchesLogQuery(entry, trimmedQuery, searchCache)) {
        continue
      }
      result.add(entry)
    }
  }

  return result
}

private fun filterNetwork(
  source: List<DebugNetworkEntry>,
  query: String,
  sortOrder: SortOrder,
  selectedOrigins: Set<String>,
  selectedKinds: Set<String>,
  allFiltersSelected: Boolean = false,
  searchCache: SearchTextCache<DebugNetworkEntry>? = null
): List<DebugNetworkEntry> {
  val trimmedQuery = query.trim()
  if (source.isEmpty() || selectedOrigins.isEmpty() || selectedKinds.isEmpty()) {
    return emptyList()
  }

  if (trimmedQuery.isEmpty() && allFiltersSelected) {
    return if (sortOrder == SortOrder.Asc) source else ReversedListView(source)
  }

  val result = ArrayList<DebugNetworkEntry>(source.size)
  if (sortOrder == SortOrder.Desc) {
    for (index in source.indices.reversed()) {
      val entry = source[index]
      val kind = normalizedNetworkKind(entry.kind)
      if (entry.origin !in selectedOrigins || kind.rawValue !in selectedKinds) {
        continue
      }
      if (trimmedQuery.isNotEmpty() && !matchesNetworkQuery(entry, trimmedQuery, kind, searchCache)) {
        continue
      }
      result.add(entry)
    }
  } else {
    for (entry in source) {
      val kind = normalizedNetworkKind(entry.kind)
      if (entry.origin !in selectedOrigins || kind.rawValue !in selectedKinds) {
        continue
      }
      if (trimmedQuery.isNotEmpty() && !matchesNetworkQuery(entry, trimmedQuery, kind, searchCache)) {
        continue
      }
      result.add(entry)
    }
  }
  return result
}

private fun matchesLogQuery(
  entry: DebugLogEntry,
  query: String,
  searchCache: SearchTextCache<DebugLogEntry>? = null
): Boolean {
  searchCache?.let { cache ->
    return cache.matches(entry, query)
  }

  return entry.message.contains(query, ignoreCase = true) ||
    entry.type.contains(query, ignoreCase = true) ||
    entry.origin.contains(query, ignoreCase = true) ||
    (entry.context?.contains(query, ignoreCase = true) == true) ||
    (entry.details?.contains(query, ignoreCase = true) == true)
}

private fun matchesNetworkQuery(
  entry: DebugNetworkEntry,
  query: String,
  kind: NetworkKindFilter = normalizedNetworkKind(entry.kind),
  searchCache: SearchTextCache<DebugNetworkEntry>? = null
): Boolean {
  searchCache?.let { cache ->
    return cache.matches(entry, query)
  }

  val kindTitle = localizedNetworkKindFilterTitle(kind)
  return entry.url.contains(query, ignoreCase = true) ||
    entry.origin.contains(query, ignoreCase = true) ||
    entry.kind.contains(query, ignoreCase = true) ||
    kindTitle.contains(query, ignoreCase = true) ||
    entry.method.contains(query, ignoreCase = true) ||
    entry.state.contains(query, ignoreCase = true) ||
    (entry.protocol?.contains(query, ignoreCase = true) == true) ||
    (entry.requestedProtocols?.contains(query, ignoreCase = true) == true) ||
    (entry.closeReason?.contains(query, ignoreCase = true) == true) ||
    (entry.error?.contains(query, ignoreCase = true) == true) ||
    (entry.events?.contains(query, ignoreCase = true) == true) ||
    (entry.messages?.contains(query, ignoreCase = true) == true)
}

private fun buildHttpSections(
  entry: DebugNetworkEntry,
  context: Context
): List<DetailItem> {
  val items = mutableListOf(
    DetailItem(localizedOriginTitleLabel(), localizedOriginTitle(entry.origin)),
    DetailItem(localizedNetworkTypeTitle(), localizedNetworkKindTitle(entry.kind)),
    DetailItem("Method", entry.method),
    DetailItem("Status", httpStatusDetailText(entry)),
    DetailItem("Protocol", entry.protocol ?: "-"),
    DetailItem("URL", entry.url, monospace = true),
    DetailItem("Duration", entry.durationMs?.let { "${it}ms" } ?: "-"),
    DetailItem("Request Headers", headerText(entry.requestHeaders), monospace = true),
    DetailItem("Response Headers", headerText(entry.responseHeaders), monospace = true),
    DetailItem(
      "Request Body",
      formattedStructuredContent(entry.requestBody, "No request body"),
      monospace = true,
      contentMaxHeight = NETWORK_BODY_SCROLLABLE_DETAIL_MAX_HEIGHT
    ),
    DetailItem(
      "Response Body",
      formattedStructuredContent(entry.responseBody, "No response body"),
      monospace = true,
      contentMaxHeight = NETWORK_BODY_SCROLLABLE_DETAIL_MAX_HEIGHT
    )
  )

  if (shouldShowNetworkStateLabel(entry)) {
    items.add(4, DetailItem("State", entry.state))
  }

  entry.events?.takeIf { it.isNotBlank() }?.let { events ->
    items += DetailItem(
      title = localizedNetworkEventsTitle(),
      content = formattedMessagesText(events, localizedNoNetworkEvents()),
      monospace = true
    )
  }

  if (!entry.error.isNullOrBlank()) {
    items += DetailItem("Error", entry.error.orEmpty(), monospace = true)
  }

  if (entry.responseSize != null || !entry.responseContentType.isNullOrBlank()) {
    items += DetailItem(
      title = localizedResponseMetaTitle(),
      content = buildString {
        appendLine("${localizedResponseTypeTitle()}: ${entry.responseType ?: "-"}")
        appendLine("${localizedContentTypeTitle()}: ${entry.responseContentType ?: "-"}")
        append("Size: ${formatByteCount(context, entry.responseSize)}")
      },
      monospace = true
    )
  }

  return items
}

private fun buildWebSocketSections(
  entry: DebugNetworkEntry,
  context: Context
): List<DetailItem> {
  val inferredIncoming = entry.messageCountIn ?: countMessages(entry.messages, "<<")
  val inferredOutgoing = entry.messageCountOut ?: countMessages(entry.messages, ">>")
  val items = mutableListOf(
    DetailItem(localizedOriginTitleLabel(), localizedOriginTitle(entry.origin)),
    DetailItem(localizedNetworkTypeTitle(), localizedNetworkKindTitle(entry.kind)),
    DetailItem("Method", entry.method),
    DetailItem("State", entry.state),
    DetailItem("Protocol", entry.protocol ?: "-"),
    DetailItem("Requested protocols", entry.requestedProtocols ?: "-"),
    DetailItem("URL", entry.url, monospace = true),
    DetailItem("Duration", entry.durationMs?.let { "${it}ms" } ?: "-"),
    DetailItem("Message Counts", "IN $inferredIncoming / OUT $inferredOutgoing"),
    DetailItem(
      "Bytes",
      "IN ${formatByteCount(context, entry.bytesIn)} / OUT ${formatByteCount(context, entry.bytesOut)}"
    ),
    DetailItem("Request Headers", headerText(entry.requestHeaders), monospace = true)
  )

  if (entry.responseHeaders.isNotEmpty()) {
    items += DetailItem("Response Headers", headerText(entry.responseHeaders), monospace = true)
  }

  if (entry.status != null) {
    items += DetailItem("Status", httpStatusDisplayText(entry))
  }

  if (entry.requestedCloseCode != null || !entry.requestedCloseReason.isNullOrBlank()) {
    items += DetailItem("Close requested", closeRequestSummary(entry), monospace = true)
  }

  if (entry.closeCode != null || entry.cleanClose != null || !entry.closeReason.isNullOrBlank()) {
    items += DetailItem("Close result", closeResultSummary(entry), monospace = true)
  }

  items += DetailItem("Event timeline", entry.events ?: localizedNoEventsText(), monospace = true)
  items += DetailItem(
    "Messages",
    formattedWebSocketMessagesText(entry.messages, "No messages"),
    monospace = true
  )

  if (!entry.error.isNullOrBlank()) {
    items += DetailItem("Error", entry.error.orEmpty(), monospace = true)
  }

  return items
}

private fun buildDebuggerInfoSections(
  runtimeInfo: DebugRuntimeInfo,
  config: DebugConfig,
  appErrors: List<DebugErrorEntry>,
  locale: String
): List<DetailItem> {
  return buildList {
    add(
    DetailItem(
      title = localizedHostRuntimeTitle(locale),
      content = buildString {
        appendLine("${localizedHostAppNameLabel(locale)}: ${runtimeInfo.appName.ifBlank { "-" }}")
        appendLine("${localizedPackageNameLabel(locale)}: ${runtimeInfo.packageName.ifBlank { "-" }}")
        appendLine("${localizedVersionLabel(locale)}: ${formatVersionSummary(runtimeInfo)}")
        appendLine("${localizedProcessLabel(locale)}: ${runtimeInfo.processName.ifBlank { "-" }}")
        appendLine("PID / UID: ${runtimeInfo.pid} / ${runtimeInfo.uid}")
        appendLine("${localizedDebuggableLabel(locale)}: ${localizedBooleanValue(runtimeInfo.debuggable, locale)}")
        appendLine("${localizedSdkLabel(locale)}: Android ${runtimeInfo.release.ifBlank { "-" }} (SDK ${runtimeInfo.sdkInt})")
        appendLine("${localizedTargetSdkLabel(locale)}: ${runtimeInfo.targetSdk.takeIf { it > 0 } ?: "-"}")
        appendLine("${localizedMinSdkLabel(locale)}: ${runtimeInfo.minSdk.takeIf { it > 0 } ?: "-"}")
        appendLine("${localizedDeviceLabel(locale)}: ${formatDeviceSummary(runtimeInfo)}")
        append("${localizedAbiLabel(locale)}: ${runtimeInfo.supportedAbis.joinToString().ifBlank { "-" }}")
      },
      monospace = true
    )
    )
    add(
    DetailItem(
      title = localizedDebuggerCapabilityTitle(locale),
      content = buildCapabilitySummary(runtimeInfo, config, locale)
    )
    )
    add(
    DetailItem(
      title = localizedCaptureStatusTitle(locale),
      content = buildString {
        appendLine("${localizedRootStatusLabel(locale)}: ${localizedRootStatus(runtimeInfo.rootStatus, locale)}")
        runtimeInfo.rootDetails?.takeIf { it.isNotBlank() }?.let {
          appendLine("${localizedRootDetailLabel(locale)}: $it")
        }
        appendLine("${localizedNativeLogsStatusLabel(locale)}: ${localizedBooleanValue(runtimeInfo.nativeLogsEnabled, locale)}")
        appendLine("${localizedNativeNetworkStatusLabel(locale)}: ${localizedBooleanValue(runtimeInfo.nativeNetworkEnabled, locale)}")
        appendLine("${localizedLogcatModeLabel(locale)}: ${localizedLogcatMode(runtimeInfo.activeLogcatMode, locale)}")
        appendLine("${localizedRequestedScopeLabel(locale)}: ${localizedLogcatScope(runtimeInfo.requestedLogcatScope, locale)}")
        appendLine("${localizedRequestedRootModeLabel(locale)}: ${localizedRootMode(runtimeInfo.requestedRootMode, locale)}")
        appendLine("${localizedCaptureItemLabel(locale)}: ${buildCaptureItemsSummary(runtimeInfo, locale)}")
        append("${localizedBuffersLabel(locale)}: ${runtimeInfo.buffers.joinToString().ifBlank { "-" }}")
      },
      monospace = true
    )
    )
    addAll(buildCrashRecordSections(runtimeInfo, locale))
    addAll(buildFatalErrorSections(appErrors, locale))
    add(
      DetailItem(
      title = localizedLimitationsTitle(locale),
      content = buildLimitationsSummary(runtimeInfo, config, locale)
    )
    )
  }
}

private fun buildFatalErrorSections(
  appErrors: List<DebugErrorEntry>,
  locale: String
): List<DetailItem> {
  val fatalErrors = ArrayList<DebugErrorEntry>(appErrors.size)
  for (index in appErrors.indices.reversed()) {
    val error = appErrors[index]
    if (error.source in setOf("global", "react") || error.message.contains("[FATAL]")) {
      fatalErrors.add(error)
    }
  }

  if (fatalErrors.isEmpty()) {
    return listOf(
      DetailItem(
        title = localizedFatalErrorRecordsTitle(locale),
        content = localizedNoFatalErrorRecordsText(locale)
      )
    )
  }

  return buildList {
    add(
      DetailItem(
        title = localizedFatalErrorRecordsTitle(locale),
        content = localizedFatalErrorRecordsSummaryText(locale, fatalErrors.size)
      )
    )
    fatalErrors.forEachIndexed { index, error ->
      add(
        DetailItem(
          title = localizedFatalErrorTitle(locale, index + 1),
          content = buildString {
            appendLine("${localizedCrashTimeLabel(locale)}: ${error.fullTimestamp.ifBlank { error.timestamp.ifBlank { "-" } }}")
            appendLine("${localizedFatalErrorSourceLabel(locale)}: ${error.source.ifBlank { "-" }}")
            appendLine("${localizedFatalErrorMessageLabel(locale)}:")
            append(error.message.ifBlank { "-" })
          },
          monospace = true,
          contentMaxHeight = APP_INFO_SCROLLABLE_DETAIL_MAX_HEIGHT
        )
      )
    }
  }
}

private fun buildCrashRecordSections(
  runtimeInfo: DebugRuntimeInfo,
  locale: String
): List<DetailItem> {
  val records = runtimeInfo.crashRecords
  if (records.isEmpty()) {
    return listOf(
      DetailItem(
        title = localizedCrashRecordsTitle(locale),
        content = localizedNoCrashRecordsText(locale)
      )
    )
  }

  return buildList {
    add(
      DetailItem(
        title = localizedCrashRecordsTitle(locale),
        content = localizedCrashRecordsSummaryText(locale, records.size)
      )
    )
    records.forEachIndexed { index, record ->
      add(
        DetailItem(
          title = localizedCrashRecordTitle(locale, index + 1),
          content = formatCrashRecord(record, locale),
          monospace = true,
          contentMaxHeight = APP_INFO_SCROLLABLE_DETAIL_MAX_HEIGHT
        )
      )
    }
  }
}

private fun formatCrashRecord(record: DebugCrashRecord, locale: String): String {
  return buildString {
    appendLine("${localizedCrashTimeLabel(locale)}: ${formatCrashTimestamp(record.timestampMillis)}")
    appendLine("${localizedCrashThreadLabel(locale)}: ${record.threadName.ifBlank { "-" }}")
    appendLine("${localizedCrashExceptionLabel(locale)}: ${record.exceptionClass.ifBlank { "-" }}")
    appendLine("${localizedCrashMessageLabel(locale)}: ${record.message.ifBlank { "-" }}")
    appendLine(localizedCrashStackLabel(locale) + ":")
    append(record.stackTrace.ifBlank { "-" })
  }
}

private fun formatCrashTimestamp(timestampMillis: Long): String {
  return appInfoCrashTimestampFormatter.format(Instant.ofEpochMilli(timestampMillis))
}

private fun toneForLogLevel(level: String): PanelTone {
  return when (level.lowercase(Locale.ROOT)) {
    "error" -> PanelTone(
      foreground = Color(0xFFB42318),
      background = Color(0xFFFEEAEA)
    )
    "warn" -> PanelTone(
      foreground = Color(0xFFD97706),
      background = Color(0xFFFFF4DE)
    )
    "info" -> PanelTone(
      foreground = Color(0xFF1D4ED8),
      background = Color(0xFFEAF2FF)
    )
    "debug" -> PanelTone(
      foreground = Color(0xFF475467),
      background = Color(0xFFF2F4F7)
    )
    else -> PanelTone(
      foreground = PanelColors.Primary,
      background = PanelColors.SurfaceAlt
    )
  }
}

private fun toneForNetwork(entry: DebugNetworkEntry): PanelTone {
  return when {
    entry.state == "error" || (entry.status ?: 0) >= 400 -> toneForLogLevel("error")
    entry.state == "pending" || entry.state == "connecting" -> PanelTone(
      foreground = Color(0xFF4B5563),
      background = Color(0xFFE5E7EB)
    )
    entry.state == "closed" || entry.state == "closing" -> toneForLogLevel("warn")
    else -> toneForLogLevel("log")
  }
}

private fun toneForRootEnhancedControl(
  runtimeInfo: DebugRuntimeInfo,
  checked: Boolean
): PanelTone {
  return when {
    checked && runtimeInfo.activeLogcatMode == "root-device" -> PanelTone(
      foreground = Color(0xFF067647),
      background = Color(0xFFE8F7EE)
    )
    checked && runtimeInfo.rootStatus == "non_root" -> toneForLogLevel("error")
    runtimeInfo.rootStatus == "checking" -> toneForLogLevel("warn")
    runtimeInfo.rootStatus == "root" -> PanelTone(
      foreground = Color(0xFF067647),
      background = Color(0xFFE8F7EE)
    )
    checked -> toneForLogLevel("info")
    else -> toneForLogLevel("debug")
  }
}

private fun normalizedNetworkKind(rawKind: String): NetworkKindFilter {
  return when (rawKind.trim().lowercase(Locale.ROOT)) {
    "", "http", "https", "xhr", "xmlhttprequest", "fetch" -> NetworkKindFilter.Http
    "websocket", "ws", "wss", "socket" -> NetworkKindFilter.WebSocket
    else -> NetworkKindFilter.Other
  }
}

private fun isWebSocketKind(rawKind: String): Boolean {
  return normalizedNetworkKind(rawKind) == NetworkKindFilter.WebSocket
}

private fun networkKindBadgeTitle(rawKind: String): String {
  return when (normalizedNetworkKind(rawKind)) {
    NetworkKindFilter.Http -> "XHR/FETCH"
    NetworkKindFilter.WebSocket -> "WS"
    NetworkKindFilter.Other -> rawKind.trim().ifBlank { "OTHER" }.uppercase(Locale.ROOT)
  }
}

private fun networkTrailingBadgeTitle(entry: DebugNetworkEntry): String? {
  return when {
    entry.status != null -> httpStatusDisplayText(entry)
    isWebSocketKind(entry.kind) -> null
    else -> networkKindBadgeTitle(entry.kind)
  }
}

private fun httpStatusDisplayText(entry: DebugNetworkEntry): String {
  val status = entry.status ?: return "-"
  if (status == 0 && entry.state == "error") {
    return "(failed)"
  }
  return status.toString()
}

private fun httpStatusDetailText(entry: DebugNetworkEntry): String {
  return if (entry.status != null) {
    httpStatusDisplayText(entry)
  } else {
    "-"
  }
}

private fun shouldShowNetworkStateLabel(entry: DebugNetworkEntry): Boolean {
  if (isWebSocketKind(entry.kind)) {
    return true
  }
  return entry.status == null
}

private fun localizedNetworkTypeTitle(): String {
  return "Request Type"
}

private fun localizedNetworkKindFilterTitle(kind: NetworkKindFilter): String {
  return when (kind) {
    NetworkKindFilter.Http -> "XHR/Fetch"
    NetworkKindFilter.WebSocket -> "WebSocket"
    NetworkKindFilter.Other -> "Other"
  }
}

private fun localizedNetworkKindTitle(rawKind: String): String {
  return when (val normalized = normalizedNetworkKind(rawKind)) {
    NetworkKindFilter.Http -> localizedNetworkKindFilterTitle(normalized)
    NetworkKindFilter.WebSocket -> localizedNetworkKindFilterTitle(normalized)
    NetworkKindFilter.Other -> rawKind.trim().takeIf {
      it.isNotEmpty() && !it.equals(NetworkKindFilter.Other.rawValue, ignoreCase = true)
    }?.uppercase(Locale.ROOT) ?: localizedNetworkKindFilterTitle(normalized)
  }
}

private fun isNativeOrigin(origin: String): Boolean {
  return origin.equals("native", ignoreCase = true)
}

private fun localizedOriginTitle(origin: String): String {
  return if (isNativeOrigin(origin)) {
    "Native"
  } else {
    "JS"
  }
}

private fun localizedOriginTitleLabel(): String {
  return "Origin"
}

private fun localizedLevelTitle(): String {
  return "Level"
}

private fun localizedSortTitle(ascending: Boolean): String {
  return if (ascending) "Time Asc" else "Time Desc"
}

private fun localizedSortMenuTitle(): String {
  return "Sort"
}

private fun localizedMenuTitle(): String {
  return "Menu"
}

private fun localizedLogsSearchPlaceholder(): String {
  return LOGS_SEARCH_PLACEHOLDER
}

private fun localizedNetworkSearchPlaceholder(): String {
  return NETWORK_SEARCH_PLACEHOLDER
}

private fun localizedEmptyHint(): String {
  return "Try another keyword or generate new events."
}

private fun localizedNoLevelHint(): String {
  return "Select at least one level to show logs."
}

private fun localizedNoLogOriginHint(nativeOriginAvailable: Boolean): String {
  return if (nativeOriginAvailable) {
    "Select JS or Native to show logs."
  } else {
    "Select JS to show logs."
  }
}

private fun localizedNoNetworkOriginHint(nativeOriginAvailable: Boolean): String {
  return if (nativeOriginAvailable) {
    "Select JS or Native to show network entries."
  } else {
    "Select JS to show network entries."
  }
}

private fun localizedNoNetworkKindHint(): String {
  return "Select at least one request type to show network entries."
}

private fun localizedNoNetworkFilterHint(): String {
  return "Select at least one source and request type to show network entries."
}

private fun localizedNoNetworkResultTitle(): String {
  return "No matching network requests found"
}

private fun localizedResponseMetaTitle(): String {
  return "Response Metadata"
}

private fun localizedResponseTypeTitle(): String {
  return "Type"
}

private fun localizedContentTypeTitle(): String {
  return "Content-Type"
}

private fun localizedNoEventsText(): String {
  return "No events yet"
}

private fun localizedExpandLabel(): String {
  return "Expand"
}

private fun localizedCollapseLabel(): String {
  return "Collapse"
}

private fun buildCapabilitySummary(
  runtimeInfo: DebugRuntimeInfo,
  config: DebugConfig,
  locale: String
): String {
  val lines = mutableListOf<String>()
  lines += localizedCapabilityJsLogs(locale)
  lines += localizedCapabilityJsErrors(locale)
  lines += if (runtimeInfo.nativeLogsEnabled) {
    localizedCapabilityNativeLogs(runtimeInfo, locale)
  } else {
    localizedCapabilityNativeDisabled(locale)
  }
  lines += if (runtimeInfo.networkTabEnabled) {
    localizedCapabilityNetworkEnabled(locale)
  } else {
    localizedCapabilityNetworkDisabled(locale)
  }
  if (runtimeInfo.networkTabEnabled) {
    lines += if (runtimeInfo.nativeNetworkEnabled) {
      localizedCapabilityNativeNetworkEnabled(locale)
    } else {
      localizedCapabilityNativeNetworkDisabled(locale)
    }
  }
  if (config.androidNativeLogs.rootMode == "auto" && runtimeInfo.rootStatus == "root") {
    lines += localizedCapabilityRootEnhanced(locale)
  }
  return lines.joinToString("\n") { "• $it" }
}

private fun buildLimitationsSummary(
  runtimeInfo: DebugRuntimeInfo,
  config: DebugConfig,
  locale: String
): String {
  val lines = mutableListOf<String>()
  lines += localizedLimitationStartupTiming(locale)
  lines += localizedLimitationStdoutTiming(locale)

  if (runtimeInfo.activeLogcatMode != "root-device") {
    lines += localizedLimitationNonRootScope(locale)
  }
  if (config.androidNativeLogs.rootMode != "auto") {
    lines += localizedLimitationRootNotEnabled(locale)
  }
  if (runtimeInfo.networkTabEnabled && runtimeInfo.nativeNetworkEnabled) {
    lines += localizedLimitationAndroidNativeNetwork(locale)
  } else if (runtimeInfo.networkTabEnabled) {
    lines += localizedLimitationNativeNetworkDisabled(locale)
  } else {
    lines += localizedLimitationNetworkTabDisabled(locale)
  }

  return lines.joinToString("\n") { "• $it" }
}

private fun formatVersionSummary(runtimeInfo: DebugRuntimeInfo): String {
  val versionName = runtimeInfo.versionName.ifBlank { "-" }
  val versionCode = runtimeInfo.versionCode?.toString() ?: "-"
  return if (versionName == "-" && versionCode == "-") "-" else "$versionName ($versionCode)"
}

private fun formatDeviceSummary(runtimeInfo: DebugRuntimeInfo): String {
  val summary = listOfNotNull(
    runtimeInfo.deviceModel.takeIf { it.isNotBlank() },
    runtimeInfo.brand.takeIf { it.isNotBlank() && !runtimeInfo.deviceModel.contains(it, ignoreCase = true) }
  ).joinToString(" / ")
  return summary.ifBlank { runtimeInfo.manufacturer.ifBlank { "-" } }
}

private fun buildCaptureItemsSummary(runtimeInfo: DebugRuntimeInfo, locale: String): String {
  val items = mutableListOf<String>()
  if (runtimeInfo.captureLogcat) {
    items += localizedCaptureLogcatLabel(locale)
  }
  if (runtimeInfo.captureStdoutStderr) {
    items += localizedCaptureStdoutLabel(locale)
  }
  if (runtimeInfo.captureUncaughtExceptions) {
    items += localizedCaptureExceptionLabel(locale)
  }
  return items.joinToString().ifBlank { localizedCaptureDisabledLabel(locale) }
}

private fun localizedHostRuntimeTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Host Runtime"
    locale.startsWith("ja") -> "ホストアプリ実行情報"
    locale == "zh-TW" -> "宿主應用執行資訊"
    else -> "宿主应用运行信息"
  }
}

private fun localizedDebuggerCapabilityTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "What This Debugger Can Inspect"
    locale.startsWith("ja") -> "このデバッガーで確認できる内容"
    locale == "zh-TW" -> "目前調試器可查看的內容"
    else -> "当前调试器可查看的内容"
  }
}

private fun localizedNativeCaptureControlTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Native Capture"
    locale.startsWith("ja") -> "ネイティブ採集"
    locale == "zh-TW" -> "原生採集"
    else -> "原生采集"
  }
}

private fun localizedNativeCaptureConfirmationTitle(
  target: NativeCaptureConfirmationTarget,
  locale: String
): String {
  return when (target) {
    NativeCaptureConfirmationTarget.Logs -> when {
      locale.startsWith("en") -> "Enable native logs?"
      locale.startsWith("ja") -> "ネイティブログを有効にしますか？"
      locale == "zh-TW" -> "確認開啟原生日誌？"
      else -> "确认开启原生日志？"
    }
    NativeCaptureConfirmationTarget.Network -> when {
      locale.startsWith("en") -> "Enable native network?"
      locale.startsWith("ja") -> "ネイティブ通信を有効にしますか？"
      locale == "zh-TW" -> "確認開啟原生網路？"
      else -> "确认开启原生网络？"
    }
  }
}

private fun localizedNativeCaptureConfirmationMessage(
  target: NativeCaptureConfirmationTarget,
  locale: String
): String {
  return when (target) {
    NativeCaptureConfirmationTarget.Logs -> when {
      locale.startsWith("en") ->
        "Native log capture enables heavier native hooks and may cause the host app to become unstable or crash. Enable it only temporarily for special debugging cases.\n\nIf you still want to enable it, confirm this dialog, then tap the switch again. It will only turn on after the second tap."
      locale.startsWith("ja") ->
        "ネイティブログ採集は重いネイティブフックを有効にするため、ホストアプリが不安定になったりクラッシュしたりする可能性があります。特殊な調査時だけ一時的に有効にしてください。\n\nそれでも有効にする場合は、この確認を承認してからもう一度スイッチをタップしてください。2 回目のタップで有効になります。"
      locale == "zh-TW" ->
        "原生日誌採集會啟用較重的原生 hook，可能導致宿主應用不穩定甚至崩潰。請僅在特殊排查場景中臨時開啟。\n\n如果確認仍要開啟，請關閉此提示後再次點擊開關；第二次點擊才會真正開啟。"
      else ->
        "原生日志采集会启用较重的原生 hook，可能导致宿主应用不稳定甚至崩溃。请仅在特殊排查场景中临时开启。\n\n如果确认仍要开启，请关闭此提示后再次点击开关；第二次点击才会真正开启。"
    }
    NativeCaptureConfirmationTarget.Network -> when {
      locale.startsWith("en") ->
        "Native network capture enables heavier native hooks and may cause the host app to become unstable or crash. Enable it only temporarily for special debugging cases.\n\nIf you still want to enable it, confirm this dialog, then tap the switch again. It will only turn on after the second tap."
      locale.startsWith("ja") ->
        "ネイティブ通信採集は重いネイティブフックを有効にするため、ホストアプリが不安定になったりクラッシュしたりする可能性があります。特殊な調査時だけ一時的に有効にしてください。\n\nそれでも有効にする場合は、この確認を承認してからもう一度スイッチをタップしてください。2 回目のタップで有効になります。"
      locale == "zh-TW" ->
        "原生網路採集會啟用較重的原生 hook，可能導致宿主應用不穩定甚至崩潰。請僅在特殊排查場景中臨時開啟。\n\n如果確認仍要開啟，請關閉此提示後再次點擊開關；第二次點擊才會真正開啟。"
      else ->
        "原生网络采集会启用较重的原生 hook，可能导致宿主应用不稳定甚至崩溃。请仅在特殊排查场景中临时开启。\n\n如果确认仍要开启，请关闭此提示后再次点击开关；第二次点击才会真正开启。"
    }
  }
}

private fun localizedNativeCaptureConfirmationConfirmLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Still enable"
    locale.startsWith("ja") -> "それでも有効にする"
    locale == "zh-TW" -> "仍要開啟"
    else -> "仍要开启"
  }
}

private fun localizedNativeCaptureConfirmationCancelLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Cancel"
    locale.startsWith("ja") -> "キャンセル"
    locale == "zh-TW" -> "取消"
    else -> "取消"
  }
}

private fun localizedNativeLogsControlTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Native logs"
    locale.startsWith("ja") -> "ネイティブログ"
    locale == "zh-TW" -> "原生日誌"
    else -> "原生日志"
  }
}

private fun localizedNativeLogsControlSummary(locale: String): String {
  return when {
    locale.startsWith("en") -> "Temporarily capture logcat, stdout/stderr, and native uncaught exceptions."
    locale.startsWith("ja") -> "logcat、stdout/stderr、ネイティブ未捕捉例外を一時的に採集します。"
    locale == "zh-TW" -> "臨時採集 logcat、stdout/stderr 與原生未捕捉例外。"
    else -> "临时采集 logcat、stdout/stderr 与原生未捕获异常。"
  }
}

private fun localizedNativeNetworkControlTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Native network"
    locale.startsWith("ja") -> "ネイティブ通信"
    locale == "zh-TW" -> "原生網路"
    else -> "原生网络"
  }
}

private fun localizedNativeNetworkControlSummary(networkTabEnabled: Boolean, locale: String): String {
  if (!networkTabEnabled) {
    return when {
      locale.startsWith("en") -> "Unavailable because the network tab is disabled."
      locale.startsWith("ja") -> "通信タブが無効なため利用できません。"
      locale == "zh-TW" -> "網路面板已關閉，因此不可用。"
      else -> "network 面板已关闭，因此不可用。"
    }
  }
  return when {
    locale.startsWith("en") -> "Temporarily capture explicitly integrated native OkHttp traffic."
    locale.startsWith("ja") -> "明示的に統合したネイティブ OkHttp 通信を一時的に採集します。"
    locale == "zh-TW" -> "臨時採集已顯式接入的原生 OkHttp 流量。"
    else -> "临时采集已显式接入的原生 OkHttp 流量。"
  }
}

private fun localizedRootEnhancedControlTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Root-Enhanced Device Logcat"
    locale.startsWith("ja") -> "root 強化の端末全体 logcat"
    locale == "zh-TW" -> "root 增強整機 logcat"
    else -> "root 增强整机 logcat"
  }
}

private fun localizedRootEnhancedControlStatus(
  runtimeInfo: DebugRuntimeInfo,
  checked: Boolean,
  locale: String
): String {
  return when {
    checked && runtimeInfo.activeLogcatMode == "root-device" -> when {
      locale.startsWith("en") -> "Root device-wide capture active"
      locale.startsWith("ja") -> "root による端末全体採集が有効"
      locale == "zh-TW" -> "root 整機採集已啟用"
      else -> "root 整机采集已启用"
    }
    checked && runtimeInfo.rootStatus == "non_root" -> when {
      locale.startsWith("en") -> "Requested, but root is unavailable"
      locale.startsWith("ja") -> "要求済みですが root は利用不可"
      locale == "zh-TW" -> "已請求，但 root 不可用"
      else -> "已请求，但 root 不可用"
    }
    runtimeInfo.rootStatus == "checking" -> when {
      locale.startsWith("en") -> "Checking root availability"
      locale.startsWith("ja") -> "root 利用可否を確認中"
      locale == "zh-TW" -> "檢查 root 可用性中"
      else -> "正在检查 root 可用性"
    }
    runtimeInfo.rootStatus == "root" -> when {
      locale.startsWith("en") -> "Root available"
      locale.startsWith("ja") -> "root 利用可能"
      locale == "zh-TW" -> "root 可用"
      else -> "root 可用"
    }
    checked -> when {
      locale.startsWith("en") -> "Requested"
      locale.startsWith("ja") -> "要求済み"
      locale == "zh-TW" -> "已請求"
      else -> "已请求"
    }
    else -> when {
      locale.startsWith("en") -> "App-only capture"
      locale.startsWith("ja") -> "アプリ限定採集"
      locale == "zh-TW" -> "僅應用採集"
      else -> "仅应用采集"
    }
  }
}

private fun localizedRootEnhancedControlSummary(
  runtimeInfo: DebugRuntimeInfo,
  checked: Boolean,
  locale: String
): String {
  return when {
    checked && runtimeInfo.activeLogcatMode == "root-device" -> when {
      locale.startsWith("en") -> "The debugger is reading device-wide Android logcat through root, including logs outside the current app process."
      locale.startsWith("ja") -> "デバッガーは root 経由で端末全体の Android logcat を読み取っており、現在のアプリプロセス外のログも含まれます。"
      locale == "zh-TW" -> "調試器目前正透過 root 讀取整機 Android logcat，包含目前應用進程之外的日誌。"
      else -> "调试器当前正通过 root 读取整机 Android logcat，包含当前应用进程之外的日志。"
    }
    checked && runtimeInfo.rootStatus == "non_root" -> when {
      locale.startsWith("en") -> "Root-enhanced mode is requested, but root was unavailable or denied. Capture falls back to the current app until root is granted."
      locale.startsWith("ja") -> "root 強化モードは要求されていますが、root が利用できないか拒否されました。root が許可されるまでは現在のアプリ採集に回退します。"
      locale == "zh-TW" -> "已請求 root 增強模式，但 root 不可用或已被拒絕；在授權前會回退為目前應用採集。"
      else -> "已请求 root 增强模式，但 root 不可用或已被拒绝；在授权前会回退为当前应用采集。"
    }
    runtimeInfo.rootStatus == "root" -> when {
      locale.startsWith("en") -> "Root is available on this device. Turn this on to upgrade Android logcat capture from app-only to device-wide."
      locale.startsWith("ja") -> "この端末では root が利用可能です。オンにすると Android logcat 採集をアプリ限定から端末全体へ拡張できます。"
      locale == "zh-TW" -> "此裝置可使用 root；打開後可將 Android logcat 採集從僅當前應用提升為整機範圍。"
      else -> "此设备可使用 root；打开后可将 Android logcat 采集从仅当前应用提升为整机范围。"
    }
    checked -> when {
      locale.startsWith("en") -> "This requests device-wide Android logcat through root. If root is unavailable, the collector falls back to app-only capture."
      locale.startsWith("ja") -> "これは root 経由の端末全体 Android logcat を要求します。root が利用できない場合はアプリ限定採集に回退します。"
      locale == "zh-TW" -> "這會要求透過 root 讀取整機 Android logcat；若 root 不可用，則會回退到僅當前應用採集。"
      else -> "这会要求通过 root 读取整机 Android logcat；若 root 不可用，则会回退到仅当前应用采集。"
    }
    else -> when {
      locale.startsWith("en") -> "Keep this off to stay on current-app logcat only. Turn it on later if root becomes available."
      locale.startsWith("ja") -> "オフのままだと現在のアプリの logcat のみを採集します。root が使えるようになったら後でオンにできます。"
      locale == "zh-TW" -> "保持關閉時只採集目前應用的 logcat；若之後可用 root，再打開即可。"
      else -> "保持关闭时只采集当前应用的 logcat；如果之后可用 root，再打开即可。"
    }
  }
}

private fun localizedCaptureStatusTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Current Capture Status"
    locale.startsWith("ja") -> "現在の採集状態"
    locale == "zh-TW" -> "目前採集狀態"
    else -> "当前采集状态"
  }
}

private fun localizedLimitationsTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Current Limitations"
    locale.startsWith("ja") -> "現在の制限事項"
    locale == "zh-TW" -> "目前限制"
    else -> "当前限制"
  }
}

private fun localizedCloseLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Close"
    locale.startsWith("ja") -> "閉じる"
    locale == "zh-TW" -> "關閉"
    else -> "关闭"
  }
}

private fun localizedHostAppNameLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "App name"
    locale.startsWith("ja") -> "アプリ名"
    locale == "zh-TW" -> "應用名稱"
    else -> "应用名称"
  }
}

private fun localizedPackageNameLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Package"
    locale.startsWith("ja") -> "パッケージ名"
    locale == "zh-TW" -> "套件名"
    else -> "包名"
  }
}

private fun localizedVersionLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Version"
    locale.startsWith("ja") -> "バージョン"
    locale == "zh-TW" -> "版本"
    else -> "版本"
  }
}

private fun localizedProcessLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Process"
    locale.startsWith("ja") -> "プロセス"
    locale == "zh-TW" -> "程序"
    else -> "进程"
  }
}

private fun localizedDebuggableLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Debuggable"
    locale.startsWith("ja") -> "デバッグ可能"
    locale == "zh-TW" -> "可調試"
    else -> "可调试"
  }
}

private fun localizedSdkLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "OS"
    locale.startsWith("ja") -> "系統"
    locale == "zh-TW" -> "系統"
    else -> "系统"
  }
}

private fun localizedTargetSdkLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Target SDK"
    locale.startsWith("ja") -> "Target SDK"
    locale == "zh-TW" -> "Target SDK"
    else -> "Target SDK"
  }
}

private fun localizedMinSdkLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Min SDK"
    locale.startsWith("ja") -> "Min SDK"
    locale == "zh-TW" -> "Min SDK"
    else -> "Min SDK"
  }
}

private fun localizedDeviceLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Device"
    locale.startsWith("ja") -> "デバイス"
    locale == "zh-TW" -> "裝置"
    else -> "设备"
  }
}

private fun localizedAbiLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "ABIs"
    locale.startsWith("ja") -> "ABI"
    locale == "zh-TW" -> "ABI"
    else -> "ABI"
  }
}

private fun localizedRootStatusLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Root status"
    locale.startsWith("ja") -> "root 状態"
    locale == "zh-TW" -> "root 狀態"
    else -> "root 状态"
  }
}

private fun localizedRootDetailLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Root detail"
    locale.startsWith("ja") -> "root 詳細"
    locale == "zh-TW" -> "root 詳情"
    else -> "root 详情"
  }
}

private fun localizedNativeLogsStatusLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Native logs enabled"
    locale.startsWith("ja") -> "ネイティブログ有効"
    locale == "zh-TW" -> "原生日誌已啟用"
    else -> "原生日志已启用"
  }
}

private fun localizedNativeNetworkStatusLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Native network enabled"
    locale.startsWith("ja") -> "ネイティブ通信有効"
    locale == "zh-TW" -> "原生網路已啟用"
    else -> "原生网络已启用"
  }
}

private fun localizedLogcatModeLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Active logcat mode"
    locale.startsWith("ja") -> "現在の logcat モード"
    locale == "zh-TW" -> "目前 logcat 模式"
    else -> "当前 logcat 模式"
  }
}

private fun localizedRequestedScopeLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Requested scope"
    locale.startsWith("ja") -> "要求された範囲"
    locale == "zh-TW" -> "要求範圍"
    else -> "请求范围"
  }
}

private fun localizedRequestedRootModeLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Root mode"
    locale.startsWith("ja") -> "root モード"
    locale == "zh-TW" -> "root 模式"
    else -> "root 模式"
  }
}

private fun localizedCaptureItemLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Capture items"
    locale.startsWith("ja") -> "採集項目"
    locale == "zh-TW" -> "採集項目"
    else -> "采集项目"
  }
}

private fun localizedBuffersLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Buffers"
    locale.startsWith("ja") -> "バッファ"
    locale == "zh-TW" -> "緩衝區"
    else -> "缓冲区"
  }
}

private fun localizedBooleanValue(value: Boolean, locale: String): String {
  return when {
    locale.startsWith("en") -> if (value) "Yes" else "No"
    locale.startsWith("ja") -> if (value) "はい" else "いいえ"
    locale == "zh-TW" -> if (value) "是" else "否"
    else -> if (value) "是" else "否"
  }
}

private fun localizedRootStatus(status: String, locale: String): String {
  return when (status) {
    "root" -> when {
      locale.startsWith("en") -> "Root verified"
      locale.startsWith("ja") -> "root を確認済み"
      locale == "zh-TW" -> "已驗證 root"
      else -> "已验证 root"
    }
    "non_root" -> when {
      locale.startsWith("en") -> "Non-root or root denied"
      locale.startsWith("ja") -> "非 root または拒否"
      locale == "zh-TW" -> "非 root 或已拒絕"
      else -> "非 root 或已拒绝"
    }
    "checking" -> when {
      locale.startsWith("en") -> "Checking..."
      locale.startsWith("ja") -> "確認中..."
      locale == "zh-TW" -> "檢查中..."
      else -> "检测中..."
    }
    "unknown" -> when {
      locale.startsWith("en") -> "Unknown"
      locale.startsWith("ja") -> "不明"
      locale == "zh-TW" -> "未知"
      else -> "未知"
    }
    else -> when {
      locale.startsWith("en") -> "Not probed yet"
      locale.startsWith("ja") -> "まだ確認していません"
      locale == "zh-TW" -> "尚未驗證"
      else -> "尚未验证"
    }
  }
}

private fun localizedLogcatMode(mode: String, locale: String): String {
  return when (mode) {
    "app" -> when {
      locale.startsWith("en") -> "App-only logcat"
      locale.startsWith("ja") -> "アプリ限定 logcat"
      locale == "zh-TW" -> "僅宿主應用 logcat"
      else -> "仅宿主应用 logcat"
    }
    "app-fallback" -> when {
      locale.startsWith("en") -> "App-only logcat (fallback)"
      locale.startsWith("ja") -> "アプリ限定 logcat（回退）"
      locale == "zh-TW" -> "僅宿主應用 logcat（回退）"
      else -> "仅宿主应用 logcat（回退）"
    }
    "root-device" -> when {
      locale.startsWith("en") -> "Device-wide logcat via root"
      locale.startsWith("ja") -> "root 経由の端末全体 logcat"
      locale == "zh-TW" -> "透過 root 的整機 logcat"
      else -> "通过 root 的整机 logcat"
    }
    else -> when {
      locale.startsWith("en") -> "Disabled"
      locale.startsWith("ja") -> "無効"
      locale == "zh-TW" -> "未啟用"
      else -> "未启用"
    }
  }
}

private fun localizedLogcatScope(scope: String, locale: String): String {
  return when (scope) {
    "device" -> when {
      locale.startsWith("en") -> "Device-wide"
      locale.startsWith("ja") -> "端末全体"
      locale == "zh-TW" -> "整機"
      else -> "整机"
    }
    else -> when {
      locale.startsWith("en") -> "Current app"
      locale.startsWith("ja") -> "現在のアプリ"
      locale == "zh-TW" -> "目前宿主應用"
      else -> "当前宿主应用"
    }
  }
}

private fun localizedRootMode(mode: String, locale: String): String {
  return when (mode) {
    "auto" -> when {
      locale.startsWith("en") -> "Auto root-enhanced"
      locale.startsWith("ja") -> "自動 root 拡張"
      locale == "zh-TW" -> "自動 root 增強"
      else -> "自动 root 增强"
    }
    else -> when {
      locale.startsWith("en") -> "Off"
      locale.startsWith("ja") -> "オフ"
      locale == "zh-TW" -> "關閉"
      else -> "关闭"
    }
  }
}

private fun localizedCaptureLogcatLabel(locale: String): String {
  return if (locale.startsWith("ja")) "logcat" else "logcat"
}

private fun localizedCaptureStdoutLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "stdout / stderr"
    locale.startsWith("ja") -> "stdout / stderr"
    locale == "zh-TW" -> "stdout / stderr"
    else -> "stdout / stderr"
  }
}

private fun localizedCaptureExceptionLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "uncaught exceptions"
    locale.startsWith("ja") -> "未捕捉例外"
    locale == "zh-TW" -> "未捕捉例外"
    else -> "未捕获异常"
  }
}

private fun localizedCaptureDisabledLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Disabled"
    locale.startsWith("ja") -> "無効"
    locale == "zh-TW" -> "未啟用"
    else -> "未启用"
  }
}

private fun localizedCrashRecordsTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Crash Records"
    locale.startsWith("ja") -> "クラッシュ記録"
    locale == "zh-TW" -> "崩潰記錄"
    else -> "崩溃记录"
  }
}

private fun localizedCrashRecordsSummaryText(locale: String, count: Int): String {
  return when {
    locale.startsWith("en") -> "Recent native uncaught crash records: $count"
    locale.startsWith("ja") -> "最近のネイティブ未捕捉クラッシュ記録: $count"
    locale == "zh-TW" -> "最近的原生未捕捉崩潰記錄：$count"
    else -> "最近的原生未捕获崩溃记录：$count"
  }
}

private fun localizedNoCrashRecordsText(locale: String): String {
  return when {
    locale.startsWith("en") -> "No native crash records yet."
    locale.startsWith("ja") -> "ネイティブクラッシュ記録はまだありません。"
    locale == "zh-TW" -> "暫無原生崩潰記錄。"
    else -> "暂无原生崩溃记录。"
  }
}

private fun localizedCrashRecordTitle(locale: String, index: Int): String {
  return when {
    locale.startsWith("en") -> "Crash #$index"
    locale.startsWith("ja") -> "クラッシュ #$index"
    locale == "zh-TW" -> "崩潰 #$index"
    else -> "崩溃 #$index"
  }
}

private fun localizedCrashTimeLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Time"
    locale.startsWith("ja") -> "時間"
    locale == "zh-TW" -> "時間"
    else -> "时间"
  }
}

private fun localizedCrashThreadLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Thread"
    locale.startsWith("ja") -> "スレッド"
    locale == "zh-TW" -> "執行緒"
    else -> "线程"
  }
}

private fun localizedCrashExceptionLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Exception"
    locale.startsWith("ja") -> "例外"
    locale == "zh-TW" -> "異常"
    else -> "异常"
  }
}

private fun localizedCrashMessageLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Message"
    locale.startsWith("ja") -> "訊息"
    locale == "zh-TW" -> "訊息"
    else -> "消息"
  }
}

private fun localizedCrashStackLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Stack trace"
    locale.startsWith("ja") -> "スタックトレース"
    locale == "zh-TW" -> "堆疊追蹤"
    else -> "堆栈追踪"
  }
}

private fun localizedFatalErrorRecordsTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Fatal Error Records"
    locale.startsWith("ja") -> "致命エラー記録"
    locale == "zh-TW" -> "致命錯誤記錄"
    else -> "致命错误记录"
  }
}

private fun localizedFatalErrorRecordsSummaryText(locale: String, count: Int): String {
  return when {
    locale.startsWith("en") -> "Recent JS / runtime fatal error records: $count"
    locale.startsWith("ja") -> "最近の JS / ランタイム致命エラー記録: $count"
    locale == "zh-TW" -> "最近的 JS / 執行期致命錯誤記錄：$count"
    else -> "最近的 JS / 运行时致命错误记录：$count"
  }
}

private fun localizedNoFatalErrorRecordsText(locale: String): String {
  return when {
    locale.startsWith("en") -> "No JS / runtime fatal error records yet."
    locale.startsWith("ja") -> "JS / ランタイム致命エラー記録はまだありません。"
    locale == "zh-TW" -> "暫無 JS / 執行期致命錯誤記錄。"
    else -> "暂无 JS / 运行时致命错误记录。"
  }
}

private fun localizedFatalErrorTitle(locale: String, index: Int): String {
  return when {
    locale.startsWith("en") -> "Fatal Error #$index"
    locale.startsWith("ja") -> "致命エラー #$index"
    locale == "zh-TW" -> "致命錯誤 #$index"
    else -> "致命错误 #$index"
  }
}

private fun localizedFatalErrorSourceLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Source"
    locale.startsWith("ja") -> "來源"
    locale == "zh-TW" -> "來源"
    else -> "来源"
  }
}

private fun localizedFatalErrorMessageLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Message"
    locale.startsWith("ja") -> "訊息"
    locale == "zh-TW" -> "訊息"
    else -> "消息"
  }
}

private fun localizedCapabilityJsLogs(locale: String): String {
  return when {
    locale.startsWith("en") -> "JS console logs, React error boundaries, global errors, and unhandled promise rejections."
    locale.startsWith("ja") -> "JS の console ログ、React エラーバウンダリ、グローバルエラー、未処理 Promise rejection。"
    locale == "zh-TW" -> "JS console 日誌、React 錯誤邊界、全域錯誤與未處理 Promise rejection。"
    else -> "JS console 日志、React 错误边界、全局错误与未处理 Promise rejection。"
  }
}

private fun localizedCapabilityJsErrors(locale: String): String {
  return when {
    locale.startsWith("en") -> "Structured log filtering, search, sorting, copy, and snapshot export inside the panel."
    locale.startsWith("ja") -> "面板內では構造化フィルタ、検索、並び替え、コピー、スナップショット出力ができます。"
    locale == "zh-TW" -> "面板內支援結構化篩選、搜尋、排序、複製與快照匯出。"
    else -> "面板内支持结构化筛选、搜索、排序、复制与快照导出。"
  }
}

private fun localizedCapabilityNativeLogs(runtimeInfo: DebugRuntimeInfo, locale: String): String {
  return when (runtimeInfo.activeLogcatMode) {
    "root-device" -> when {
      locale.startsWith("en") -> "Android native logs from stdout, stderr, uncaught exceptions, and device-wide logcat through root."
      locale.startsWith("ja") -> "Android ネイティブログ: stdout、stderr、未捕捉例外、および root 経由の端末全体 logcat。"
      locale == "zh-TW" -> "Android 原生日誌：stdout、stderr、未捕捉例外，以及透過 root 的整機 logcat。"
      else -> "Android 原生日志：stdout、stderr、未捕获异常，以及通过 root 的整机 logcat。"
    }
    else -> when {
      locale.startsWith("en") -> "Android native logs from the current app process: logcat, stdout, stderr, and uncaught exceptions."
      locale.startsWith("ja") -> "Android ネイティブログ: 現在のアプリプロセスの logcat、stdout、stderr、未捕捉例外。"
      locale == "zh-TW" -> "Android 原生日誌：目前宿主應用程序的 logcat、stdout、stderr、未捕捉例外。"
      else -> "Android 原生日志：当前宿主应用进程的 logcat、stdout、stderr、未捕获异常。"
    }
  }
}

private fun localizedCapabilityNativeDisabled(locale: String): String {
  return when {
    locale.startsWith("en") -> "Android native log capture is currently disabled."
    locale.startsWith("ja") -> "Android ネイティブログ採集は現在無効です。"
    locale == "zh-TW" -> "Android 原生日誌採集目前未啟用。"
    else -> "Android 原生日志采集当前未启用。"
  }
}

private fun localizedCapabilityNetworkEnabled(locale: String): String {
  return when {
    locale.startsWith("en") -> "JS XHR / fetch / WebSocket events from React Native."
    locale.startsWith("ja") -> "React Native の JS XHR / fetch / WebSocket イベント。"
    locale == "zh-TW" -> "React Native 的 JS XHR / fetch / WebSocket 事件。"
    else -> "React Native 的 JS XHR / fetch / WebSocket 事件。"
  }
}

private fun localizedCapabilityNativeNetworkEnabled(locale: String): String {
  return when {
    locale.startsWith("en") -> "Android native network capture is enabled for instrumented or explicitly integrated OkHttp paths."
    locale.startsWith("ja") -> "計装済みまたは明示的に統合した OkHttp 経路の Android ネイティブ通信採集が有効です。"
    locale == "zh-TW" -> "已啟用已掛接或顯式接入 OkHttp 路徑上的 Android 原生網路採集。"
    else -> "已启用已挂接或显式接入 OkHttp 路径上的 Android 原生网络采集。"
  }
}

private fun localizedCapabilityNativeNetworkDisabled(locale: String): String {
  return when {
    locale.startsWith("en") -> "Native network capture is off until explicitly enabled in App Info."
    locale.startsWith("ja") -> "App Info で明示的に有効化するまで、ネイティブ通信採集はオフです。"
    locale == "zh-TW" -> "原生網路採集保持關閉，直到在 App Info 中明確啟用。"
    else -> "原生网络采集保持关闭，直到在 App Info 中显式启用。"
  }
}

private fun localizedCapabilityNetworkDisabled(locale: String): String {
  return when {
    locale.startsWith("en") -> "The network tab is disabled in the current configuration."
    locale.startsWith("ja") -> "現在の設定では通信タブが無効です。"
    locale == "zh-TW" -> "目前設定已關閉網路面板。"
    else -> "当前配置已关闭网络面板。"
  }
}

private fun localizedCapabilityRootEnhanced(locale: String): String {
  return when {
    locale.startsWith("en") -> "Root-enhanced device-wide logcat is available on this host."
    locale.startsWith("ja") -> "この宿主環境では root 強化の端末全体 logcat が利用可能です。"
    locale == "zh-TW" -> "此宿主環境可使用 root 增強的整機 logcat。"
    else -> "此宿主环境可使用 root 增强的整机 logcat。"
  }
}

private fun localizedLimitationStartupTiming(locale: String): String {
  return when {
    locale.startsWith("en") -> "Logs emitted before the debugger hooks started are not fully replayed, except for the persisted uncaught crash report."
    locale.startsWith("ja") -> "デバッガーフック起動前のログは、保存済みの未捕捉クラッシュレポートを除き完全には再生されません。"
    locale == "zh-TW" -> "除已持久化的未捕捉崩潰報告外，調試器掛鉤啟動前輸出的日誌不會被完整回放。"
    else -> "除已持久化的未捕获崩溃报告外，调试器挂钩启动前输出的日志不会被完整回放。"
  }
}

private fun localizedLimitationStdoutTiming(locale: String): String {
  return when {
    locale.startsWith("en") -> "stdout and stderr are captured only after the current process installs the redirection hook."
    locale.startsWith("ja") -> "stdout / stderr は、現在のプロセスにリダイレクトフックが入った後の内容のみ採集されます。"
    locale == "zh-TW" -> "stdout / stderr 僅能採集目前進程安裝重定向掛鉤之後輸出的內容。"
    else -> "stdout / stderr 只能采集当前进程安装重定向挂钩之后输出的内容。"
  }
}

private fun localizedLimitationNonRootScope(locale: String): String {
  return when {
    locale.startsWith("en") -> "Without active root device-wide capture, this panel does not guarantee logs from other apps, system_server, kernel, or radio buffers."
    locale.startsWith("ja") -> "root による端末全体採集が有効でない場合、他アプリ、system_server、kernel、radio のログは保証されません。"
    locale == "zh-TW" -> "若未啟用 root 的整機採集，則無法保證看到其他應用、system_server、kernel 或 radio 緩衝區日誌。"
    else -> "若未启用 root 的整机采集，则无法保证看到其他应用、system_server、kernel 或 radio 缓冲区日志。"
  }
}

private fun localizedLimitationRootNotEnabled(locale: String): String {
  return when {
    locale.startsWith("en") -> "Root-enhanced capture is not enabled in the current configuration, even if the host may support root."
    locale.startsWith("ja") -> "ホストが root 対応でも、現在の設定では root 強化採集は有効化されていません。"
    locale == "zh-TW" -> "即使宿主裝置可能支援 root，目前設定也未啟用 root 增強採集。"
    else -> "即使宿主设备可能支持 root，当前配置也未启用 root 增强采集。"
  }
}

private fun localizedLimitationAndroidNativeNetwork(locale: String): String {
  return when {
    locale.startsWith("en") -> "Android captures native HTTP traffic on instrumented or explicitly integrated OkHttp paths. Traffic outside OkHttp, plus full native WebSocket frame lifecycle, is still not automatically covered."
    locale.startsWith("ja") -> "Android は計装済みまたは明示的に統合した OkHttp 経路のネイティブ HTTP 通信を採集できます。OkHttp 外の通信と、ネイティブ WebSocket フレームの完全なライフサイクルはまだ自動採集できません。"
    locale == "zh-TW" -> "Android 現已可採集已掛接或顯式接入 OkHttp 路徑上的原生 HTTP 通信；但 OkHttp 之外的流量，以及原生 WebSocket frame 的完整生命週期，仍未自動覆蓋。"
    else -> "Android 现已可采集已挂接或显式接入 OkHttp 路径上的原生 HTTP 通信；但 OkHttp 之外的流量，以及原生 WebSocket frame 的完整生命周期，仍未自动覆盖。"
  }
}

private fun localizedLimitationNativeNetworkDisabled(locale: String): String {
  return when {
    locale.startsWith("en") -> "Native network capture is disabled by default to avoid OkHttp instrumentation overhead on normal sessions."
    locale.startsWith("ja") -> "通常セッションでの OkHttp 計装コストを避けるため、ネイティブ通信採集はデフォルトで無効です。"
    locale == "zh-TW" -> "為避免一般會話承擔 OkHttp 掛接開銷，原生網路採集預設關閉。"
    else -> "为避免普通会话承担 OkHttp 挂接开销，原生网络采集默认关闭。"
  }
}

private fun localizedNetworkEventsTitle(): String {
  return "Events"
}

private fun localizedNoNetworkEvents(): String {
  return "No event timeline"
}

private fun localizedLimitationNetworkTabDisabled(locale: String): String {
  return when {
    locale.startsWith("en") -> "The network tab is disabled, so no network events are collected for display."
    locale.startsWith("ja") -> "通信タブが無効のため、表示用の通信イベントは採集されません。"
    locale == "zh-TW" -> "網路面板已關閉，因此不會採集可供展示的網路事件。"
    else -> "网络面板已关闭，因此不会采集可供展示的网络事件。"
  }
}

private fun headerText(headers: Map<String, String>): String {
  if (headers.isEmpty()) {
    return "-"
  }
  return buildString(headers.size * 32) {
    headers.entries.forEachIndexed { index, entry ->
      if (index > 0) {
        append('\n')
      }
      append(entry.key)
      append(": ")
      append(entry.value)
    }
  }
}

private fun formattedMessagesText(raw: String?, fallback: String): String {
  return raw?.trim()?.takeIf { it.isNotEmpty() } ?: fallback
}

private fun formattedStructuredContent(raw: String?, fallback: String): String {
  val source = raw?.takeIf { it.isNotBlank() } ?: return fallback
  return prettyJsonOrOriginal(source)
}

private fun formattedWebSocketMessagesText(raw: String?, fallback: String): String {
  val source = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return fallback
  val rendered = StringBuilder(source.length + 32)
  var currentPrefix: String? = null
  val currentPayload = StringBuilder()

  fun flushCurrentBlock() {
    if (currentPrefix == null && currentPayload.isEmpty()) {
      return
    }

    val payload = currentPayload.toString().trimEnd()
    val renderedBlock = currentPrefix?.let { prefix ->
      formatDirectionalMessageBlock(prefix, payload)
    } ?: prettyJsonOrOriginal(payload)

    if (renderedBlock.isNotBlank()) {
      if (rendered.isNotEmpty()) {
        rendered.append('\n')
      }
      rendered.append(renderedBlock)
    }

    currentPrefix = null
    currentPayload.setLength(0)
  }

  source.lineSequence().forEach { line ->
    val prefix = directionalMessagePrefix(line)
    if (prefix != null) {
      flushCurrentBlock()
      currentPrefix = prefix
      currentPayload.append(extractDirectionalMessagePayload(line, prefix))
    } else {
      if (currentPayload.isNotEmpty()) {
        currentPayload.append('\n')
      }
      currentPayload.append(line)
    }
  }

  flushCurrentBlock()
  return rendered.toString()
}

private fun formatDirectionalMessageBlock(prefix: String, payload: String): String {
  val formattedPayload = prettyJsonOrOriginal(payload)
  if (formattedPayload.isBlank()) {
    return prefix
  }

  val continuationIndent = " ".repeat(prefix.length + 1)
  return buildString {
    append(prefix)
    append(' ')
    var startIndex = 0
    var firstLine = true
    while (startIndex <= formattedPayload.length) {
      val lineEnd = formattedPayload.indexOf('\n', startIndex).takeIf { it >= 0 } ?: formattedPayload.length
      if (!firstLine) {
        append('\n')
        append(continuationIndent)
      }
      append(formattedPayload, startIndex, lineEnd)
      if (lineEnd == formattedPayload.length) {
        break
      }
      startIndex = lineEnd + 1
      firstLine = false
    }
  }
}

private fun directionalMessagePrefix(line: String): String? {
  return when {
    line.startsWith(">> ") || line == ">>" -> ">>"
    line.startsWith("<< ") || line == "<<" -> "<<"
    else -> null
  }
}

private fun extractDirectionalMessagePayload(line: String, prefix: String): String {
  return line.removePrefix("$prefix ").removePrefix(prefix)
}

private fun prettyJsonOrOriginal(raw: String): String {
  val trimmed = raw.trim()
  if (trimmed.isEmpty()) {
    return raw.trimEnd()
  }
  return prettyJsonOrNull(trimmed) ?: raw.trimEnd()
}

private fun prettyJsonOrNull(raw: String): String? {
  if (!hasJsonContainerBounds(raw) || !isValidJson(raw)) {
    return null
  }
  return formatJsonWhitespaceOnly(raw)
}

private fun hasJsonContainerBounds(raw: String): Boolean {
  return (raw.startsWith("{") && raw.endsWith("}")) ||
    (raw.startsWith("[") && raw.endsWith("]"))
}

private fun isValidJson(raw: String): Boolean {
  return runCatching {
    JsonReader(StringReader(raw)).use { reader ->
      reader.setLenient(false)
      reader.skipValue()
      reader.peek() == JsonToken.END_DOCUMENT
    }
  }.getOrDefault(false)
}

private fun formatJsonWhitespaceOnly(raw: String): String {
  val result = StringBuilder(raw.length + 32)
  var indentLevel = 0
  var index = 0
  var insideString = false
  var escaping = false

  fun appendIndent() {
    repeat(indentLevel * 2) {
      result.append(' ')
    }
  }

  fun nextNonWhitespaceChar(startIndex: Int): Char? {
    var cursor = startIndex
    while (cursor < raw.length) {
      val candidate = raw[cursor]
      if (!candidate.isJsonWhitespace()) {
        return candidate
      }
      cursor += 1
    }
    return null
  }

  while (index < raw.length) {
    val char = raw[index]

    if (insideString) {
      result.append(char)
      when {
        escaping -> escaping = false
        char == '\\' -> escaping = true
        char == '"' -> insideString = false
      }
      index += 1
      continue
    }

    when {
      char.isJsonWhitespace() -> Unit
      char == '"' -> {
        insideString = true
        result.append(char)
      }
      char == '{' || char == '[' -> {
        result.append(char)
        indentLevel += 1
        val closingChar = if (char == '{') '}' else ']'
        if (nextNonWhitespaceChar(index + 1) != closingChar) {
          result.append('\n')
          appendIndent()
        }
      }
      char == '}' || char == ']' -> {
        indentLevel = (indentLevel - 1).coerceAtLeast(0)
        val previousChar = result.lastOrNull()
        if (previousChar != '{' && previousChar != '[') {
          result.append('\n')
          appendIndent()
        }
        result.append(char)
      }
      char == ',' -> {
        result.append(char)
        result.append('\n')
        appendIndent()
      }
      char == ':' -> result.append(": ")
      else -> result.append(char)
    }

    index += 1
  }

  return result.toString()
}

private fun Char.isJsonWhitespace(): Boolean {
  return this == ' ' || this == '\n' || this == '\r' || this == '\t'
}

private fun closeRequestSummary(entry: DebugNetworkEntry): String {
  val code = entry.requestedCloseCode?.toString() ?: "-"
  val reason = entry.requestedCloseReason?.ifBlank { "-" } ?: "-"
  return "code: $code\nreason: $reason"
}

private fun closeResultSummary(entry: DebugNetworkEntry): String {
  val code = entry.closeCode?.toString() ?: "-"
  val clean = entry.cleanClose?.toString() ?: "-"
  val reason = entry.closeReason?.ifBlank { "-" } ?: "-"
  return "code: $code\nclean: $clean\nreason: $reason"
}

private fun countMessages(messages: String?, directionPrefix: String): Int {
  return messages
    ?.lineSequence()
    ?.count { it.trimStart().startsWith(directionPrefix) }
    ?: 0
}

private fun buildNetworkDurationSummary(
  entry: DebugNetworkEntry,
  durationLabel: String
): String {
  val durationText = "$durationLabel ${entry.durationMs?.let { "${it}ms" } ?: "-"}"
  if (!isWebSocketKind(entry.kind)) {
    return durationText
  }
  val incoming = entry.messageCountIn ?: countMessages(entry.messages, "<<")
  val outgoing = entry.messageCountOut ?: countMessages(entry.messages, ">>")
  return "$durationText · IN $incoming / OUT $outgoing"
}

private fun formatNetworkSummaryText(
  entry: DebugNetworkEntry,
  context: Context
): String {
  val parts = mutableListOf(
    "${entry.method.uppercase(Locale.ROOT)} ${entry.url}",
    "origin=${localizedOriginTitle(entry.origin)}",
    "type=${localizedNetworkKindTitle(entry.kind)}",
    "state=${entry.state}",
    "status=${entry.status?.let { httpStatusDisplayText(entry) } ?: networkKindBadgeTitle(entry.kind)}",
    "duration=${entry.durationMs?.let { "${it}ms" } ?: "-"}"
  )
  if (isWebSocketKind(entry.kind)) {
    parts += "bytes=in ${formatByteCount(context, entry.bytesIn)} / out ${formatByteCount(context, entry.bytesOut)}"
  }
  if (!entry.error.isNullOrBlank()) {
    parts += "error=${entry.error}"
  }
  return parts.joinToString(" | ")
}

private fun formatLogCopyText(entry: DebugLogEntry): String {
  val metadataLines = mutableListOf("timestamp: ${entry.fullTimestamp.ifBlank { entry.timestamp }}")
  metadataLines += "origin: ${entry.origin}"
  entry.context?.takeIf { it.isNotBlank() }?.let { metadataLines += "context: $it" }
  entry.details?.takeIf { it.isNotBlank() }?.let { metadataLines += it }
  return metadataLines.joinToString("\n") + "\n\n" + entry.message
}

private fun formatByteCount(context: Context, count: Int?): String {
  return if (count == null) {
    "-"
  } else {
    Formatter.formatShortFileSize(context, count.coerceAtLeast(0).toLong())
  }
}

private fun Set<String>.toggle(value: String): Set<String> {
  val next = toMutableSet()
  if (value in next) {
    next.remove(value)
  } else {
    next.add(value)
  }
  return next
}

private class ReversedListView<T>(
  private val source: List<T>
) : AbstractList<T>() {
  override val size: Int
    get() = source.size

  override fun get(index: Int): T {
    return source[source.lastIndex - index]
  }
}

private class SearchTextCache<T>(
  capacity: Int,
  private val keySelector: (T) -> String,
  private val searchTextBuilder: (T) -> String
) {
  private data class CachedSearchText<T>(
    val entry: T,
    val text: String
  )

  private val texts = object : LinkedHashMap<String, CachedSearchText<T>>(capacity, 0.75f, true) {
    override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CachedSearchText<T>>?): Boolean {
      return size > capacity
    }
  }

  fun matches(entry: T, query: String): Boolean {
    val key = keySelector(entry)
    val cached = texts[key]
    val searchText =
      if (cached?.entry === entry) {
        cached.text
      } else {
        searchTextBuilder(entry).also { built ->
          texts[key] = CachedSearchText(entry = entry, text = built)
        }
      }
    return searchText.contains(query, ignoreCase = true)
  }
}

private fun buildLogSearchText(entry: DebugLogEntry): String {
  return buildSearchText(
    entry.message,
    entry.type,
    entry.origin,
    entry.context,
    entry.details
  )
}

private fun buildNetworkSearchText(
  entry: DebugNetworkEntry,
  localizedKindTitle: String
): String {
  return buildSearchText(
    entry.url,
    entry.origin,
    entry.kind,
    localizedKindTitle,
    entry.method,
    entry.state,
    entry.protocol,
    entry.requestedProtocols,
    entry.closeReason,
    entry.error,
    entry.events,
    entry.messages
  )
}

private fun buildSearchText(vararg parts: String?): String {
  val result = StringBuilder()
  parts.forEach { part ->
    if (!part.isNullOrEmpty()) {
      if (result.isNotEmpty()) {
        // Use a sentinel separator so a query cannot accidentally match across field boundaries.
        result.append('\u0000')
      }
      result.append(part)
    }
  }
  return result.toString()
}

private fun copyToClipboard(text: String, successMessage: String, context: Context?) {
  val actualContext = context ?: return
  val clipboard = actualContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
  clipboard.setPrimaryClip(ClipData.newPlainText("expo-inapp-debugger", text))
  android.widget.Toast.makeText(actualContext, successMessage, android.widget.Toast.LENGTH_SHORT).show()
}
