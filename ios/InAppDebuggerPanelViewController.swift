import Darwin
import UIKit

private enum ActiveTab: Int {
  case logs
  case network
  case appInfo
}

private let panelSearchPlaceholder = "Search logs..."
private let logsTabTitle = "Logs"
private let networkTabTitle = "Network"
private let appInfoTabTitle = "App Info"

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

private struct StoreChangeSummary {
  var mask: InAppDebuggerStoreChangeMask
  var changedNetworkIDs: Set<String>

  static let empty = StoreChangeSummary(mask: [], changedNetworkIDs: [])
  static let full = StoreChangeSummary(mask: .all, changedNetworkIDs: [])

  init(mask: InAppDebuggerStoreChangeMask, changedNetworkIDs: Set<String>) {
    self.mask = mask
    self.changedNetworkIDs = changedNetworkIDs
  }

  init(notification: Notification) {
    let rawMask = notification.userInfo?[inAppDebuggerStoreChangeMaskUserInfoKey] as? Int ?? 0
    let rawNetworkIDs = notification.userInfo?[inAppDebuggerStoreChangedNetworkIDsUserInfoKey] as? [String] ?? []
    self.mask = InAppDebuggerStoreChangeMask(rawValue: rawMask)
    self.changedNetworkIDs = Set(rawNetworkIDs)
  }

  mutating func merge(_ other: StoreChangeSummary) {
    mask.formUnion(other.mask)
    changedNetworkIDs.formUnion(other.changedNetworkIDs)
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

private func localizedNetworkTypeTitle() -> String {
  "Request Type"
}

private func localizedNetworkKindFilterTitle(_ kind: NetworkKindFilter) -> String {
  switch kind {
  case .http:
    return "XHR/Fetch"
  case .websocket:
    return "WebSocket"
  case .other:
    return "Other"
  }
}

private func localizedNetworkKindTitle(_ rawKind: String) -> String {
  let trimmedKind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines)
  switch normalizedNetworkKind(trimmedKind) {
  case .http:
    return "XHR/Fetch"
  case .websocket:
    return "WebSocket"
  case .other:
    if !trimmedKind.isEmpty, trimmedKind.lowercased() != NetworkKindFilter.other.rawValue {
      return trimmedKind.uppercased()
    }
    return "Other"
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

private func localizedOriginTitle(_ origin: String) -> String {
  if isNativeOrigin(origin) {
    return "Native"
  }
  return "JS"
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

private var panelNavigationTitleTextAttributes: [NSAttributedString.Key: Any] {
  [
    .foregroundColor: PanelColors.text,
    .font: UIFont.systemFont(ofSize: 18, weight: .bold),
  ]
}

private func makePanelNavigationBarStandardAppearance() -> UINavigationBarAppearance {
  let appearance = UINavigationBarAppearance()
  appearance.configureWithDefaultBackground()
  appearance.shadowColor = .clear
  appearance.titleTextAttributes = panelNavigationTitleTextAttributes
  return appearance
}

private func applyPanelNavigationBarAppearance(to navigationBar: UINavigationBar) {
  let standardAppearance = makePanelNavigationBarStandardAppearance()
  navigationBar.standardAppearance = standardAppearance
  navigationBar.compactAppearance = standardAppearance
  navigationBar.scrollEdgeAppearance = nil
  if #available(iOS 15.0, *) {
    navigationBar.compactScrollEdgeAppearance = nil
  }
}

private func applyPanelNavigationItemAppearance(_ navigationItem: UINavigationItem) {
  let standardAppearance = makePanelNavigationBarStandardAppearance()
  navigationItem.standardAppearance = standardAppearance
  navigationItem.compactAppearance = standardAppearance
  navigationItem.scrollEdgeAppearance = nil
  if #available(iOS 15.0, *) {
    navigationItem.compactScrollEdgeAppearance = nil
  }
}

private final class InAppDebuggerLegacyBarButton: UIButton {
  static let sideLength: CGFloat = 34

  override var intrinsicContentSize: CGSize {
    CGSize(width: Self.sideLength, height: Self.sideLength)
  }

  init(symbolName: String, accessibilityLabel: String, target: AnyObject?, action: Selector?) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    tintColor = PanelColors.primary
    self.accessibilityLabel = accessibilityLabel
    accessibilityTraits.insert(.button)
    setImage(UIImage(systemName: symbolName), for: .normal)
    setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 17, weight: .regular),
      forImageIn: .normal
    )

    if #available(iOS 15.0, *) {
      var config = UIButton.Configuration.plain()
      config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
      configuration = config
    } else {
      contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
    }

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Self.sideLength),
      heightAnchor.constraint(equalToConstant: Self.sideLength),
    ])

    if let target, let action {
      addTarget(target, action: action, for: .touchUpInside)
    }
  }

  required init?(coder: NSCoder) {
    nil
  }
}

final class InAppDebuggerPanelViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, UITabBarDelegate, UISearchResultsUpdating, UIGestureRecognizerDelegate {
  private enum ReloadReason {
    case full
    case dataOnly
  }

  private enum TableUpdatePlan {
    case none
    case reloadData
    case reloadRows([IndexPath])
    case edgeMutation(deletions: [IndexPath], insertions: [IndexPath], reloads: [IndexPath])
  }

  private static let maxIncrementalTableMutationCount = 32
  private static let tableBottomInset: CGFloat = 18
  private static let legacyTabBarBaseHeight: CGFloat = 49

  private var activeTab: ActiveTab = .logs
  private var searchText = ""
  private var selectedLogLevels: Set<String> = PanelFilterPreferences.loadLogLevels()
  private var selectedLogOrigins: Set<String> = PanelFilterPreferences.loadLogOrigins()
  private var selectedNetworkOrigins: Set<String> = PanelFilterPreferences.loadNetworkOrigins()
  private var selectedNetworkKinds: Set<String> = PanelFilterPreferences.loadNetworkKinds()
  private var sortAscending = true
  private var displayedLogs: [DebugLogEntry] = []
  private var displayedNetwork: [DebugNetworkEntry] = []
  private var currentLogRetentionState = DebugLogRetentionState.empty
  private var notificationObserver: NSObjectProtocol?
  private var currentConfig = DebugConfig()
  private var scheduledReloadWorkItem: DispatchWorkItem?
  private var scheduledSearchWorkItem: DispatchWorkItem?
  private var pendingReloadChangeSummary = StoreChangeSummary.empty
  private let filteringQueue = DispatchQueue(label: "expo.inappdebugger.panel.filtering", qos: .userInitiated)
  private var visibleRenderGeneration = 0
  private var isSuspendingLiveUpdatesForScroll = false
  private var renderedAppInfoSignature = ""
  private var renderedTableTab: ActiveTab?
  private var lastAppliedBottomBarInset: CGFloat = -1
  private var legacyTabBarHeightConstraint: NSLayoutConstraint?
  private var legacyHeaderWidthConstraint: NSLayoutConstraint?
  private lazy var dismissKeyboardTapGestureRecognizer: UITapGestureRecognizer = {
    let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
    recognizer.cancelsTouchesInView = false
    recognizer.delegate = self
    return recognizer
  }()

  private lazy var panelSearchController: UISearchController = {
    let controller = UISearchController(searchResultsController: nil)
    controller.searchResultsUpdater = self
    controller.obscuresBackgroundDuringPresentation = false
    controller.hidesNavigationBarDuringPresentation = false
    controller.automaticallyShowsCancelButton = false

    let searchField = controller.searchBar.searchTextField
    searchField.clearButtonMode = .whileEditing
    searchField.autocapitalizationType = .none
    searchField.autocorrectionType = .no
    searchField.smartDashesType = .no
    searchField.smartQuotesType = .no
    searchField.smartInsertDeleteType = .no
    searchField.returnKeyType = .done
    return controller
  }()

