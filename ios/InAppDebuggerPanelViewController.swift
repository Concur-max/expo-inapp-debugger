import Darwin
import UIKit

private enum PanelSection {
  case main
}

private enum ActiveTab: Int {
  case logs
  case network
  case appInfo
}

private let panelTitle = "Debugging panel"
private let panelSearchPlaceholder = "Please enter"
private let logsTabTitle = "log"
private let networkTabTitle = "network"
private let appInfoTabTitle = "app Info"

private enum ToolbarButtonStyle {
  case primary
  case neutral
}

private enum PanelColors {
  static let background = UIColor.systemGroupedBackground
  static let card = UIColor.secondarySystemGroupedBackground
  static let controlBackground = UIColor.tertiarySystemFill
  static let border = UIColor.separator
  static let primary = UIColor.systemBlue
  static let text = UIColor.label
  static let mutedText = UIColor.secondaryLabel
}

private struct PanelTone {
  let foreground: UIColor
  let background: UIColor
}

private struct PanelDetailItem {
  let title: String
  let content: String
  let monospace: Bool

  init(title: String, content: String, monospace: Bool = false) {
    self.title = title
    self.content = content
    self.monospace = monospace
  }
}

private enum NetworkKindFilter: String, CaseIterable {
  case http
  case websocket
  case other
}

private func normalizedNetworkKind(_ kind: String) -> NetworkKindFilter {
  switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "", "http", "https", "xhr", "xmlhttprequest", "fetch":
    return .http
  case "websocket", "ws", "wss", "socket":
    return .websocket
  default:
    return .other
  }
}

private func isWebSocketKind(_ kind: String) -> Bool {
  normalizedNetworkKind(kind) == .websocket
}

private func localizedNetworkTypeTitle(locale: String) -> String {
  if locale.hasPrefix("en") {
    return "Request type"
  }
  if locale.hasPrefix("ja") {
    return "通信種別"
  }
  if locale == "zh-TW" {
    return "請求類型"
  }
  return "请求类型"
}

private func localizedNetworkKindFilterTitle(_ kind: NetworkKindFilter, locale: String) -> String {
  switch kind {
  case .http:
    return "XHR/Fetch"
  case .websocket:
    return "WebSocket"
  case .other:
    if locale.hasPrefix("en") {
      return "Other"
    }
    if locale.hasPrefix("ja") {
      return "その他"
    }
    return "其他"
  }
}

private func localizedNetworkKindTitle(_ rawKind: String, locale: String) -> String {
  let trimmedKind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines)
  switch normalizedNetworkKind(trimmedKind) {
  case .http:
    return localizedNetworkKindFilterTitle(.http, locale: locale)
  case .websocket:
    return localizedNetworkKindFilterTitle(.websocket, locale: locale)
  case .other:
    if !trimmedKind.isEmpty, trimmedKind.lowercased() != NetworkKindFilter.other.rawValue {
      return trimmedKind.uppercased()
    }
    return localizedNetworkKindFilterTitle(.other, locale: locale)
  }
}

private func networkKindBadgeTitle(_ rawKind: String) -> String {
  switch normalizedNetworkKind(rawKind) {
  case .http:
    return "XHR/FETCH"
  case .websocket:
    return "WS"
  case .other:
    let trimmedKind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedKind.isEmpty ? "OTHER" : trimmedKind.uppercased()
  }
}

private func networkTrailingBadgeTitle(_ entry: DebugNetworkEntry) -> String? {
  if let status = entry.status {
    if status == 0 && entry.state == "error" {
      return "(failed)"
    }
    return String(status)
  }
  if isWebSocketKind(entry.kind) {
    return nil
  }
  return networkKindBadgeTitle(entry.kind)
}

