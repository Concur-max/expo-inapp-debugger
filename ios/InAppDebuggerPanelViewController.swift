import UIKit

private enum PanelSection {
  case main
}

private enum ActiveTab: Int {
  case logs
  case network
}

final class InAppDebuggerPanelViewController: UIViewController, UITableViewDelegate, UISearchBarDelegate {
  private var activeTab: ActiveTab = .logs
  private var searchText = ""
  private var selectedLevels: Set<String> = ["log", "info", "warn", "error", "debug"]
  private var sortAscending = false
  private var displayedLogs: [DebugLogEntry] = []
  private var displayedNetwork: [DebugNetworkEntry] = []
  private var notificationObserver: NSObjectProtocol?

  private lazy var segmentedControl: UISegmentedControl = {
    let control = UISegmentedControl(items: ["日志", "网络"])
    control.selectedSegmentIndex = 0
    control.addTarget(self, action: #selector(handleSegmentChange(_:)), for: .valueChanged)
    return control
  }()

  private lazy var searchBar: UISearchBar = {
    let view = UISearchBar()
    view.delegate = self
    view.searchBarStyle = .minimal
    return view
  }()

  private lazy var copyVisibleButton: UIButton = {
    var config = UIButton.Configuration.filled()
    config.title = "复制"
    let button = UIButton(configuration: config)
    button.addTarget(self, action: #selector(copyVisibleTapped), for: .touchUpInside)
    return button
  }()

  private lazy var clearButton: UIButton = {
    var config = UIButton.Configuration.tinted()
    config.title = "清空"
    let button = UIButton(configuration: config)
    button.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
    return button
  }()

  private lazy var filterScrollView = UIScrollView()
  private lazy var filterStackView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 8
    return stack
  }()

  private lazy var sortStackView: UIStackView = {
    let asc = makeActionButton(title: "时间升序", action: #selector(sortAscTapped))
    let desc = makeActionButton(title: "时间倒序", action: #selector(sortDescTapped))
    let stack = UIStackView(arrangedSubviews: [UIView(), asc, desc])
    stack.spacing = 8
    return stack
  }()

  private lazy var tableView: UITableView = {
    let table = UITableView(frame: .zero, style: .plain)
    table.backgroundColor = UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)
    table.separatorStyle = .none
    table.delegate = self
    table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    return table
  }()

  private lazy var dataSource = UITableViewDiffableDataSource<PanelSection, String>(
    tableView: tableView
  ) { [weak self] tableView, indexPath, identifier in
    guard let self else { return nil }
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.selectionStyle = .none
    cell.backgroundColor = .clear
    cell.contentView.backgroundColor = .white
    cell.contentView.layer.cornerRadius = 14
    cell.contentView.layer.masksToBounds = true

    if self.activeTab == .logs, let entry = self.displayedLogs.first(where: { $0.id == identifier }) {
      cell.textLabel?.text = "[\(entry.type.uppercased())] \(entry.timestamp)"
      cell.textLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
      cell.detailTextLabel?.text = entry.message
      cell.detailTextLabel?.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
      cell.detailTextLabel?.numberOfLines = 3
      let copyButton = UIButton(type: .system)
      copyButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
      copyButton.addAction(UIAction { [weak self] _ in
        self?.copy(text: entry.message, successKey: "copySingleSuccess")
      }, for: .touchUpInside)
      cell.accessoryView = copyButton
    } else if let entry = self.displayedNetwork.first(where: { $0.id == identifier }) {
      cell.textLabel?.text = "\(entry.method)  \(entry.status.map(String.init) ?? "-")  \(entry.state.uppercased())"
      cell.textLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
      cell.detailTextLabel?.text = "\(entry.url)\n\((strings["duration"] ?? "耗时")): \(entry.durationMs ?? 0)ms"
      cell.detailTextLabel?.numberOfLines = 3
      cell.accessoryType = .disclosureIndicator
    }

    return cell
  }

  private var strings: [String: String] {
    InAppDebuggerStore.shared.currentConfig().strings
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close,
      target: self,
      action: #selector(closeTapped)
    )

    layoutUI()
    rebuildFilterButtons()
    reloadFromStore()

    notificationObserver = NotificationCenter.default.addObserver(
      forName: .inAppDebuggerStoreDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.reloadFromStore()
    }
  }

  deinit {
    if let notificationObserver {
      NotificationCenter.default.removeObserver(notificationObserver)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    title = strings["title"] ?? "调试面板"
  }

  private func layoutUI() {
    let actionRow = UIStackView(arrangedSubviews: [copyVisibleButton, clearButton])
    actionRow.axis = .horizontal
    actionRow.spacing = 8

    filterScrollView.showsHorizontalScrollIndicator = false
    filterScrollView.addSubview(filterStackView)

    let stack = UIStackView(arrangedSubviews: [segmentedControl, searchBar, actionRow, filterScrollView, sortStackView, tableView])
    stack.axis = .vertical
    stack.spacing = 10
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    filterStackView.translatesAutoresizingMaskIntoConstraints = false
    tableView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      filterScrollView.heightAnchor.constraint(equalToConstant: 38),

      filterStackView.topAnchor.constraint(equalTo: filterScrollView.topAnchor),
      filterStackView.bottomAnchor.constraint(equalTo: filterScrollView.bottomAnchor),
      filterStackView.leadingAnchor.constraint(equalTo: filterScrollView.leadingAnchor),
      filterStackView.trailingAnchor.constraint(equalTo: filterScrollView.trailingAnchor),
      filterStackView.heightAnchor.constraint(equalTo: filterScrollView.heightAnchor),

      tableView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
    ])
  }

