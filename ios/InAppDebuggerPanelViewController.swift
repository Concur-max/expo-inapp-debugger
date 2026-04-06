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
  if entry.state == "pending" {
    return PanelTone(
      foreground: UIColor(red: 0.29, green: 0.36, blue: 0.45, alpha: 1),
      background: UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)
    )
  }
  if entry.state == "closed" {
    return toneForLogLevel("warn")
  }
  return toneForLogLevel("log")
}

final class InAppDebuggerPanelViewController: UIViewController, UITableViewDelegate {
  private enum ReloadReason {
    case full
    case dataOnly
  }

  private var activeTab: ActiveTab = .logs
  private var searchText = ""
  private var selectedLevels: Set<String> = ["log", "info", "warn", "error", "debug"]
  private var selectedOrigins: Set<String> = ["js", "native"]
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
    field.backgroundColor = PanelColors.card
    field.clearButtonMode = .whileEditing
    field.layer.cornerRadius = 8
    field.layer.borderColor = PanelColors.border.cgColor
    field.layer.borderWidth = 1
    field.addTarget(self, action: #selector(searchTextChanged(_:)), for: .editingChanged)
    return field
  }()

  private lazy var clearButton: UIButton = {
    let button = makeToolbarButton(title: "清空", imageName: nil, style: .neutral)
    button.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
  }()

  private let originWrapView = InAppDebuggerWrapView()
  private let filterWrapView = InAppDebuggerWrapView()