private func shouldShowNetworkStateLabel(_ entry: DebugNetworkEntry) -> Bool {
  if isWebSocketKind(entry.kind) {
    return true
  }
  return entry.status == nil
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
  static let selectedNetworkKindsKey = "expo.inappdebugger.panel.selectedNetworkKinds"
  static let allLevels: Set<String> = ["log", "info", "warn", "error", "debug"]
  static let allOrigins: Set<String> = ["js", "native"]
  static let allNetworkKinds: Set<String> = Set(NetworkKindFilter.allCases.map(\.rawValue))
  static let defaultOrigins: Set<String> = ["js"]
  static let defaultNetworkOrigins: Set<String> = defaultOrigins
  static let defaultNetworkKinds = allNetworkKinds

  static func loadLogLevels() -> Set<String> {
    loadSet(forKey: selectedLogLevelsKey, allowedValues: allLevels, defaultValues: allLevels)
  }

  static func loadLogOrigins() -> Set<String> {
    loadSet(forKey: selectedLogOriginsKey, allowedValues: allOrigins, defaultValues: defaultOrigins)
  }

  static func loadNetworkOrigins() -> Set<String> {
    loadSet(forKey: selectedNetworkOriginsKey, allowedValues: allOrigins, defaultValues: defaultNetworkOrigins)
  }

  static func loadNetworkKinds() -> Set<String> {
    loadSet(forKey: selectedNetworkKindsKey, allowedValues: allNetworkKinds, defaultValues: defaultNetworkKinds)
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

  static func saveNetworkKinds(_ kinds: Set<String>) {
    saveSet(kinds, forKey: selectedNetworkKindsKey)
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
  private var selectedNetworkKinds: Set<String> = PanelFilterPreferences.loadNetworkKinds()
  private var sortAscending = true
  private var displayedLogs: [DebugLogEntry] = []
  private var displayedNetwork: [DebugNetworkEntry] = []
  private var displayedLogLookup: [String: DebugLogEntry] = [:]
  private var displayedNetworkLookup: [String: DebugNetworkEntry] = [:]
  private var notificationObserver: NSObjectProtocol?
  private var currentConfig = DebugConfig()
  private var scheduledReloadWorkItem: DispatchWorkItem?
  private var scheduledSearchWorkItem: DispatchWorkItem?
  private var isSuspendingLiveUpdatesForScroll = false
  private var renderedAppInfoSignature = ""

  private lazy var closeButton: UIButton = {
    let button = UIButton(type: .close)
    button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 30),
      button.heightAnchor.constraint(equalToConstant: 30),
    ])
    return button
  }()

  private lazy var segmentedControl: UISegmentedControl = {
    let control = UISegmentedControl(items: [logsTabTitle, networkTabTitle, appInfoTabTitle])
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
    field.clearButtonMode = .whileEditing
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.smartDashesType = .no
    field.smartQuotesType = .no
    field.smartInsertDeleteType = .no
    field.returnKeyType = .done
    field.addTarget(self, action: #selector(searchTextChanged(_:)), for: .editingChanged)
    return field
  }()

  private lazy var clearButton: UIButton = {
    let button = makeToolbarButton(
      systemName: "trash",
      foregroundColor: .systemRed
    )
    button.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
    return button
  }()

  private lazy var filterButton: UIButton = {
    let button = makeToolbarButton(
      systemName: "line.3.horizontal.decrease",
      foregroundColor: PanelColors.primary
    )
    button.showsMenuAsPrimaryAction = true
    return button
  }()

  private lazy var sortToggleButton: UIButton = {
    let button = makeToolbarButton(
      systemName: "arrow.down",
      foregroundColor: PanelColors.text
    )
    button.addTarget(self, action: #selector(sortToggleTapped), for: .touchUpInside)
    return button
  }()

  private lazy var actionRow: UIStackView = {
    let stack = UIStackView(arrangedSubviews: [searchField, filterButton, sortToggleButton, clearButton])
    stack.axis = .horizontal
    stack.alignment = .fill
    stack.spacing = 8
    return stack
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

  private lazy var appInfoScrollView: UIScrollView = {
    let scrollView = UIScrollView()
    scrollView.backgroundColor = PanelColors.background
    scrollView.alwaysBounceVertical = true
    scrollView.keyboardDismissMode = .onDrag
    scrollView.isHidden = true
    return scrollView
  }()

  private lazy var appInfoStackView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 10
    return stack
  }()

  private let emptyStateView = InAppDebuggerEmptyStateView()

  private lazy var dataSource = UITableViewDiffableDataSource<PanelSection, String>(
    tableView: tableView
  ) { [weak self] tableView, indexPath, identifier in
    guard let self else { return nil }

    switch self.activeTab {
    case .logs:
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
    case .network:
      guard let entry = self.displayedNetworkLookup[identifier] else {
        return UITableViewCell()
      }
      let cell = tableView.dequeueReusableCell(
        withIdentifier: InAppDebuggerNetworkCell.reuseIdentifier,
        for: indexPath
      ) as? InAppDebuggerNetworkCell
      cell?.configure(entry: entry, strings: self.strings)
      return cell
    case .appInfo:
      return UITableViewCell()
    }
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
    scheduledSearchWorkItem?.cancel()
    scheduledSearchWorkItem = nil
    InAppDebuggerStore.shared.setLiveUpdatesEnabled(false)
    InAppDebuggerNativeLogCapture.shared.setPanelActive(false)
    InAppDebuggerNativeNetworkCapture.shared.setPanelActive(false)
    InAppDebuggerNativeWebSocketCapture.shared.setPanelActive(false)
    isSuspendingLiveUpdatesForScroll = false
  }

  deinit {
    scheduledReloadWorkItem?.cancel()
    scheduledSearchWorkItem?.cancel()
    InAppDebuggerStore.shared.setLiveUpdatesEnabled(false)
    InAppDebuggerNativeLogCapture.shared.setPanelActive(false)
    InAppDebuggerNativeNetworkCapture.shared.setPanelActive(false)
    InAppDebuggerNativeWebSocketCapture.shared.setPanelActive(false)
    if let notificationObserver {
      NotificationCenter.default.removeObserver(notificationObserver)
    }
  }

  private func configureNavigationBar() {
    title = panelTitle
    closeButton.accessibilityLabel = strings["close"] ?? "关闭"
    navigationItem.rightBarButtonItem = UIBarButtonItem(customView: closeButton)

    guard let navigationBar = navigationController?.navigationBar else {
      return
    }
    navigationController?.navigationBar.prefersLargeTitles = false
    let appearance = UINavigationBarAppearance()
    appearance.configureWithDefaultBackground()
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
    let topStack = UIStackView(arrangedSubviews: [segmentedControl, actionRow])
    topStack.axis = .vertical
    topStack.spacing = 12
    
    view.addSubview(topStack)
    view.addSubview(tableView)
    view.addSubview(appInfoScrollView)
    appInfoScrollView.addSubview(appInfoStackView)
    
    topStack.translatesAutoresizingMaskIntoConstraints = false
    tableView.translatesAutoresizingMaskIntoConstraints = false
    appInfoScrollView.translatesAutoresizingMaskIntoConstraints = false
    appInfoStackView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      topStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
      topStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      topStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),

      tableView.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 10),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      appInfoScrollView.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 10),
      appInfoScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      appInfoScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      appInfoScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      appInfoStackView.topAnchor.constraint(equalTo: appInfoScrollView.contentLayoutGuide.topAnchor, constant: 4),
      appInfoStackView.leadingAnchor.constraint(equalTo: appInfoScrollView.contentLayoutGuide.leadingAnchor, constant: 14),
      appInfoStackView.trailingAnchor.constraint(equalTo: appInfoScrollView.contentLayoutGuide.trailingAnchor, constant: -14),
      appInfoStackView.bottomAnchor.constraint(equalTo: appInfoScrollView.contentLayoutGuide.bottomAnchor, constant: -18),
      appInfoStackView.widthAnchor.constraint(equalTo: appInfoScrollView.frameLayoutGuide.widthAnchor, constant: -28),

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

  private func makeToolbarButton(systemName: String, foregroundColor: UIColor) -> UIButton {
    let button = UIButton(type: .system)
    button.configuration = toolbarButtonConfiguration(
      systemName: systemName,
      foregroundColor: foregroundColor,
      style: .neutral
    )
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
  }

  private func toolbarButtonConfiguration(
    systemName: String,
    foregroundColor: UIColor,
    style: ToolbarButtonStyle
  ) -> UIButton.Configuration {
    var config: UIButton.Configuration
    switch style {
    case .primary:
      config = .tinted()
      config.baseBackgroundColor = PanelColors.primary
      config.baseForegroundColor = .white
    case .neutral:
      config = .gray()
      config.baseForegroundColor = foregroundColor
    }
    config.image = UIImage(systemName: systemName)
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 15,
      weight: .semibold
    )
    config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    return config
  }

  private func updateFilterMenu() {
    guard activeTab != .appInfo else {
      filterButton.menu = nil
      filterButton.configuration = toolbarButtonConfiguration(
        systemName: "line.3.horizontal.decrease",
        foregroundColor: PanelColors.primary,
        style: .neutral
      )
      return
    }

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
    } else {
      let kindOptions = NetworkKindFilter.allCases.map { kindFilter -> UIAction in
        let kind = kindFilter.rawValue
        let isSelected = selectedNetworkKinds.contains(kind)
        var attributes: UIMenuElement.Attributes = []
        if #available(iOS 16.0, *) { attributes.insert(.keepsMenuPresented) }
        return UIAction(
          title: localizedNetworkKindFilterTitle(kindFilter, locale: currentConfig.locale),
          attributes: attributes,
          state: isSelected ? .on : .off
        ) { [weak self] _ in
          self?.toggleNetworkKind(kind)
        }
      }
      let kindMenu = UIMenu(
        title: localizedNetworkTypeTitle(locale: currentConfig.locale),
        options: .displayInline,
        children: kindOptions
      )
      menuChildren.append(kindMenu)
    }

    filterButton.menu = UIMenu(title: strings["filter"] ?? "筛选", children: menuChildren)
    
    let hasFilters: Bool
    if activeTab == .logs {
      hasFilters =
        selectedLogOrigins.count < PanelFilterPreferences.allOrigins.count ||
        selectedLogLevels.count < PanelFilterPreferences.allLevels.count
    } else {
      hasFilters =
        selectedNetworkOrigins.count < PanelFilterPreferences.allOrigins.count ||
        selectedNetworkKinds.count < PanelFilterPreferences.allNetworkKinds.count
    }
    filterButton.configuration = toolbarButtonConfiguration(
      systemName: "line.3.horizontal.decrease",
      foregroundColor: PanelColors.primary,
      style: hasFilters ? .primary : .neutral
    )
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
    case .appInfo:
      return
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

  private func toggleNetworkKind(_ kind: String) {
    if selectedNetworkKinds.contains(kind) {
      selectedNetworkKinds.remove(kind)
    } else {
      selectedNetworkKinds.insert(kind)
    }
    PanelFilterPreferences.saveNetworkKinds(selectedNetworkKinds)
    updateFilterMenu()
    syncNativeCaptureStates()
    reloadFromStore()
  }

  private func syncNativeCaptureStates() {
    let shouldActivateNativeLogs = activeTab == .logs && selectedLogOrigins.contains("native")
    InAppDebuggerNativeLogCapture.shared.setPanelActive(shouldActivateNativeLogs)

    let shouldActivateNativeNetwork =
      currentConfig.enableNetworkTab &&
      activeTab == .network &&
      selectedNetworkOrigins.contains("native") &&
      (
        selectedNetworkKinds.contains(NetworkKindFilter.http.rawValue) ||
        selectedNetworkKinds.contains(NetworkKindFilter.websocket.rawValue)
      )
    InAppDebuggerNativeNetworkCapture.shared.setPanelActive(shouldActivateNativeNetwork)

    // The current native WebSocket hook captures RN-managed sockets, which are still JS-origin requests.
    let shouldActivateNativeWebSocket =
      currentConfig.enableNetworkTab &&
      activeTab == .network &&
      selectedNetworkOrigins.contains("js") &&
      selectedNetworkKinds.contains(NetworkKindFilter.websocket.rawValue)
    InAppDebuggerNativeWebSocketCapture.shared.setPanelActive(shouldActivateNativeWebSocket)
  }

  private func applySnapshot(reconfiguring identifiers: [String] = []) {
    guard activeTab != .appInfo else {
      return
    }

    var snapshot = NSDiffableDataSourceSnapshot<PanelSection, String>()
    snapshot.appendSections([.main])
    if activeTab == .logs {
      snapshot.appendItems(displayedLogs.map(\.id))
    } else {
      snapshot.appendItems(displayedNetwork.map(\.id))
    }

    updateEmptyState()
    if #available(iOS 15.0, *) {
      if !identifiers.isEmpty {
        snapshot.reconfigureItems(identifiers)
      }
      dataSource.apply(snapshot, animatingDifferences: false)
      return
    }

    if !identifiers.isEmpty {
      snapshot.reloadItems(identifiers)
    }
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  private func reloadFromStore(reason: ReloadReason = .full) {
    let state = InAppDebuggerStore.shared.snapshotState()
    let shouldRefreshChrome = reason == .full || state.0 != currentConfig
    if shouldRefreshChrome {
      currentConfig = state.0

      if !currentConfig.enableNetworkTab && activeTab == .network {
        activeTab = .logs
      }

      configureNavigationBar()
      segmentedControl.selectedSegmentIndex = activeTab.rawValue
      segmentedControl.setTitle(logsTabTitle, forSegmentAt: 0)
      segmentedControl.setTitle(networkTabTitle, forSegmentAt: 1)
      segmentedControl.setTitle(appInfoTabTitle, forSegmentAt: 2)
      segmentedControl.setEnabled(currentConfig.enableNetworkTab, forSegmentAt: 1)

      searchField.placeholder = panelSearchPlaceholder
      updateContentVisibility()
      updateToolbarTitles()
      updateFilterMenu()
      updateSortButton()
      if view.window != nil {
        syncNativeCaptureStates()
      }
    }

    if activeTab == .appInfo {
      renderAppInfo(logs: state.1, errors: state.2)
      return
    }

    if activeTab == .logs {
      let previousLogLookup = displayedLogLookup
      let nextLogs = filteredLogs(from: state.1)
      let nextLogLookup = Dictionary(uniqueKeysWithValues: nextLogs.map { ($0.id, $0) })

      displayedLogs = nextLogs
      displayedLogLookup = nextLogLookup

      let changedIdentifiers = changedIdentifiers(
        orderedIDs: nextLogs.map(\.id),
        previousLookup: previousLogLookup,
        nextLookup: nextLogLookup
      )
      applySnapshot(reconfiguring: changedIdentifiers)
      return
    }

    let previousNetworkLookup = displayedNetworkLookup
    let nextNetwork = filteredNetwork(from: state.3)
    let nextNetworkLookup = Dictionary(uniqueKeysWithValues: nextNetwork.map { ($0.id, $0) })

    displayedNetwork = nextNetwork
    displayedNetworkLookup = nextNetworkLookup

    let changedIdentifiers = changedIdentifiers(
      orderedIDs: nextNetwork.map(\.id),
      previousLookup: previousNetworkLookup,
      nextLookup: nextNetworkLookup
    )
    applySnapshot(reconfiguring: changedIdentifiers)
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
    result.sort(by: logSortComparator)
    return result
  }

  private func filteredNetwork(from source: [DebugNetworkEntry]) -> [DebugNetworkEntry] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    var result: [DebugNetworkEntry] = []
    result.reserveCapacity(source.count)
    for entry in source {
      let normalizedKind = normalizedNetworkKind(entry.kind).rawValue
      guard selectedNetworkOrigins.contains(entry.origin), selectedNetworkKinds.contains(normalizedKind) else {
        continue
      }
      if !query.isEmpty {
        let kindTitle = localizedNetworkKindTitle(entry.kind, locale: currentConfig.locale)
        let matchesQuery =
          entry.url.localizedCaseInsensitiveContains(query) ||
          entry.origin.localizedCaseInsensitiveContains(query) ||
          entry.kind.localizedCaseInsensitiveContains(query) ||
          kindTitle.localizedCaseInsensitiveContains(query) ||
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
    result.sort(by: networkSortComparator)
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
      self.scheduledReloadWorkItem = nil
      if self.tableView.isDragging || self.tableView.isDecelerating {
        return
      }
      self.reloadFromStore(reason: .dataOnly)
    }
    scheduledReloadWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
  }

  private func scheduleSearchReload() {
    scheduledSearchWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }
      self.scheduledSearchWorkItem = nil
      self.reloadFromStore(reason: .dataOnly)
    }
    scheduledSearchWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
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

  private func updateContentVisibility() {
    let showingAppInfo = activeTab == .appInfo
    actionRow.isHidden = showingAppInfo
    tableView.isHidden = showingAppInfo
    appInfoScrollView.isHidden = !showingAppInfo
    if showingAppInfo {
      tableView.backgroundView = nil
    }
  }

  private func updateSortButton() {
    sortToggleButton.configuration = toolbarButtonConfiguration(
      systemName: sortAscending ? "arrow.up" : "arrow.down",
      foregroundColor: PanelColors.text,
      style: .neutral
    )
    sortToggleButton.accessibilityLabel = localizedSortTitle(ascending: sortAscending)
  }

  private func updateEmptyState() {
    guard activeTab != .appInfo else {
      tableView.backgroundView = nil
      return
    }

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
      let isOriginEmpty = selectedNetworkOrigins.isEmpty
      let isKindEmpty = selectedNetworkKinds.isEmpty
      title = hasSearch || isOriginEmpty || isKindEmpty
        ? localizedNoNetworkResultTitle()
        : strings["noNetworkRequests"] ?? "暂无网络请求"
      if isOriginEmpty && isKindEmpty {
        detail = localizedNoNetworkFilterHint()
      } else if isOriginEmpty {
        detail = localizedNoNetworkOriginHint()
      } else if isKindEmpty {
        detail = localizedNoNetworkKindHint()
      } else {
        detail = localizedEmptyHint()
      }
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

  private func localizedNoNetworkKindHint() -> String {
    if currentConfig.locale.hasPrefix("en") {
      return "Select at least one request type to show network entries."
    }
    if currentConfig.locale.hasPrefix("ja") {
      return "少なくとも 1 つの通信種別を選択してください。"
    }
    if currentConfig.locale == "zh-TW" {
      return "至少選擇一種請求類型。"
    }
    return "至少选择一种请求类型。"
  }

  private func localizedNoNetworkFilterHint() -> String {
    if currentConfig.locale.hasPrefix("en") {
      return "Select at least one source and request type to show network entries."
    }
    if currentConfig.locale.hasPrefix("ja") {
      return "少なくとも 1 つの送信元と通信種別を選択してください。"
    }
    if currentConfig.locale == "zh-TW" {
      return "至少選擇一種來源與請求類型。"
    }
    return "至少选择一种来源和请求类型。"
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

  private func changedIdentifiers<Entry: Equatable>(
    orderedIDs: [String],
    previousLookup: [String: Entry],
    nextLookup: [String: Entry]
  ) -> [String] {
    orderedIDs.compactMap { identifier in
      guard let nextEntry = nextLookup[identifier] else {
        return nil
      }
      guard let previousEntry = previousLookup[identifier] else {
        return identifier
      }
      return previousEntry == nextEntry ? nil : identifier
    }
  }

  private func logSortComparator(_ lhs: DebugLogEntry, _ rhs: DebugLogEntry) -> Bool {
    let lhsKey = lhs.fullTimestamp.isEmpty ? lhs.timestamp : lhs.fullTimestamp
    let rhsKey = rhs.fullTimestamp.isEmpty ? rhs.timestamp : rhs.fullTimestamp
    if lhsKey == rhsKey {
      return sortAscending ? lhs.id < rhs.id : lhs.id > rhs.id
    }
    return sortAscending ? lhsKey < rhsKey : lhsKey > rhsKey
  }

  private func networkSortComparator(_ lhs: DebugNetworkEntry, _ rhs: DebugNetworkEntry) -> Bool {
    if lhs.startedAt != rhs.startedAt {
      return sortAscending ? lhs.startedAt < rhs.startedAt : lhs.startedAt > rhs.startedAt
    }
    if lhs.updatedAt != rhs.updatedAt {
      return sortAscending ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
    }
    return sortAscending ? lhs.id < rhs.id : lhs.id > rhs.id
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

  private func renderAppInfo(logs: [DebugLogEntry], errors: [DebugErrorEntry]) {
    let sections = buildAppInfoSections(logs: logs, errors: errors)
    let signature = sections
      .map { "\($0.title)\n\($0.content)\n\($0.monospace)" }
      .joined(separator: "\n---\n")
    guard signature != renderedAppInfoSignature else {
      return
    }
    renderedAppInfoSignature = signature

    appInfoStackView.arrangedSubviews.forEach { view in
      appInfoStackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    sections.forEach { section in
      let sectionView = InAppDebuggerDetailSectionView()
      sectionView.configure(title: section.title, body: section.content, monospace: section.monospace)
      appInfoStackView.addArrangedSubview(sectionView)
    }
  }

  private func buildAppInfoSections(logs: [DebugLogEntry], errors: [DebugErrorEntry]) -> [PanelDetailItem] {
    [
      PanelDetailItem(title: "宿主运行环境", content: buildHostRuntimeInfo(), monospace: true),
      PanelDetailItem(title: "调试器能力", content: buildDebuggerCapabilityInfo()),
      PanelDetailItem(title: "采集状态", content: buildCaptureStatusInfo(), monospace: true),
      buildNativeCrashInfo(logs: logs),
      buildFatalErrorInfo(errors: errors),
      PanelDetailItem(title: "限制说明", content: buildLimitationsInfo()),
    ]
  }

  private func buildHostRuntimeInfo() -> String {
    let bundle = Bundle.main
    let processInfo = ProcessInfo.processInfo
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    let versionSummary = version.isEmpty && build.isEmpty
      ? "-"
      : "\(version.isEmpty ? "-" : version) (\(build.isEmpty ? "-" : build))"
    let device = UIDevice.current

    return [
      "应用名称: \(appDisplayName())",
      "Bundle ID: \(bundle.bundleIdentifier ?? "-")",
      "版本: \(versionSummary)",
      "进程: \(processInfo.processName)",
      "PID: \(processInfo.processIdentifier)",
      "系统: \(device.systemName) \(device.systemVersion)",
      "设备: \(device.model) / \(deviceMachineIdentifier())",
      "语言环境: \(Locale.current.identifier)",
      "应用状态: \(applicationStateTitle(UIApplication.shared.applicationState))",
      "后台刷新: \(backgroundRefreshStatusTitle(UIApplication.shared.backgroundRefreshStatus))",
      "低电量模式: \(processInfo.isLowPowerModeEnabled ? "是" : "否")",
      "温度状态: \(thermalStateTitle(processInfo.thermalState))",
    ].joined(separator: "\n")
  }

  private func buildDebuggerCapabilityInfo() -> String {
    var lines = [
      "JS console 日志、React 错误、全局错误与未处理 Promise rejection。",
      "iOS 原生日志：stdout、stderr、log/native 页面激活时的 OSLog 轮询、未捕获 NSException，以及 fatal signal 崩溃标记。",
    ]

    if currentConfig.enableNetworkTab {
      lines.append("network 面板：JS fetch/XHR、WebSocket，以及 network/native 页面激活时的 native URLSession 请求。")
    } else {
      lines.append("当前配置已关闭 network 面板。")
    }

    return lines.map { "- \($0)" }.joined(separator: "\n")
  }

  private func buildCaptureStatusInfo() -> String {
    [
      "调试器已启用: \(currentConfig.enabled ? "是" : "否")",
      "network 面板已启用: \(currentConfig.enableNetworkTab ? "是" : "否")",
      "原生崩溃持久化: 已启用",
      "原生 stream 采集: 仅在选择 log/native 时激活",
      "原生网络预览: 仅在选择 network/native 时激活",
      "最大日志数: \(currentConfig.maxLogs)",
      "最大错误数: \(currentConfig.maxErrors)",
      "最大请求数: \(currentConfig.maxRequests)",
      "Fatal signals: \(fatalSignalSummary())",
    ].joined(separator: "\n")
  }

  private func buildNativeCrashInfo(logs: [DebugLogEntry]) -> PanelDetailItem {
    let crashLogs = logs
      .reversed()
      .filter { entry in
        guard entry.origin == "native" else {
          return false
        }
        let context = entry.context ?? ""
        let details = entry.details ?? ""
        return context == "previous-launch crash report" ||
          context == "uncaught-exception" ||
          entry.message.localizedCaseInsensitiveContains("fatal signal") ||
          details.localizedCaseInsensitiveContains("fatal signal")
      }
      .prefix(5)

    guard !crashLogs.isEmpty else {
      return PanelDetailItem(
        title: "最近原生崩溃记录",
        content: "暂无原生崩溃记录。"
      )
    }

    let body = crashLogs.enumerated().map { index, entry in
      let context = entry.context ?? ""
      let details = entry.details ?? "-"
      return [
        "#\(index + 1)",
        "时间: \(entry.fullTimestamp.isEmpty ? entry.timestamp : entry.fullTimestamp)",
        "上下文: \(context.isEmpty ? "-" : context)",
        "消息: \(entry.message.isEmpty ? "-" : entry.message)",
        "详情:\n\(trimForPanel(details, limit: 2_000))",
      ].joined(separator: "\n")
    }.joined(separator: "\n\n")

    return PanelDetailItem(
      title: "最近原生崩溃记录",
      content: body,
      monospace: true
    )
  }

  private func buildFatalErrorInfo(errors: [DebugErrorEntry]) -> PanelDetailItem {
    let fatalErrors = errors
      .reversed()
      .filter { error in
        error.source == "global" ||
          error.source == "react" ||
          error.message.localizedCaseInsensitiveContains("[FATAL]")
      }
      .prefix(5)

    guard !fatalErrors.isEmpty else {
      return PanelDetailItem(
        title: "最近严重错误",
        content: "暂无 JS / runtime 严重错误记录。"
      )
    }

    let body = fatalErrors.enumerated().map { index, error in
      [
        "#\(index + 1)",
        "时间: \(error.fullTimestamp.isEmpty ? error.timestamp : error.fullTimestamp)",
        "来源: \(error.source.isEmpty ? "-" : error.source)",
        "消息:\n\(trimForPanel(error.message, limit: 2_000))",
      ].joined(separator: "\n")
    }.joined(separator: "\n\n")

    return PanelDetailItem(
      title: "最近严重错误",
      content: body,
      monospace: true
    )
  }

  private func buildLimitationsInfo() -> String {
    var lines = [
      "为了降低宿主应用开销，native stream 与 OSLog 采集只会在 log/native 页面激活。",
      "iOS 无法完整回放调试器挂钩启动之前产生的任意日志，但会尽力保留已持久化的未捕获崩溃报告。",
      "network 面板未激活时会尽量减少 payload preview 处理，以保护运行时性能。",
    ]

    if !currentConfig.enableNetworkTab {
      lines.append("当前配置已关闭 network 面板，因此不会采集用于展示的网络事件。")
    }

    return lines.map { "- \($0)" }.joined(separator: "\n")
  }

  private func appDisplayName() -> String {
    let bundle = Bundle.main
    let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
    return displayName?.isEmpty == false ? displayName ?? "-" : (bundleName?.isEmpty == false ? bundleName ?? "-" : "-")
  }

  private func deviceMachineIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let mirror = Mirror(reflecting: systemInfo.machine)
    let identifier = mirror.children.reduce(into: "") { result, child in
      guard let value = child.value as? Int8, value != 0 else {
        return
      }
      result.append(String(UnicodeScalar(UInt8(value))))
    }
    return identifier.isEmpty ? "-" : identifier
  }

  private func applicationStateTitle(_ state: UIApplication.State) -> String {
    switch state {
    case .active:
      return "前台活跃"
    case .inactive:
      return "非活跃"
    case .background:
      return "后台"
    @unknown default:
      return "未知"
    }
  }

  private func backgroundRefreshStatusTitle(_ status: UIBackgroundRefreshStatus) -> String {
    switch status {
    case .available:
      return "可用"
    case .denied:
      return "已拒绝"
    case .restricted:
      return "受限"
    @unknown default:
      return "未知"
    }
  }

  private func thermalStateTitle(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
      return "正常"
    case .fair:
      return "偏高"
    case .serious:
      return "严重"
    case .critical:
      return "危急"
    @unknown default:
      return "未知"
    }
  }

  private func fatalSignalSummary() -> String {
    "SIGABRT(6), SIGBUS(10), SIGFPE(8), SIGILL(4), SIGSEGV(11), SIGTERM(15), SIGTRAP(5)"
  }

  private func trimForPanel(_ value: String, limit: Int) -> String {
    guard value.count > limit else {
      return value
    }
    let endIndex = value.index(value.startIndex, offsetBy: limit)
    return "\(value[..<endIndex])\n...已截断"
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
    let nextSearchText = sender.text ?? ""
    guard nextSearchText != searchText else {
      return
    }
    searchText = nextSearchText
    scheduleSearchReload()
  }

  @objc private func clearTapped() {
    switch activeTab {
    case .logs:
      InAppDebuggerStore.shared.clear(kind: "logs")
    case .network:
      InAppDebuggerStore.shared.clear(kind: "network")
      InAppDebuggerNativeNetworkCapture.shared.refreshVisibleEntries()
      if selectedNetworkOrigins.contains("js") &&
        selectedNetworkKinds.contains(NetworkKindFilter.websocket.rawValue) {
        InAppDebuggerNativeWebSocketCapture.shared.refreshVisibleEntries()
      }
    case .appInfo:
      return
    }
  }

  @objc private func sortToggleTapped() {
    sortAscending.toggle()
    reloadFromStore()
  }


  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch activeTab {
    case .logs:
      guard displayedLogs.indices.contains(indexPath.row) else {
        return
      }
      let entry = displayedLogs[indexPath.row]
      let detail = InAppDebuggerTextDetailViewController(
        titleText: "[\(localizedOriginTitle(entry.origin, strings: strings))] [\(entry.type.uppercased())] \(entry.timestamp)",
        bodyText: logDetailBody(for: entry)
      )
      navigationController?.pushViewController(detail, animated: true)
    case .network:
      guard displayedNetwork.indices.contains(indexPath.row) else {
        return
      }
      let entry = displayedNetwork[indexPath.row]
      let detail = InAppDebuggerNetworkDetailViewController(
        entry: entry,
        strings: strings,
        locale: currentConfig.locale
      )
      navigationController?.pushViewController(detail, animated: true)
    case .appInfo:
      return
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
    statusLabel.text = networkTrailingBadgeTitle(entry)
    statusLabel.isHidden = statusLabel.text == nil
    statusLabel.textColor = tone.foreground
    statusLabel.backgroundColor = tone.background
    stateLabel.text = entry.state.uppercased()
    stateLabel.isHidden = !shouldShowNetworkStateLabel(entry)
    urlLabel.text = entry.url
    if isWebSocketKind(entry.kind) {
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

private final class InAppDebuggerDetailSectionView: UIView {
  private let cardView = UIView()
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    buildUI()
  }

  required init?(coder: NSCoder) {
    nil
  }

  func configure(title: String, body: String, monospace: Bool) {
    titleLabel.text = title
    bodyLabel.text = body
    bodyLabel.font = monospace
      ? .monospacedSystemFont(ofSize: 12, weight: .regular)
      : .systemFont(ofSize: 13, weight: .regular)
  }

  private func buildUI() {
    backgroundColor = .clear

    cardView.backgroundColor = PanelColors.card
    cardView.layer.cornerRadius = 8
    cardView.layer.borderWidth = 1
    cardView.layer.borderColor = PanelColors.border.cgColor
    addSubview(cardView)

    titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
    titleLabel.textColor = PanelColors.text
    titleLabel.numberOfLines = 1

    bodyLabel.textColor = PanelColors.text
    bodyLabel.numberOfLines = 0
    bodyLabel.lineBreakMode = .byWordWrapping

    let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
    stack.axis = .vertical
    stack.spacing = 8
    cardView.addSubview(stack)

    cardView.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      cardView.topAnchor.constraint(equalTo: topAnchor),
      cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
      cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
      cardView.bottomAnchor.constraint(equalTo: bottomAnchor),

      stack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),
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
  private static let maxScrollableSectionHeight: CGFloat = 280

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
  private let locale: String
  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private var notificationObserver: NSObjectProtocol?
  private var scheduledReloadWorkItem: DispatchWorkItem?

  init(entry: DebugNetworkEntry, strings: [String: String], locale: String) {
    self.entryId = entry.id
    self.entry = entry
    self.strings = strings
    self.locale = locale
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

    if let latestEntry = InAppDebuggerStore.shared.networkEntry(withID: entryId) {
      entry = latestEntry
    }
    renderSections()

    notificationObserver = NotificationCenter.default.addObserver(
      forName: .inAppDebuggerStoreDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.scheduleReloadEntryFromStore()
    }
  }

  deinit {
    scheduledReloadWorkItem?.cancel()
    if let notificationObserver {
      NotificationCenter.default.removeObserver(notificationObserver)
    }
  }

  private func scheduleReloadEntryFromStore() {
    scheduledReloadWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }
      self.scheduledReloadWorkItem = nil
      self.reloadEntryFromStore()
    }
    scheduledReloadWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
  }

  private func reloadEntryFromStore() {
    guard let latestEntry = InAppDebuggerStore.shared.networkEntry(withID: entryId),
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

    let sections = isWebSocketKind(entry.kind)
      ? webSocketSections()
      : httpSections()

    let messagesTitle = strings["messages"] ?? "消息"
    let noMessagesText = strings["noMessages"] ?? "暂无消息"

    sections.forEach { title, body, monospace in
      if isWebSocketKind(entry.kind), title == messagesTitle {
        stack.addArrangedSubview(
          makeWebSocketMessagesSection(title: title, raw: entry.messages, fallback: noMessagesText)
        )
      } else {
        stack.addArrangedSubview(
          makeSection(
            title: title,
            body: body,
            monospace: monospace,
            bodyMaxHeight: maxBodyHeight(forSectionTitle: title)
          )
        )
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
    var sections: [(title: String, body: String, monospace: Bool)] = [
      (title: strings["origin"] ?? "来源", body: localizedOriginTitle(entry.origin, strings: strings), monospace: false),
      (title: localizedNetworkTypeTitle(locale: locale), body: localizedNetworkKindTitle(entry.kind, locale: locale), monospace: false),
      (title: strings["method"] ?? "方法", body: entry.method, monospace: false),
      (title: strings["status"] ?? "状态码", body: networkTrailingBadgeTitle(entry) ?? "-", monospace: false),
      (title: strings["protocol"] ?? "协议", body: entry.`protocol` ?? "-", monospace: false),
      (title: "URL", body: entry.url, monospace: true),
      (title: strings["duration"] ?? "耗时", body: durationText, monospace: false),
      (title: strings["requestHeaders"] ?? "请求头", body: headerText(entry.requestHeaders), monospace: true),
      (title: strings["responseHeaders"] ?? "响应头", body: headerText(entry.responseHeaders), monospace: true),
      (title: strings["requestBody"] ?? "请求体", body: entry.requestBody ?? noRequestBodyText, monospace: true),
      (title: strings["responseBody"] ?? "响应体", body: entry.responseBody ?? noResponseBodyText, monospace: true),
      (title: strings["messages"] ?? "消息", body: formattedMessagesText(entry.messages, fallback: noMessagesText), monospace: true),
    ]

    if shouldShowNetworkStateLabel(entry) {
      sections.insert((title: strings["state"] ?? "状态", body: entry.state, monospace: false), at: 4)
    }

    return sections
  }

  private func webSocketSections() -> [(title: String, body: String, monospace: Bool)] {
    let durationText = entry.durationMs.map { "\($0)ms" } ?? "-"
    let noMessagesText = strings["noMessages"] ?? "暂无消息"
    let noEventsText = "暂无事件"
    let messageSummary = "IN \(entry.messageCountIn ?? 0) / OUT \(entry.messageCountOut ?? 0)"
    let byteSummary = "IN \(formatNetworkByteCount(entry.bytesIn)) / OUT \(formatNetworkByteCount(entry.bytesOut))"

    var sections: [(title: String, body: String, monospace: Bool)] = [
      (title: strings["origin"] ?? "来源", body: localizedOriginTitle(entry.origin, strings: strings), monospace: false),
      (title: localizedNetworkTypeTitle(locale: locale), body: localizedNetworkKindTitle(entry.kind, locale: locale), monospace: false),
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

  private func maxBodyHeight(forSectionTitle title: String) -> CGFloat? {
    let requestBodyTitle = strings["requestBody"] ?? "请求体"
    let responseBodyTitle = strings["responseBody"] ?? "响应体"
    let messagesTitle = strings["messages"] ?? "消息"
    if title == requestBodyTitle || title == responseBodyTitle || title == messagesTitle {
      return Self.maxScrollableSectionHeight
    }
    return nil
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
    let scrollView = InAppDebuggerIntrinsicScrollView()
    scrollView.maxHeight = Self.maxScrollableSectionHeight
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
      scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxScrollableSectionHeight),
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

  private func makeSectionBodyView(body: String, monospace: Bool, scrollable: Bool = false) -> UIView {
    let bodyTextView = InAppDebuggerSelectableTextView()
    let presentation = sectionBodyPresentation(body: body, monospace: monospace)
    bodyTextView.font = monospace
      ? .monospacedSystemFont(ofSize: 12, weight: .regular)
      : .systemFont(ofSize: 13, weight: .regular)
    bodyTextView.textColor = PanelColors.text
    bodyTextView.overrideCopyText = presentation.copyText
    bodyTextView.isScrollEnabled = scrollable
    bodyTextView.alwaysBounceVertical = scrollable
    bodyTextView.showsVerticalScrollIndicator = scrollable
    bodyTextView.showsHorizontalScrollIndicator = false
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

  private func makeSection(
    title: String,
    body: String,
    monospace: Bool,
    bodyMaxHeight: CGFloat? = nil
  ) -> UIView {
    let container = UIView()
    container.backgroundColor = PanelColors.card
    container.layer.cornerRadius = 8
    container.layer.borderWidth = 1
    container.layer.borderColor = PanelColors.border.cgColor

    let titleLabel = UILabel()
    titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
    titleLabel.textColor = PanelColors.text
    titleLabel.text = title

    let bodyTextView = makeSectionBodyView(
      body: body,
      monospace: monospace,
      scrollable: bodyMaxHeight != nil
    )
    bodyTextView.accessibilityLabel = title
    if let bodyMaxHeight {
      bodyTextView.translatesAutoresizingMaskIntoConstraints = false
      bodyTextView.heightAnchor.constraint(lessThanOrEqualToConstant: bodyMaxHeight).isActive = true
    }

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

private final class InAppDebuggerIntrinsicScrollView: UIScrollView {
  var maxHeight: CGFloat = .greatestFiniteMagnitude {
    didSet {
      invalidateIntrinsicContentSize()
    }
  }

  private var lastMeasuredContentHeight: CGFloat = 0

  override var contentSize: CGSize {
    didSet {
      if abs(contentSize.height - lastMeasuredContentHeight) > 0.5 {
        lastMeasuredContentHeight = contentSize.height
        invalidateIntrinsicContentSize()
      }
    }
  }

  override var intrinsicContentSize: CGSize {
    let cappedHeight = min(contentSize.height, maxHeight)
    return CGSize(
      width: UIView.noIntrinsicMetric,
      height: ceil(max(cappedHeight, 0))
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if abs(contentSize.height - lastMeasuredContentHeight) > 0.5 {
      lastMeasuredContentHeight = contentSize.height
      invalidateIntrinsicContentSize()
    }
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