  private func rebuildFilterButtons() {
    filterStackView.arrangedSubviews.forEach {
      filterStackView.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    ["log", "info", "warn", "error", "debug"].forEach { level in
      let button = makeActionButton(title: level.uppercased(), action: #selector(levelTapped(_:)))
      button.accessibilityIdentifier = level
      filterStackView.addArrangedSubview(button)
    }
  }

  private func applySnapshot() {
    var snapshot = NSDiffableDataSourceSnapshot<PanelSection, String>()
    snapshot.appendSections([.main])
    if activeTab == .logs {
      snapshot.appendItems(displayedLogs.map(\.id))
    } else {
      snapshot.appendItems(displayedNetwork.map(\.id))
    }
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  private func reloadFromStore() {
    let state = InAppDebuggerStore.shared.snapshotState()
    navigationItem.title = state.0.strings["title"] ?? "调试面板"
    searchBar.placeholder = state.0.strings["searchPlaceholder"] ?? "搜索日志..."
    copyVisibleButton.configuration?.title = state.0.strings["copyVisibleA11y"] ?? "复制当前显示的日志"
    clearButton.configuration?.title = state.0.strings["clear"] ?? "清空"
    sortStackView.arrangedSubviews.compactMap { $0 as? UIButton }.enumerated().forEach { index, button in
      button.configuration?.title = index == 0 ? state.0.strings["sortAsc"] ?? "时间升序" : state.0.strings["sortDesc"] ?? "时间倒序"
    }
    segmentedControl.setTitle(state.0.strings["logsTab"] ?? "日志", forSegmentAt: 0)
    segmentedControl.setTitle(state.0.strings["networkTab"] ?? "网络", forSegmentAt: 1)

    displayedLogs = filteredLogs(from: state.1)
    displayedNetwork = filteredNetwork(from: state.3)
    tableView.reloadData()
    applySnapshot()
  }

  private func filteredLogs(from source: [DebugLogEntry]) -> [DebugLogEntry] {
    var result = source.filter { selectedLevels.contains($0.type) }
    if !searchText.isEmpty {
      result = result.filter {
        $0.message.localizedCaseInsensitiveContains(searchText) ||
          $0.type.localizedCaseInsensitiveContains(searchText)
      }
    }
    return sortAscending ? result.sorted(by: { $0.fullTimestamp < $1.fullTimestamp }) : result.sorted(by: { $0.fullTimestamp > $1.fullTimestamp })
  }

  private func filteredNetwork(from source: [DebugNetworkEntry]) -> [DebugNetworkEntry] {
    guard !searchText.isEmpty else {
      return source
    }
    return source.filter {
      $0.url.localizedCaseInsensitiveContains(searchText) ||
        $0.method.localizedCaseInsensitiveContains(searchText) ||
        $0.state.localizedCaseInsensitiveContains(searchText)
    }
  }

  private func makeActionButton(title: String, action: Selector) -> UIButton {
    var config = UIButton.Configuration.tinted()
    config.title = title
    let button = UIButton(configuration: config)
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  @objc private func closeTapped() {
    dismiss(animated: true)
  }

  @objc private func handleSegmentChange(_ sender: UISegmentedControl) {
    activeTab = ActiveTab(rawValue: sender.selectedSegmentIndex) ?? .logs
    reloadFromStore()
  }

  @objc private func copyVisibleTapped() {
    if activeTab == .logs {
      let text = displayedLogs.map { "[\($0.type.uppercased())] \($0.timestamp) \($0.message)" }.joined(separator: "\n")
      copy(text: text, successKey: "copyVisibleSuccess")
    } else {
      let text = displayedNetwork.map { "\($0.method) \($0.url) \($0.status.map(String.init) ?? "-") \($0.state)" }.joined(separator: "\n")
      copy(text: text, successKey: "copyVisibleSuccess")
    }
  }

  @objc private func clearTapped() {
    InAppDebuggerStore.shared.clear(kind: activeTab == .logs ? "logs" : "network")
  }

  @objc private func sortAscTapped() {
    sortAscending = true
    reloadFromStore()
  }

  @objc private func sortDescTapped() {
    sortAscending = false
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

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    self.searchText = searchText
    reloadFromStore()
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    activeTab == .logs ? displayedLogs.count : displayedNetwork.count
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if activeTab == .logs {
      let entry = displayedLogs[indexPath.row]
      let detail = InAppDebuggerTextDetailViewController(
        titleText: "[\(entry.type.uppercased())] \(entry.timestamp)",
        bodyText: entry.message
      )
      navigationController?.pushViewController(detail, animated: true)
    } else {
      let entry = displayedNetwork[indexPath.row]
      let detail = InAppDebuggerNetworkDetailViewController(entry: entry, strings: strings)
      navigationController?.pushViewController(detail, animated: true)
    }
  }

  private func copy(text: String, successKey: String) {
    UIPasteboard.general.string = text
    showToast(message: strings[successKey] ?? "已复制")
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
    view.backgroundColor = .systemBackground
    let textView = UITextView()
    textView.text = bodyText
    textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.isEditable = false
    view.addSubview(textView)
    textView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
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
    view.backgroundColor = .systemBackground

    let scrollView = UIScrollView()
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 12
    view.addSubview(scrollView)
    scrollView.addSubview(stack)
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -12),
      stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -24),
    ])

    let requestHeaders = entry.requestHeaders
      .map { "\($0.key): \($0.value)" }
      .joined(separator: "\n")
      .ifEmpty("-")
    let responseHeaders = entry.responseHeaders
      .map { "\($0.key): \($0.value)" }
      .joined(separator: "\n")
      .ifEmpty("-")
    let durationText = "\(entry.durationMs ?? 0)ms"
    let noRequestBodyText = strings["noRequestBody"] ?? "无请求体"
    let noResponseBodyText = strings["noResponseBody"] ?? "无响应体"
    let noMessagesText = strings["noMessages"] ?? "暂无消息"

    let sections: [(title: String, body: String)] = [
      (title: strings["method"] ?? "方法", body: entry.method),
      (title: strings["status"] ?? "状态码", body: entry.status.map(String.init) ?? "-"),
      (title: strings["state"] ?? "状态", body: entry.state),
      (title: strings["protocol"] ?? "协议", body: entry.`protocol` ?? "-"),
      (title: "URL", body: entry.url),
      (title: strings["duration"] ?? "耗时", body: durationText),
      (title: strings["requestHeaders"] ?? "请求头", body: requestHeaders),
      (title: strings["responseHeaders"] ?? "响应头", body: responseHeaders),
      (title: strings["requestBody"] ?? "请求体", body: entry.requestBody ?? noRequestBodyText),
      (title: strings["responseBody"] ?? "响应体", body: entry.responseBody ?? noResponseBodyText),
      (title: strings["messages"] ?? "消息", body: entry.messages ?? noMessagesText),
    ]

    sections.forEach { title, body in
      stack.addArrangedSubview(makeSection(title: title, body: body))
    }

    if let error = entry.error, !error.isEmpty {
      stack.addArrangedSubview(makeSection(title: "错误", body: error))
    }
  }

  private func makeSection(title: String, body: String) -> UIView {
    let container = UIView()
    container.backgroundColor = .secondarySystemBackground
    container.layer.cornerRadius = 14

    let titleLabel = UILabel()
    titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
    titleLabel.text = title

    let bodyLabel = UILabel()
    bodyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    bodyLabel.text = body
    bodyLabel.numberOfLines = 0

    let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
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

private extension UIViewController {
  func showToast(message: String) {
    let label = UILabel()
    label.text = message
    label.textColor = .white
    label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
    label.textAlignment = .center
    label.layer.cornerRadius = 12
    label.layer.masksToBounds = true
    label.alpha = 0
    view.addSubview(label)
    label.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
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
