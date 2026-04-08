import UIKit

private enum PanelSection {
  case main
}

private enum ActiveTab: Int {
  case logs
  case network
}

private enum ToolbarButtonStyle {
  case primary
  case neutral
}

private enum PanelColors {
  static let background = UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)
  static let card = UIColor.white
  static let controlBackground = UIColor(red: 0.91, green: 0.94, blue: 0.96, alpha: 1)
  static let border = UIColor(red: 0.86, green: 0.88, blue: 0.91, alpha: 1)
  static let primary = UIColor(red: 0.05, green: 0.47, blue: 0.42, alpha: 1)
  static let text = UIColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)
  static let mutedText = UIColor(red: 0.40, green: 0.45, blue: 0.52, alpha: 1)
}

private struct PanelTone {
  let foreground: UIColor
  let background: UIColor
}

private func toneForLogLevel(_ level: String) -> PanelTone {
  switch level.lowercased() {
  case "error":
    return PanelTone(
      foreground: UIColor(red: 0.70, green: 0.13, blue: 0.10, alpha: 1),
      background: UIColor(red: 1.00, green: 0.91, blue: 0.91, alpha: 1)
    )
  case "warn":
    return PanelTone(
      foreground: UIColor(red: 0.71, green: 0.33, blue: 0.04, alpha: 1),
      background: UIColor(red: 1.00, green: 0.96, blue: 0.86, alpha: 1)
    )
  case "info":
    return PanelTone(
      foreground: UIColor(red: 0.14, green: 0.39, blue: 0.92, alpha: 1),
      background: UIColor(red: 0.91, green: 0.95, blue: 1.00, alpha: 1)
    )
  case "debug":
    return PanelTone(
      foreground: UIColor(red: 0.29, green: 0.36, blue: 0.45, alpha: 1),
      background: UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)
    )
  default:
    return PanelTone(
      foreground: PanelColors.primary,
      background: UIColor(red: 0.89, green: 0.96, blue: 0.94, alpha: 1)
    )
  }
}

private func toneForNetwork(_ entry: DebugNetworkEntry) -> PanelTone {
  if entry.state == "error" || (entry.status ?? 0) >= 400 {
    return toneForLogLevel("error")
  }
  if entry.state == "pending" || entry.state == "connecting" {
    return PanelTone(
      foreground: UIColor(red: 0.29, green: 0.36, blue: 0.45, alpha: 1),
      background: UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)
    )
  }
  if entry.state == "closed" || entry.state == "closing" {
    return toneForLogLevel("warn")
  }
  return toneForLogLevel("log")
}

private func isNativeOrigin(_ origin: String) -> Bool {
  origin.lowercased() == "native"
}

private func localizedOriginTitle(_ origin: String, strings: [String: String]) -> String {
  if isNativeOrigin(origin) {
    return strings["nativeLogOrigin"] ?? "native"
  }
  return strings["jsLogOrigin"] ?? "JS"
}

private let panelByteCountFormatter: ByteCountFormatter = {
  let formatter = ByteCountFormatter()
  formatter.allowedUnits = [.useBytes, .useKB, .useMB]
  formatter.countStyle = .file
  formatter.includesUnit = true
  formatter.isAdaptive = true
  return formatter
}()

private func formatNetworkByteCount(_ count: Int?) -> String {
  guard let count else {
    return "-"
  }
  return panelByteCountFormatter.string(fromByteCount: Int64(max(0, count)))
}

private enum PanelFilterPreferences {
  static let selectedLogLevelsKey = "expo.inappdebugger.panel.selectedLevels"
  static let selectedLogOriginsKey = "expo.inappdebugger.panel.selectedOrigins"
  static let selectedNetworkOriginsKey = "expo.inappdebugger.panel.selectedNetworkOrigins"
  static let allLevels: Set<String> = ["log", "info", "warn", "error", "debug"]
  static let allOrigins: Set<String> = ["js", "native"]
  static let defaultOrigins: Set<String> = ["js"]

  static func loadLogLevels() -> Set<String> {
    loadSet(forKey: selectedLogLevelsKey, allowedValues: allLevels, defaultValues: allLevels)
  }

  static func loadLogOrigins() -> Set<String> {
    loadSet(forKey: selectedLogOriginsKey, allowedValues: allOrigins, defaultValues: defaultOrigins)
  }

  static func loadNetworkOrigins() -> Set<String> {
    loadSet(forKey: selectedNetworkOriginsKey, allowedValues: allOrigins, defaultValues: defaultOrigins)
  }

  static func saveLogLevels(_ levels: Set<String>) {
    saveSet(levels, forKey: selectedLogLevelsKey)
  }

  static func saveLogOrigins(_ origins: Set<String>) {
    saveSet(origins, forKey: selectedLogOriginsKey)
  }

  static func saveNetworkOrigins(_ origins: Set<String>) {
    saveSet(origins, forKey: selectedNetworkOriginsKey)
  }

  private static func loadSet(
    forKey key: String,
    allowedValues: Set<String>,
    defaultValues: Set<String>
  ) -> Set<String> {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: key) != nil else {
      return defaultValues
    }

    let values = defaults.stringArray(forKey: key) ?? []
    return Set(values.filter { allowedValues.contains($0) })
  }

  private static func saveSet(_ values: Set<String>, forKey key: String) {
    UserDefaults.standard.set(Array(values).sorted(), forKey: key)
  }
}

final class InAppDebuggerPanelViewController: UIViewController, UITableViewDelegate {
  private enum ReloadReason {
    case full
    case dataOnly
  }

  private var activeTab: ActiveTab = .logs
  private var searchText = ""
  private var selectedLogLevels: Set<String> = PanelFilterPreferences.loadLogLevels()
  private var selectedLogOrigins: Set<String> = PanelFilterPreferences.loadLogOrigins()
  private var selectedNetworkOrigins: Set<String> = PanelFilterPreferences.loadNetworkOrigins()
  private var sortAscending = false
  private var displayedLogs: [DebugLogEntry] = []
  private var displayedNetwork: [DebugNetworkEntry] = []
  private var displayedLogLookup: [String: DebugLogEntry] = [:]
  private var displayedNetworkLookup: [String: DebugNetworkEntry] = [:]
  private var notificationObserver: NSObjectProtocol?
  private var currentConfig = DebugConfig()
  private var scheduledReloadWorkItem: DispatchWorkItem?
  private var isSuspendingLiveUpdatesForScroll = false

