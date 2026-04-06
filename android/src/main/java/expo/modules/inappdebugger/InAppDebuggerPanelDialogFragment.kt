package expo.modules.inappdebugger

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import androidx.fragment.app.DialogFragment
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.util.Locale

class InAppDebuggerPanelDialogFragment : DialogFragment() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    setStyle(STYLE_NORMAL, android.R.style.Theme_DeviceDefault_Light_NoActionBar_Fullscreen)
  }

  override fun onCreateView(
    inflater: android.view.LayoutInflater,
    container: ViewGroup?,
    savedInstanceState: Bundle?
  ): View {
    return ComposeView(requireContext()).apply {
      setContent {
        MaterialTheme(
          colorScheme = lightColorScheme(
            primary = Color(0xFF1E6F5C),
            secondary = Color(0xFFDDEFE9),
            surface = Color(0xFFFBFAF7),
            background = Color(0xFFF4F1EA)
          )
        ) {
          Surface(modifier = Modifier.fillMaxSize()) {
            DebugPanel(onDismiss = { dismissAllowingStateLoss() })
          }
        }
      }
    }
  }

  override fun onStart() {
    super.onStart()
    dialog?.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
  }
}

private enum class DebugTab {
  Logs,
  Network
}

private enum class SortOrder {
  Asc,
  Desc
}

@Composable
private fun DebugPanel(onDismiss: () -> Unit) {
  val state by InAppDebuggerStore.state.collectAsStateWithLifecycle()
  var activeTab by rememberSaveable { mutableStateOf(DebugTab.Logs) }
  var selectedNetworkId by rememberSaveable { mutableStateOf<String?>(null) }
  val strings = state.config.strings

  Column(
    modifier = Modifier
      .fillMaxSize()
      .background(Color(0xFFF4F1EA))
  ) {
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .padding(horizontal = 12.dp, vertical = 10.dp),
      verticalAlignment = Alignment.CenterVertically
    ) {
      Text(
        text = strings["title"] ?: "调试面板",
        style = MaterialTheme.typography.titleLarge,
        color = Color(0xFF2D2A26)
      )
      Spacer(modifier = Modifier.weight(1f))
      IconButton(onClick = onDismiss) {
        Icon(Icons.Outlined.Close, contentDescription = strings["close"] ?: "关闭")
      }
    }

    Row(modifier = Modifier.fillMaxWidth()) {
      PanelTab(
        title = strings["logsTab"] ?: "日志",
        selected = activeTab == DebugTab.Logs,
        onClick = {
          selectedNetworkId = null
          activeTab = DebugTab.Logs
        }
      )
      if (state.config.enableNetworkTab) {
        PanelTab(
          title = strings["networkTab"] ?: "网络",
          selected = activeTab == DebugTab.Network,
          onClick = {
            activeTab = DebugTab.Network
          }
        )
      }
    }

    when (activeTab) {
      DebugTab.Logs -> LogsTab(state = state)
      DebugTab.Network -> NetworkTab(
        state = state,
        selectedNetworkId = selectedNetworkId,
        onSelectNetwork = { selectedNetworkId = it },
        onBack = { selectedNetworkId = null }
      )
    }
  }
}

@Composable
private fun PanelTab(title: String, selected: Boolean, onClick: () -> Unit) {
  Box(
    modifier = Modifier
      .weight(1f)
      .clickable(onClick = onClick)
      .background(if (selected) Color(0xFFE7F3EF) else Color(0xFFF4F1EA))
      .padding(vertical = 12.dp),
    contentAlignment = Alignment.Center
  ) {
    Text(
      text = title,
      color = if (selected) Color(0xFF1E6F5C) else Color(0xFF7A7266),
      style = MaterialTheme.typography.titleMedium
    )
  }
}