  private lazy var legacySearchField: UISearchTextField = {
    let field = UISearchTextField()
    field.clearButtonMode = .whileEditing
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.smartDashesType = .no
    field.smartQuotesType = .no
    field.smartInsertDeleteType = .no
    field.returnKeyType = .done
    field.addTarget(self, action: #selector(searchTextChanged(_:)), for: .editingChanged)
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    NSLayoutConstraint.activate([
      field.heightAnchor.constraint(equalToConstant: 36),
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
    ])
    return field
  }()

  private lazy var clearBarButtonItem: UIBarButtonItem = {
    let item = UIBarButtonItem(
      image: UIImage(systemName: "trash"),
      style: .plain,
      target: self,
      action: #selector(clearTapped)
    )
    return item
  }()

  private lazy var menuBarButtonItem: UIBarButtonItem = {
    let item = UIBarButtonItem(
      image: UIImage(systemName: "ellipsis.circle"),
      style: .plain,
      target: nil,
      action: nil
    )
    return item
  }()

  private lazy var closeBarButtonItem: UIBarButtonItem = {
    let item = UIBarButtonItem(
      image: UIImage(systemName: "xmark"),
      style: .plain,
      target: self,
      action: #selector(closeTapped)
    )
    return item
  }()

  private lazy var appInfoCloseBarButtonItem: UIBarButtonItem = {
    let item = UIBarButtonItem(
      image: UIImage(systemName: "xmark"),
      style: .plain,
      target: self,
      action: #selector(closeTapped)
    )
    return item
  }()

  private lazy var legacyClearButton: InAppDebuggerLegacyBarButton = {
    InAppDebuggerLegacyBarButton(
      symbolName: "trash",
      accessibilityLabel: "Clear",
      target: self,
      action: #selector(clearTapped)
    )
  }()

  private lazy var legacyMenuButton: InAppDebuggerLegacyBarButton = {
    let button = InAppDebuggerLegacyBarButton(
      symbolName: "ellipsis.circle",
      accessibilityLabel: localizedMenuTitle(),
      target: nil,
      action: nil
    )
    button.showsMenuAsPrimaryAction = true
    return button
  }()

  private lazy var legacyCloseButton: InAppDebuggerLegacyBarButton = {
    InAppDebuggerLegacyBarButton(
      symbolName: "xmark",
      accessibilityLabel: "Close",
      target: self,
      action: #selector(closeTapped)
    )
  }()

  private lazy var legacyHeaderContainer: UIView = {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false

    let stack = UIStackView(arrangedSubviews: [
      legacySearchField,
      legacyClearButton,
      legacyMenuButton,
      legacyCloseButton,
    ])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      container.heightAnchor.constraint(equalToConstant: 36),
    ])