  private lazy var closeButton: UIButton = {
    var config = UIButton.Configuration.tinted()
    config.image = UIImage(systemName: "xmark")
    config.baseForegroundColor = PanelColors.text
    config.baseBackgroundColor = PanelColors.controlBackground
    config.cornerStyle = .small
    let button = UIButton(configuration: config)
    button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 36),
      button.heightAnchor.constraint(equalToConstant: 36),
    ])
    return button
  }()

  private lazy var segmentedControl: UISegmentedControl = {
    let control = UISegmentedControl(items: ["日志", "网络"])
    control.selectedSegmentIndex = 0
    control.backgroundColor = PanelColors.controlBackground
    control.selectedSegmentTintColor = PanelColors.card
    control.setTitleTextAttributes([
      .foregroundColor: PanelColors.mutedText,
      .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
    ], for: .normal)
    control.setTitleTextAttributes([
      .foregroundColor: PanelColors.text,
      .font: UIFont.systemFont(ofSize: 14, weight: .bold),
    ], for: .selected)
    control.addTarget(self, action: #selector(handleSegmentChange(_:)), for: .valueChanged)
    return control
  }()

  private lazy var searchField: UISearchTextField = {
    let field = UISearchTextField()
    field.font = .systemFont(ofSize: 15, weight: .regular)
    field.textColor = PanelColors.text
    field.tintColor = PanelColors.primary
    field.backgroundColor = PanelColors.controlBackground
    field.borderStyle = .none
    field.layer.cornerRadius = 10
    field.layer.masksToBounds = true
    field.clearButtonMode = .whileEditing
    field.addTarget(self, action: #selector(searchTextChanged(_:)), for: .editingChanged)
    return field
  }()

  private lazy var clearButton: UIButton = {
    var config = UIButton.Configuration.tinted()
    config.image = UIImage(systemName: "trash")
    config.baseForegroundColor = PanelColors.text
    config.baseBackgroundColor = PanelColors.controlBackground
    config.cornerStyle = .medium
    let button = UIButton(configuration: config)
    button.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
  }()

  private lazy var filterButton: UIButton = {
    var config = UIButton.Configuration.tinted()
    config.image = UIImage(systemName: "line.3.horizontal.decrease")
    config.baseForegroundColor = PanelColors.primary
    config.baseBackgroundColor = PanelColors.controlBackground
    config.cornerStyle = .medium
    let button = UIButton(configuration: config)
    button.showsMenuAsPrimaryAction = true
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
  }()

  private lazy var sortToggleButton: UIButton = {
    var config = UIButton.Configuration.tinted()
    config.image = UIImage(systemName: "arrow.down")
    config.baseForegroundColor = PanelColors.text
    config.baseBackgroundColor = PanelColors.controlBackground
    config.cornerStyle = .medium
    let button = UIButton(configuration: config)
    button.addTarget(self, action: #selector(sortToggleTapped), for: .touchUpInside)
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
  }()

  private lazy var tableView: UITableView = {
    let table = UITableView(frame: .zero, style: .plain)
    table.backgroundColor = PanelColors.background
    table.separatorStyle = .none
    table.delegate = self
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 108
    table.keyboardDismissMode = .onDrag
    table.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 18, right: 0)
    table.register(InAppDebuggerLogCell.self, forCellReuseIdentifier: InAppDebuggerLogCell.reuseIdentifier)
    table.register(InAppDebuggerNetworkCell.self, forCellReuseIdentifier: InAppDebuggerNetworkCell.reuseIdentifier)
    return table
  }()

  private let emptyStateView = InAppDebuggerEmptyStateView()

  private lazy var dataSource = UITableViewDiffableDataSource<PanelSection, String>(
    tableView: tableView
  ) { [weak self] tableView, indexPath, identifier in
    guard let self else { return nil }

    if self.activeTab == .logs {
      guard let entry = self.displayedLogLookup[identifier] else {
        return UITableViewCell()
      }
      let cell = tableView.dequeueReusableCell(
        withIdentifier: InAppDebuggerLogCell.reuseIdentifier,
        for: indexPath
      ) as? InAppDebuggerLogCell
      cell?.configure(entry: entry, strings: self.strings) { [weak self] in
        self?.copy(text: entry.message, successKey: "copySingleSuccess")
      }
      return cell
    }

    guard let entry = self.displayedNetworkLookup[identifier] else {
      return UITableViewCell()
    }
    let cell = tableView.dequeueReusableCell(
      withIdentifier: InAppDebuggerNetworkCell.reuseIdentifier,
      for: indexPath
    ) as? InAppDebuggerNetworkCell
    cell?.configure(entry: entry, strings: self.strings)
    return cell
  }

  private var strings: [String: String] {
    currentConfig.strings
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    currentConfig = InAppDebuggerStore.shared.currentConfig()
    view.backgroundColor = PanelColors.background
    navigationItem.largeTitleDisplayMode = .never

    configureNavigationBar()
    layoutUI()
    updateFilterMenu()
    reloadFromStore()

    notificationObserver = NotificationCenter.default.addObserver(
      forName: .inAppDebuggerStoreDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.scheduleReloadFromStore()
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    configureNavigationBar()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    InAppDebuggerStore.shared.setLiveUpdatesEnabled(true)
    syncNativeCaptureStates()
    reloadFromStore()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    guard isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent else {
      return
    }
    scheduledReloadWorkItem?.cancel()
    scheduledReloadWorkItem = nil
    InAppDebuggerStore.shared.setLiveUpdatesEnabled(false)
    InAppDebuggerNativeLogCapture.shared.setPanelActive(false)
    InAppDebuggerNativeWebSocketCapture.shared.setPanelActive(false)
    isSuspendingLiveUpdatesForScroll = false
  }

  deinit {
    scheduledReloadWorkItem?.cancel()
    InAppDebuggerStore.shared.setLiveUpdatesEnabled(false)
    InAppDebuggerNativeLogCapture.shared.setPanelActive(false)
    InAppDebuggerNativeWebSocketCapture.shared.setPanelActive(false)
    if let notificationObserver {
      NotificationCenter.default.removeObserver(notificationObserver)
    }
  }

  private func configureNavigationBar() {
    title = strings["title"] ?? "调试面板"
    closeButton.accessibilityLabel = strings["close"] ?? "关闭"
    navigationItem.rightBarButtonItem = UIBarButtonItem(customView: closeButton)

    guard let navigationBar = navigationController?.navigationBar else {
      return
    }
    navigationController?.navigationBar.prefersLargeTitles = false
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = PanelColors.background
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [
      .foregroundColor: PanelColors.text,
      .font: UIFont.systemFont(ofSize: 18, weight: .bold),
    ]
    navigationBar.standardAppearance = appearance
    navigationBar.scrollEdgeAppearance = appearance
    navigationBar.compactAppearance = appearance
    navigationBar.tintColor = PanelColors.primary
  }

  private func layoutUI() {
    let actionRow = UIStackView(arrangedSubviews: [searchField, filterButton, sortToggleButton, clearButton])
    actionRow.axis = .horizontal
    actionRow.alignment = .fill
    actionRow.spacing = 8

    let topStack = UIStackView(arrangedSubviews: [segmentedControl, actionRow])
    topStack.axis = .vertical
    topStack.spacing = 12
    
    view.addSubview(topStack)
    view.addSubview(tableView)
    
    topStack.translatesAutoresizingMaskIntoConstraints = false
    tableView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      topStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
      topStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      topStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),

      tableView.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 10),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      segmentedControl.heightAnchor.constraint(equalToConstant: 36),
      searchField.heightAnchor.constraint(equalToConstant: 36),
      filterButton.widthAnchor.constraint(equalToConstant: 36),
      filterButton.heightAnchor.constraint(equalToConstant: 36),
      sortToggleButton.widthAnchor.constraint(equalToConstant: 36),
      sortToggleButton.heightAnchor.constraint(equalToConstant: 36),
      clearButton.widthAnchor.constraint(equalToConstant: 36),
      clearButton.heightAnchor.constraint(equalToConstant: 36),
    ])
  }

  private func updateFilterMenu() {
    let selectedOrigins = activeTab == .logs ? selectedLogOrigins : selectedNetworkOrigins
    let originOptions = ["js", "native"].map { origin -> UIAction in
      let title = localizedOriginTitle(origin, strings: strings)
      let isSelected = selectedOrigins.contains(origin)
      var attributes: UIMenuElement.Attributes = []
      if #available(iOS 16.0, *) { attributes.insert(.keepsMenuPresented) }
      return UIAction(title: title, attributes: attributes, state: isSelected ? .on : .off) { [weak self] _ in
        self?.toggleOrigin(origin)
      }
    }

    let originMenu = UIMenu(title: strings["origin"] ?? "来源", options: .displayInline, children: originOptions)
    var menuChildren: [UIMenuElement] = [originMenu]
    if activeTab == .logs {
      let levelOptions = ["log", "info", "warn", "error", "debug"].map { level -> UIAction in
        let isSelected = selectedLogLevels.contains(level)
        var attributes: UIMenuElement.Attributes = []
        if #available(iOS 16.0, *) { attributes.insert(.keepsMenuPresented) }
        return UIAction(title: level.uppercased(), attributes: attributes, state: isSelected ? .on : .off) { [weak self] _ in
          self?.toggleLevel(level)
        }
      }
      let levelMenu = UIMenu(title: strings["level"] ?? "级别", options: .displayInline, children: levelOptions)
      menuChildren.append(levelMenu)
    }

    filterButton.menu = UIMenu(title: strings["filter"] ?? "筛选", children: menuChildren)
    
    let hasFilters: Bool
    if activeTab == .logs {
      hasFilters =
        selectedLogOrigins.count < PanelFilterPreferences.allOrigins.count ||
        selectedLogLevels.count < PanelFilterPreferences.allLevels.count
    } else {
      hasFilters = selectedNetworkOrigins.count < PanelFilterPreferences.allOrigins.count
    }
    var config = filterButton.configuration
    config?.baseForegroundColor = hasFilters ? .white : PanelColors.primary
    config?.baseBackgroundColor = hasFilters ? PanelColors.primary : PanelColors.controlBackground
    filterButton.configuration = config
  }

  private func toggleOrigin(_ origin: String) {
    switch activeTab {
    case .logs:
      if selectedLogOrigins.contains(origin) {
        selectedLogOrigins.remove(origin)
      } else {
        selectedLogOrigins.insert(origin)
      }
      PanelFilterPreferences.saveLogOrigins(selectedLogOrigins)
    case .network:
      if selectedNetworkOrigins.contains(origin) {
        selectedNetworkOrigins.remove(origin)
      } else {
        selectedNetworkOrigins.insert(origin)
      }
      PanelFilterPreferences.saveNetworkOrigins(selectedNetworkOrigins)
    }
    updateFilterMenu()
    syncNativeCaptureStates()
    reloadFromStore()
  }

  private func toggleLevel(_ level: String) {
    if selectedLogLevels.contains(level) {
      selectedLogLevels.remove(level)
    } else {
      selectedLogLevels.insert(level)
    }
    PanelFilterPreferences.saveLogLevels(selectedLogLevels)
    updateFilterMenu()
    reloadFromStore()
  }

  private func syncNativeCaptureStates() {
    let shouldActivateNativeLogs = activeTab == .logs && selectedLogOrigins.contains("native")
    InAppDebuggerNativeLogCapture.shared.setPanelActive(shouldActivateNativeLogs)

    // The current native WebSocket hook captures RN-managed sockets, which are still JS-origin requests.
    let shouldActivateNativeWebSocket =
      currentConfig.enableNetworkTab &&
      activeTab == .network &&
      selectedNetworkOrigins.contains("js")
    InAppDebuggerNativeWebSocketCapture.shared.setPanelActive(shouldActivateNativeWebSocket)
  }

  private func applySnapshot() {
    var snapshot = NSDiffableDataSourceSnapshot<PanelSection, String>()
    snapshot.appendSections([.main])
    if activeTab == .logs {
      snapshot.appendItems(displayedLogs.map(\.id))
    } else {
      snapshot.appendItems(displayedNetwork.map(\.id))
    }

    updateEmptyState()
    if #available(iOS 15.0, *) {
      dataSource.applySnapshotUsingReloadData(snapshot)
    } else {
      dataSource.apply(snapshot, animatingDifferences: false)
    }
  }

  private func reloadFromStore(reason: ReloadReason = .full) {
    let state = InAppDebuggerStore.shared.snapshotState()
    if reason == .full {
      currentConfig = state.0

      if !currentConfig.enableNetworkTab && activeTab == .network {
        activeTab = .logs
      }

      configureNavigationBar()
      segmentedControl.selectedSegmentIndex = activeTab.rawValue
      segmentedControl.setTitle(currentConfig.strings["logsTab"] ?? "日志", forSegmentAt: 0)
      segmentedControl.setTitle(currentConfig.strings["networkTab"] ?? "网络", forSegmentAt: 1)
      segmentedControl.setEnabled(currentConfig.enableNetworkTab, forSegmentAt: 1)

      searchField.placeholder = activeTab == .logs
        ? currentConfig.strings["searchPlaceholder"] ?? "搜索日志..."
        : localizedNetworkSearchPlaceholder()
      filterButton.isHidden = false
      updateToolbarTitles()
      updateFilterMenu()
      updateSortButton()
      if view.window != nil {
        syncNativeCaptureStates()
      }
    }

    displayedLogs = filteredLogs(from: state.1)
    displayedNetwork = filteredNetwork(from: state.3)
    displayedLogLookup = Dictionary(uniqueKeysWithValues: displayedLogs.map { ($0.id, $0) })
    displayedNetworkLookup = Dictionary(uniqueKeysWithValues: displayedNetwork.map { ($0.id, $0) })
    applySnapshot()
  }

  private func filteredLogs(from source: [DebugLogEntry]) -> [DebugLogEntry] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    var result: [DebugLogEntry] = []
    result.reserveCapacity(source.count)
    for entry in source {
      guard selectedLogLevels.contains(entry.type), selectedLogOrigins.contains(entry.origin) else {
        continue
      }
      if !query.isEmpty {
        let matchesQuery =
          entry.message.localizedCaseInsensitiveContains(query) ||
          entry.type.localizedCaseInsensitiveContains(query) ||
          entry.origin.localizedCaseInsensitiveContains(query) ||
          (entry.context ?? "").localizedCaseInsensitiveContains(query) ||
          (entry.details ?? "").localizedCaseInsensitiveContains(query)
        guard matchesQuery else {
          continue
        }
      }
      result.append(entry)
    }
    if !sortAscending {
      result.reverse()
    }
    return result
  }

  private func filteredNetwork(from source: [DebugNetworkEntry]) -> [DebugNetworkEntry] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    var result: [DebugNetworkEntry] = []
    result.reserveCapacity(source.count)
    for entry in source {
      guard selectedNetworkOrigins.contains(entry.origin) else {
        continue
      }
      if !query.isEmpty {
        let matchesQuery =
          entry.url.localizedCaseInsensitiveContains(query) ||
          entry.origin.localizedCaseInsensitiveContains(query) ||
          entry.method.localizedCaseInsensitiveContains(query) ||
          entry.state.localizedCaseInsensitiveContains(query) ||
          (entry.protocol ?? "").localizedCaseInsensitiveContains(query) ||
          (entry.requestedProtocols ?? "").localizedCaseInsensitiveContains(query) ||
          (entry.closeReason ?? "").localizedCaseInsensitiveContains(query) ||
          (entry.error ?? "").localizedCaseInsensitiveContains(query) ||
          (entry.events ?? "").localizedCaseInsensitiveContains(query) ||
          (entry.messages ?? "").localizedCaseInsensitiveContains(query)
        guard matchesQuery else {
          continue
        }
      }
      result.append(entry)
    }
    if !sortAscending {
      result.reverse()
    }
    return result
  }

  private func scheduleReloadFromStore() {
    guard !isSuspendingLiveUpdatesForScroll else {
      return
    }
    scheduledReloadWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }
      if self.tableView.isDragging || self.tableView.isDecelerating {
        return
      }
      self.reloadFromStore(reason: .dataOnly)
    }
    scheduledReloadWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
  }

  private func suspendLiveUpdatesForScrollIfNeeded() {
    guard !isSuspendingLiveUpdatesForScroll else {
      return
    }
    isSuspendingLiveUpdatesForScroll = true
    scheduledReloadWorkItem?.cancel()
    scheduledReloadWorkItem = nil
    InAppDebuggerStore.shared.setLiveUpdatesEnabled(false)
  }

  private func resumeLiveUpdatesAfterScrollIfNeeded() {
    guard isSuspendingLiveUpdatesForScroll else {
      return
    }
    isSuspendingLiveUpdatesForScroll = false
    InAppDebuggerStore.shared.setLiveUpdatesEnabled(true)
    reloadFromStore(reason: .dataOnly)
  }

  private func updateToolbarTitles() {
    clearButton.accessibilityLabel = strings["clear"] ?? "清空"
    filterButton.accessibilityLabel = strings["filter"] ?? "筛选"
  }

  private func updateSortButton() {
    guard var config = sortToggleButton.configuration else {
      return
    }
    config.image = UIImage(systemName: sortAscending ? "arrow.up" : "arrow.down")
    sortToggleButton.configuration = config
    sortToggleButton.accessibilityLabel = localizedSortTitle(ascending: sortAscending)
  }

  private func updateEmptyState() {
    let isEmpty = activeTab == .logs ? displayedLogs.isEmpty : displayedNetwork.isEmpty
    guard isEmpty else {
      tableView.backgroundView = nil
      return
    }

    let hasSearch = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let title: String
    let detail: String
    if activeTab == .logs {
      title = hasSearch || selectedLogLevels.isEmpty
        ? strings["noSearchResult"] ?? "未找到匹配的日志"
        : strings["noLogs"] ?? "暂无日志"
      detail = selectedLogOrigins.isEmpty
        ? localizedNoLogOriginHint()
        : (selectedLogLevels.isEmpty ? localizedNoLevelHint() : localizedEmptyHint())
    } else {
      title = hasSearch || selectedNetworkOrigins.isEmpty
        ? localizedNoNetworkResultTitle()
        : strings["noNetworkRequests"] ?? "暂无网络请求"
      detail = selectedNetworkOrigins.isEmpty ? localizedNoNetworkOriginHint() : localizedEmptyHint()
    }
    emptyStateView.configure(title: title, detail: detail)
    tableView.backgroundView = emptyStateView
  }

  private func localizedSortTitle(ascending: Bool) -> String {
    if currentConfig.locale.hasPrefix("en") {
      return ascending ? "Time Asc" : "Time Desc"
    }
    if currentConfig.locale.hasPrefix("ja") {
      return ascending ? "時間昇順" : "時間降順"
    }
    if currentConfig.locale == "zh-TW" {
      return ascending ? "時間升序" : "時間倒序"
    }
    return ascending ? "时间升序" : "时间倒序"
  }

  private func localizedNetworkSearchPlaceholder() -> String {
    if currentConfig.locale.hasPrefix("en") {
      return "Search network..."
    }
    if currentConfig.locale.hasPrefix("ja") {
      return "通信を検索..."
    }
    if currentConfig.locale == "zh-TW" {
      return "搜尋網路請求..."
    }
    return "搜索网络请求..."
  }

  private func localizedEmptyHint() -> String {
    if currentConfig.locale.hasPrefix("en") {
      return "Try another keyword or generate new events."
    }
    if currentConfig.locale.hasPrefix("ja") {
      return "別のキーワードを試すか、新しいイベントを生成してください。"
    }
    if currentConfig.locale == "zh-TW" {
      return "換個關鍵字，或產生新的事件。"
    }
    return "换个关键词，或生成新的调试事件。"
  }

  private func localizedNoLevelHint() -> String {
    if currentConfig.locale.hasPrefix("en") {
      return "Select at least one level to show logs."
    }
    if currentConfig.locale.hasPrefix("ja") {
      return "少なくとも 1 つのレベルを選択してください。"
    }
    if currentConfig.locale == "zh-TW" {
      return "至少選擇一個級別。"
    }
    return "至少选择一个日志级别。"
  }

  private func localizedNoLogOriginHint() -> String {
    if currentConfig.locale.hasPrefix("en") {
      return "Select JS or native to show logs."
    }
    if currentConfig.locale.hasPrefix("ja") {
      return "JS または native を選択してください。"
    }
    if currentConfig.locale == "zh-TW" {
      return "請選擇 JS 或 native 日誌。"
    }
    return "请选择 JS 或 native 日志。"
  }

  private func localizedNoNetworkOriginHint() -> String {
    if currentConfig.locale.hasPrefix("en") {
      return "Select JS or native to show network entries."
    }
    if currentConfig.locale.hasPrefix("ja") {
      return "JS または native を選択してください。"
    }
    if currentConfig.locale == "zh-TW" {
      return "請選擇 JS 或 native 網路請求。"
    }
    return "请选择 JS 或 native 网络请求。"
  }

  private func localizedNoNetworkResultTitle() -> String {
    if currentConfig.locale.hasPrefix("en") {
      return "No matching network requests found"
    }
    if currentConfig.locale.hasPrefix("ja") {
      return "一致する通信が見つかりません"
    }
    if currentConfig.locale == "zh-TW" {
      return "未找到符合的網路請求"
    }
    return "未找到匹配的网络请求"
  }

  private func logDetailBody(for entry: DebugLogEntry) -> String {
    var metadataLines = ["timestamp: \(entry.fullTimestamp)"]
    if let context = entry.context, !context.isEmpty {
      metadataLines.append("context: \(context)")
    }
    if let details = entry.details, !details.isEmpty {
      metadataLines.append(details)
    }
    return metadataLines.joined(separator: "\n") + "\n\n" + entry.message
  }

  @objc private func closeTapped() {
    dismiss(animated: true)
  }

  @objc private func handleSegmentChange(_ sender: UISegmentedControl) {
    activeTab = ActiveTab(rawValue: sender.selectedSegmentIndex) ?? .logs
    if activeTab == .network && !currentConfig.enableNetworkTab {
      activeTab = .logs
    }
    syncNativeCaptureStates()
    reloadFromStore()
  }

  @objc private func searchTextChanged(_ sender: UITextField) {
    searchText = sender.text ?? ""
    reloadFromStore()
  }

  @objc private func clearTapped() {
    InAppDebuggerStore.shared.clear(kind: activeTab == .logs ? "logs" : "network")
    if activeTab == .network && selectedNetworkOrigins.contains("js") {
      InAppDebuggerNativeWebSocketCapture.shared.refreshVisibleEntries()
    }
  }

  @objc private func sortToggleTapped() {
    sortAscending.toggle()
    reloadFromStore()
  }


  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if activeTab == .logs {
      guard displayedLogs.indices.contains(indexPath.row) else {
        return
      }
      let entry = displayedLogs[indexPath.row]
      let detail = InAppDebuggerTextDetailViewController(
        titleText: "[\(localizedOriginTitle(entry.origin, strings: strings))] [\(entry.type.uppercased())] \(entry.timestamp)",
        bodyText: logDetailBody(for: entry)
      )
      navigationController?.pushViewController(detail, animated: true)
    } else {
      guard displayedNetwork.indices.contains(indexPath.row) else {
        return
      }
      let entry = displayedNetwork[indexPath.row]
      let detail = InAppDebuggerNetworkDetailViewController(entry: entry, strings: strings)
      navigationController?.pushViewController(detail, animated: true)
    }
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    guard scrollView === tableView else {
      return
    }
    suspendLiveUpdatesForScrollIfNeeded()
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    guard scrollView === tableView, !decelerate else {
      return
    }
    resumeLiveUpdatesAfterScrollIfNeeded()
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    guard scrollView === tableView else {
      return
    }
    resumeLiveUpdatesAfterScrollIfNeeded()
  }

  private func copy(text: String, successKey: String) {
    UIPasteboard.general.string = text
    showToast(message: strings[successKey] ?? "已复制")
  }
}