@Composable
private fun LogsTab(state: DebugPanelState) {
  val strings = state.config.strings
  val context = LocalContext.current
  var searchQuery by rememberSaveable { mutableStateOf("") }
  var sortOrder by rememberSaveable { mutableStateOf(SortOrder.Desc) }
  val selectedLevels = remember {
    mutableStateMapOf(
      "log" to true,
      "info" to true,
      "warn" to true,
      "error" to true,
      "debug" to true
    )
  }
  val visibleLogs = remember(state.logs, searchQuery, sortOrder, selectedLevels.toMap()) {
    val query = searchQuery.trim().lowercase(Locale.getDefault())
    val base = state.logs.filter { entry ->
      val levelSelected = selectedLevels[entry.type] ?: false
      val queryMatches = query.isEmpty() || entry.message.lowercase(Locale.getDefault()).contains(query) || entry.type.lowercase(Locale.getDefault()).contains(query)
      levelSelected && queryMatches
    }
    if (sortOrder == SortOrder.Asc) {
      base.sortedBy { it.fullTimestamp }
    } else {
      base.sortedByDescending { it.fullTimestamp }
    }
  }

  Column(modifier = Modifier.fillMaxSize()) {
    SearchAndActionRow(
      query = searchQuery,
      placeholder = strings["searchPlaceholder"] ?: "搜索日志...",
      onQueryChange = { searchQuery = it },
      onCopyVisible = {
        copyToClipboard(
          visibleLogs.joinToString("\n") { "[${it.type.uppercase(Locale.getDefault())}] ${it.timestamp} ${it.message}" },
          strings["copyVisibleSuccess"] ?: "已复制当前显示的日志",
          context
        )
      },
      onClear = { InAppDebuggerStore.clear("logs") },
      clearLabel = strings["clear"] ?: "清空"
    )

    Row(
      modifier = Modifier
        .fillMaxWidth()
        .padding(horizontal = 12.dp, vertical = 6.dp),
      horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
      listOf("log", "info", "warn", "error", "debug").forEach { level ->
        FilterChip(
          selected = selectedLevels[level] == true,
          onClick = { selectedLevels[level] = !(selectedLevels[level] ?: true) },
          label = { Text(level.uppercase(Locale.getDefault())) }
        )
      }
    }

    Row(
      modifier = Modifier
        .fillMaxWidth()
        .padding(horizontal = 12.dp, vertical = 6.dp),
      horizontalArrangement = Arrangement.End
    ) {
      AssistChip(
        onClick = { sortOrder = SortOrder.Asc },
        label = { Text(strings["sortAsc"] ?: "时间升序") }
      )
      Spacer(modifier = Modifier.width(8.dp))
      AssistChip(
        onClick = { sortOrder = SortOrder.Desc },
        label = { Text(strings["sortDesc"] ?: "时间倒序") }
      )
    }

    if (visibleLogs.isEmpty()) {
      EmptyState(
        text = if (searchQuery.isBlank()) strings["noLogs"] ?: "暂无日志" else strings["noSearchResult"] ?: "未找到匹配的日志"
      )
    } else {
      LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
      ) {
        items(visibleLogs, key = { it.id }) { log ->
          LogCard(log = log, strings = strings)
        }
      }
    }
  }
}

