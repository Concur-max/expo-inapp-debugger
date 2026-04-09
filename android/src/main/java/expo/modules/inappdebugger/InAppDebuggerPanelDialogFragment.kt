package expo.modules.inappdebugger

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.text.format.Formatter
import android.view.View
import android.view.ViewGroup
import androidx.core.view.WindowInsetsControllerCompat
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentManager
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

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
            DebugPanel(onDismiss = ::closePanel)
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
}

const val PANEL_BACK_STACK_NAME = "expo.modules.inappdebugger.panel.backstack"
private const val ANDROID_PANEL_TITLE = "Debugging panel"
private const val ANDROID_SEARCH_PLACEHOLDER = "Please enter"

private enum class DebugTab {
  Logs,
  Network,
  AppInfo
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
  val monospace: Boolean = false
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

  fun hasActiveLogFilters(levels: Set<String>, origins: Set<String>): Boolean {
    return origins.size < allOrigins.size || levels.size < allLevels.size
  }

  fun hasActiveNetworkFilters(origins: Set<String>, kinds: Set<String>): Boolean {
    return origins.size < allOrigins.size || kinds.size < allNetworkKinds.size
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DebugPanel(onDismiss: () -> Unit) {
  val chromeState by InAppDebuggerStore.chromeState.collectAsStateWithLifecycle()
  val locale = chromeState.config.locale
  val strings = chromeState.config.strings
  var activeTab by rememberSaveable { mutableStateOf(DebugTab.Logs) }
  var selectedNetworkId by rememberSaveable { mutableStateOf<String?>(null) }

  DisposableEffect(Unit) {
    InAppDebuggerStore.setPanelVisible(true)
    onDispose {
      InAppDebuggerStore.setActiveFeed(DebugPanelFeed.None)
      InAppDebuggerStore.setPanelVisible(false)
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
  }

  LaunchedEffect(chromeState.config.enableNetworkTab) {
    if (!chromeState.config.enableNetworkTab && activeTab == DebugTab.Network) {
      activeTab = DebugTab.Logs
    }
  }

  if (selectedNetworkId != null) {
    NetworkDetailScreen(
      entryId = selectedNetworkId.orEmpty(),
      strings = strings,
      locale = locale,
      onBack = { selectedNetworkId = null },
      onClose = onDismiss,
      onMissing = { selectedNetworkId = null }
    )
    return
  }

  Scaffold(
    topBar = {
      TopAppBar(
        title = { Text(ANDROID_PANEL_TITLE) },
        colors = TopAppBarDefaults.topAppBarColors(
          containerColor = PanelColors.Background,
          titleContentColor = PanelColors.Text,
          actionIconContentColor = PanelColors.Primary
        ),
        actions = {
          IconButton(onClick = onDismiss) {
            Icon(Icons.Outlined.Close, contentDescription = strings["close"] ?: "关闭")
          }
        }
      )
    },
    containerColor = PanelColors.Background
  ) { innerPadding ->
    Column(
      modifier = Modifier
        .fillMaxSize()
        .padding(innerPadding)
        .background(PanelColors.Background)
    ) {
      TabRow(
        selectedTabIndex = activeTab.ordinal,
        containerColor = PanelColors.Background,
        contentColor = PanelColors.Primary,
        divider = {
          HorizontalDivider(color = PanelColors.Border)
        }
      ) {
        Tab(
          selected = activeTab == DebugTab.Logs,
          onClick = {
            selectedNetworkId = null
            activeTab = DebugTab.Logs
          },
          text = { Text("log") }
        )
        Tab(
          selected = activeTab == DebugTab.Network,
          onClick = { activeTab = DebugTab.Network },
          enabled = chromeState.config.enableNetworkTab,
          text = { Text("network") }
        )
        Tab(
          selected = activeTab == DebugTab.AppInfo,
          onClick = {
            InAppDebuggerNativeLogCapture.refreshRuntimeInfo(forceRootProbe = true)
            activeTab = DebugTab.AppInfo
          },
          text = { Text("app Info") }
        )
      }

      when (activeTab) {
        DebugTab.Logs -> LogsTab(config = chromeState.config, locale = locale)
        DebugTab.Network -> NetworkTab(
          config = chromeState.config,
          locale = locale,
          onSelectNetwork = { selectedNetworkId = it }
        )
        DebugTab.AppInfo -> AppInfoTab(
          config = chromeState.config,
          runtimeInfo = chromeState.runtimeInfo,
          locale = locale
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
  var rootTogglePending by remember { mutableStateOf(false) }
  val rootEnhancedEnabled = remember(config.androidNativeLogs.logcatScope, config.androidNativeLogs.rootMode) {
    isRootEnhancedRequested(config)
  }

  LaunchedEffect(Unit) {
    InAppDebuggerNativeLogCapture.refreshRuntimeInfo(forceRootProbe = true)
  }

  val sections = remember(runtimeInfo, config, errorsWindowState.version, locale) {
    buildDebuggerInfoSections(
      runtimeInfo = runtimeInfo,
      config = config,
      appErrors = errorsWindowState.items,
      locale = locale
    )
  }

  LazyColumn(
    modifier = Modifier.fillMaxSize(),
    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
    verticalArrangement = Arrangement.spacedBy(10.dp)
  ) {
    item("app_info_root_control") {
      RootEnhancedControlCard(
        checked = rootEnhancedEnabled,
        enabled = runtimeInfo.rootStatus != "checking" && !rootTogglePending,
        pending = rootTogglePending,
        runtimeInfo = runtimeInfo,
        locale = locale,
        onCheckedChange = { enabled ->
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
      )
    }
    items(
      items = sections,
      key = { it.title }
    ) { section ->
      DetailSection(
        title = section.title,
        content = section.content,
        monospace = section.monospace
      )
    }
    item("app_info_footer") {
      Spacer(modifier = Modifier.height(12.dp))
    }
  }
}

@Composable
private fun RootEnhancedControlCard(
  checked: Boolean,
  enabled: Boolean,
  pending: Boolean,
  runtimeInfo: DebugRuntimeInfo,
  locale: String,
  onCheckedChange: (Boolean) -> Unit
) {
  val tone = toneForRootEnhancedControl(runtimeInfo, checked, pending)

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
            text = localizedRootEnhancedControlSummary(runtimeInfo, checked, pending, locale),
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
        text = localizedRootEnhancedControlStatus(runtimeInfo, checked, pending, locale),
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
  config: DebugConfig,
  locale: String
) {
  val logsWindowState by InAppDebuggerStore.logsWindowState.collectAsStateWithLifecycle()
  val context = LocalContext.current
  val strings = config.strings
  var searchQuery by rememberSaveable { mutableStateOf("") }
  var sortOrder by rememberSaveable { mutableStateOf(SortOrder.Desc) }
  var selectedLevels by remember { mutableStateOf(PanelPreferences.loadLogLevels(context)) }
  var selectedOrigins by remember { mutableStateOf(PanelPreferences.loadLogOrigins(context)) }
  val hasActiveFilters = remember(selectedLevels, selectedOrigins) {
    PanelPreferences.hasActiveLogFilters(selectedLevels, selectedOrigins)
  }

  val visibleLogs =
    remember(logsWindowState.version, searchQuery, sortOrder, selectedLevels, selectedOrigins) {
    filterLogs(
      source = logsWindowState.items,
      query = searchQuery,
      sortOrder = sortOrder,
      selectedLevels = selectedLevels,
      selectedOrigins = selectedOrigins
    )
  }

  Column(modifier = Modifier.fillMaxSize()) {
    SearchAndActionRow(
      query = searchQuery,
      placeholder = localizedAndroidSearchPlaceholder(),
      filterTitle = strings["filter"] ?: "筛选",
      clearLabel = strings["clear"] ?: "清空",
      sortLabel = localizedSortTitle(locale, sortOrder == SortOrder.Asc),
      sortOrder = sortOrder,
      hasActiveFilters = hasActiveFilters,
      filterSections = listOf(
        FilterMenuSection(
          title = localizedOriginTitleLabel(locale),
          items = listOf(
            FilterMenuItem(
              label = strings["jsLogOrigin"] ?: "JS",
              selected = "js" in selectedOrigins,
              onToggle = {
                selectedOrigins = selectedOrigins.toggle("js")
                PanelPreferences.saveLogOrigins(context, selectedOrigins)
              }
            ),
            FilterMenuItem(
              label = strings["nativeLogOrigin"] ?: "native",
              selected = "native" in selectedOrigins,
              onToggle = {
                selectedOrigins = selectedOrigins.toggle("native")
                PanelPreferences.saveLogOrigins(context, selectedOrigins)
              }
            )
          )
        ),
        FilterMenuSection(
          title = localizedLevelTitle(locale),
          items = listOf("log", "info", "warn", "error", "debug").map { level ->
            FilterMenuItem(
              label = level.uppercase(Locale.ROOT),
              selected = level in selectedLevels,
              onToggle = {
                selectedLevels = selectedLevels.toggle(level)
                PanelPreferences.saveLogLevels(context, selectedLevels)
              }
            )
          }
        )
      ),
      onQueryChange = { searchQuery = it },
      onToggleSort = {
        sortOrder = if (sortOrder == SortOrder.Asc) SortOrder.Desc else SortOrder.Asc
      },
      onClear = { InAppDebuggerStore.clear("logs") }
    )

    if (visibleLogs.isEmpty()) {
      val title = if (searchQuery.isNotBlank() || selectedLevels.isEmpty()) {
        strings["noSearchResult"] ?: "未找到匹配的日志"
      } else {
        strings["noLogs"] ?: "暂无日志"
      }
      val detail = when {
        selectedOrigins.isEmpty() -> localizedNoLogOriginHint(locale)
        selectedLevels.isEmpty() -> localizedNoLevelHint(locale)
        else -> localizedEmptyHint(locale)
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
          LogCard(log = log, strings = strings, locale = locale)
        }
        item("logs_footer") {
          Spacer(modifier = Modifier.height(12.dp))
        }
      }
    }
  }
}

@Composable
private fun NetworkTab(
  config: DebugConfig,
  locale: String,
  onSelectNetwork: (String) -> Unit
) {
  val networkWindowState by InAppDebuggerStore.networkWindowState.collectAsStateWithLifecycle()
  val context = LocalContext.current
  val strings = config.strings
  var searchQuery by rememberSaveable { mutableStateOf("") }
  var sortOrder by rememberSaveable { mutableStateOf(SortOrder.Desc) }
  var selectedOrigins by remember { mutableStateOf(PanelPreferences.loadNetworkOrigins(context)) }
  var selectedKinds by remember { mutableStateOf(PanelPreferences.loadNetworkKinds(context)) }
  val hasActiveFilters = remember(selectedOrigins, selectedKinds) {
    PanelPreferences.hasActiveNetworkFilters(selectedOrigins, selectedKinds)
  }

  val visibleEntries = remember(
    networkWindowState.version,
    searchQuery,
    sortOrder,
    selectedOrigins,
    selectedKinds,
    locale
  ) {
    filterNetwork(
      source = networkWindowState.items,
      query = searchQuery,
      sortOrder = sortOrder,
      selectedOrigins = selectedOrigins,
      selectedKinds = selectedKinds,
      locale = locale
    )
  }

  Column(modifier = Modifier.fillMaxSize()) {
    SearchAndActionRow(
      query = searchQuery,
      placeholder = localizedAndroidSearchPlaceholder(),
      filterTitle = strings["filter"] ?: "筛选",
      clearLabel = strings["clear"] ?: "清空",
      sortLabel = localizedSortTitle(locale, sortOrder == SortOrder.Asc),
      sortOrder = sortOrder,
      hasActiveFilters = hasActiveFilters,
      filterSections = listOf(
        FilterMenuSection(
          title = localizedOriginTitleLabel(locale),
          items = listOf(
            FilterMenuItem(
              label = strings["jsLogOrigin"] ?: "JS",
              selected = "js" in selectedOrigins,
              onToggle = {
                selectedOrigins = selectedOrigins.toggle("js")
                PanelPreferences.saveNetworkOrigins(context, selectedOrigins)
              }
            ),
            FilterMenuItem(
              label = strings["nativeLogOrigin"] ?: "native",
              selected = "native" in selectedOrigins,
              onToggle = {
                selectedOrigins = selectedOrigins.toggle("native")
                PanelPreferences.saveNetworkOrigins(context, selectedOrigins)
              }
            )
          )
        ),
        FilterMenuSection(
          title = localizedNetworkTypeTitle(locale),
          items = NetworkKindFilter.entries.map { kind ->
            FilterMenuItem(
              label = localizedNetworkKindFilterTitle(kind, locale),
              selected = kind.rawValue in selectedKinds,
              onToggle = {
                selectedKinds = selectedKinds.toggle(kind.rawValue)
                PanelPreferences.saveNetworkKinds(context, selectedKinds)
              }
            )
          }
        )
      ),
      onQueryChange = { searchQuery = it },
      onToggleSort = {
        sortOrder = if (sortOrder == SortOrder.Asc) SortOrder.Desc else SortOrder.Asc
      },
      onClear = { InAppDebuggerStore.clear("network") }
    )

    if (visibleEntries.isEmpty()) {
      val title = if (
        searchQuery.isNotBlank() ||
          selectedOrigins.isEmpty() ||
          selectedKinds.isEmpty()
      ) {
        localizedNoNetworkResultTitle(locale)
      } else {
        strings["noNetworkRequests"] ?: "暂无网络请求"
      }
      val detail = when {
        selectedOrigins.isEmpty() && selectedKinds.isEmpty() -> localizedNoNetworkFilterHint(locale)
        selectedOrigins.isEmpty() -> localizedNoNetworkOriginHint(locale)
        selectedKinds.isEmpty() -> localizedNoNetworkKindHint(locale)
        else -> localizedEmptyHint(locale)
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
            strings = strings,
            onClick = { onSelectNetwork(entry.id) }
          )
        }
        item("network_footer") {
          Spacer(modifier = Modifier.height(12.dp))
        }
      }
    }
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NetworkDetailScreen(
  entryId: String,
  strings: Map<String, String>,
  locale: String,
  onBack: () -> Unit,
  onClose: () -> Unit,
  onMissing: () -> Unit
) {
  val networkWindowState by InAppDebuggerStore.networkWindowState.collectAsStateWithLifecycle()
  val context = LocalContext.current
  val entry = remember(entryId, networkWindowState.version) {
    networkWindowState.items.firstOrNull { it.id == entryId } ?: InAppDebuggerStore.networkEntry(entryId)
  }

  LaunchedEffect(entryId, networkWindowState.version) {
    if (entry == null) {
      onMissing()
    }
  }

  val resolvedEntry = entry ?: return
  val sections = remember(resolvedEntry, strings, locale) {
    if (isWebSocketKind(resolvedEntry.kind)) {
      buildWebSocketSections(resolvedEntry, strings, locale, context)
    } else {
      buildHttpSections(resolvedEntry, strings, locale, context)
    }
  }

  Scaffold(
    topBar = {
      TopAppBar(
        title = { Text(strings["requestDetails"] ?: "请求详情") },
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
            Icon(Icons.Outlined.Close, contentDescription = strings["close"] ?: "关闭")
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
      items(sections, key = { it.title }) { item ->
        DetailSection(title = item.title, content = item.content, monospace = item.monospace)
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
  filterTitle: String,
  clearLabel: String,
  sortLabel: String,
  sortOrder: SortOrder,
  hasActiveFilters: Boolean,
  filterSections: List<FilterMenuSection>,
  onQueryChange: (String) -> Unit,
  onToggleSort: () -> Unit,
  onClear: () -> Unit
) {
  var filterMenuExpanded by rememberSaveable { mutableStateOf(false) }
  val searchFieldTextStyle = MaterialTheme.typography.bodyLarge.copy(
    lineHeight = 20.sp,
    platformStyle = PlatformTextStyle(includeFontPadding = true)
  )
  Row(
    modifier = Modifier
      .fillMaxWidth()
      .padding(horizontal = 12.dp, vertical = 4.dp),
    verticalAlignment = Alignment.CenterVertically
  ) {
    OutlinedTextField(
      value = query,
      onValueChange = onQueryChange,
      modifier = Modifier
        .weight(1f)
        .heightIn(min = 56.dp),
      textStyle = searchFieldTextStyle,
      placeholder = {
        Text(
          text = placeholder,
          style = searchFieldTextStyle,
          maxLines = 1
        )
      },
      leadingIcon = {
        Icon(
          imageVector = Icons.Outlined.Search,
          contentDescription = null,
          tint = PanelColors.MutedText
        )
      },
      singleLine = true,
      keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None),
      shape = RoundedCornerShape(12.dp),
      colors = OutlinedTextFieldDefaults.colors(
        focusedContainerColor = PanelColors.Surface,
        unfocusedContainerColor = PanelColors.Surface,
        focusedBorderColor = PanelColors.Primary.copy(alpha = 0.45f),
        unfocusedBorderColor = PanelColors.Border,
        focusedTextColor = PanelColors.Text,
        unfocusedTextColor = PanelColors.Text,
        focusedPlaceholderColor = PanelColors.MutedText,
        unfocusedPlaceholderColor = PanelColors.MutedText,
        focusedLeadingIconColor = PanelColors.MutedText,
        unfocusedLeadingIconColor = PanelColors.MutedText,
        cursorColor = PanelColors.Primary
      )
    )
    Spacer(modifier = Modifier.width(6.dp))
    Box {
      PanelActionButton(
        imageVector = Icons.Outlined.FilterList,
        contentDescription = filterTitle,
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
      imageVector = if (sortOrder == SortOrder.Asc) Icons.Outlined.ArrowUpward else Icons.Outlined.ArrowDownward,
      contentDescription = sortLabel,
      onClick = onToggleSort
    )
    Spacer(modifier = Modifier.width(6.dp))
    PanelActionButton(
      imageVector = Icons.Outlined.DeleteOutline,
      contentDescription = clearLabel,
      onClick = onClear,
      tint = Color(0xFFB42318)
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
      modifier = Modifier.size(18.dp),
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
  log: DebugLogEntry,
  strings: Map<String, String>,
  locale: String
) {
  var expanded by remember(log.id) { mutableStateOf(false) }
  var detailsOverflow by remember(log.id) { mutableStateOf(false) }
  var messageOverflow by remember(log.id) { mutableStateOf(false) }
  val context = LocalContext.current
  val tone = toneForLogLevel(log.type)
  val details = listOfNotNull(
    log.context?.takeIf { it.isNotBlank() },
    log.details?.takeIf { it.isNotBlank() }
  ).joinToString("\n")
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
          .animateContentSize()
      ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
          PanelChip(
            text = localizedOriginTitle(log.origin, strings),
            background = if (isNativeOrigin(log.origin)) PanelColors.Primary else PanelColors.Control,
            foreground = if (isNativeOrigin(log.origin)) Color.White else PanelColors.MutedText
          )
          Spacer(modifier = Modifier.width(8.dp))
          PanelChip(
            text = log.type.uppercase(Locale.ROOT),
            background = tone.background,
            foreground = tone.foreground
          )
          Spacer(modifier = Modifier.weight(1f))
          Text(
            text = log.timestamp,
            style = MaterialTheme.typography.labelMedium,
            color = PanelColors.MutedText
          )
          IconButton(onClick = {
            copyToClipboard(
              text = formatLogCopyText(log),
              successMessage = strings["copySingleSuccess"] ?: "已复制到剪贴板",
              context = context
            )
          }) {
            Icon(
              imageVector = Icons.Outlined.ContentCopy,
              contentDescription = strings["copySingleA11y"] ?: "复制该条日志",
              tint = tone.foreground
            )
          }
        }

        SelectionContainer(
          modifier = Modifier
            .fillMaxWidth()
            .padding(top = if (details.isNotBlank()) 6.dp else 8.dp)
        ) {
          Column(modifier = Modifier.fillMaxWidth()) {
            if (details.isNotBlank()) {
              Text(
                text = details,
                style = MaterialTheme.typography.labelMedium,
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

        if (canExpand) {
          TextButton(onClick = { expanded = !expanded }) {
            Text(if (expanded) localizedCollapseLabel(locale) else localizedExpandLabel(locale))
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
  strings: Map<String, String>,
  onClick: () -> Unit
) {
  val tone = toneForNetwork(entry)
  val trailingBadgeText = networkTrailingBadgeTitle(entry)
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
            text = localizedOriginTitle(entry.origin, strings),
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
          Text(
            text = entry.state.uppercase(Locale.ROOT),
            style = MaterialTheme.typography.labelMedium,
            color = PanelColors.MutedText
          )
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
          text = buildNetworkDurationSummary(entry, strings),
          style = MaterialTheme.typography.labelMedium,
          color = PanelColors.MutedText,
          modifier = Modifier.padding(top = 6.dp)
        )
      }
    }
  }
}

@Composable
private fun DetailSection(
  title: String,
  content: String,
  monospace: Boolean = false
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
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = PanelColors.Text
      )
      Spacer(modifier = Modifier.height(6.dp))
      SelectionContainer(modifier = Modifier.fillMaxWidth()) {
        Text(
          text = content,
          color = PanelColors.Text,
          fontFamily = if (monospace) FontFamily.Monospace else FontFamily.Default,
          modifier = Modifier.fillMaxWidth()
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
    InAppDebuggerNativeLogCapture.refreshRuntimeInfo(forceRootProbe = enabled)
    return
  }

  val nextConfig = currentConfig.copy(androidNativeLogs = nextAndroidNativeLogs)
  InAppDebuggerStore.updateConfig(nextConfig)
  InAppDebuggerNativeLogCapture.applyConfig(context?.applicationContext, nextConfig)
  InAppDebuggerNativeNetworkCapture.applyConfig(context?.applicationContext, nextConfig)
  InAppDebuggerNativeLogCapture.refreshRuntimeInfo(forceRootProbe = enabled)
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
  foreground: Color
) {
  Surface(
    color = background,
    shape = RoundedCornerShape(8.dp)
  ) {
    Text(
      text = text,
      color = foreground,
      style = MaterialTheme.typography.labelMedium,
      modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
    )
  }
}

private fun filterLogs(
  source: List<DebugLogEntry>,
  query: String,
  sortOrder: SortOrder,
  selectedLevels: Set<String>,
  selectedOrigins: Set<String>
): List<DebugLogEntry> {
  val trimmedQuery = query.trim()
  return source
    .asSequence()
    .filter { entry -> entry.type in selectedLevels && entry.origin in selectedOrigins }
    .filter { entry ->
      trimmedQuery.isEmpty() ||
        entry.message.contains(trimmedQuery, ignoreCase = true) ||
        entry.type.contains(trimmedQuery, ignoreCase = true) ||
        entry.origin.contains(trimmedQuery, ignoreCase = true) ||
        (entry.context?.contains(trimmedQuery, ignoreCase = true) == true) ||
        (entry.details?.contains(trimmedQuery, ignoreCase = true) == true)
    }
    .sortedWith { lhs, rhs ->
      compareLogs(lhs, rhs, sortOrder)
    }
    .toList()
}

private fun filterNetwork(
  source: List<DebugNetworkEntry>,
  query: String,
  sortOrder: SortOrder,
  selectedOrigins: Set<String>,
  selectedKinds: Set<String>,
  locale: String
): List<DebugNetworkEntry> {
  val trimmedQuery = query.trim()
  return source
    .asSequence()
    .filter { entry ->
      entry.origin in selectedOrigins && normalizedNetworkKind(entry.kind).rawValue in selectedKinds
    }
    .filter { entry ->
      val kindTitle = localizedNetworkKindTitle(entry.kind, locale)
      trimmedQuery.isEmpty() ||
        entry.url.contains(trimmedQuery, ignoreCase = true) ||
        entry.origin.contains(trimmedQuery, ignoreCase = true) ||
        entry.kind.contains(trimmedQuery, ignoreCase = true) ||
        kindTitle.contains(trimmedQuery, ignoreCase = true) ||
        entry.method.contains(trimmedQuery, ignoreCase = true) ||
        entry.state.contains(trimmedQuery, ignoreCase = true) ||
        (entry.protocol?.contains(trimmedQuery, ignoreCase = true) == true) ||
        (entry.requestedProtocols?.contains(trimmedQuery, ignoreCase = true) == true) ||
        (entry.closeReason?.contains(trimmedQuery, ignoreCase = true) == true) ||
        (entry.error?.contains(trimmedQuery, ignoreCase = true) == true) ||
        (entry.events?.contains(trimmedQuery, ignoreCase = true) == true) ||
        (entry.messages?.contains(trimmedQuery, ignoreCase = true) == true)
    }
    .sortedWith { lhs, rhs ->
      compareNetwork(lhs, rhs, sortOrder)
    }
    .toList()
}

private fun compareLogs(lhs: DebugLogEntry, rhs: DebugLogEntry, sortOrder: SortOrder): Int {
  val lhsKey = lhs.fullTimestamp.ifBlank { lhs.timestamp }
  val rhsKey = rhs.fullTimestamp.ifBlank { rhs.timestamp }
  if (lhsKey != rhsKey) {
    return if (sortOrder == SortOrder.Asc) lhsKey.compareTo(rhsKey) else rhsKey.compareTo(lhsKey)
  }
  return if (sortOrder == SortOrder.Asc) lhs.id.compareTo(rhs.id) else rhs.id.compareTo(lhs.id)
}

private fun compareNetwork(lhs: DebugNetworkEntry, rhs: DebugNetworkEntry, sortOrder: SortOrder): Int {
  if (lhs.updatedAt != rhs.updatedAt) {
    return if (sortOrder == SortOrder.Asc) {
      lhs.updatedAt.compareTo(rhs.updatedAt)
    } else {
      rhs.updatedAt.compareTo(lhs.updatedAt)
    }
  }
  if (lhs.startedAt != rhs.startedAt) {
    return if (sortOrder == SortOrder.Asc) {
      lhs.startedAt.compareTo(rhs.startedAt)
    } else {
      rhs.startedAt.compareTo(lhs.startedAt)
    }
  }
  return if (sortOrder == SortOrder.Asc) lhs.id.compareTo(rhs.id) else rhs.id.compareTo(lhs.id)
}

private fun buildHttpSections(
  entry: DebugNetworkEntry,
  strings: Map<String, String>,
  locale: String,
  context: Context
): List<DetailItem> {
  val items = mutableListOf(
    DetailItem(localizedOriginTitleLabel(locale), localizedOriginTitle(entry.origin, strings)),
    DetailItem(localizedNetworkTypeTitle(locale), localizedNetworkKindTitle(entry.kind, locale)),
    DetailItem(strings["method"] ?: "方法", entry.method),
    DetailItem(strings["status"] ?: "状态码", entry.status?.toString() ?: "-"),
    DetailItem(strings["state"] ?: "状态", entry.state),
    DetailItem(strings["protocol"] ?: "协议", entry.protocol ?: "-"),
    DetailItem("URL", entry.url, monospace = true),
    DetailItem(strings["duration"] ?: "耗时", entry.durationMs?.let { "${it}ms" } ?: "-"),
    DetailItem(strings["requestHeaders"] ?: "请求头", headerText(entry.requestHeaders), monospace = true),
    DetailItem(strings["responseHeaders"] ?: "响应头", headerText(entry.responseHeaders), monospace = true),
    DetailItem(
      strings["requestBody"] ?: "请求体",
      formattedStructuredContent(entry.requestBody, strings["noRequestBody"] ?: "无请求体"),
      monospace = true
    ),
    DetailItem(
      strings["responseBody"] ?: "响应体",
      formattedStructuredContent(entry.responseBody, strings["noResponseBody"] ?: "无响应体"),
      monospace = true
    )
  )

  entry.events?.takeIf { it.isNotBlank() }?.let { events ->
    items += DetailItem(
      title = localizedNetworkEventsTitle(locale),
      content = formattedMessagesText(events, localizedNoNetworkEvents(locale)),
      monospace = true
    )
  }

  if (!entry.error.isNullOrBlank()) {
    items += DetailItem(strings["errorTitle"] ?: "错误", entry.error.orEmpty(), monospace = true)
  }

  if (entry.responseSize != null || !entry.responseContentType.isNullOrBlank()) {
    items += DetailItem(
      title = localizedResponseMetaTitle(locale),
      content = buildString {
        appendLine("${localizedResponseTypeTitle(locale)}: ${entry.responseType ?: "-"}")
        appendLine("${localizedContentTypeTitle(locale)}: ${entry.responseContentType ?: "-"}")
        append("Size: ${formatByteCount(context, entry.responseSize)}")
      },
      monospace = true
    )
  }

  return items
}

private fun buildWebSocketSections(
  entry: DebugNetworkEntry,
  strings: Map<String, String>,
  locale: String,
  context: Context
): List<DetailItem> {
  val inferredIncoming = entry.messageCountIn ?: countMessages(entry.messages, "<<")
  val inferredOutgoing = entry.messageCountOut ?: countMessages(entry.messages, ">>")
  val items = mutableListOf(
    DetailItem(localizedOriginTitleLabel(locale), localizedOriginTitle(entry.origin, strings)),
    DetailItem(localizedNetworkTypeTitle(locale), localizedNetworkKindTitle(entry.kind, locale)),
    DetailItem(strings["method"] ?: "方法", entry.method),
    DetailItem(strings["state"] ?: "状态", entry.state),
    DetailItem(strings["protocol"] ?: "协议", entry.protocol ?: "-"),
    DetailItem("Requested protocols", entry.requestedProtocols ?: "-"),
    DetailItem("URL", entry.url, monospace = true),
    DetailItem(strings["duration"] ?: "耗时", entry.durationMs?.let { "${it}ms" } ?: "-"),
    DetailItem("Messages", "IN $inferredIncoming / OUT $inferredOutgoing"),
    DetailItem(
      "Bytes",
      "IN ${formatByteCount(context, entry.bytesIn)} / OUT ${formatByteCount(context, entry.bytesOut)}"
    ),
    DetailItem(strings["requestHeaders"] ?: "请求头", headerText(entry.requestHeaders), monospace = true)
  )

  if (entry.responseHeaders.isNotEmpty()) {
    items += DetailItem(strings["responseHeaders"] ?: "响应头", headerText(entry.responseHeaders), monospace = true)
  }

  if (entry.status != null) {
    items += DetailItem(strings["status"] ?: "状态码", entry.status.toString())
  }

  if (entry.requestedCloseCode != null || !entry.requestedCloseReason.isNullOrBlank()) {
    items += DetailItem("Close requested", closeRequestSummary(entry), monospace = true)
  }

  if (entry.closeCode != null || entry.cleanClose != null || !entry.closeReason.isNullOrBlank()) {
    items += DetailItem("Close result", closeResultSummary(entry), monospace = true)
  }

  items += DetailItem("Event timeline", entry.events ?: localizedNoEventsText(locale), monospace = true)
  items += DetailItem(
    strings["messages"] ?: "消息",
    formattedWebSocketMessagesText(entry.messages, strings["noMessages"] ?: "暂无消息"),
    monospace = true
  )

  if (!entry.error.isNullOrBlank()) {
    items += DetailItem(strings["errorTitle"] ?: "错误", entry.error.orEmpty(), monospace = true)
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
  val fatalErrors = appErrors.filter { error ->
    error.source in setOf("global", "react") || error.message.contains("[FATAL]")
  }.sortedByDescending(DebugErrorEntry::fullTimestamp)

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
          monospace = true
        )
      )
    }
  }
}

private fun buildCrashRecordSections(
  runtimeInfo: DebugRuntimeInfo,
  locale: String
): List<DetailItem> {
  val records = runtimeInfo.crashRecords.sortedByDescending(DebugCrashRecord::timestampMillis)
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
          monospace = true
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
  checked: Boolean,
  pending: Boolean
): PanelTone {
  return when {
    pending || runtimeInfo.rootStatus == "checking" -> toneForLogLevel("warn")
    checked && runtimeInfo.activeLogcatMode == "root-device" -> PanelTone(
      foreground = Color(0xFF067647),
      background = Color(0xFFE8F7EE)
    )
    checked && runtimeInfo.rootStatus == "non_root" -> toneForLogLevel("error")
    checked -> toneForLogLevel("info")
    runtimeInfo.rootStatus == "root" -> PanelTone(
      foreground = Color(0xFF067647),
      background = Color(0xFFE8F7EE)
    )
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
    entry.status != null -> entry.status.toString()
    isWebSocketKind(entry.kind) -> null
    else -> networkKindBadgeTitle(entry.kind)
  }
}

private fun localizedNetworkTypeTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Request type"
    locale.startsWith("ja") -> "通信種別"
    locale == "zh-TW" -> "請求類型"
    else -> "请求类型"
  }
}

private fun localizedNetworkKindFilterTitle(kind: NetworkKindFilter, locale: String): String {
  return when (kind) {
    NetworkKindFilter.Http -> "XHR/Fetch"
    NetworkKindFilter.WebSocket -> "WebSocket"
    NetworkKindFilter.Other -> when {
      locale.startsWith("en") -> "Other"
      locale.startsWith("ja") -> "その他"
      else -> "其他"
    }
  }
}

private fun localizedNetworkKindTitle(rawKind: String, locale: String): String {
  return when (val normalized = normalizedNetworkKind(rawKind)) {
    NetworkKindFilter.Http -> localizedNetworkKindFilterTitle(normalized, locale)
    NetworkKindFilter.WebSocket -> localizedNetworkKindFilterTitle(normalized, locale)
    NetworkKindFilter.Other -> rawKind.trim().takeIf {
      it.isNotEmpty() && !it.equals(NetworkKindFilter.Other.rawValue, ignoreCase = true)
    }?.uppercase(Locale.ROOT) ?: localizedNetworkKindFilterTitle(normalized, locale)
  }
}

private fun isNativeOrigin(origin: String): Boolean {
  return origin.equals("native", ignoreCase = true)
}

private fun localizedOriginTitle(origin: String, strings: Map<String, String>): String {
  return if (isNativeOrigin(origin)) {
    strings["nativeLogOrigin"] ?: "native"
  } else {
    strings["jsLogOrigin"] ?: "JS"
  }
}

private fun localizedOriginTitleLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Origin"
    locale.startsWith("ja") -> "送信元"
    locale == "zh-TW" -> "來源"
    else -> "来源"
  }
}

private fun localizedLevelTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Level"
    locale.startsWith("ja") -> "レベル"
    locale == "zh-TW" -> "級別"
    else -> "级别"
  }
}

private fun localizedSortTitle(locale: String, ascending: Boolean): String {
  return when {
    locale.startsWith("en") -> if (ascending) "Time Asc" else "Time Desc"
    locale.startsWith("ja") -> if (ascending) "時間昇順" else "時間降順"
    else -> if (ascending) "时间升序" else "时间倒序"
  }
}

private fun localizedAndroidSearchPlaceholder(): String {
  return ANDROID_SEARCH_PLACEHOLDER
}

private fun localizedEmptyHint(locale: String): String {
  return when {
    locale.startsWith("en") -> "Try another keyword or generate new events."
    locale.startsWith("ja") -> "別のキーワードを試すか、新しいイベントを生成してください。"
    locale == "zh-TW" -> "換個關鍵字，或產生新的事件。"
    else -> "换个关键词，或生成新的调试事件。"
  }
}

private fun localizedNoLevelHint(locale: String): String {
  return when {
    locale.startsWith("en") -> "Select at least one level to show logs."
    locale.startsWith("ja") -> "少なくとも 1 つのレベルを選択してください。"
    locale == "zh-TW" -> "至少選擇一個級別。"
    else -> "至少选择一个日志级别。"
  }
}

private fun localizedNoLogOriginHint(locale: String): String {
  return when {
    locale.startsWith("en") -> "Select JS or native to show logs."
    locale.startsWith("ja") -> "JS または native を選択してください。"
    locale == "zh-TW" -> "請選擇 JS 或 native 日誌。"
    else -> "请选择 JS 或 native 日志。"
  }
}

private fun localizedNoNetworkOriginHint(locale: String): String {
  return when {
    locale.startsWith("en") -> "Select JS or native to show network entries."
    locale.startsWith("ja") -> "JS または native を選択してください。"
    locale == "zh-TW" -> "請選擇 JS 或 native 網路請求。"
    else -> "请选择 JS 或 native 网络请求。"
  }
}

private fun localizedNoNetworkKindHint(locale: String): String {
  return when {
    locale.startsWith("en") -> "Select at least one request type to show network entries."
    locale.startsWith("ja") -> "少なくとも 1 つの通信種別を選択してください。"
    locale == "zh-TW" -> "至少選擇一種請求類型。"
    else -> "至少选择一种请求类型。"
  }
}

private fun localizedNoNetworkFilterHint(locale: String): String {
  return when {
    locale.startsWith("en") -> "Select at least one source and request type to show network entries."
    locale.startsWith("ja") -> "少なくとも 1 つの送信元と通信種別を選択してください。"
    locale == "zh-TW" -> "至少選擇一種來源與請求類型。"
    else -> "至少选择一种来源和请求类型。"
  }
}

private fun localizedNoNetworkResultTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "No matching network requests found"
    locale.startsWith("ja") -> "一致する通信が見つかりません"
    locale == "zh-TW" -> "未找到符合的網路請求"
    else -> "未找到匹配的网络请求"
  }
}

private fun localizedResponseMetaTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Response metadata"
    locale.startsWith("ja") -> "レスポンス情報"
    locale == "zh-TW" -> "回應資訊"
    else -> "响应信息"
  }
}

private fun localizedResponseTypeTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Type"
    locale.startsWith("ja") -> "種別"
    locale == "zh-TW" -> "類型"
    else -> "类型"
  }
}