private final class InAppDebuggerLogCell: UITableViewCell {
  static let reuseIdentifier = "InAppDebuggerLogCell"

  private let cardView = UIView()
  private let accentView = UIView()
  private let originLabel = InAppDebuggerPaddedLabel()
  private let levelLabel = InAppDebuggerPaddedLabel()
  private let timeLabel = UILabel()
  private let contextLabel = UILabel()
  private let messageLabel = UILabel()
  private let copyButton = UIButton(type: .system)
  private var onCopy: (() -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    buildUI()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onCopy = nil
  }

  func configure(entry: DebugLogEntry, strings: [String: String], onCopy: @escaping () -> Void) {
    self.onCopy = onCopy
    let tone = toneForLogLevel(entry.type)
    accentView.backgroundColor = tone.foreground
    originLabel.text = localizedOriginTitle(entry.origin, strings: strings)
    originLabel.textColor = isNativeOrigin(entry.origin) ? .white : PanelColors.mutedText
    originLabel.backgroundColor = isNativeOrigin(entry.origin) ? PanelColors.primary : PanelColors.controlBackground
    levelLabel.text = entry.type.uppercased()
    levelLabel.textColor = tone.foreground
    levelLabel.backgroundColor = tone.background
    timeLabel.text = entry.timestamp
    let contextText = entry.context ?? ""
    contextLabel.text = contextText
    contextLabel.isHidden = entry.origin != "native" || contextText.isEmpty
    messageLabel.text = entry.message
    copyButton.tintColor = tone.foreground
    copyButton.accessibilityLabel = strings["copySingleA11y"] ?? "复制该条日志"
  }