@Composable
private fun LogCard(log: DebugLogEntry, strings: Map<String, String>) {
  var expanded by remember(log.id) { mutableStateOf(false) }
  val context = LocalContext.current
  val tone = when (log.type) {
    "warn" -> Pair(Color(0xFFFFF4DE), Color(0xFFD97706))
    "error" -> Pair(Color(0xFFFEEAEA), Color(0xFFB42318))
    "info" -> Pair(Color(0xFFEFF6FF), Color(0xFF2563EB))
    "debug" -> Pair(Color(0xFFF4EBFF), Color(0xFF7C3AED))
    else -> Pair(Color(0xFFE8F5E9), Color(0xFF1E6F5C))
  }

  Card(
    colors = CardDefaults.cardColors(containerColor = tone.first),
    modifier = Modifier.fillMaxWidth()
  ) {
    Column(modifier = Modifier.padding(14.dp)) {
      Row(verticalAlignment = Alignment.CenterVertically) {
        AssistChip(
          onClick = {},
          label = { Text(log.type.uppercase(Locale.getDefault())) }
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(text = log.timestamp, color = Color(0xFF6D655A))
        IconButton(onClick = {
          copyToClipboard(log.message, strings["copySingleSuccess"] ?: "已复制到剪贴板", context)
        }) {
          Icon(Icons.Outlined.ContentCopy, contentDescription = strings["copySingleA11y"] ?: "复制该条日志", tint = tone.second)
        }
      }
      Text(
        text = log.message,
        color = Color(0xFF2D2A26),
        fontFamily = FontFamily.Monospace,
        maxLines = if (expanded) Int.MAX_VALUE else 6,
        overflow = TextOverflow.Ellipsis
      )
      if (log.message.length > 240 || log.message.count { it == '\n' } > 5) {
        TextButton(onClick = { expanded = !expanded }) {
          Text(if (expanded) "收起" else "展开")
        }
      }
    }
  }
}

@Composable
private fun NetworkTab(
  state: DebugPanelState,
  selectedNetworkId: String?,
  onSelectNetwork: (String) -> Unit,
  onBack: () -> Unit
) {
  val strings = state.config.strings
  val context = LocalContext.current
  val selected = state.network.firstOrNull { it.id == selectedNetworkId }
  if (selected != null) {
    NetworkDetail(entry = selected, strings = strings, onBack = onBack)
    return
  }

  var searchQuery by rememberSaveable { mutableStateOf("") }
  val requests = remember(state.network, searchQuery) {
    val query = searchQuery.trim().lowercase(Locale.getDefault())
    state.network.filter { entry ->
      query.isEmpty() ||
        entry.url.lowercase(Locale.getDefault()).contains(query) ||
        entry.method.lowercase(Locale.getDefault()).contains(query) ||
        entry.state.lowercase(Locale.getDefault()).contains(query)
    }
  }

  Column(modifier = Modifier.fillMaxSize()) {
    SearchAndActionRow(
      query = searchQuery,
      placeholder = strings["searchPlaceholder"] ?: "搜索日志...",
      onQueryChange = { searchQuery = it },
      onCopyVisible = {
        copyToClipboard(
          requests.joinToString("\n") { "${it.method} ${it.url} ${it.status ?: "-"} ${it.state}" },
          strings["copyVisibleSuccess"] ?: "已复制当前显示的日志",
          context
        )
      },
      onClear = { InAppDebuggerStore.clear("network") },
      clearLabel = strings["clear"] ?: "清空"
    )

    if (requests.isEmpty()) {
      EmptyState(text = strings["noNetworkRequests"] ?: "暂无网络请求")
    } else {
      LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
      ) {
        items(requests, key = { it.id }) { entry ->
          Card(
            modifier = Modifier
              .fillMaxWidth()
              .clickable { onSelectNetwork(entry.id) }
          ) {
            Column(modifier = Modifier.padding(14.dp)) {
              Row(verticalAlignment = Alignment.CenterVertically) {
                AssistChip(onClick = {}, label = { Text(entry.method) })
                Spacer(modifier = Modifier.width(8.dp))
                Text(text = entry.state.uppercase(Locale.getDefault()), color = Color(0xFF6D655A))
                Spacer(modifier = Modifier.weight(1f))
                Text(text = entry.status?.toString() ?: "-", color = Color(0xFF2D2A26))
              }
              Spacer(modifier = Modifier.height(6.dp))
              Text(text = entry.url, maxLines = 2, overflow = TextOverflow.Ellipsis)
              Spacer(modifier = Modifier.height(4.dp))
              Text(
                text = "${strings["duration"] ?: "耗时"}: ${entry.durationMs ?: 0}ms",
                color = Color(0xFF6D655A)
              )
            }
          }
        }
      }
    }
  }
}