  private lazy var sortToggleButton: UIButton = {
    var config = UIButton.Configuration.tinted()
    config.title = "时间倒序"
    config.image = UIImage(systemName: "arrow.down")
    config.imagePadding = 4
    config.cornerStyle = .small
    config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9)
    config.baseForegroundColor = PanelColors.primary
    config.baseBackgroundColor = PanelColors.controlBackground
    let button = UIButton(configuration: config)
    button.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
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
    rebuildFilterButtons()
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
    InAppDebuggerNativeLogCapture.shared.setPanelActive(true)
    reloadFromStore()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    scheduledReloadWorkItem?.cancel()
    scheduledReloadWorkItem = nil
    InAppDebuggerStore.shared.setLiveUpdatesEnabled(false)
    InAppDebuggerNativeLogCapture.shared.setPanelActive(false)
    isSuspendingLiveUpdatesForScroll = false
  }

  deinit {
    scheduledReloadWorkItem?.cancel()
    InAppDebuggerStore.shared.setLiveUpdatesEnabled(false)
    InAppDebuggerNativeLogCapture.shared.setPanelActive(false)
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
    let searchRow = UIStackView(arrangedSubviews: [searchField, clearButton])
    searchRow.axis = .horizontal
    searchRow.alignment = .center
    searchRow.spacing = 8

    let sortRow = UIStackView(arrangedSubviews: [UIView(), sortToggleButton])
    sortRow.axis = .horizontal
    sortRow.alignment = .center
    sortRow.spacing = 8

    let filterGroup = UIStackView(arrangedSubviews: [originWrapView, filterWrapView, sortRow])
    filterGroup.axis = .vertical
    filterGroup.alignment = .fill
    filterGroup.spacing = 6

    let stack = UIStackView(arrangedSubviews: [segmentedControl, searchRow, filterGroup, tableView])
    stack.axis = .vertical
    stack.spacing = 10
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

      segmentedControl.heightAnchor.constraint(equalToConstant: 36),
      searchField.heightAnchor.constraint(equalToConstant: 38),
      clearButton.heightAnchor.constraint(equalToConstant: 34),
      clearButton.widthAnchor.constraint(equalToConstant: 58),
      sortToggleButton.heightAnchor.constraint(equalToConstant: 30),
    ])
  }

  private func rebuildFilterButtons() {
    let originButtons = ["js", "native"].map { makeOriginButton(origin: $0) }
    originWrapView.setArrangedSubviews(originButtons)
    let buttons = ["log", "info", "warn", "error", "debug"].map { makeLevelButton(level: $0) }
    filterWrapView.setArrangedSubviews(buttons)
    updateOriginButtonStates()
    updateFilterButtonStates()
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
      originWrapView.isHidden = activeTab != .logs
      filterWrapView.isHidden = activeTab != .logs
      updateToolbarTitles()
      updateOriginButtonStates()
      updateFilterButtonStates()
      updateSortButton()
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
      guard selectedLevels.contains(entry.type), selectedOrigins.contains(entry.origin) else {
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
      if !query.isEmpty {
        let matchesQuery =
          entry.url.localizedCaseInsensitiveContains(query) ||
          entry.method.localizedCaseInsensitiveContains(query) ||
          entry.state.localizedCaseInsensitiveContains(query)
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

  private func makeToolbarButton(title: String, imageName: String?, style: ToolbarButtonStyle) -> UIButton {
    var config = style == .primary ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
    config.title = title
    config.image = imageName.flatMap { UIImage(systemName: $0) }
    config.imagePadding = imageName == nil ? 0 : 6
    config.cornerStyle = .small
    config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
    switch style {
    case .primary:
      config.baseForegroundColor = .white
      config.baseBackgroundColor = PanelColors.primary
    case .neutral:
      config.baseForegroundColor = PanelColors.primary
      config.baseBackgroundColor = PanelColors.controlBackground
    }

    let button = UIButton(configuration: config)
    button.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
    return button
  }

  private func makeLevelButton(level: String) -> UIButton {
    let button = UIButton(type: .system)
    button.accessibilityIdentifier = level
    button.addTarget(self, action: #selector(levelTapped(_:)), for: .touchUpInside)
    button.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
    styleLevelButton(button)
    return button
  }

  private func makeOriginButton(origin: String) -> UIButton {
    let button = UIButton(type: .system)
    button.accessibilityIdentifier = origin
    button.addTarget(self, action: #selector(originTapped(_:)), for: .touchUpInside)
    button.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
    styleOriginButton(button)
    return button
  }

  private func styleOriginButton(_ button: UIButton) {
    guard let origin = button.accessibilityIdentifier else {
      return
    }
    button.isSelected = selectedOrigins.contains(origin)
    var config = button.isSelected ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
    config.title = localizedLogOriginTitle(origin)
    config.cornerStyle = .small
    config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
    config.baseForegroundColor = button.isSelected ? .white : PanelColors.mutedText
    config.baseBackgroundColor = button.isSelected ? PanelColors.primary : UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1)
    button.configuration = config
    button.layer.borderWidth = button.isSelected ? 0 : 1.2
    button.layer.borderColor = (button.isSelected ? PanelColors.primary : PanelColors.border).cgColor
    button.layer.cornerRadius = 7
    button.invalidateIntrinsicContentSize()
  }

  private func styleLevelButton(_ button: UIButton) {
    guard let level = button.accessibilityIdentifier else {
      return
    }
    button.isSelected = selectedLevels.contains(level)
    let tone = toneForLogLevel(level)
    var config = button.isSelected ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
    config.title = level.uppercased()
    config.cornerStyle = .small
    config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
    config.baseForegroundColor = button.isSelected ? .white : PanelColors.mutedText
    config.baseBackgroundColor = button.isSelected ? tone.foreground : UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1)
    button.configuration = config
    button.layer.borderWidth = button.isSelected ? 0 : 1.2
    button.layer.borderColor = (button.isSelected ? tone.foreground : PanelColors.border).cgColor
    button.layer.cornerRadius = 7
    button.invalidateIntrinsicContentSize()
  }

  private func updateFilterButtonStates() {
    filterWrapView.arrangedSubviews
      .compactMap { $0 as? UIButton }
      .forEach { styleLevelButton($0) }
    filterWrapView.invalidateIntrinsicContentSize()
  }

  private func updateOriginButtonStates() {
    originWrapView.arrangedSubviews
      .compactMap { $0 as? UIButton }
      .forEach { styleOriginButton($0) }
    originWrapView.invalidateIntrinsicContentSize()
  }

  private func updateToolbarTitles() {
    setButtonTitle(clearButton, title: strings["clear"] ?? "清空")
    clearButton.accessibilityLabel = strings["clear"] ?? "清空"
  }

  private func updateSortButton() {
    guard var config = sortToggleButton.configuration else {
      return
    }
    config.title = localizedSortTitle(ascending: sortAscending)
    config.image = UIImage(systemName: sortAscending ? "arrow.up" : "arrow.down")
    sortToggleButton.configuration = config
  }

  private func setButtonTitle(_ button: UIButton, title: String) {
    guard var config = button.configuration else {
      return
    }
    config.title = title
    button.configuration = config
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
      title = hasSearch || selectedLevels.isEmpty
        ? strings["noSearchResult"] ?? "未找到匹配的日志"
        : strings["noLogs"] ?? "暂无日志"
      detail = selectedOrigins.isEmpty
        ? localizedNoOriginHint()
        : (selectedLevels.isEmpty ? localizedNoLevelHint() : localizedEmptyHint())
    } else {
      title = hasSearch
        ? strings["noSearchResult"] ?? "未找到匹配的日志"
        : strings["noNetworkRequests"] ?? "暂无网络请求"
      detail = localizedEmptyHint()
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

  private func localizedNoOriginHint() -> String {
    if currentConfig.locale.hasPrefix("en") {
      return "Select JS or Native to show logs."
    }
    if currentConfig.locale.hasPrefix("ja") {
      return "JS または Native を選択してください。"
    }
    if currentConfig.locale == "zh-TW" {
      return "請選擇 JS 或原生日誌。"
    }
    return "请选择 JS 或原生日志。"
  }

  private func localizedLogOriginTitle(_ origin: String) -> String {
    if origin == "native" {
      return strings["nativeLogOrigin"] ?? (currentConfig.locale.hasPrefix("zh") ? "原生" : "Native")
    }
    return strings["jsLogOrigin"] ?? "JS"
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
    reloadFromStore()
  }

  @objc private func searchTextChanged(_ sender: UITextField) {
    searchText = sender.text ?? ""
    reloadFromStore()
  }

  @objc private func clearTapped() {
    InAppDebuggerStore.shared.clear(kind: activeTab == .logs ? "logs" : "network")
  }

  @objc private func sortToggleTapped() {
    sortAscending.toggle()
    reloadFromStore()
  }

  @objc private func levelTapped(_ sender: UIButton) {
    guard let level = sender.accessibilityIdentifier else {
      return
    }
    if selectedLevels.contains(level) {
      selectedLevels.remove(level)
    } else {
      selectedLevels.insert(level)
    }
    reloadFromStore()
  }

  @objc private func originTapped(_ sender: UIButton) {
    guard let origin = sender.accessibilityIdentifier else {
      return
    }
    if selectedOrigins.contains(origin) {
      selectedOrigins.remove(origin)
    } else {
      selectedOrigins.insert(origin)
    }
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
        titleText: "[\(localizedLogOriginTitle(entry.origin))] [\(entry.type.uppercased())] \(entry.timestamp)",
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
    originLabel.text = entry.origin == "native"
      ? strings["nativeLogOrigin"] ?? "原生"
      : strings["jsLogOrigin"] ?? "JS"
    originLabel.textColor = entry.origin == "native" ? .white : PanelColors.mutedText
    originLabel.backgroundColor = entry.origin == "native" ? PanelColors.primary : PanelColors.controlBackground
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
    methodLabel.text = entry.method.uppercased()
    methodLabel.textColor = PanelColors.primary
    methodLabel.backgroundColor = UIColor(red: 0.89, green: 0.96, blue: 0.94, alpha: 1)
    statusLabel.text = entry.status.map(String.init) ?? entry.kind.uppercased()
    statusLabel.textColor = tone.foreground
    statusLabel.backgroundColor = tone.background
    stateLabel.text = entry.state.uppercased()
    urlLabel.text = entry.url
    durationLabel.text = "\(strings["duration"] ?? "耗时") \(entry.durationMs.map { "\($0)ms" } ?? "-")"
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

    let headerStack = UIStackView(arrangedSubviews: [methodLabel, statusLabel, stateLabel, UIView(), chevronView])
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

private final class InAppDebuggerWrapView: UIView {
  private(set) var arrangedSubviews: [UIView] = []
  private let itemSpacing: CGFloat = 6
  private let rowSpacing: CGFloat = 6
  private var lastMeasuredWidth: CGFloat = 0

  func setArrangedSubviews(_ views: [UIView]) {
    arrangedSubviews.forEach { $0.removeFromSuperview() }
    arrangedSubviews = views
    arrangedSubviews.forEach { addSubview($0) }
    setNeedsLayout()
    invalidateIntrinsicContentSize()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if abs(bounds.width - lastMeasuredWidth) > 0.5 {
      lastMeasuredWidth = bounds.width
      invalidateIntrinsicContentSize()
    }
    _ = layoutItems(for: bounds.width, updateFrames: true)
  }

  override var intrinsicContentSize: CGSize {
    let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 28
    return CGSize(width: UIView.noIntrinsicMetric, height: layoutItems(for: width, updateFrames: false))
  }

  private func layoutItems(for width: CGFloat, updateFrames: Bool) -> CGFloat {
    guard !arrangedSubviews.isEmpty else {
      return 0
    }

    let availableWidth = max(width, 1)
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0

    arrangedSubviews.forEach { view in
      let fittingSize = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
      let itemWidth = min(ceil(fittingSize.width), availableWidth)
      let itemHeight = ceil(max(fittingSize.height, 28))

      if x > 0, x + itemWidth > availableWidth {
        x = 0
        y += rowHeight + rowSpacing
        rowHeight = 0
      }

      if updateFrames {
        view.frame = CGRect(x: x, y: y, width: itemWidth, height: itemHeight)
      }

      x += itemWidth + itemSpacing
      rowHeight = max(rowHeight, itemHeight)
    }

    return y + rowHeight
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
      textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
    ])
  }

  @objc private func copyTapped() {
    UIPasteboard.general.string = bodyText
    showToast(message: "已复制")
  }
}

final class InAppDebuggerNetworkDetailViewController: UIViewController {
  private let entry: DebugNetworkEntry
  private let strings: [String: String]

  init(entry: DebugNetworkEntry, strings: [String: String]) {
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

    let scrollView = UIScrollView()
    let stack = UIStackView()
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

    let requestHeaders = entry.requestHeaders
      .map { "\($0.key): \($0.value)" }
      .joined(separator: "\n")
      .ifEmpty("-")
    let responseHeaders = entry.responseHeaders
      .map { "\($0.key): \($0.value)" }
      .joined(separator: "\n")
      .ifEmpty("-")
    let durationText = entry.durationMs.map { "\($0)ms" } ?? "-"
    let noRequestBodyText = strings["noRequestBody"] ?? "无请求体"
    let noResponseBodyText = strings["noResponseBody"] ?? "无响应体"
    let noMessagesText = strings["noMessages"] ?? "暂无消息"

    let sections: [(title: String, body: String, monospace: Bool)] = [
      (title: strings["method"] ?? "方法", body: entry.method, monospace: false),
      (title: strings["status"] ?? "状态码", body: entry.status.map(String.init) ?? "-", monospace: false),
      (title: strings["state"] ?? "状态", body: entry.state, monospace: false),
      (title: strings["protocol"] ?? "协议", body: entry.`protocol` ?? "-", monospace: false),
      (title: "URL", body: entry.url, monospace: true),
      (title: strings["duration"] ?? "耗时", body: durationText, monospace: false),
      (title: strings["requestHeaders"] ?? "请求头", body: requestHeaders, monospace: true),
      (title: strings["responseHeaders"] ?? "响应头", body: responseHeaders, monospace: true),
      (title: strings["requestBody"] ?? "请求体", body: entry.requestBody ?? noRequestBodyText, monospace: true),
      (title: strings["responseBody"] ?? "响应体", body: entry.responseBody ?? noResponseBodyText, monospace: true),
      (title: strings["messages"] ?? "消息", body: entry.messages ?? noMessagesText, monospace: true),
    ]

    sections.forEach { title, body, monospace in
      stack.addArrangedSubview(makeSection(title: title, body: body, monospace: monospace))
    }

    if let error = entry.error, !error.isEmpty {
      stack.addArrangedSubview(makeSection(title: "错误", body: error, monospace: true))
    }
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

    let bodyTextView = InAppDebuggerSelectableTextView()
    bodyTextView.font = monospace
      ? .monospacedSystemFont(ofSize: 12, weight: .regular)
      : .systemFont(ofSize: 13, weight: .regular)
    bodyTextView.textColor = PanelColors.text
    bodyTextView.text = body
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
    let fullText = text ?? ""
    if selectedRange.length > 0,
       let range = Range(selectedRange, in: fullText) {
      UIPasteboard.general.string = String(fullText[range])
    } else {
      UIPasteboard.general.string = fullText
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