  private func buildUI() {
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    selectionStyle = .none

    cardView.backgroundColor = PanelColors.card
    cardView.layer.cornerRadius = 8
    cardView.layer.borderWidth = 1
    cardView.layer.borderColor = PanelColors.border.cgColor
    cardView.layer.masksToBounds = true
    contentView.addSubview(cardView)

    originLabel.font = .systemFont(ofSize: 11, weight: .bold)
    originLabel.layer.cornerRadius = 8
    originLabel.layer.masksToBounds = true

    levelLabel.font = .systemFont(ofSize: 12, weight: .bold)
    levelLabel.layer.cornerRadius = 8
    levelLabel.layer.masksToBounds = true

    timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    timeLabel.textColor = PanelColors.mutedText
    timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    contextLabel.font = .systemFont(ofSize: 11, weight: .medium)
    contextLabel.textColor = PanelColors.mutedText
    contextLabel.numberOfLines = 1
    contextLabel.lineBreakMode = .byTruncatingMiddle

    messageLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    messageLabel.textColor = PanelColors.text
    messageLabel.numberOfLines = 4
    messageLabel.lineBreakMode = .byTruncatingTail

    var copyConfig = UIButton.Configuration.plain()
    copyConfig.image = UIImage(systemName: "doc.on.doc")
    copyConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
    copyButton.configuration = copyConfig
    copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

    let headerStack = UIStackView(arrangedSubviews: [originLabel, levelLabel, timeLabel, UIView(), copyButton])
    headerStack.axis = .horizontal
    headerStack.alignment = .center
    headerStack.spacing = 8

    let bodyStack = UIStackView(arrangedSubviews: [headerStack, contextLabel, messageLabel])
    bodyStack.axis = .vertical
    bodyStack.spacing = 8

    cardView.addSubview(accentView)
    cardView.addSubview(bodyStack)

    cardView.translatesAutoresizingMaskIntoConstraints = false
    accentView.translatesAutoresizingMaskIntoConstraints = false
    bodyStack.translatesAutoresizingMaskIntoConstraints = false
    copyButton.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
      cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

      accentView.topAnchor.constraint(equalTo: cardView.topAnchor),
      accentView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
      accentView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
      accentView.widthAnchor.constraint(equalToConstant: 4),

      bodyStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
      bodyStack.leadingAnchor.constraint(equalTo: accentView.trailingAnchor, constant: 12),
      bodyStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
      bodyStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),

      copyButton.widthAnchor.constraint(equalToConstant: 30),
      copyButton.heightAnchor.constraint(equalToConstant: 30),
    ])
  }

  @objc private func copyTapped() {
    onCopy?()
  }
}

private final class InAppDebuggerNetworkCell: UITableViewCell {
  static let reuseIdentifier = "InAppDebuggerNetworkCell"