    let widthConstraint = container.widthAnchor.constraint(equalToConstant: 320)
    widthConstraint.isActive = true
    legacyHeaderWidthConstraint = widthConstraint
    return container
  }()

  private lazy var trailingButtonGroup: UIBarButtonItemGroup = {
    UIBarButtonItemGroup(
      barButtonItems: [clearBarButtonItem, menuBarButtonItem, closeBarButtonItem],
      representativeItem: nil
    )
  }()

  private lazy var logsTabBarItem = UITabBarItem(
    title: logsTabTitle,
    image: UIImage(systemName: "doc.text"),
    tag: ActiveTab.logs.rawValue
  )

  private lazy var networkTabBarItem = UITabBarItem(
    title: networkTabTitle,
    image: UIImage(systemName: "network"),
    tag: ActiveTab.network.rawValue
  )

  private lazy var appInfoTabBarItem = UITabBarItem(
    title: appInfoTabTitle,
    image: UIImage(systemName: "info.circle"),
    tag: ActiveTab.appInfo.rawValue
  )

  private lazy var tabBar: UITabBar = {
    let bar = UITabBar()
    bar.delegate = self
    bar.itemPositioning = .fill
    bar.items = [logsTabBarItem, networkTabBarItem, appInfoTabBarItem]
    bar.selectedItem = logsTabBarItem
    return bar
  }()

  private lazy var tableView: UITableView = {
    let table = UITableView(frame: .zero, style: .plain)
    table.backgroundColor = PanelColors.background
    table.separatorStyle = .none
    table.delegate = self
    table.dataSource = self
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 108
    table.keyboardDismissMode = .onDrag
    table.contentInsetAdjustmentBehavior = .automatic
    table.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: Self.tableBottomInset, right: 0)
    table.register(InAppDebuggerLogCell.self, forCellReuseIdentifier: InAppDebuggerLogCell.reuseIdentifier)
    table.register(InAppDebuggerNetworkCell.self, forCellReuseIdentifier: InAppDebuggerNetworkCell.reuseIdentifier)
    return table
  }()

  private lazy var appInfoScrollView: UIScrollView = {
    let scrollView = UIScrollView()
    scrollView.backgroundColor = PanelColors.background
    scrollView.alwaysBounceVertical = true
    scrollView.keyboardDismissMode = .onDrag
    scrollView.contentInsetAdjustmentBehavior = .automatic
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
  private let logRetentionNoticeView = InAppDebuggerTableNoticeView()

  override func viewDidLoad() {
    super.viewDidLoad()
    currentConfig = InAppDebuggerStore.shared.currentConfig()
    view.backgroundColor = PanelColors.background
    navigationItem.largeTitleDisplayMode = .never
    definesPresentationContext = true

    configureNavigationBar()
    layoutUI()
    installDismissKeyboardGestureIfNeeded()
    updateFilterMenu()
    reloadFromStore()

    notificationObserver = NotificationCenter.default.addObserver(
      forName: .inAppDebuggerStoreDidChange,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self else {
        return
      }
      self.scheduleReloadFromStore(changeSummary: StoreChangeSummary(notification: notification))
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    configureNavigationBar()
    installDismissKeyboardGestureIfNeeded()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    InAppDebuggerStore.shared.setLiveUpdatesEnabled(true)
    syncNativeCaptureStates()
    reloadFromStore()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateLegacyHeaderWidthIfNeeded()
    updateLegacyTabBarHeightIfNeeded()
    updateBottomContentInsetsIfNeeded()
    updateLogRetentionNoticeIfNeeded()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    guard isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent else {
      return
    }
    InAppDebuggerOverlayManager.shared.panelWillDismiss(
      using: transitionCoordinator ?? navigationController?.transitionCoordinator
    )
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
    InAppDebuggerOverlayManager.shared.panelDidDismiss()
  }

  deinit {
    scheduledReloadWorkItem?.cancel()
    scheduledSearchWorkItem?.cancel()
    dismissKeyboardTapGestureRecognizer.view?.removeGestureRecognizer(dismissKeyboardTapGestureRecognizer)
    InAppDebuggerStore.shared.setLiveUpdatesEnabled(false)
    InAppDebuggerNativeLogCapture.shared.setPanelActive(false)
    InAppDebuggerNativeNetworkCapture.shared.setPanelActive(false)
    InAppDebuggerNativeWebSocketCapture.shared.setPanelActive(false)
    if let notificationObserver {
      NotificationCenter.default.removeObserver(notificationObserver)
    }
  }

  private func configureNavigationBar() {
    let shouldShowSearchControl = activeTab != .appInfo
    if #available(iOS 26.0, *) {
      title = nil
      navigationItem.titleView = nil
      navigationItem.searchController = shouldShowSearchControl ? panelSearchController : nil
      navigationItem.preferredSearchBarPlacement = .integrated
      navigationItem.searchBarPlacementAllowsToolbarIntegration = false
      if shouldShowSearchControl {
        navigationItem.pinnedTrailingGroup = trailingButtonGroup
        navigationItem.rightBarButtonItems = nil
      } else {
        navigationItem.pinnedTrailingGroup = nil
        navigationItem.rightBarButtonItems = [appInfoCloseBarButtonItem]
      }
    } else {
      title = nil
      navigationItem.searchController = nil
      navigationItem.titleView = legacyHeaderContainer
      if #available(iOS 16.0, *) {
        navigationItem.pinnedTrailingGroup = nil
      }
      navigationItem.rightBarButtonItems = nil
    }

    updateTabBarState()
    updateSearchPresentation()
    updateFilterMenu()
    updateBarButtonItems()

    guard let navigationBar = navigationController?.navigationBar else {
      return
    }
    navigationController?.navigationBar.prefersLargeTitles = false
    applyPanelNavigationBarAppearance(to: navigationBar)
  }

  private func layoutUI() {
    view.addSubview(tableView)
    view.addSubview(appInfoScrollView)
    view.addSubview(tabBar)
    appInfoScrollView.addSubview(appInfoStackView)

    tableView.translatesAutoresizingMaskIntoConstraints = false
    appInfoScrollView.translatesAutoresizingMaskIntoConstraints = false
    appInfoStackView.translatesAutoresizingMaskIntoConstraints = false
    tabBar.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      appInfoScrollView.topAnchor.constraint(equalTo: view.topAnchor),
      appInfoScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      appInfoScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      appInfoScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      appInfoStackView.topAnchor.constraint(equalTo: appInfoScrollView.contentLayoutGuide.topAnchor, constant: 4),
      appInfoStackView.leadingAnchor.constraint(equalTo: appInfoScrollView.contentLayoutGuide.leadingAnchor, constant: 14),
      appInfoStackView.trailingAnchor.constraint(equalTo: appInfoScrollView.contentLayoutGuide.trailingAnchor, constant: -14),
      appInfoStackView.bottomAnchor.constraint(equalTo: appInfoScrollView.contentLayoutGuide.bottomAnchor, constant: -18),
      appInfoStackView.widthAnchor.constraint(equalTo: appInfoScrollView.frameLayoutGuide.widthAnchor, constant: -28),

      tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    if #unavailable(iOS 26.0) {
      let heightConstraint = tabBar.heightAnchor.constraint(equalToConstant: Self.legacyTabBarBaseHeight)
      heightConstraint.isActive = true
      legacyTabBarHeightConstraint = heightConstraint
    }
  }

  private func updateLegacyHeaderWidthIfNeeded() {
    guard navigationItem.titleView === legacyHeaderContainer, let legacyHeaderWidthConstraint else {
      return
    }

    let navigationBarWidth = navigationController?.navigationBar.bounds.width ?? view.bounds.width
    let horizontalMargin: CGFloat = 20
    let availableWidth = max(180, navigationBarWidth - horizontalMargin)
    legacyHeaderWidthConstraint.constant = availableWidth
  }

  private func updateLegacyTabBarHeightIfNeeded() {
    guard #unavailable(iOS 26.0), let legacyTabBarHeightConstraint else {
      return
    }

    let nextHeight = Self.legacyTabBarBaseHeight + view.safeAreaInsets.bottom
    guard abs(legacyTabBarHeightConstraint.constant - nextHeight) > 0.5 else {
      return
    }
    legacyTabBarHeightConstraint.constant = nextHeight
  }

  private func installDismissKeyboardGestureIfNeeded() {
    guard let containerView = navigationController?.view ?? view else {
      return
    }
    guard dismissKeyboardTapGestureRecognizer.view !== containerView else {
      return
    }
    dismissKeyboardTapGestureRecognizer.view?.removeGestureRecognizer(dismissKeyboardTapGestureRecognizer)
    containerView.addGestureRecognizer(dismissKeyboardTapGestureRecognizer)
  }

  private func updateBottomContentInsetsIfNeeded() {
    let resolvedTabBarHeight = legacyTabBarHeightConstraint?.constant ?? tabBar.bounds.height
    let tabBarHeight = max(0, resolvedTabBarHeight)
    let bottomInset = tabBarHeight + Self.tableBottomInset
    guard abs(bottomInset - lastAppliedBottomBarInset) > 0.5 else {
      return
    }

    lastAppliedBottomBarInset = bottomInset
    tableView.contentInset.bottom = bottomInset
    tableView.verticalScrollIndicatorInsets.bottom = bottomInset
    appInfoScrollView.contentInset.bottom = bottomInset
    appInfoScrollView.verticalScrollIndicatorInsets.bottom = bottomInset
  }

  private func currentSearchPlaceholder() -> String {
    activeTab == .network ? localizedNetworkSearchPlaceholder() : panelSearchPlaceholder
  }

  private func updateSearchPresentation() {
    let shouldShowSearchControl = activeTab != .appInfo
    let placeholder = currentSearchPlaceholder()

    if #available(iOS 26.0, *) {
      panelSearchController.searchBar.placeholder = placeholder
      panelSearchController.searchBar.text = searchText
      panelSearchController.searchBar.isEnabled = shouldShowSearchControl
    } else {
      legacySearchField.placeholder = placeholder
      legacySearchField.text = searchText
      legacySearchField.isEnabled = shouldShowSearchControl
      legacySearchField.alpha = shouldShowSearchControl ? 1 : 0
      legacySearchField.isUserInteractionEnabled = shouldShowSearchControl
    }
  }

  private func updateFilterMenu() {
    guard activeTab != .appInfo else {
      menuBarButtonItem.menu = nil
      legacyMenuButton.menu = nil
      return
    }

    let sortOptions = [
      makePersistentMenuAction(title: localizedSortTitle(ascending: true), state: sortAscending ? .on : .off) { [weak self] in
        self?.setSortAscending(true)
      },
      makePersistentMenuAction(title: localizedSortTitle(ascending: false), state: sortAscending ? .off : .on) { [weak self] in
        self?.setSortAscending(false)
      },
    ]
    let sortMenu = UIMenu(title: localizedSortMenuTitle(), options: .displayInline, children: sortOptions)

    let selectedOrigins = activeTab == .logs ? selectedLogOrigins : selectedNetworkOrigins
    let originOptions = ["js", "native"].map { origin in
      let title = localizedOriginTitle(origin)
      let isSelected = selectedOrigins.contains(origin)
      return makePersistentMenuAction(title: title, state: isSelected ? .on : .off) { [weak self] in
        self?.toggleOrigin(origin)
      }
    }

    let originMenu = UIMenu(title: "Origin", options: .displayInline, children: originOptions)
    var menuChildren: [UIMenuElement] = [sortMenu, originMenu]
    if activeTab == .logs {
      let levelOptions = ["log", "info", "warn", "error", "debug"].map { level in
        let isSelected = selectedLogLevels.contains(level)
        return makePersistentMenuAction(title: level.uppercased(), state: isSelected ? .on : .off) { [weak self] in
          self?.toggleLevel(level)
        }
      }
      let levelMenu = UIMenu(title: "Level", options: .displayInline, children: levelOptions)
      menuChildren.append(levelMenu)
    } else {
      let kindOptions = NetworkKindFilter.allCases.map { kindFilter in
        let kind = kindFilter.rawValue
        let isSelected = selectedNetworkKinds.contains(kind)
        return makePersistentMenuAction(
          title: localizedNetworkKindFilterTitle(kindFilter),
          state: isSelected ? .on : .off
        ) { [weak self] in
          self?.toggleNetworkKind(kind)
        }
      }
      let kindMenu = UIMenu(
        title: localizedNetworkTypeTitle(),
        options: .displayInline,
        children: kindOptions
      )
      menuChildren.append(kindMenu)
    }

    let menu = UIMenu(title: localizedMenuTitle(), children: menuChildren)
    menuBarButtonItem.menu = menu
    legacyMenuButton.menu = menu
  }

  private func makePersistentMenuAction(
    title: String,
    state: UIMenuElement.State = .off,
    handler: @escaping () -> Void
  ) -> UIAction {
    var attributes: UIMenuElement.Attributes = []
    if #available(iOS 16.0, *) {
      attributes.insert(.keepsMenuPresented)
    }
    return UIAction(title: title, attributes: attributes, state: state) { _ in
      handler()
    }
  }

  private func updateTabBarState() {
    logsTabBarItem.title = logsTabTitle
    networkTabBarItem.title = networkTabTitle
    appInfoTabBarItem.title = appInfoTabTitle
    networkTabBarItem.isEnabled = currentConfig.enableNetworkTab
    tabBar.selectedItem = tabBarItem(for: activeTab)
  }

  private func updateBarButtonItems() {
    let shouldShowLegacyActions = activeTab != .appInfo
    clearBarButtonItem.accessibilityLabel = "Clear"
    menuBarButtonItem.accessibilityLabel = localizedMenuTitle()
    closeBarButtonItem.accessibilityLabel = "Close"
    appInfoCloseBarButtonItem.accessibilityLabel = "Close"
    legacyClearButton.accessibilityLabel = "Clear"
    legacyMenuButton.accessibilityLabel = localizedMenuTitle()
    legacyCloseButton.accessibilityLabel = "Close"

    let areActionsEnabled = activeTab != .appInfo
    clearBarButtonItem.isEnabled = areActionsEnabled
    menuBarButtonItem.isEnabled = areActionsEnabled
    legacyClearButton.isEnabled = shouldShowLegacyActions
    legacyMenuButton.isEnabled = shouldShowLegacyActions
    legacyClearButton.alpha = shouldShowLegacyActions ? 1 : 0
    legacyMenuButton.alpha = shouldShowLegacyActions ? 1 : 0
    legacyClearButton.isUserInteractionEnabled = shouldShowLegacyActions
    legacyMenuButton.isUserInteractionEnabled = shouldShowLegacyActions
  }

  private func tabBarItem(for tab: ActiveTab) -> UITabBarItem {
    switch tab {
    case .logs:
      return logsTabBarItem
    case .network:
      return networkTabBarItem
    case .appInfo:
      return appInfoTabBarItem
    }
  }

  private func setActiveTab(_ nextTab: ActiveTab) {
    var resolvedTab = nextTab
    if resolvedTab == .network && !currentConfig.enableNetworkTab {
      resolvedTab = .logs
    }
    guard resolvedTab != activeTab else {
      updateTabBarState()
      return
    }

    activeTab = resolvedTab
    deactivateSearchInput()
    syncNativeCaptureStates()
    configureNavigationBar()
    updateContentVisibility()
    reloadFromStore()
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

  private func configuredCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
    switch activeTab {
    case .logs:
      guard displayedLogs.indices.contains(indexPath.row) else {
        return UITableViewCell()
      }
      let entry = displayedLogs[indexPath.row]
      let cell = tableView.dequeueReusableCell(
        withIdentifier: InAppDebuggerLogCell.reuseIdentifier,
        for: indexPath
      ) as? InAppDebuggerLogCell
      cell?.configure(entry: entry)
      return cell ?? UITableViewCell()
    case .network:
      guard displayedNetwork.indices.contains(indexPath.row) else {
        return UITableViewCell()
      }
      let entry = displayedNetwork[indexPath.row]
      let cell = tableView.dequeueReusableCell(
        withIdentifier: InAppDebuggerNetworkCell.reuseIdentifier,
        for: indexPath
      ) as? InAppDebuggerNetworkCell
      cell?.configure(entry: entry)
      return cell ?? UITableViewCell()
    case .appInfo:
      return UITableViewCell()
    }
  }

  private func reloadTableData() {
    UIView.performWithoutAnimation {
      tableView.reloadData()
    }
  }

  private func applyTableUpdate(_ plan: TableUpdatePlan, for tab: ActiveTab) {
    guard tab != .appInfo else {
      return
    }

    renderedTableTab = tab
    updateEmptyState()

    switch plan {
    case .none:
      return
    case .reloadData:
      reloadTableData()
    case .reloadRows(let indexPaths):
      guard !indexPaths.isEmpty else {
        return
      }
      UIView.performWithoutAnimation {
        tableView.reloadRows(at: indexPaths, with: .none)
      }
    case .edgeMutation(let deletions, let insertions, let reloads):
      guard !deletions.isEmpty || !insertions.isEmpty else {
        guard !reloads.isEmpty else {
          return
        }
        UIView.performWithoutAnimation {
          tableView.reloadRows(at: reloads, with: .none)
        }
        return
      }

      UIView.performWithoutAnimation {
        tableView.performBatchUpdates {
          if !deletions.isEmpty {
            tableView.deleteRows(at: deletions, with: .none)
          }
          if !insertions.isEmpty {
            tableView.insertRows(at: insertions, with: .none)
          }
        } completion: { [weak self] _ in
          guard let self, !reloads.isEmpty else {
            return
          }
          UIView.performWithoutAnimation {
            self.tableView.reloadRows(at: reloads, with: .none)
          }
        }
      }
    }
  }

  private func reloadFromStore(
    reason: ReloadReason = .full,
    changeSummary: StoreChangeSummary = .full
  ) {
    if reason == .full || changeSummary.mask.contains(.config) {
      let state = InAppDebuggerStore.shared.snapshotState()
      renderFromSnapshotState(
        config: state.0,
        logs: state.1,
        errors: state.2,
        network: state.3,
        logRetentionState: state.4,
        reason: reason,
        changeSummary: changeSummary
      )
      return
    }

    switch activeTab {
    case .logs:
      let state = InAppDebuggerStore.shared.snapshotLogsState()
      renderLogs(
        state.0,
        logRetentionState: state.1,
        changeSummary: changeSummary
      )
    case .network:
      renderNetwork(
        InAppDebuggerStore.shared.snapshotNetwork(),
        changeSummary: changeSummary
      )
    case .appInfo:
      let state = InAppDebuggerStore.shared.snapshotAppInfo()
      renderAppInfo(logs: state.0, errors: state.1)
    }
  }

  private func renderFromSnapshotState(
    config: DebugConfig,
    logs: [DebugLogEntry],
    errors: [DebugErrorEntry],
    network: [DebugNetworkEntry],
    logRetentionState: DebugLogRetentionState,
    reason: ReloadReason,
    changeSummary: StoreChangeSummary
  ) {
    let shouldRefreshChrome = reason == .full || config != currentConfig
    if shouldRefreshChrome {
      currentConfig = config

      if !currentConfig.enableNetworkTab && activeTab == .network {
        activeTab = .logs
      }

      configureNavigationBar()
      updateContentVisibility()
      if view.window != nil {
        syncNativeCaptureStates()
      }
    }

    if activeTab == .appInfo {
      renderAppInfo(logs: logs, errors: errors)
      return
    }

    if activeTab == .logs {
      renderLogs(logs, logRetentionState: logRetentionState, changeSummary: changeSummary)
      return
    }

    renderNetwork(network, changeSummary: changeSummary)
  }

  private func renderLogs(
    _ source: [DebugLogEntry],
    logRetentionState: DebugLogRetentionState,
    changeSummary: StoreChangeSummary
  ) {
    let generation = nextVisibleRenderGeneration()
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let selectedLogLevels = selectedLogLevels
    let selectedLogOrigins = selectedLogOrigins
    let sortAscending = sortAscending

    filteringQueue.async { [weak self] in
      let nextLogs = autoreleasepool {
        Self.filterLogs(
          source,
          query: query,
          selectedLogLevels: selectedLogLevels,
          selectedLogOrigins: selectedLogOrigins,
          sortAscending: sortAscending
        )
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.visibleRenderGeneration == generation, self.activeTab == .logs else {
          return
        }
        self.applyRenderedLogs(
          nextLogs,
          logRetentionState: logRetentionState,
          changeSummary: changeSummary
        )
      }
    }
  }

  private func renderNetwork(_ source: [DebugNetworkEntry], changeSummary: StoreChangeSummary) {
    let generation = nextVisibleRenderGeneration()
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let selectedNetworkOrigins = selectedNetworkOrigins
    let selectedNetworkKinds = selectedNetworkKinds
    let sortAscending = sortAscending

    filteringQueue.async { [weak self] in
      let nextNetwork = autoreleasepool {
        Self.filterNetwork(
          source,
          query: query,
          selectedNetworkOrigins: selectedNetworkOrigins,
          selectedNetworkKinds: selectedNetworkKinds,
          sortAscending: sortAscending
        )
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.visibleRenderGeneration == generation, self.activeTab == .network else {
          return
        }
        self.applyRenderedNetwork(nextNetwork, changeSummary: changeSummary)
      }
    }
  }

  private func scheduleReloadFromStore(changeSummary: StoreChangeSummary = .full) {
    guard !isSuspendingLiveUpdatesForScroll else {
      return
    }
    guard shouldReload(for: changeSummary) else {
      return
    }
    pendingReloadChangeSummary.merge(changeSummary)
    scheduledReloadWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }
      let summary = self.pendingReloadChangeSummary
      self.pendingReloadChangeSummary = .empty
      self.scheduledReloadWorkItem = nil
      if self.tableView.isDragging || self.tableView.isDecelerating {
        return
      }
      self.reloadFromStore(reason: .dataOnly, changeSummary: summary)
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
      self.reloadFromStore(reason: .dataOnly, changeSummary: .empty)
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
    reloadFromStore(reason: .dataOnly, changeSummary: .empty)
  }

  private func updateContentVisibility() {
    let showingAppInfo = activeTab == .appInfo
    tableView.isHidden = showingAppInfo
    appInfoScrollView.isHidden = !showingAppInfo
    if showingAppInfo {
      tableView.backgroundView = nil
    }
    updateLogRetentionNoticeIfNeeded()
    view.setNeedsLayout()
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
        ? "No matching logs found"
        : "No logs yet"
      detail = selectedLogOrigins.isEmpty
        ? localizedNoLogOriginHint()
        : (selectedLogLevels.isEmpty ? localizedNoLevelHint() : localizedEmptyHint())
    } else {
      let isOriginEmpty = selectedNetworkOrigins.isEmpty
      let isKindEmpty = selectedNetworkKinds.isEmpty
      title = hasSearch || isOriginEmpty || isKindEmpty
        ? localizedNoNetworkResultTitle()
        : "No network requests yet"
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
    ascending ? "Time Asc" : "Time Desc"
  }

  private func localizedSortMenuTitle() -> String {
    "Sort"
  }

  private func localizedMenuTitle() -> String {
    "Menu"
  }

  private func localizedNetworkSearchPlaceholder() -> String {
    "Search network requests..."
  }

  private func localizedEmptyHint() -> String {
    "Try another keyword or generate new events."
  }

  private func localizedNoLevelHint() -> String {
    "Select at least one level to show logs."
  }

  private func localizedNoLogOriginHint() -> String {
    "Select JS or Native to show logs."
  }

  private func localizedNoNetworkOriginHint() -> String {
    "Select JS or Native to show network entries."
  }

  private func localizedNoNetworkKindHint() -> String {
    "Select at least one request type to show network entries."
  }

  private func localizedNoNetworkFilterHint() -> String {
    "Select at least one source and request type to show network entries."
  }

  private func localizedNoNetworkResultTitle() -> String {
    "No matching network requests found"
  }

  private func shouldReload(for changeSummary: StoreChangeSummary) -> Bool {
    if changeSummary.mask.contains(.config) || changeSummary.mask == .all {
      return true
    }

    switch activeTab {
    case .logs:
      return changeSummary.mask.contains(.logs)
    case .network:
      return changeSummary.mask.contains(.network)
    case .appInfo:
      return changeSummary.mask.contains(.logs) || changeSummary.mask.contains(.errors)
    }
  }

  private func nextVisibleRenderGeneration() -> Int {
    visibleRenderGeneration += 1
    return visibleRenderGeneration
  }

  private func indexPaths(for ids: [String], matching targetIDs: Set<String>) -> [IndexPath] {
    guard !ids.isEmpty, !targetIDs.isEmpty else {
      return []
    }

    var indexPaths: [IndexPath] = []
    indexPaths.reserveCapacity(min(ids.count, targetIDs.count))
    for (index, id) in ids.enumerated() where targetIDs.contains(id) {
      indexPaths.append(IndexPath(row: index, section: 0))
    }
    return indexPaths
  }

  private func indexPaths(forRowRange range: Range<Int>) -> [IndexPath] {
    guard !range.isEmpty else {
      return []
    }

    var indexPaths: [IndexPath] = []
    indexPaths.reserveCapacity(range.count)
    for row in range {
      indexPaths.append(IndexPath(row: row, section: 0))
    }
    return indexPaths
  }

  private func suffixPrefixOverlapCount(_ previousIDs: [String], _ nextIDs: [String]) -> Int {
    guard
      !previousIDs.isEmpty,
      !nextIDs.isEmpty,
      let nextFirst = nextIDs.first,
      let previousStart = previousIDs.firstIndex(of: nextFirst)
    else {
      return 0
    }

    let overlapCount = previousIDs.count - previousStart
    guard overlapCount <= nextIDs.count else {
      return 0
    }

    for offset in 0..<overlapCount where previousIDs[previousStart + offset] != nextIDs[offset] {
      return 0
    }
    return overlapCount
  }

  private func prefixSuffixOverlapCount(_ previousIDs: [String], _ nextIDs: [String]) -> Int {
    guard
      !previousIDs.isEmpty,
      !nextIDs.isEmpty,
      let previousFirst = previousIDs.first,
      let nextStart = nextIDs.firstIndex(of: previousFirst)
    else {
      return 0
    }

    let overlapCount = nextIDs.count - nextStart
    guard overlapCount <= previousIDs.count else {
      return 0
    }

    for offset in 0..<overlapCount where previousIDs[offset] != nextIDs[nextStart + offset] {
      return 0
    }
    return overlapCount
  }

  private func edgeMutationPlan(
    previousIDs: [String],
    nextIDs: [String],
    reloadIDs: Set<String>,
    overlapCount: Int,
    deletesFromHead: Bool
  ) -> TableUpdatePlan? {
    let deletionCount = previousIDs.count - overlapCount
    let insertionCount = nextIDs.count - overlapCount
    guard deletionCount + insertionCount <= Self.maxIncrementalTableMutationCount else {
      return nil
    }

    let deletions = deletesFromHead
      ? indexPaths(forRowRange: 0..<deletionCount)
      : indexPaths(forRowRange: overlapCount..<previousIDs.count)
    let insertions = deletesFromHead
      ? indexPaths(forRowRange: overlapCount..<nextIDs.count)
      : indexPaths(forRowRange: 0..<insertionCount)
    let insertedIDs = Set(
      deletesFromHead
        ? nextIDs.suffix(insertionCount)
        : nextIDs.prefix(insertionCount)
    )
    let reloads = indexPaths(for: nextIDs, matching: reloadIDs.subtracting(insertedIDs))

    if deletions.isEmpty, insertions.isEmpty {
      guard !reloads.isEmpty else {
        return TableUpdatePlan.none
      }
      return .reloadRows(reloads)
    }
    return .edgeMutation(deletions: deletions, insertions: insertions, reloads: reloads)
  }

  private func tableUpdatePlan(
    previousIDs: [String],
    nextIDs: [String],
    reloadIDs: Set<String>,
    tab: ActiveTab
  ) -> TableUpdatePlan {
    guard renderedTableTab == tab else {
      return .reloadData
    }

    if previousIDs == nextIDs {
      let reloads = indexPaths(for: nextIDs, matching: reloadIDs)
      guard !reloads.isEmpty else {
        return .none
      }
      return reloads.count >= nextIDs.count ? .reloadData : .reloadRows(reloads)
    }

    let forwardOverlap = suffixPrefixOverlapCount(previousIDs, nextIDs)
    let backwardOverlap = prefixSuffixOverlapCount(previousIDs, nextIDs)

    if forwardOverlap >= backwardOverlap,
       let plan = edgeMutationPlan(
         previousIDs: previousIDs,
         nextIDs: nextIDs,
         reloadIDs: reloadIDs,
         overlapCount: forwardOverlap,
         deletesFromHead: true
       ) {
      return plan
    }

    if let plan = edgeMutationPlan(
      previousIDs: previousIDs,
      nextIDs: nextIDs,
      reloadIDs: reloadIDs,
      overlapCount: backwardOverlap,
      deletesFromHead: false
    ) {
      return plan
    }

    return .reloadData
  }

  private func applyRenderedLogs(
    _ nextLogs: [DebugLogEntry],
    logRetentionState: DebugLogRetentionState,
    changeSummary: StoreChangeSummary
  ) {
    let previousLogs = displayedLogs
    let shouldReconfigureAll = changeSummary.mask.contains(.config)
    displayedLogs = nextLogs
    currentLogRetentionState = logRetentionState
    updateLogRetentionNoticeIfNeeded()
    let reloadIDs = shouldReconfigureAll ? Set(nextLogs.map(\.id)) : []
    let plan = tableUpdatePlan(
      previousIDs: previousLogs.map(\.id),
      nextIDs: nextLogs.map(\.id),
      reloadIDs: reloadIDs,
      tab: .logs
    )
    applyTableUpdate(plan, for: .logs)
  }

  private func applyRenderedNetwork(_ nextNetwork: [DebugNetworkEntry], changeSummary: StoreChangeSummary) {
    let previousNetwork = displayedNetwork
    displayedNetwork = nextNetwork

    let shouldReconfigureAll = changeSummary.mask.contains(.config) || (changeSummary.mask.isEmpty && !nextNetwork.isEmpty)
    if changeSummary.mask.isEmpty, previousNetwork == nextNetwork, renderedTableTab == .network {
      applyTableUpdate(.none, for: .network)
      return
    }

    let reloadIDs: Set<String>
    if shouldReconfigureAll {
      reloadIDs = Set(nextNetwork.map(\.id))
    } else if changeSummary.changedNetworkIDs.isEmpty {
      reloadIDs = []
    } else {
      reloadIDs = Set(
        nextNetwork.compactMap { entry in
          changeSummary.changedNetworkIDs.contains(entry.id) ? entry.id : nil
        }
      )
    }

    let plan = tableUpdatePlan(
      previousIDs: previousNetwork.map(\.id),
      nextIDs: nextNetwork.map(\.id),
      reloadIDs: reloadIDs,
      tab: .network
    )
    applyTableUpdate(plan, for: .network)
  }

  private static func filterLogs(
    _ source: [DebugLogEntry],
    query: String,
    selectedLogLevels: Set<String>,
    selectedLogOrigins: Set<String>,
    sortAscending: Bool
  ) -> [DebugLogEntry] {
    guard !source.isEmpty, !selectedLogLevels.isEmpty, !selectedLogOrigins.isEmpty else {
      return []
    }

    if query.isEmpty &&
      selectedLogLevels == PanelFilterPreferences.allLevels &&
      selectedLogOrigins == PanelFilterPreferences.allOrigins {
      return sortAscending ? source : Array(source.reversed())
    }

    var result: [DebugLogEntry] = []
    result.reserveCapacity(source.count)
    if sortAscending {
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
      return result
    }

    for entry in source.reversed() {
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
    return result
  }

  private static func filterNetwork(
    _ source: [DebugNetworkEntry],
    query: String,
    selectedNetworkOrigins: Set<String>,
    selectedNetworkKinds: Set<String>,
    sortAscending: Bool
  ) -> [DebugNetworkEntry] {
    guard !source.isEmpty, !selectedNetworkOrigins.isEmpty, !selectedNetworkKinds.isEmpty else {
      return []
    }

    if query.isEmpty &&
      selectedNetworkOrigins == PanelFilterPreferences.allOrigins &&
      selectedNetworkKinds == PanelFilterPreferences.allNetworkKinds {
      return sortAscending ? source : Array(source.reversed())
    }

    var result: [DebugNetworkEntry] = []
    result.reserveCapacity(source.count)

    func matches(_ entry: DebugNetworkEntry) -> Bool {
      let normalizedKind = normalizedNetworkKind(entry.kind).rawValue
      guard selectedNetworkOrigins.contains(entry.origin), selectedNetworkKinds.contains(normalizedKind) else {
        return false
      }
      if !query.isEmpty {
        let kindTitle = localizedNetworkKindTitle(entry.kind)
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
        return matchesQuery
      }
      return true
    }

    if sortAscending {
      for entry in source where matches(entry) {
        result.append(entry)
      }
    } else {
      for entry in source.reversed() where matches(entry) {
        result.append(entry)
      }
    }

    return result
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

  private func updateLogRetentionNoticeIfNeeded() {
    let shouldShowNotice = activeTab == .logs && currentLogRetentionState.isTruncated
    guard shouldShowNotice else {
      if tableView.tableHeaderView != nil {
        tableView.tableHeaderView = nil
      }
      return
    }

    logRetentionNoticeView.configure(
      title: "Log Window Truncated",
      detail: localizedLogRetentionNoticeDetail(currentLogRetentionState)
    )

    let targetWidth = max(0, tableView.bounds.width)
    guard targetWidth > 0 else {
      return
    }

    let targetSize = CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height)
    let fittingHeight = logRetentionNoticeView.systemLayoutSizeFitting(
      targetSize,
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    ).height
    let resolvedHeight = max(1, fittingHeight)
    let frame = CGRect(x: 0, y: 0, width: targetWidth, height: resolvedHeight)

    if tableView.tableHeaderView !== logRetentionNoticeView || logRetentionNoticeView.frame != frame {
      logRetentionNoticeView.frame = frame
      tableView.tableHeaderView = logRetentionNoticeView
    }
  }

  private func localizedLogRetentionNoticeDetail(_ state: DebugLogRetentionState) -> String {
    guard state.maxCount > 0 else {
      return "The log buffer reached its configured limit and older entries were discarded."
    }

    let droppedLabel = state.droppedCount == 1 ? "entry" : "entries"
    let discardedVerb = state.droppedCount == 1 ? "was" : "were"
    return "The buffer keeps at most \(state.maxCount) timeline-ordered logs. \(state.droppedCount) older \(droppedLabel) \(discardedVerb) discarded since the last clear."
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

  func updateSearchResults(for searchController: UISearchController) {
    applySearchText(searchController.searchBar.text ?? "")
  }

  @objc private func searchTextChanged(_ sender: UITextField) {
    applySearchText(sender.text ?? "")
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

  private func applySearchText(_ nextSearchText: String) {
    guard nextSearchText != searchText else {
      return
    }
    searchText = nextSearchText
    scheduleSearchReload()
  }

  private func setSortAscending(_ ascending: Bool) {
    guard sortAscending != ascending else {
      return
    }
    sortAscending = ascending
    updateFilterMenu()
    reloadFromStore()
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard let tab = ActiveTab(rawValue: item.tag) else {
      return
    }
    setActiveTab(tab)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard gestureRecognizer === dismissKeyboardTapGestureRecognizer else {
      return true
    }
    let touchedView = touch.view
    if isView(touchedView, descendantOf: legacySearchField) {
      return false
    }
    if isView(touchedView, descendantOf: panelSearchController.searchBar) {
      return false
    }
    return true
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch activeTab {
    case .logs:
      return displayedLogs.count
    case .network:
      return displayedNetwork.count
    case .appInfo:
      return 0
    }
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    configuredCell(for: tableView, at: indexPath)
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
        titleText: "[\(localizedOriginTitle(entry.origin))] [\(entry.type.uppercased())] \(entry.timestamp)",
        bodyText: logDetailBody(for: entry)
      )
      navigationController?.pushViewController(detail, animated: true)
    case .network:
      guard displayedNetwork.indices.contains(indexPath.row) else {
        return
      }
      let entry = displayedNetwork[indexPath.row]
      let detail = InAppDebuggerNetworkDetailViewController(
        entry: entry
      )
      navigationController?.pushViewController(detail, animated: true)
    case .appInfo:
      return
    }
  }

  @objc private func handleBackgroundTap() {
    deactivateSearchInput()
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    guard scrollView === tableView || scrollView === appInfoScrollView else {
      return
    }
    deactivateSearchInput()
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

  private func deactivateSearchInput() {
    navigationController?.view.endEditing(true)
    view.endEditing(true)
    legacySearchField.resignFirstResponder()
    panelSearchController.searchBar.searchTextField.resignFirstResponder()
    if panelSearchController.isActive {
      panelSearchController.isActive = false
    }
  }

  private func isView(_ view: UIView?, descendantOf ancestor: UIView) -> Bool {
    var current = view
    while let currentView = current {
      if currentView === ancestor {
        return true
      }
      current = currentView.superview
    }
    return false
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
  private let messageTextView = InAppDebuggerSelectableTextView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    buildUI()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    messageTextView.selectedRange = NSRange(location: 0, length: 0)
    messageTextView.overrideCopyText = nil
  }

  func configure(entry: DebugLogEntry) {
    let tone = toneForLogLevel(entry.type)
    accentView.backgroundColor = tone.foreground
    originLabel.text = localizedOriginTitle(entry.origin)
    originLabel.textColor = isNativeOrigin(entry.origin) ? .white : PanelColors.mutedText
    originLabel.backgroundColor = isNativeOrigin(entry.origin) ? PanelColors.primary : PanelColors.controlBackground
    levelLabel.text = entry.type.uppercased()
    levelLabel.textColor = tone.foreground
    levelLabel.backgroundColor = tone.background
    timeLabel.text = entry.timestamp
    let contextText = entry.context ?? ""
    contextLabel.text = contextText
    contextLabel.isHidden = entry.origin != "native" || contextText.isEmpty
    messageTextView.text = entry.message
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

    messageTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    messageTextView.textColor = PanelColors.text
    messageTextView.presentsSelectionMenuAutomatically = true
    messageTextView.textContainer.maximumNumberOfLines = 4
    messageTextView.textContainer.lineBreakMode = .byTruncatingTail

    let headerStack = UIStackView(arrangedSubviews: [originLabel, levelLabel, timeLabel, UIView()])
    headerStack.axis = .horizontal
    headerStack.alignment = .center
    headerStack.spacing = 8

    let bodyStack = UIStackView(arrangedSubviews: [headerStack, contextLabel, messageTextView])
    bodyStack.axis = .vertical
    bodyStack.spacing = 8

    cardView.addSubview(accentView)
    cardView.addSubview(bodyStack)

    cardView.translatesAutoresizingMaskIntoConstraints = false
    accentView.translatesAutoresizingMaskIntoConstraints = false
    bodyStack.translatesAutoresizingMaskIntoConstraints = false

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
    ])
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

  func configure(entry: DebugNetworkEntry) {
    let tone = toneForNetwork(entry)
    accentView.backgroundColor = tone.foreground
    originLabel.text = localizedOriginTitle(entry.origin)
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
      durationLabel.text = "Duration \(entry.durationMs.map { "\($0)ms" } ?? "-") · IN \(incoming) / OUT \(outgoing)"
    } else {
      durationLabel.text = "Duration \(entry.durationMs.map { "\($0)ms" } ?? "-")"
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

private final class InAppDebuggerTableNoticeView: UIView {
  private let cardView = UIView()
  private let accentView = UIView()
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
    backgroundColor = .clear

    let warnTone = toneForLogLevel("warn")
    cardView.backgroundColor = UIColor(
      red: 1.0,
      green: 0.98,
      blue: 0.91,
      alpha: 1.0
    )
    cardView.layer.cornerRadius = 8
    cardView.layer.borderWidth = 1
    cardView.layer.borderColor = warnTone.foreground.withAlphaComponent(0.24).cgColor
    addSubview(cardView)

    accentView.backgroundColor = warnTone.foreground
    accentView.layer.cornerRadius = 2
    cardView.addSubview(accentView)

    titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
    titleLabel.textColor = PanelColors.text
    titleLabel.numberOfLines = 1

    detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
    detailLabel.textColor = PanelColors.mutedText
    detailLabel.numberOfLines = 0

    let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
    stack.axis = .vertical
    stack.spacing = 4
    cardView.addSubview(stack)

    cardView.translatesAutoresizingMaskIntoConstraints = false
    accentView.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      cardView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
      cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
      cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

      accentView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
      accentView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
      accentView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),
      accentView.widthAnchor.constraint(equalToConstant: 4),

      stack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: accentView.trailingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),
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
    navigationItem.largeTitleDisplayMode = .never
    applyPanelNavigationItemAppearance(navigationItem)

    let textView = InAppDebuggerSelectableTextView()
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 4
    paragraphStyle.lineBreakMode = .byCharWrapping
    textView.attributedText = NSAttributedString(
      string: bodyText,
      attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        .foregroundColor: PanelColors.text,
        .paragraphStyle: paragraphStyle,
      ]
    )
    textView.overrideCopyText = bodyText
    textView.presentsSelectionMenuAutomatically = true
    textView.isScrollEnabled = true
    textView.alwaysBounceVertical = true
    textView.showsVerticalScrollIndicator = true
    textView.contentInsetAdjustmentBehavior = .automatic
    textView.textContainerInset = UIEdgeInsets(top: 18, left: 18, bottom: 32, right: 18)
    view.addSubview(textView)
    textView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: view.topAnchor),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
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
  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private var notificationObserver: NSObjectProtocol?
  private var scheduledReloadWorkItem: DispatchWorkItem?

  init(entry: DebugNetworkEntry) {
    self.entryId = entry.id
    self.entry = entry
    super.init(nibName: nil, bundle: nil)
    title = "Request Details"
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = PanelColors.background
    navigationItem.largeTitleDisplayMode = .never
    applyPanelNavigationItemAppearance(navigationItem)

    stack.axis = .vertical
    stack.spacing = 10
    scrollView.contentInsetAdjustmentBehavior = .automatic
    scrollView.delaysContentTouches = false
    view.addSubview(scrollView)
    scrollView.addSubview(stack)
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
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

    let messagesTitle = "Messages"
    let noMessagesText = "No messages"

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
      stack.addArrangedSubview(makeSection(title: "Error", body: error, monospace: true))
    }
  }

  private func httpSections() -> [(title: String, body: String, monospace: Bool)] {
    let durationText = entry.durationMs.map { "\($0)ms" } ?? "-"
    let noRequestBodyText = "No request body"
    let noResponseBodyText = "No response body"
    let noMessagesText = "No messages"
    var sections: [(title: String, body: String, monospace: Bool)] = [
      (title: "Origin", body: englishOriginTitle(entry.origin), monospace: false),
      (title: "Request Type", body: englishNetworkKindTitle(entry.kind), monospace: false),
      (title: "Method", body: entry.method, monospace: false),
      (title: "Status", body: networkTrailingBadgeTitle(entry) ?? "-", monospace: false),
      (title: "Protocol", body: entry.`protocol` ?? "-", monospace: false),
      (title: "URL", body: entry.url, monospace: true),
      (title: "Duration", body: durationText, monospace: false),
      (title: "Request Headers", body: headerText(entry.requestHeaders), monospace: true),
      (title: "Response Headers", body: headerText(entry.responseHeaders), monospace: true),
      (title: "Request Body", body: entry.requestBody ?? noRequestBodyText, monospace: true),
      (title: "Response Body", body: entry.responseBody ?? noResponseBodyText, monospace: true),
      (title: "Messages", body: formattedMessagesText(entry.messages, fallback: noMessagesText), monospace: true),
    ]

    if shouldShowNetworkStateLabel(entry) {
      sections.insert((title: "State", body: entry.state, monospace: false), at: 4)
    }

    return sections
  }

  private func webSocketSections() -> [(title: String, body: String, monospace: Bool)] {
    let durationText = entry.durationMs.map { "\($0)ms" } ?? "-"
    let noMessagesText = "No messages"
    let noEventsText = "No events"
    let byteSummary = "IN \(formatNetworkByteCount(entry.bytesIn)) / OUT \(formatNetworkByteCount(entry.bytesOut))"

    var sections: [(title: String, body: String, monospace: Bool)] = [
      (title: "Origin", body: englishOriginTitle(entry.origin), monospace: false),
      (title: "Request Type", body: englishNetworkKindTitle(entry.kind), monospace: false),
      (title: "Method", body: entry.method, monospace: false),
      (title: "State", body: entry.state, monospace: false),
      (title: "Protocol", body: entry.`protocol` ?? "-", monospace: false),
      (title: "Requested protocols", body: entry.requestedProtocols ?? "-", monospace: false),
      (title: "URL", body: entry.url, monospace: true),
      (title: "Duration", body: durationText, monospace: false),
      (title: "Bytes", body: byteSummary, monospace: false),
      (title: "Request Headers", body: headerText(entry.requestHeaders), monospace: true),
    ]

    if !entry.responseHeaders.isEmpty {
      sections.append((title: "Response Headers", body: headerText(entry.responseHeaders), monospace: true))
    }

    if let status = entry.status {
      sections.append((title: "Status", body: String(status), monospace: false))
    }

    if entry.requestedCloseCode != nil || (entry.requestedCloseReason?.isEmpty == false) {
      sections.append((title: "Close requested", body: closeRequestSummary(), monospace: false))
    }

    if entry.closeCode != nil || entry.cleanClose != nil || (entry.closeReason?.isEmpty == false) {
      sections.append((title: "Close result", body: closeResultSummary(), monospace: false))
    }

    sections.append((title: "Event timeline", body: entry.events ?? noEventsText, monospace: true))
    sections.append((title: "Messages", body: formattedMessagesText(entry.messages, fallback: noMessagesText), monospace: true))
    return sections
  }

  private func englishOriginTitle(_ origin: String) -> String {
    if isNativeOrigin(origin) {
      return "Native"
    }
    return "JS"
  }

  private func englishNetworkKindTitle(_ rawKind: String) -> String {
    let trimmedKind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines)
    switch normalizedNetworkKind(trimmedKind) {
    case .http:
      return "XHR/Fetch"
    case .websocket:
      return "WebSocket"
    case .other:
      if !trimmedKind.isEmpty, trimmedKind.lowercased() != NetworkKindFilter.other.rawValue {
        return trimmedKind.uppercased()
      }
      return "Other"
    }
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
    let requestBodyTitle = "Request Body"
    let responseBodyTitle = "Response Body"
    let messagesTitle = "Messages"
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

    if let structuredJSON = extractedStructuredJSON(from: normalizedTrimmed),
       let prettyObject = prettyPrintedJSONObjectOrArray(structuredJSON) {
      return prettyObject
    }

    return nil
  }

  private func prettyPrintedJSONObjectOrArray(_ text: String) -> String? {
    var formatter = InAppDebuggerJSONPrettyPrinter(source: text)
    return formatter.formatTopLevelObjectOrArray()
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
    let guideColor = UIColor(red: 0.76, green: 0.84, blue: 1.00, alpha: 1)
    let baseColor = UIColor(red: 0.14, green: 0.18, blue: 0.24, alpha: 1)
    let punctuationColor = UIColor(red: 0.24, green: 0.30, blue: 0.39, alpha: 1)
    let keyColor = UIColor(red: 0.75, green: 0.23, blue: 0.16, alpha: 1)
    let valueColor = UIColor(red: 0.66, green: 0.35, blue: 0.08, alpha: 1)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 3
    paragraphStyle.lineBreakMode = .byCharWrapping

    let lines = prettyJSON.components(separatedBy: .newlines)
    let result = NSMutableAttributedString()

    for (index, line) in lines.enumerated() {
      let lineAttributes: [NSAttributedString.Key: Any] = [
        .font: codeFont,
        .foregroundColor: baseColor,
        .paragraphStyle: paragraphStyle,
      ]
      let lineAttributed = NSMutableAttributedString(string: line, attributes: lineAttributes)
      highlightJSONStringTokens(
        in: lineAttributed,
        keyColor: keyColor,
        valueColor: valueColor,
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
    valueColor: UIColor,
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
        .foregroundColor: valueColor,
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
        .foregroundColor: valueColor,
        .font: font,
      ]
    )

    applyRegex(
      #"\b(?:true|false|null)\b"#,
      to: attributedString,
      attributes: [
        .foregroundColor: valueColor,
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
    bodyTextView.presentsSelectionMenuAutomatically = true
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
      bodyTextView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
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

// Formats JSON by rewriting whitespace only. All original token text is preserved verbatim.
private struct InAppDebuggerJSONPrettyPrinter {
  private let source: String
  private var index: String.Index

  init(source: String) {
    self.source = source
    self.index = source.startIndex
  }

  mutating func formatTopLevelObjectOrArray() -> String? {
    skipWhitespace()

    let formatted: String?
    switch currentCharacter {
    case "{":
      formatted = parseObject(indentationLevel: 0)
    case "[":
      formatted = parseArray(indentationLevel: 0)
    default:
      formatted = nil
    }

    guard let formatted else {
      return nil
    }

    skipWhitespace()
    guard index == source.endIndex else {
      return nil
    }
    return formatted
  }

  private var currentCharacter: Character? {
    guard index < source.endIndex else {
      return nil
    }
    return source[index]
  }

  private mutating func advance() {
    index = source.index(after: index)
  }

  private mutating func skipWhitespace() {
    while let character = currentCharacter,
          character == " " || character == "\n" || character == "\r" || character == "\t" {
      advance()
    }
  }

  private func indentation(_ level: Int) -> String {
    String(repeating: "  ", count: level)
  }

  private mutating func parseValue(indentationLevel: Int) -> String? {
    skipWhitespace()

    switch currentCharacter {
    case "{":
      return parseObject(indentationLevel: indentationLevel)
    case "[":
      return parseArray(indentationLevel: indentationLevel)
    case "\"":
      return parseStringLiteral()
    case "t":
      return parseKeyword("true")
    case "f":
      return parseKeyword("false")
    case "n":
      return parseKeyword("null")
    case "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
      return parseNumberLiteral()
    default:
      return nil
    }
  }

  private mutating func parseObject(indentationLevel: Int) -> String? {
    guard currentCharacter == "{" else {
      return nil
    }
    advance()
    skipWhitespace()

    if currentCharacter == "}" {
      advance()
      return "{}"
    }

    var members: [String] = []

    while true {
      skipWhitespace()
      guard let key = parseStringLiteral() else {
        return nil
      }

      skipWhitespace()
      guard currentCharacter == ":" else {
        return nil
      }
      advance()

      guard let value = parseValue(indentationLevel: indentationLevel + 1) else {
        return nil
      }
      members.append("\(indentation(indentationLevel + 1))\(key): \(value)")

      skipWhitespace()
      if currentCharacter == "," {
        advance()
        continue
      }
      if currentCharacter == "}" {
        advance()
        break
      }
      return nil
    }

    return "{\n\(members.joined(separator: ",\n"))\n\(indentation(indentationLevel))}"
  }

  private mutating func parseArray(indentationLevel: Int) -> String? {
    guard currentCharacter == "[" else {
      return nil
    }
    advance()
    skipWhitespace()

    if currentCharacter == "]" {
      advance()
      return "[]"
    }

    var elements: [String] = []

    while true {
      guard let value = parseValue(indentationLevel: indentationLevel + 1) else {
        return nil
      }
      elements.append("\(indentation(indentationLevel + 1))\(value)")

      skipWhitespace()
      if currentCharacter == "," {
        advance()
        continue
      }
      if currentCharacter == "]" {
        advance()
        break
      }
      return nil
    }

    return "[\n\(elements.joined(separator: ",\n"))\n\(indentation(indentationLevel))]"
  }

  private mutating func parseStringLiteral() -> String? {
    guard currentCharacter == "\"" else {
      return nil
    }

    let start = index
    advance()

    while let character = currentCharacter {
      if character == "\"" {
        advance()
        return String(source[start..<index])
      }

      if character == "\\" {
        advance()
        guard let escapedCharacter = currentCharacter else {
          return nil
        }

        switch escapedCharacter {
        case "\"", "\\", "/", "b", "f", "n", "r", "t":
          advance()
        case "u":
          advance()
          for _ in 0..<4 {
            guard let hex = currentCharacter, isHexDigit(hex) else {
              return nil
            }
            advance()
          }
        default:
          return nil
        }
        continue
      }

      if isDisallowedStringCharacter(character) {
        return nil
      }

      advance()
    }

    return nil
  }

  private mutating func parseKeyword(_ keyword: String) -> String? {
    guard source[index...].hasPrefix(keyword) else {
      return nil
    }
    index = source.index(index, offsetBy: keyword.count)
    return keyword
  }

  private mutating func parseNumberLiteral() -> String? {
    let start = index

    if currentCharacter == "-" {
      advance()
    }

    guard let firstDigit = currentCharacter else {
      return nil
    }

    if firstDigit == "0" {
      advance()
    } else if isDigitOneToNine(firstDigit) {
      advance()
      while let digit = currentCharacter, isDigit(digit) {
        advance()
      }
    } else {
      return nil
    }

    if currentCharacter == "." {
      advance()
      guard let digit = currentCharacter, isDigit(digit) else {
        return nil
      }
      while let digit = currentCharacter, isDigit(digit) {
        advance()
      }
    }

    if currentCharacter == "e" || currentCharacter == "E" {
      advance()
      if currentCharacter == "+" || currentCharacter == "-" {
        advance()
      }
      guard let digit = currentCharacter, isDigit(digit) else {
        return nil
      }
      while let digit = currentCharacter, isDigit(digit) {
        advance()
      }
    }

    return String(source[start..<index])
  }

  private func isDigit(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
      return false
    }
    return scalar.value >= 48 && scalar.value <= 57
  }

  private func isDigitOneToNine(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
      return false
    }
    return scalar.value >= 49 && scalar.value <= 57
  }

  private func isHexDigit(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
      return false
    }
    switch scalar.value {
    case 48...57, 65...70, 97...102:
      return true
    default:
      return false
    }
  }

  private func isDisallowedStringCharacter(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
      return false
    }
    return scalar.value < 0x20
  }
}