@Composable
private fun NetworkDetail(entry: DebugNetworkEntry, strings: Map<String, String>, onBack: () -> Unit) {
  val scrollState = rememberScrollState()
  Column(modifier = Modifier.fillMaxSize()) {
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .padding(horizontal = 12.dp, vertical = 10.dp),
      verticalAlignment = Alignment.CenterVertically
    ) {
      IconButton(onClick = onBack) {
        Icon(Icons.Outlined.ArrowBack, contentDescription = "返回")
      }
      Text(
        text = strings["requestDetails"] ?: "请求详情",
        style = MaterialTheme.typography.titleMedium
      )
    }
    Column(
      modifier = Modifier
        .fillMaxSize()
        .verticalScroll(scrollState)
        .padding(horizontal = 12.dp, vertical = 8.dp),
      verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
      DetailSection(title = strings["method"] ?: "方法", content = entry.method)
      DetailSection(title = strings["status"] ?: "状态码", content = entry.status?.toString() ?: "-")
      DetailSection(title = strings["state"] ?: "状态", content = entry.state)
      DetailSection(title = strings["protocol"] ?: "协议", content = entry.protocol ?: "-")
      DetailSection(title = strings["duration"] ?: "耗时", content = "${entry.durationMs ?: 0}ms")
      DetailSection(title = "URL", content = entry.url)
      DetailSection(
        title = strings["requestHeaders"] ?: "请求头",
        content = entry.requestHeaders.entries.joinToString("\n") { "${it.key}: ${it.value}" }.ifBlank { "-" }
      )
      DetailSection(
        title = strings["responseHeaders"] ?: "响应头",
        content = entry.responseHeaders.entries.joinToString("\n") { "${it.key}: ${it.value}" }.ifBlank { "-" }
      )
      DetailSection(
        title = strings["requestBody"] ?: "请求体",
        content = entry.requestBody ?: strings["noRequestBody"] ?: "无请求体",
        monospace = true
      )
      DetailSection(
        title = strings["responseBody"] ?: "响应体",
        content = entry.responseBody ?: strings["noResponseBody"] ?: "无响应体",
        monospace = true
      )
      DetailSection(
        title = strings["messages"] ?: "消息",
        content = entry.messages ?: strings["noMessages"] ?: "暂无消息",
        monospace = true
      )
      if (!entry.error.isNullOrBlank()) {
        DetailSection(title = "错误", content = entry.error, monospace = true)
      }
    }
  }
}

@Composable
private fun DetailSection(title: String, content: String, monospace: Boolean = false) {
  Card {
    Column(modifier = Modifier.padding(14.dp)) {
      Text(text = title, style = MaterialTheme.typography.titleSmall)
      Spacer(modifier = Modifier.height(6.dp))
      Text(text = content, fontFamily = if (monospace) FontFamily.Monospace else FontFamily.Default)
    }
  }
}

@Composable
private fun SearchAndActionRow(
  query: String,
  placeholder: String,
  onQueryChange: (String) -> Unit,
  onCopyVisible: () -> Unit,
  onClear: () -> Unit,
  clearLabel: String
) {
  Row(
    modifier = Modifier
      .fillMaxWidth()
      .padding(horizontal = 12.dp, vertical = 8.dp),
    verticalAlignment = Alignment.CenterVertically
  ) {
    OutlinedTextField(
      value = query,
      onValueChange = onQueryChange,
      modifier = Modifier.weight(1f),
      placeholder = { Text(placeholder) },
      singleLine = true,
      keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None)
    )
    Spacer(modifier = Modifier.width(8.dp))
    IconButton(onClick = onCopyVisible) {
      Icon(Icons.Outlined.ContentCopy, contentDescription = "复制当前列表")
    }
    TextButton(onClick = onClear) {
      Text(clearLabel)
    }
  }
}

@Composable
private fun EmptyState(text: String) {
  Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
    Text(text = text, color = Color(0xFF7A7266))
  }
}

private fun copyToClipboard(text: String, successMessage: String, context: Context? = null) {
  val ctx = context ?: return
  val clipboard = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
  clipboard.setPrimaryClip(ClipData.newPlainText("expo-inapp-debugger", text))
  android.widget.Toast.makeText(ctx, successMessage, android.widget.Toast.LENGTH_SHORT).show()
}