  private let cardView = UIView()
  private let accentView = UIView()
  private let originLabel = InAppDebuggerPaddedLabel()
  private let methodLabel = InAppDebuggerPaddedLabel()
  private let statusLabel = InAppDebuggerPaddedLabel()
  private let stateLabel = UILabel()
  private let urlLabel = UILabel()
  private let durationLabel = UILabel()
  private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    buildUI()
  }

  required init?(coder: NSCoder) {
    nil
  }

  func configure(entry: DebugNetworkEntry, strings: [String: String]) {
    let tone = toneForNetwork(entry)
    accentView.backgroundColor = tone.foreground
    originLabel.text = localizedOriginTitle(entry.origin, strings: strings)
    originLabel.textColor = isNativeOrigin(entry.origin) ? .white : PanelColors.mutedText
    originLabel.backgroundColor = isNativeOrigin(entry.origin) ? PanelColors.primary : PanelColors.controlBackground
    methodLabel.text = entry.method.uppercased()
    methodLabel.textColor = PanelColors.primary
    methodLabel.backgroundColor = UIColor(red: 0.89, green: 0.96, blue: 0.94, alpha: 1)
    statusLabel.text = entry.status.map(String.init) ?? (entry.kind == "websocket" ? "WS" : entry.kind.uppercased())
    statusLabel.textColor = tone.foreground
    statusLabel.backgroundColor = tone.background
    stateLabel.text = entry.state.uppercased()
    urlLabel.text = entry.url
    if entry.kind == "websocket" {
      let incoming = entry.messageCountIn ?? 0
      let outgoing = entry.messageCountOut ?? 0
      durationLabel.text = "\(strings["duration"] ?? "耗时") \(entry.durationMs.map { "\($0)ms" } ?? "-") · IN \(incoming) / OUT \(outgoing)"
    } else {
      durationLabel.text = "\(strings["duration"] ?? "耗时") \(entry.durationMs.map { "\($0)ms" } ?? "-")"
    }
  }

  private func buildUI() {
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    selectionStyle = .none

    cardView.backgroundColor = PanelColors.card
    cardView.layer.cornerRadius = 8
    cardView.layer.borderWidth = 1
    cardView.layer.borderColor = PanelColors.border.cgColor
    cardView.layer.masksToBounds = true
    contentView.addSubview(cardView)

    originLabel.font = .systemFont(ofSize: 11, weight: .bold)
    originLabel.layer.cornerRadius = 8
    originLabel.layer.masksToBounds = true

    methodLabel.font = .systemFont(ofSize: 12, weight: .bold)
    methodLabel.layer.cornerRadius = 8
    methodLabel.layer.masksToBounds = true

    statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
    statusLabel.layer.cornerRadius = 8
    statusLabel.layer.masksToBounds = true

    stateLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    stateLabel.textColor = PanelColors.mutedText

    urlLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    urlLabel.textColor = PanelColors.text
    urlLabel.numberOfLines = 2
    urlLabel.lineBreakMode = .byTruncatingMiddle

    durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    durationLabel.textColor = PanelColors.mutedText

    chevronView.tintColor = PanelColors.mutedText
    chevronView.setContentHuggingPriority(.required, for: .horizontal)

    let headerStack = UIStackView(arrangedSubviews: [originLabel, methodLabel, statusLabel, stateLabel, UIView(), chevronView])
    headerStack.axis = .horizontal
    headerStack.alignment = .center
    headerStack.spacing = 8

    let bodyStack = UIStackView(arrangedSubviews: [headerStack, urlLabel, durationLabel])
    bodyStack.axis = .vertical
    bodyStack.spacing = 8

    cardView.addSubview(accentView)
    cardView.addSubview(bodyStack)

    cardView.translatesAutoresizingMaskIntoConstraints = false
    accentView.translatesAutoresizingMaskIntoConstraints = false
    bodyStack.translatesAutoresizingMaskIntoConstraints = false
    chevronView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
      cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

      accentView.topAnchor.constraint(equalTo: cardView.topAnchor),
      accentView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
      accentView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
      accentView.widthAnchor.constraint(equalToConstant: 4),

      bodyStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
      bodyStack.leadingAnchor.constraint(equalTo: accentView.trailingAnchor, constant: 12),
      bodyStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
      bodyStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),

      chevronView.widthAnchor.constraint(equalToConstant: 10),
      chevronView.heightAnchor.constraint(equalToConstant: 16),
    ])
  }
}

private final class InAppDebuggerEmptyStateView: UIView {
  private let titleLabel = UILabel()
  private let detailLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    buildUI()
  }

  required init?(coder: NSCoder) {
    nil
  }

  func configure(title: String, detail: String) {
    titleLabel.text = title
    detailLabel.text = detail
  }

  private func buildUI() {
    titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
    titleLabel.textColor = PanelColors.text
    titleLabel.textAlignment = .center

    detailLabel.font = .systemFont(ofSize: 13, weight: .regular)
    detailLabel.textColor = PanelColors.mutedText
    detailLabel.textAlignment = .center
    detailLabel.numberOfLines = 0

    let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 8
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
    ])
  }
}


private final class InAppDebuggerPaddedLabel: UILabel {
  var contentInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(
      width: size.width + contentInsets.left + contentInsets.right,
      height: size.height + contentInsets.top + contentInsets.bottom
    )
  }

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: contentInsets))
  }
}

final class InAppDebuggerTextDetailViewController: UIViewController {
  private let bodyText: String

  init(titleText: String, bodyText: String) {
    self.bodyText = bodyText
    super.init(nibName: nil, bundle: nil)
    title = titleText
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = PanelColors.background
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "doc.on.doc"),
      style: .plain,
      target: self,
      action: #selector(copyTapped)
    )

    let textView = UITextView()
    textView.text = bodyText
    textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textColor = PanelColors.text
    textView.backgroundColor = PanelColors.card
    textView.isEditable = false
    textView.alwaysBounceVertical = true
    textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    textView.layer.cornerRadius = 8
    textView.layer.borderColor = PanelColors.border.cgColor
    textView.layer.borderWidth = 1
    view.addSubview(textView)
    textView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  @objc private func copyTapped() {
    UIPasteboard.general.string = bodyText
    showToast(message: "已复制")
  }
}

final class InAppDebuggerNetworkDetailViewController: UIViewController {
  private struct ParsedMessageHeader {
    let timestamp: String?
    let direction: String?
    let kind: String?
    let remainder: String
  }

  private struct ParsedMessageBlock {
    let timestamp: String?
    let direction: String?
    let kind: String?
    let metadata: String?
    let payload: String?
  }

  private struct SectionBodyPresentation {
    let displayedText: String
    let copyText: String?
    let attributedText: NSAttributedString?
    let usesCodeBlockStyle: Bool
  }

  private let entryId: String
  private var entry: DebugNetworkEntry
  private let strings: [String: String]
  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private var notificationObserver: NSObjectProtocol?