private final class InAppDebuggerSelectableTextView: UITextView, UITextViewDelegate {
  private var lastMeasuredWidth: CGFloat = 0
  private var hasScheduledSelectionMenu = false
  private var selectionMenuTargetRect: CGRect = .null
  var overrideCopyText: String?
  var presentsSelectionMenuAutomatically = false

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
    if #available(iOS 16.0, *) {
      addInteraction(UIEditMenuInteraction(delegate: self))
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  func textViewDidChangeSelection(_ textView: UITextView) {
    guard presentsSelectionMenuAutomatically else {
      return
    }

    guard selectedRange.length > 0 else {
      hasScheduledSelectionMenu = false
      dismissSelectionMenu()
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

    selectionMenuTargetRect = currentSelectionMenuTargetRect()

    if #available(iOS 16.0, *) {
      let configuration = UIEditMenuConfiguration(
        identifier: nil,
        sourcePoint: CGPoint(
          x: selectionMenuTargetRect.midX,
          y: selectionMenuTargetRect.midY
        )
      )
      editMenuInteraction?.presentEditMenu(with: configuration)
    } else {
      UIMenuController.shared.showMenu(from: self, rect: selectionMenuTargetRect)
    }
  }

  private func dismissSelectionMenu() {
    if #available(iOS 16.0, *) {
      editMenuInteraction?.dismissMenu()
    }
  }

  private func currentSelectionMenuTargetRect() -> CGRect {
    if let selectedTextRange {
      let rect = firstRect(for: selectedTextRange)
      if !rect.isNull && !rect.isInfinite && !rect.isEmpty {
        return rect
      }
    }
    return bounds.insetBy(dx: 8, dy: 8)
  }

}

@available(iOS 16.0, *)
extension InAppDebuggerSelectableTextView: UIEditMenuInteractionDelegate {
  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction,
    targetRectFor configuration: UIEditMenuConfiguration
  ) -> CGRect {
    selectionMenuTargetRect
  }

  private var editMenuInteraction: UIEditMenuInteraction? {
    interactions.first(where: { $0 is UIEditMenuInteraction }) as? UIEditMenuInteraction
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