private fun localizedContentTypeTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Content-Type"
    locale.startsWith("ja") -> "Content-Type"
    else -> "Content-Type"
  }
}

private fun localizedNoEventsText(locale: String): String {
  return when {
    locale.startsWith("en") -> "No events yet"
    locale.startsWith("ja") -> "イベントはまだありません"
    locale == "zh-TW" -> "暫無事件"
    else -> "暂无事件"
  }
}

private fun localizedExpandLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Expand"
    locale.startsWith("ja") -> "展開"
    locale == "zh-TW" -> "展開"
    else -> "展开"
  }
}

private fun localizedCollapseLabel(locale: String): String {
  return when {
    locale.startsWith("en") -> "Collapse"
    locale.startsWith("ja") -> "折りたたむ"
    locale == "zh-TW" -> "收起"
    else -> "收起"
  }
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
  if (runtimeInfo.networkTabEnabled) {
    lines += localizedLimitationAndroidNativeNetwork(locale)
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
  pending: Boolean,
  locale: String
): String {
  return when {
    pending -> when {
      locale.startsWith("en") -> "Applying..."
      locale.startsWith("ja") -> "適用中..."
      locale == "zh-TW" -> "套用中..."
      else -> "应用中..."
    }
    checked && runtimeInfo.activeLogcatMode == "root-device" -> when {
      locale.startsWith("en") -> "Root device-wide capture active"
      locale.startsWith("ja") -> "root による端末全体採集が有効"
      locale == "zh-TW" -> "root 整機採集已啟用"
      else -> "root 整机采集已启用"
    }
    checked && runtimeInfo.rootStatus == "checking" -> when {
      locale.startsWith("en") -> "Checking root availability"
      locale.startsWith("ja") -> "root 利用可否を確認中"
      locale == "zh-TW" -> "檢查 root 可用性中"
      else -> "正在检查 root 可用性"
    }
    checked && runtimeInfo.rootStatus == "non_root" -> when {
      locale.startsWith("en") -> "Requested, but root is unavailable"
      locale.startsWith("ja") -> "要求済みですが root は利用不可"
      locale == "zh-TW" -> "已請求，但 root 不可用"
      else -> "已请求，但 root 不可用"
    }
    checked -> when {
      locale.startsWith("en") -> "Requested"
      locale.startsWith("ja") -> "要求済み"
      locale == "zh-TW" -> "已請求"
      else -> "已请求"
    }
    runtimeInfo.rootStatus == "root" -> when {
      locale.startsWith("en") -> "Root available"
      locale.startsWith("ja") -> "root 利用可能"
      locale == "zh-TW" -> "root 可用"
      else -> "root 可用"
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
  pending: Boolean,
  locale: String
): String {
  return when {
    pending -> when {
      locale.startsWith("en") -> "Updating the collector now. The panel will refresh after the native logcat readers restart."
      locale.startsWith("ja") -> "現在コレクターを更新しています。ネイティブ logcat リーダー再起動後に面板が更新されます。"
      locale == "zh-TW" -> "正在更新採集器，原生 logcat 讀取器重啟後面板會自動刷新。"
      else -> "正在更新采集器，原生 logcat 读取器重启后面板会自动刷新。"
    }
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
    checked -> when {
      locale.startsWith("en") -> "This requests device-wide Android logcat through root. If root is unavailable, the collector falls back to app-only capture."
      locale.startsWith("ja") -> "これは root 経由の端末全体 Android logcat を要求します。root が利用できない場合はアプリ限定採集に回退します。"
      locale == "zh-TW" -> "這會要求透過 root 讀取整機 Android logcat；若 root 不可用，則會回退到僅當前應用採集。"
      else -> "这会要求通过 root 读取整机 Android logcat；若 root 不可用，则会回退到仅当前应用采集。"
    }
    runtimeInfo.rootStatus == "root" -> when {
      locale.startsWith("en") -> "Root is available on this device. Turn this on to upgrade Android logcat capture from app-only to device-wide."
      locale.startsWith("ja") -> "この端末では root が利用可能です。オンにすると Android logcat 採集をアプリ限定から端末全体へ拡張できます。"
      locale == "zh-TW" -> "此裝置可使用 root；打開後可將 Android logcat 採集從僅當前應用提升為整機範圍。"
      else -> "此设备可使用 root；打开后可将 Android logcat 采集从仅当前应用提升为整机范围。"
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
    locale.startsWith("en") -> "JS XHR / WebSocket events plus Android native HTTP traffic and native WebSocket handshakes on instrumented OkHttp paths."
    locale.startsWith("ja") -> "JS 層の XHR / WebSocket イベントに加え、計装済み OkHttp 経路の Android ネイティブ HTTP 通信とネイティブ WebSocket ハンドシェイク。"
    locale == "zh-TW" -> "除 JS 層 XHR / WebSocket 事件外，也覆蓋已掛接 OkHttp 路徑上的 Android 原生 HTTP 通信與原生 WebSocket 握手。"
    else -> "除 JS 层 XHR / WebSocket 事件外，也覆盖已挂接 OkHttp 路径上的 Android 原生 HTTP 通信与原生 WebSocket 握手。"
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
    locale.startsWith("en") -> "Android now captures native HTTP traffic on instrumented OkHttp paths. Traffic outside OkHttp, plus full native WebSocket frame lifecycle, is still not automatically covered."
    locale.startsWith("ja") -> "Android は計装済み OkHttp 経路のネイティブ HTTP 通信を採集できるようになりました。OkHttp 外の通信と、ネイティブ WebSocket フレームの完全なライフサイクルはまだ自動採集できません。"
    locale == "zh-TW" -> "Android 現已可採集已掛接 OkHttp 路徑上的原生 HTTP 通信；但 OkHttp 之外的流量，以及原生 WebSocket frame 的完整生命週期，仍未自動覆蓋。"
    else -> "Android 现已可采集已挂接 OkHttp 路径上的原生 HTTP 通信；但 OkHttp 之外的流量，以及原生 WebSocket frame 的完整生命周期，仍未自动覆盖。"
  }
}

private fun localizedNetworkEventsTitle(locale: String): String {
  return when {
    locale.startsWith("en") -> "Events"
    locale.startsWith("ja") -> "イベント"
    locale == "zh-TW" -> "事件"
    else -> "事件"
  }
}

private fun localizedNoNetworkEvents(locale: String): String {
  return when {
    locale.startsWith("en") -> "No event timeline"
    locale.startsWith("ja") -> "イベントタイムラインはありません"
    locale == "zh-TW" -> "暫無事件時間線"
    else -> "暂无事件时间线"
  }
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
  return headers.entries
    .sortedBy { it.key.lowercase(Locale.ROOT) }
    .joinToString("\n") { "${it.key}: ${it.value}" }
}

private fun formattedMessagesText(raw: String?, fallback: String): String {
  return raw?.trim()?.takeIf { it.isNotEmpty() } ?: fallback
}

private fun formattedStructuredContent(raw: String?, fallback: String): String {
  val normalized = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return fallback
  return prettyJsonOrOriginal(normalized)
}

private fun formattedWebSocketMessagesText(raw: String?, fallback: String): String {
  val source = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return fallback
  val renderedBlocks = mutableListOf<String>()
  var currentPrefix: String? = null
  val currentPayloadLines = mutableListOf<String>()

  fun flushCurrentBlock() {
    if (currentPrefix == null && currentPayloadLines.isEmpty()) {
      return
    }

    val payload = currentPayloadLines.joinToString("\n").trimEnd()
    val renderedBlock =
      currentPrefix?.let { prefix ->
        formatDirectionalMessageBlock(prefix, payload)
      } ?: prettyJsonOrOriginal(payload)

    if (renderedBlock.isNotBlank()) {
      renderedBlocks += renderedBlock
    }

    currentPrefix = null
    currentPayloadLines.clear()
  }

  source.lineSequence().forEach { line ->
    val prefix = directionalMessagePrefix(line)
    if (prefix != null) {
      flushCurrentBlock()
      currentPrefix = prefix
      currentPayloadLines += extractDirectionalMessagePayload(line, prefix)
    } else {
      currentPayloadLines += line
    }
  }

  flushCurrentBlock()
  return renderedBlocks.joinToString("\n")
}

private fun formatDirectionalMessageBlock(prefix: String, payload: String): String {
  val formattedPayload = prettyJsonOrOriginal(payload)
  if (formattedPayload.isBlank()) {
    return prefix
  }

  val lines = formattedPayload.lines()
  val continuationIndent = " ".repeat(prefix.length + 1)
  return buildString {
    append(prefix)
    append(' ')
    append(lines.first())
    lines.drop(1).forEach { line ->
      append('\n')
      append(continuationIndent)
      append(line)
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
  return when {
    raw.startsWith("{") && raw.endsWith("}") -> runCatching { JSONObject(raw).toString(2) }.getOrNull()
    raw.startsWith("[") && raw.endsWith("]") -> runCatching { JSONArray(raw).toString(2) }.getOrNull()
    else -> null
  }
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
  strings: Map<String, String>
): String {
  val durationText = "${strings["duration"] ?: "耗时"} ${entry.durationMs?.let { "${it}ms" } ?: "-"}"
  if (!isWebSocketKind(entry.kind)) {
    return durationText
  }
  val incoming = entry.messageCountIn ?: countMessages(entry.messages, "<<")
  val outgoing = entry.messageCountOut ?: countMessages(entry.messages, ">>")
  return "$durationText · IN $incoming / OUT $outgoing"
}

private fun formatNetworkSummaryText(
  entry: DebugNetworkEntry,
  strings: Map<String, String>,
  locale: String,
  context: Context
): String {
  val parts = mutableListOf(
    "${entry.method.uppercase(Locale.ROOT)} ${entry.url}",
    "origin=${localizedOriginTitle(entry.origin, strings)}",
    "type=${localizedNetworkKindTitle(entry.kind, locale)}",
    "state=${entry.state}",
    "status=${entry.status?.toString() ?: networkKindBadgeTitle(entry.kind)}",
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

private fun copyToClipboard(text: String, successMessage: String, context: Context?) {
  val actualContext = context ?: return
  val clipboard = actualContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
  clipboard.setPrimaryClip(ClipData.newPlainText("expo-inapp-debugger", text))
  android.widget.Toast.makeText(actualContext, successMessage, android.widget.Toast.LENGTH_SHORT).show()
}