  init(entry: DebugNetworkEntry, strings: [String: String]) {
    self.entryId = entry.id
    self.entry = entry
    self.strings = strings
    super.init(nibName: nil, bundle: nil)
    title = strings["requestDetails"] ?? "请求详情"
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = PanelColors.background

    stack.axis = .vertical
    stack.spacing = 10
    view.addSubview(scrollView)
    scrollView.addSubview(stack)
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -14),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
      stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -28),
    ])

    if let latestEntry = InAppDebuggerStore.shared.snapshotState().3.first(where: { $0.id == entryId }) {
      entry = latestEntry
    }
    renderSections()

    notificationObserver = NotificationCenter.default.addObserver(
      forName: .inAppDebuggerStoreDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.reloadEntryFromStore()
    }
  }

  deinit {
    if let notificationObserver {
      NotificationCenter.default.removeObserver(notificationObserver)
    }
  }

  private func reloadEntryFromStore() {
    let state = InAppDebuggerStore.shared.snapshotState()
    guard let latestEntry = state.3.first(where: { $0.id == entryId }),
          latestEntry != entry else {
      return
    }
    entry = latestEntry
    renderSections()
  }

  private func renderSections() {
    for arrangedSubview in stack.arrangedSubviews {
      stack.removeArrangedSubview(arrangedSubview)
      arrangedSubview.removeFromSuperview()
    }

    let sections = entry.kind == "websocket"
      ? webSocketSections()
      : httpSections()

    let messagesTitle = strings["messages"] ?? "消息"
    let noMessagesText = strings["noMessages"] ?? "暂无消息"

    sections.forEach { title, body, monospace in
      if entry.kind == "websocket", title == messagesTitle {
        stack.addArrangedSubview(
          makeWebSocketMessagesSection(title: title, raw: entry.messages, fallback: noMessagesText)
        )
      } else {
        stack.addArrangedSubview(makeSection(title: title, body: body, monospace: monospace))
      }
    }

    if let error = entry.error, !error.isEmpty {
      stack.addArrangedSubview(makeSection(title: "错误", body: error, monospace: true))
    }
  }

  private func httpSections() -> [(title: String, body: String, monospace: Bool)] {
    let durationText = entry.durationMs.map { "\($0)ms" } ?? "-"
    let noRequestBodyText = strings["noRequestBody"] ?? "无请求体"
    let noResponseBodyText = strings["noResponseBody"] ?? "无响应体"
    let noMessagesText = strings["noMessages"] ?? "暂无消息"

    return [
      (title: strings["origin"] ?? "来源", body: localizedOriginTitle(entry.origin, strings: strings), monospace: false),
      (title: strings["method"] ?? "方法", body: entry.method, monospace: false),
      (title: strings["status"] ?? "状态码", body: entry.status.map(String.init) ?? "-", monospace: false),
      (title: strings["state"] ?? "状态", body: entry.state, monospace: false),
      (title: strings["protocol"] ?? "协议", body: entry.`protocol` ?? "-", monospace: false),
      (title: "URL", body: entry.url, monospace: true),
      (title: strings["duration"] ?? "耗时", body: durationText, monospace: false),
      (title: strings["requestHeaders"] ?? "请求头", body: headerText(entry.requestHeaders), monospace: true),
      (title: strings["responseHeaders"] ?? "响应头", body: headerText(entry.responseHeaders), monospace: true),
      (title: strings["requestBody"] ?? "请求体", body: entry.requestBody ?? noRequestBodyText, monospace: true),
      (title: strings["responseBody"] ?? "响应体", body: entry.responseBody ?? noResponseBodyText, monospace: true),
      (title: strings["messages"] ?? "消息", body: formattedMessagesText(entry.messages, fallback: noMessagesText), monospace: true),
    ]
  }

  private func webSocketSections() -> [(title: String, body: String, monospace: Bool)] {
    let durationText = entry.durationMs.map { "\($0)ms" } ?? "-"
    let noMessagesText = strings["noMessages"] ?? "暂无消息"
    let noEventsText = "暂无事件"
    let messageSummary = "IN \(entry.messageCountIn ?? 0) / OUT \(entry.messageCountOut ?? 0)"
    let byteSummary = "IN \(formatNetworkByteCount(entry.bytesIn)) / OUT \(formatNetworkByteCount(entry.bytesOut))"

    var sections: [(title: String, body: String, monospace: Bool)] = [
      (title: strings["origin"] ?? "来源", body: localizedOriginTitle(entry.origin, strings: strings), monospace: false),
      (title: strings["method"] ?? "方法", body: entry.method, monospace: false),
      (title: strings["state"] ?? "状态", body: entry.state, monospace: false),
      (title: strings["protocol"] ?? "协议", body: entry.`protocol` ?? "-", monospace: false),
      (title: "Requested protocols", body: entry.requestedProtocols ?? "-", monospace: false),
      (title: "URL", body: entry.url, monospace: true),
      (title: strings["duration"] ?? "耗时", body: durationText, monospace: false),
      (title: "Messages", body: messageSummary, monospace: false),
      (title: "Bytes", body: byteSummary, monospace: false),
      (title: strings["requestHeaders"] ?? "请求头", body: headerText(entry.requestHeaders), monospace: true),
    ]

    if !entry.responseHeaders.isEmpty {
      sections.append((title: strings["responseHeaders"] ?? "响应头", body: headerText(entry.responseHeaders), monospace: true))
    }

    if let status = entry.status {
      sections.append((title: strings["status"] ?? "状态码", body: String(status), monospace: false))
    }

    if entry.requestedCloseCode != nil || (entry.requestedCloseReason?.isEmpty == false) {
      sections.append((title: "Close requested", body: closeRequestSummary(), monospace: false))
    }

    if entry.closeCode != nil || entry.cleanClose != nil || (entry.closeReason?.isEmpty == false) {
      sections.append((title: "Close result", body: closeResultSummary(), monospace: false))
    }

    sections.append((title: "Event timeline", body: entry.events ?? noEventsText, monospace: true))
    sections.append((title: strings["messages"] ?? "消息", body: formattedMessagesText(entry.messages, fallback: noMessagesText), monospace: true))
    return sections
  }

  private func headerText(_ headers: [String: String]) -> String {
    headers
      .map { "\($0.key): \($0.value)" }
      .joined(separator: "\n")
      .ifEmpty("-")
  }

  private func closeRequestSummary() -> String {
    let code = entry.requestedCloseCode.map(String.init) ?? "-"
    let reason = entry.requestedCloseReason?.ifEmpty("-") ?? "-"
    return "code: \(code)\nreason: \(reason)"
  }

  private func closeResultSummary() -> String {
    let code = entry.closeCode.map(String.init) ?? "-"
    let reason = entry.closeReason?.ifEmpty("-") ?? "-"
    let clean = entry.cleanClose.map { $0 ? "true" : "false" } ?? "-"
    return "code: \(code)\nclean: \(clean)\nreason: \(reason)"
  }

  private func formattedMessagesText(_ raw: String?, fallback: String) -> String {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return fallback
    }

    let normalizedRaw = normalizedPlainText(raw)
    let blocks = messageBlocks(from: normalizedRaw)
      .map(formatMessageBlock)
      .filter { !$0.isEmpty }

    guard !blocks.isEmpty else {
      return normalizedRaw
    }
    return blocks.joined(separator: "\n\n")
  }

  private func parsedMessageBlocks(from raw: String?) -> [ParsedMessageBlock] {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return []
    }

    let normalizedRaw = normalizedPlainText(raw)
    return messageBlocks(from: normalizedRaw)
      .compactMap(parseMessageBlock)
  }

  private func parseMessageBlock(_ lines: [String]) -> ParsedMessageBlock? {
    guard let firstLine = lines.first else {
      return nil
    }

    let header = parseMessageHeader(firstLine)
    let combinedBody = ([header.remainder] + Array(lines.dropFirst()))
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let (metadata, payload) = splitMessageMetadataAndPayload(combinedBody)

    let normalizedMetadata = metadata?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedPayload = payload?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasHeader = header.timestamp != nil || header.direction != nil || header.kind != nil
    let hasBody = normalizedMetadata?.isEmpty == false || normalizedPayload?.isEmpty == false
    guard hasHeader || hasBody else {
      return nil
    }

    return ParsedMessageBlock(
      timestamp: header.timestamp,
      direction: header.direction,
      kind: header.kind?.uppercased(),
      metadata: normalizedMetadata?.isEmpty == true ? nil : normalizedMetadata,
      payload: normalizedPayload?.isEmpty == true ? nil : normalizedPayload
    )
  }

  private func messageBlocks(from raw: String) -> [[String]] {
    let lines = raw.components(separatedBy: .newlines)
    var blocks: [[String]] = []
    var current: [String] = []

    for line in lines {
      if isMessageBoundary(line) {
        if !current.isEmpty {
          blocks.append(current)
        }
        current = [line]
        continue
      }

      if current.isEmpty {
        if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          current = [line]
        }
        continue
      }

      current.append(line)
    }

    if !current.isEmpty {
      blocks.append(current)
    }
    return blocks
  }

  private func isMessageBoundary(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      return false
    }
    if trimmed.hasPrefix(">> ") || trimmed == ">>" || trimmed.hasPrefix("<< ") || trimmed == "<<" {
      return true
    }
    return trimmed.range(
      of: #"^\[?\d{2}:\d{2}:\d{2}\.\d{3}\]?\s+(>>|<<)(?:\s|$)"#,
      options: .regularExpression
    ) != nil || trimmed.range(
      of: #"^\[?\d{2}:\d{2}:\d{2}\.\d{3}\]?\s*$"#,
      options: .regularExpression
    ) != nil
  }

  private func formatMessageBlock(_ lines: [String]) -> String {
    guard let firstLine = lines.first else {
      return ""
    }

    let header = parseMessageHeader(firstLine)
    let combinedBody = ([header.remainder] + Array(lines.dropFirst()))
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let (metadata, payload) = splitMessageMetadataAndPayload(combinedBody)

    var headerParts: [String] = []
    if let timestamp = header.timestamp {
      headerParts.append("[\(timestamp)]")
    }
    if let direction = header.direction {
      headerParts.append(direction)
    }
    if let kind = header.kind {
      headerParts.append(kind.uppercased())
    }
    if let metadata, !metadata.isEmpty {
      headerParts.append("(\(metadata))")
    }

    var blockLines: [String] = []
    let headerLine = headerParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    if !headerLine.isEmpty {
      blockLines.append(headerLine)
    }

    if let payload, !payload.isEmpty {
      blockLines.append(payload)
    } else if headerLine.isEmpty {
      blockLines.append(combinedBody)
    }

    return blockLines.joined(separator: "\n")
  }

  private func parseMessageHeader(_ line: String) -> ParsedMessageHeader {
    var working = line.trimmingCharacters(in: .whitespacesAndNewlines)
    var timestamp: String?
    var direction: String?
    var kind: String?

    if working.hasPrefix("["),
       let closingBracket = working.firstIndex(of: "]") {
      let candidate = String(working[working.index(after: working.startIndex)..<closingBracket])
      if candidate.range(of: #"^\d{2}:\d{2}:\d{2}\.\d{3}$"#, options: .regularExpression) != nil {
        timestamp = candidate
        working = String(working[working.index(after: closingBracket)...]).trimmingCharacters(in: .whitespaces)
      }
    }

    if timestamp == nil,
       let match = working.range(
         of: #"^\d{2}:\d{2}:\d{2}\.\d{3}"#,
         options: .regularExpression
       ) {
      timestamp = String(working[match])
      working = String(working[match.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    if working.hasPrefix(">>") {
      direction = ">>"
      working = String(working.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    } else if working.hasPrefix("<<") {
      direction = "<<"
      working = String(working.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    if let firstToken = working.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first {
      let token = String(firstToken)
      if ["text", "binary", "unknown"].contains(token.lowercased()) {
        kind = token
        working = String(working.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
      }
    }

    return ParsedMessageHeader(
      timestamp: timestamp,
      direction: direction,
      kind: kind,
      remainder: working
    )
  }

  private func makeWebSocketMessagesSection(title: String, raw: String?, fallback: String) -> UIView {
    let maxMessagesHeight: CGFloat = 360
    let container = UIView()
    container.backgroundColor = PanelColors.card
    container.layer.cornerRadius = 8
    container.layer.borderWidth = 1
    container.layer.borderColor = PanelColors.border.cgColor

    let titleLabel = UILabel()
    titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
    titleLabel.textColor = PanelColors.text
    titleLabel.text = title

    let contentStack = UIStackView()
    contentStack.axis = .vertical
    contentStack.spacing = 10

    let blocks = parsedMessageBlocks(from: raw)
    if blocks.isEmpty {
      contentStack.addArrangedSubview(makeSectionBodyView(body: fallback, monospace: true))
    } else {
      blocks.forEach { block in
        contentStack.addArrangedSubview(makeWebSocketMessageBlockView(block))
      }
    }

    let scrollContentView = UIView()
    let scrollView = UIScrollView()
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = true
    scrollView.delaysContentTouches = false
    scrollView.clipsToBounds = true
    scrollView.addSubview(scrollContentView)
    scrollContentView.addSubview(contentStack)
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollContentView.translatesAutoresizingMaskIntoConstraints = false
    contentStack.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      scrollView.heightAnchor.constraint(equalToConstant: maxMessagesHeight),
      scrollContentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      scrollContentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      scrollContentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      scrollContentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      scrollContentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      contentStack.topAnchor.constraint(equalTo: scrollContentView.topAnchor),
      contentStack.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor),
      contentStack.bottomAnchor.constraint(equalTo: scrollContentView.bottomAnchor),
    ])

    let stack = UIStackView(arrangedSubviews: [titleLabel, scrollView])
    stack.axis = .vertical
    stack.spacing = 10
    container.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
    ])

    return container
  }

  private func makeWebSocketMessageBlockView(_ block: ParsedMessageBlock) -> UIView {
    let container = UIView()
    container.backgroundColor = UIColor(red: 0.985, green: 0.99, blue: 1.00, alpha: 1)
    container.layer.cornerRadius = 8
    container.layer.borderWidth = 1
    container.layer.borderColor = UIColor(red: 0.80, green: 0.87, blue: 1.00, alpha: 1).cgColor

    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 6

    let headerLine = messageHeaderLine(for: block)
    if !headerLine.isEmpty {
      let headerLabel = UILabel()
      headerLabel.numberOfLines = 0
      headerLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
      headerLabel.textColor = PanelColors.text
      headerLabel.text = headerLine
      stack.addArrangedSubview(headerLabel)
    }

    if let metadata = block.metadata, !metadata.isEmpty {
      let metadataLabel = UILabel()
      metadataLabel.numberOfLines = 0
      metadataLabel.font = .systemFont(ofSize: 11, weight: .medium)
      metadataLabel.textColor = PanelColors.mutedText
      metadataLabel.text = metadata
      stack.addArrangedSubview(metadataLabel)
    }

    if let payload = block.payload, !payload.isEmpty {
      stack.addArrangedSubview(makeSectionBodyView(body: payload, monospace: true))
    }

    container.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
    ])

    return container
  }

  private func messageHeaderLine(for block: ParsedMessageBlock) -> String {
    var parts: [String] = []

    if let timestamp = block.timestamp, !timestamp.isEmpty {
      parts.append("[\(timestamp)]")
    }
    if let direction = block.direction, !direction.isEmpty {
      parts.append(direction)
    }
    if let kind = block.kind, !kind.isEmpty {
      parts.append(kind)
    }

    return parts.joined(separator: " ")
  }

  private func splitMessageMetadataAndPayload(_ body: String) -> (String?, String?) {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return (nil, nil)
    }

    if let prettyJSON = prettyPrintedJSON(trimmed) {
      return (nil, prettyJSON)
    }

    if let structuredStart = firstStructuredPayloadStart(in: trimmed) {
      let metadata = String(trimmed[..<structuredStart]).trimmingCharacters(in: .whitespacesAndNewlines)
      let payload = String(trimmed[structuredStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
      if let prettyJSON = prettyPrintedJSON(payload) {
        return (metadata.ifEmpty(""), prettyJSON)
      }
    }

    return (nil, normalizedPlainText(trimmed))
  }

  private func firstStructuredPayloadStart(in text: String) -> String.Index? {
    let objectIndex = text.firstIndex(of: "{")
    let arrayIndex = text.firstIndex(of: "[")
    switch (objectIndex, arrayIndex) {
    case let (.some(object), .some(array)):
      return min(object, array)
    case let (.some(object), .none):
      return object
    case let (.none, .some(array)):
      return array
    case (.none, .none):
      return nil
    }
  }

  private func prettyPrintedJSON(_ text: String) -> String? {
    let rawTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawTrimmed.isEmpty else {
      return nil
    }

    if let prettyObject = prettyPrintedJSONObjectOrArray(rawTrimmed) {
      return prettyObject
    }

    if let decodedString = decodedJSONStringValue(rawTrimmed),
       let prettyObject = prettyPrintedJSONObjectOrArray(decodedString.trimmingCharacters(in: .whitespacesAndNewlines)) {
      return prettyObject
    }

    if let structuredJSON = extractedStructuredJSON(from: rawTrimmed),
       let prettyObject = prettyPrintedJSONObjectOrArray(structuredJSON) {
      return prettyObject
    }

    let normalizedTrimmed = normalizedPlainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedTrimmed != rawTrimmed else {
      return nil
    }

    if let prettyObject = prettyPrintedJSONObjectOrArray(normalizedTrimmed) {
      return prettyObject
    }

    if let decodedString = decodedJSONStringValue(normalizedTrimmed),
       let prettyObject = prettyPrintedJSONObjectOrArray(decodedString.trimmingCharacters(in: .whitespacesAndNewlines)) {
      return prettyObject
    }

    if let structuredJSON = extractedStructuredJSON(from: normalizedTrimmed),
       let prettyObject = prettyPrintedJSONObjectOrArray(structuredJSON) {
      return prettyObject
    }

    return nil
  }

  private func prettyPrintedJSONObjectOrArray(_ text: String) -> String? {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          object is [Any] || object is [String: Any],
          let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
          let prettyText = String(data: prettyData, encoding: .utf8) else {
      return nil
    }
    return prettyText
  }

  private func decodedJSONStringValue(_ text: String) -> String? {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          let stringValue = object as? String else {
      return nil
    }
    return stringValue
  }

  private func extractedStructuredJSON(from text: String) -> String? {
    guard let start = firstStructuredPayloadStart(in: text) else {
      return nil
    }
    let candidate = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else {
      return nil
    }
    return candidate
  }

  private func normalizedPlainText(_ text: String) -> String {
    if text.contains("\\n") || text.contains("\\r") || text.contains("\\t") {
      return text
        .replacingOccurrences(of: "\\r\\n", with: "\n")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\r", with: "\n")
        .replacingOccurrences(of: "\\t", with: "  ")
    }
    return text
  }

  private func sectionBodyPresentation(body: String, monospace: Bool) -> SectionBodyPresentation {
    guard monospace else {
      return SectionBodyPresentation(
        displayedText: body,
        copyText: nil,
        attributedText: nil,
        usesCodeBlockStyle: false
      )
    }

    let normalizedBody = normalizedPlainText(body)
    let attributedJSON = jsonCodeAttributedText(from: body) ?? jsonCodeAttributedText(from: normalizedBody)
    if let attributedJSON {
      return SectionBodyPresentation(
        displayedText: normalizedBody,
        copyText: prettyPrintedJSON(body) ?? prettyPrintedJSON(normalizedBody) ?? normalizedBody,
        attributedText: attributedJSON,
        usesCodeBlockStyle: true
      )
    }

    return SectionBodyPresentation(
      displayedText: normalizedBody,
      copyText: nil,
      attributedText: nil,
      usesCodeBlockStyle: false
    )
  }

  private func jsonCodeAttributedText(from text: String) -> NSAttributedString? {
    guard let prettyJSON = prettyPrintedJSON(text) else {
      return nil
    }

    let codeFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let lineNumberFont = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    let lineNumberColor = UIColor(red: 0.10, green: 0.33, blue: 0.86, alpha: 1)
    let lineNumberBackground = UIColor(red: 0.92, green: 0.96, blue: 1.00, alpha: 1)
    let guideColor = UIColor(red: 0.76, green: 0.84, blue: 1.00, alpha: 1)
    let baseColor = UIColor(red: 0.14, green: 0.18, blue: 0.24, alpha: 1)
    let punctuationColor = UIColor(red: 0.24, green: 0.30, blue: 0.39, alpha: 1)
    let keyColor = UIColor(red: 0.75, green: 0.23, blue: 0.16, alpha: 1)
    let stringColor = UIColor(red: 0.66, green: 0.35, blue: 0.08, alpha: 1)
    let numberColor = UIColor(red: 0.11, green: 0.43, blue: 0.87, alpha: 1)
    let literalColor = UIColor(red: 0.01, green: 0.53, blue: 0.42, alpha: 1)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 3
    paragraphStyle.lineBreakMode = .byCharWrapping

    let lines = prettyJSON.components(separatedBy: .newlines)
    let digits = max(2, String(lines.count).count)
    let result = NSMutableAttributedString()

    for (index, line) in lines.enumerated() {
      let lineNumber = String(format: "%\(digits)d", index + 1)
      let prefix = " \(lineNumber) │ "
      let prefixAttributes: [NSAttributedString.Key: Any] = [
        .font: lineNumberFont,
        .foregroundColor: lineNumberColor,
        .backgroundColor: lineNumberBackground,
        .paragraphStyle: paragraphStyle,
      ]
      result.append(NSAttributedString(string: prefix, attributes: prefixAttributes))

      let lineAttributes: [NSAttributedString.Key: Any] = [
        .font: codeFont,
        .foregroundColor: baseColor,
        .paragraphStyle: paragraphStyle,
      ]
      let lineAttributed = NSMutableAttributedString(string: line, attributes: lineAttributes)
      highlightJSONStringTokens(
        in: lineAttributed,
        keyColor: keyColor,
        stringColor: stringColor,
        numberColor: numberColor,
        literalColor: literalColor,
        punctuationColor: punctuationColor,
        guideColor: guideColor,
        font: codeFont
      )
      result.append(lineAttributed)

      if index < lines.count - 1 {
        result.append(NSAttributedString(string: "\n", attributes: lineAttributes))
      }
    }

    return result
  }

  private func highlightJSONStringTokens(
    in attributedString: NSMutableAttributedString,
    keyColor: UIColor,
    stringColor: UIColor,
    numberColor: UIColor,
    literalColor: UIColor,
    punctuationColor: UIColor,
    guideColor: UIColor,
    font: UIFont
  ) {
    applyRegex(
      #"[{}\[\],:]"#,
      to: attributedString,
      attributes: [
        .foregroundColor: punctuationColor,
        .font: font,
      ]
    )

    applyRegex(
      #"^(?:  )+"#,
      to: attributedString,
      attributes: [
        .foregroundColor: guideColor,
        .font: font,
      ]
    )

    applyRegex(
      #""(?:\\.|[^"\\])*""#,
      to: attributedString,
      attributes: [
        .foregroundColor: stringColor,
        .font: font,
      ]
    )

    applyRegex(
      #""(?:\\.|[^"\\])*"(?=\s*:)"#,
      to: attributedString,
      attributes: [
        .foregroundColor: keyColor,
        .font: font,
      ]
    )

    applyRegex(
      #"(?<![A-Za-z0-9_])[-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#,
      to: attributedString,
      attributes: [
        .foregroundColor: numberColor,
        .font: font,
      ]
    )

    applyRegex(
      #"\b(?:true|false|null)\b"#,
      to: attributedString,
      attributes: [
        .foregroundColor: literalColor,
        .font: font,
      ]
    )
  }

  private func applyRegex(
    _ pattern: String,
    to attributedString: NSMutableAttributedString,
    attributes: [NSAttributedString.Key: Any]
  ) {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return
    }
    let range = NSRange(location: 0, length: attributedString.string.utf16.count)
    regex.enumerateMatches(in: attributedString.string, options: [], range: range) { match, _, _ in
      guard let match else {
        return
      }
      attributedString.addAttributes(attributes, range: match.range)
    }
  }

  private func makeSectionBodyView(body: String, monospace: Bool) -> UIView {
    let bodyTextView = InAppDebuggerSelectableTextView()
    let presentation = sectionBodyPresentation(body: body, monospace: monospace)
    bodyTextView.font = monospace
      ? .monospacedSystemFont(ofSize: 12, weight: .regular)
      : .systemFont(ofSize: 13, weight: .regular)
    bodyTextView.textColor = PanelColors.text
    bodyTextView.overrideCopyText = presentation.copyText
    bodyTextView.textContainer.lineBreakMode = presentation.usesCodeBlockStyle
      ? .byCharWrapping
      : .byWordWrapping
    if let attributedText = presentation.attributedText {
      bodyTextView.attributedText = attributedText
    } else {
      bodyTextView.text = presentation.displayedText
    }
    if presentation.usesCodeBlockStyle {
      bodyTextView.backgroundColor = UIColor(red: 0.985, green: 0.99, blue: 1.00, alpha: 1)
      bodyTextView.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 12)
      bodyTextView.layer.cornerRadius = 8
      bodyTextView.layer.borderWidth = 1
      bodyTextView.layer.borderColor = UIColor(red: 0.80, green: 0.87, blue: 1.00, alpha: 1).cgColor
    } else {
      bodyTextView.backgroundColor = .clear
      bodyTextView.textContainerInset = .zero
      bodyTextView.layer.cornerRadius = 0
      bodyTextView.layer.borderWidth = 0
      bodyTextView.layer.borderColor = UIColor.clear.cgColor
    }
    return bodyTextView
  }

  private func makeSection(title: String, body: String, monospace: Bool) -> UIView {
    let container = UIView()
    container.backgroundColor = PanelColors.card
    container.layer.cornerRadius = 8
    container.layer.borderWidth = 1
    container.layer.borderColor = PanelColors.border.cgColor

    let titleLabel = UILabel()
    titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
    titleLabel.textColor = PanelColors.text
    titleLabel.text = title

    let bodyTextView = makeSectionBodyView(body: body, monospace: monospace)
    bodyTextView.accessibilityLabel = title

    let stack = UIStackView(arrangedSubviews: [titleLabel, bodyTextView])
    stack.axis = .vertical
    stack.spacing = 8
    container.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
    ])
    return container
  }
}

private extension String {
  func ifEmpty(_ fallback: String) -> String {
    isEmpty ? fallback : self
  }
}

private final class InAppDebuggerSelectableTextView: UITextView, UITextViewDelegate {
  private var lastMeasuredWidth: CGFloat = 0
  private var hasScheduledSelectionMenu = false
  var overrideCopyText: String?

  override var text: String! {
    didSet {
      invalidateIntrinsicContentSize()
    }
  }

  override var attributedText: NSAttributedString! {
    didSet {
      invalidateIntrinsicContentSize()
    }
  }

  override var intrinsicContentSize: CGSize {
    let fittingWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 52
    let size = sizeThatFits(CGSize(width: fittingWidth, height: CGFloat.greatestFiniteMagnitude))
    return CGSize(width: UIView.noIntrinsicMetric, height: ceil(size.height))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if abs(bounds.width - lastMeasuredWidth) > 0.5 {
      lastMeasuredWidth = bounds.width
      invalidateIntrinsicContentSize()
    }
  }

  override var canBecomeFirstResponder: Bool {
    true
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(copy(_:)) {
      return selectedRange.length > 0 || !(text ?? "").isEmpty
    }
    return super.canPerformAction(action, withSender: sender)
  }

  override func copy(_ sender: Any?) {
    let displayedText = text ?? attributedText?.string ?? ""
    if selectedRange.length > 0,
       let range = Range(selectedRange, in: displayedText) {
      UIPasteboard.general.string = String(displayedText[range])
    } else {
      UIPasteboard.general.string = overrideCopyText ?? displayedText
    }
  }

  init() {
    super.init(frame: .zero, textContainer: nil)
    isEditable = false
    isSelectable = true
    isScrollEnabled = false
    backgroundColor = .clear
    textContainerInset = .zero
    textContainer.lineFragmentPadding = 0
    showsVerticalScrollIndicator = false
    showsHorizontalScrollIndicator = false
    dataDetectorTypes = []
    adjustsFontForContentSizeCategory = true
    delegate = self
  }

  required init?(coder: NSCoder) {
    nil
  }

  func textViewDidChangeSelection(_ textView: UITextView) {
    guard selectedRange.length > 0 else {
      hasScheduledSelectionMenu = false
      return
    }
    guard !hasScheduledSelectionMenu else {
      return
    }

    hasScheduledSelectionMenu = true
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }
      self.hasScheduledSelectionMenu = false
      self.presentSelectionMenu()
    }
  }

  private func presentSelectionMenu() {
    guard window != nil else {
      return
    }
    becomeFirstResponder()

    let targetRect: CGRect
    if let selectedTextRange {
      let rect = firstRect(for: selectedTextRange)
      targetRect = rect.isNull || rect.isInfinite || rect.isEmpty
        ? bounds.insetBy(dx: 8, dy: 8)
        : rect
    } else {
      targetRect = bounds.insetBy(dx: 8, dy: 8)
    }

    UIMenuController.shared.showMenu(from: self, rect: targetRect)
  }
}

private extension UIViewController {
  func showToast(message: String) {
    let label = UILabel()
    label.text = message
    label.textColor = .white
    label.backgroundColor = UIColor.black.withAlphaComponent(0.76)
    label.textAlignment = .center
    label.font = .systemFont(ofSize: 14, weight: .semibold)
    label.layer.cornerRadius = 8
    label.layer.masksToBounds = true
    label.alpha = 0
    view.addSubview(label)
    label.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
      label.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
    ])
    UIView.animate(withDuration: 0.2, animations: {
      label.alpha = 1
    }, completion: { _ in
      UIView.animate(withDuration: 0.2, delay: 1.1, options: [], animations: {
        label.alpha = 0
      }, completion: { _ in
        label.removeFromSuperview()
      })
    })
  }
}
