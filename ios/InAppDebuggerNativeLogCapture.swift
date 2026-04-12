import Darwin
import Foundation
import Network
import ObjectiveC.runtime
import OSLog
import UIKit

private let inAppDebuggerCrashReportURL = URL(fileURLWithPath: NSTemporaryDirectory())
  .appendingPathComponent("expo-inapp-debugger-last-native-crash.log")

private var inAppDebuggerCrashFileDescriptor: Int32 = -1

private let inAppDebuggerFatalSignals: [Int32] = [
  SIGABRT,
  SIGBUS,
  SIGFPE,
  SIGILL,
  SIGSEGV,
  SIGTERM,
  SIGTRAP,
]

private func inAppDebuggerSignalName(_ signal: Int32) -> StaticString {
  switch signal {
  case SIGABRT:
    return "SIGABRT"
  case SIGBUS:
    return "SIGBUS"
  case SIGFPE:
    return "SIGFPE"
  case SIGILL:
    return "SIGILL"
  case SIGSEGV:
    return "SIGSEGV"
  case SIGTERM:
    return "SIGTERM"
  case SIGTRAP:
    return "SIGTRAP"
  default:
    return "UNKNOWN"
  }
}

private func inAppDebuggerSignalMessage(_ signal: Int32) -> StaticString {
  switch signal {
  case SIGABRT:
    return "[expo-inapp-debugger] Fatal signal SIGABRT (6)\n"
  case SIGBUS:
    return "[expo-inapp-debugger] Fatal signal SIGBUS (10)\n"
  case SIGFPE:
    return "[expo-inapp-debugger] Fatal signal SIGFPE (8)\n"
  case SIGILL:
    return "[expo-inapp-debugger] Fatal signal SIGILL (4)\n"
  case SIGSEGV:
    return "[expo-inapp-debugger] Fatal signal SIGSEGV (11)\n"
  case SIGTERM:
    return "[expo-inapp-debugger] Fatal signal SIGTERM (15)\n"
  case SIGTRAP:
    return "[expo-inapp-debugger] Fatal signal SIGTRAP (5)\n"
  default:
    return "[expo-inapp-debugger] Fatal signal UNKNOWN\n"
  }
}

private func inAppDebuggerWriteStaticString(_ message: StaticString, to fd: Int32) {
  guard fd >= 0 else {
    return
  }

  message.withUTF8Buffer { buffer in
    guard let baseAddress = buffer.baseAddress else {
      return
    }
    _ = Darwin.write(fd, baseAddress, buffer.count)
  }
}

private func inAppDebuggerHandleSignal(_ signal: Int32) -> Void {
  let message = inAppDebuggerSignalMessage(signal)
  if inAppDebuggerCrashFileDescriptor >= 0 {
    inAppDebuggerWriteStaticString(message, to: inAppDebuggerCrashFileDescriptor)
  }
  inAppDebuggerWriteStaticString(message, to: STDERR_FILENO)

  Darwin.signal(signal, SIG_DFL)
  Darwin.raise(signal)
}

private func inAppDebuggerHandleUncaughtException(_ exception: NSException) {
  InAppDebuggerNativeLogCapture.shared.handleUncaughtException(exception)
}

private let inAppDebuggerWhitespaceAndNewlineCharacterSet = CharacterSet.whitespacesAndNewlines
private let inAppDebuggerErrorLevelKeywords: [[UInt8]] = [
  Array("fatal".utf8),
  Array("fault".utf8),
  Array("error".utf8),
  Array("exception".utf8),
  Array("crash".utf8),
]
private let inAppDebuggerWarnLevelKeyword = Array("warn".utf8)
private let inAppDebuggerDebugLevelKeyword = Array("debug".utf8)
private let inAppDebuggerInfoLevelKeyword = Array("info".utf8)

private func inAppDebuggerTrimmedMessage(_ value: String) -> String {
  guard !value.isEmpty else {
    return value
  }

  var start = value.startIndex
  var end = value.endIndex

  while start < end, inAppDebuggerIsWhitespaceOrNewline(value[start]) {
    start = value.index(after: start)
  }
  while start < end {
    let previousEnd = value.index(before: end)
    guard inAppDebuggerIsWhitespaceOrNewline(value[previousEnd]) else {
      break
    }
    end = previousEnd
  }

  guard start != value.startIndex || end != value.endIndex else {
    return value
  }
  return String(value[start..<end])
}

private func inAppDebuggerIsWhitespaceOrNewline(_ character: Character) -> Bool {
  character.unicodeScalars.allSatisfy(inAppDebuggerWhitespaceAndNewlineCharacterSet.contains)
}

private func inAppDebuggerLowercasedASCII(_ byte: UInt8) -> UInt8 {
  switch byte {
  case 65...90:
    return byte &+ 32
  default:
    return byte
  }
}

private func inAppDebuggerContainsASCIIKeyword(_ value: String, keyword: [UInt8]) -> Bool {
  guard !value.isEmpty, !keyword.isEmpty else {
    return false
  }

  let bytes = value.utf8
  var start = bytes.startIndex
  while start != bytes.endIndex {
    var current = start
    var keywordIndex = 0

    while current != bytes.endIndex,
      keywordIndex < keyword.count,
      inAppDebuggerLowercasedASCII(bytes[current]) == keyword[keywordIndex] {
      bytes.formIndex(after: &current)
      keywordIndex += 1
    }

    if keywordIndex == keyword.count {
      return true
    }
    bytes.formIndex(after: &start)
  }
  return false
}

final class InAppDebuggerNativeLogCapture {
  static let shared = InAppDebuggerNativeLogCapture()

  private let queue = DispatchQueue(label: "expo-inapp-debugger.native-log-capture")
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var originalStdout: Int32 = -1
  private var originalStderr: Int32 = -1
  private var stdoutBuffer = Data()
  private var stderrBuffer = Data()
  private var osLogStore: OSLogStore?
  private var osLogTimer: DispatchSourceTimer?
  private var lastOSLogDate = Date()
  private var pathMonitor: NWPathMonitor?
  private var isRunning = false
  private var isPrepared = false
  private var captureEnabled = false
  private var panelActive = false
  private var didInstallCrashHandlers = false
  private var didLogSessionStart = false
  private var lifecycleObservers: [NSObjectProtocol] = []
  private var diagnosticObservers: [NSObjectProtocol] = []
  private let processName = ProcessInfo.processInfo.processName
  private let processIdentifier = ProcessInfo.processInfo.processIdentifier
  private var streamMetadataCache: [String: (context: String, details: String?)] = [:]

  private init() {}

  func prepare() {
    queue.sync {
      guard !isPrepared else {
        return
      }

      replayPersistedCrashReportIfNeeded()
      prepareCrashPersistence()
      installCrashHandlersIfNeeded()
      isPrepared = true
    }
  }

  func setEnabled(_ enabled: Bool) {
    queue.sync {
      captureEnabled = enabled
      if enabled {
        prepareLocked()
      } else {
        panelActive = false
      }
      refreshCaptureStateLocked()
    }
  }

  func shutdown() {
    queue.sync {
      captureEnabled = false
      panelActive = false
      stopDetailedCollectorsLocked()
      stopLifecycleObserversLocked()
      stopStreamCaptureLocked()
      closeCrashPersistenceLocked()
      didLogSessionStart = false
    }
  }

  func setPanelActive(_ active: Bool) {
    queue.async {
      self.panelActive = active
      self.refreshCaptureStateLocked()
    }
  }

  private func prepareLocked() {
    guard !isPrepared else {
      if inAppDebuggerCrashFileDescriptor < 0 {
        prepareCrashPersistence()
      }
      return
    }
    replayPersistedCrashReportIfNeeded()
    prepareCrashPersistence()
    installCrashHandlersIfNeeded()
    isPrepared = true
  }

  private func ensureStreamCaptureLocked() {
    guard captureEnabled, !isRunning else {
      return
    }

    let nextOriginalStdout = dup(STDOUT_FILENO)
    let nextOriginalStderr = dup(STDERR_FILENO)
    guard nextOriginalStdout >= 0, nextOriginalStderr >= 0 else {
      return
    }

    let nextStdoutPipe = Pipe()
    let nextStderrPipe = Pipe()
    installReader(pipe: nextStdoutPipe, stream: "stdout", originalFD: nextOriginalStdout)
    installReader(pipe: nextStderrPipe, stream: "stderr", originalFD: nextOriginalStderr)

    fflush(stdout)
    fflush(stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)

    let stdoutResult = dup2(nextStdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    let stderrResult = dup2(nextStderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
    guard stdoutResult >= 0, stderrResult >= 0 else {
      restore(originalStdout: nextOriginalStdout, originalStderr: nextOriginalStderr)
      nextStdoutPipe.fileHandleForReading.readabilityHandler = nil
      nextStderrPipe.fileHandleForReading.readabilityHandler = nil
      Darwin.close(nextOriginalStdout)
      Darwin.close(nextOriginalStderr)
      return
    }

    originalStdout = nextOriginalStdout
    originalStderr = nextOriginalStderr
    stdoutPipe = nextStdoutPipe
    stderrPipe = nextStderrPipe
    isRunning = true
  }

  private func stopStreamCaptureLocked() {
    guard isRunning else {
      return
    }

    fflush(stdout)
    fflush(stderr)
    restore(originalStdout: originalStdout, originalStderr: originalStderr)

    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil

    try? stdoutPipe?.fileHandleForReading.close()
    try? stdoutPipe?.fileHandleForWriting.close()
    try? stderrPipe?.fileHandleForReading.close()
    try? stderrPipe?.fileHandleForWriting.close()

    if originalStdout >= 0 {
      Darwin.close(originalStdout)
    }
    if originalStderr >= 0 {
      Darwin.close(originalStderr)
    }

    stdoutPipe = nil
    stderrPipe = nil
    originalStdout = -1
    originalStderr = -1
    stdoutBuffer.removeAll(keepingCapacity: false)
    stderrBuffer.removeAll(keepingCapacity: false)
    isRunning = false
  }

  private func refreshCaptureStateLocked() {
    guard captureEnabled, panelActive else {
      stopDetailedCollectorsLocked()
      stopLifecycleObserversLocked()
      stopStreamCaptureLocked()
      return
    }

    prepareLocked()
    ensureStreamCaptureLocked()
    startLifecycleObserversIfNeeded()
    logSessionStartIfNeeded()
    startOSLogPolling()
    startNetworkPathMonitoringIfNeeded()
    startDiagnosticObserversIfNeeded()
  }

  private func stopDetailedCollectorsLocked() {
    stopOSLogPollingLocked()
    stopNetworkPathMonitoringLocked()
    stopDiagnosticObserversLocked()
  }

  func handleUncaughtException(_ exception: NSException) {
    let name = exception.name.rawValue
    let reason = exception.reason ?? "No reason provided"
    let processInfo = ProcessInfo.processInfo
    let details = buildDetailsString([
      ("collector", "uncaught-exception"),
      ("exceptionName", name),
      ("reason", reason),
      ("bundleIdentifier", Bundle.main.bundleIdentifier ?? ""),
      ("process", processInfo.processName),
      ("pid", "\(processInfo.processIdentifier)"),
      ("callStack", exception.callStackSymbols.joined(separator: "\n")),
    ])

    persistCrashReport(
      buildDetailsString([
        ("collector", "uncaught-exception"),
        ("exceptionName", name),
        ("reason", reason),
        ("bundleIdentifier", Bundle.main.bundleIdentifier ?? ""),
        ("process", processInfo.processName),
        ("pid", "\(processInfo.processIdentifier)"),
        ("callStack", exception.callStackSymbols.joined(separator: "\n")),
      ]) ?? "\(name): \(reason)"
    )

    InAppDebuggerStore.shared.appendNativeLog(
      type: "error",
      message: "\(name): \(reason)",
      stream: "uncaught-exception",
      details: details,
      date: Date()
    )
  }

  private func prepareCrashPersistence() {
    closeCrashPersistenceLocked()

    inAppDebuggerCrashReportURL.path.withCString { crashPath in
      inAppDebuggerCrashFileDescriptor = Darwin.open(
        crashPath,
        O_CREAT | O_WRONLY | O_TRUNC,
        S_IRUSR | S_IWUSR
      )
    }
  }

  private func persistCrashReport(_ report: String) {
    guard let data = report.data(using: .utf8) else {
      return
    }

    if inAppDebuggerCrashFileDescriptor >= 0 {
      Darwin.ftruncate(inAppDebuggerCrashFileDescriptor, 0)
      Darwin.lseek(inAppDebuggerCrashFileDescriptor, 0, SEEK_SET)
      writeData(data, fd: inAppDebuggerCrashFileDescriptor)
      Darwin.fsync(inAppDebuggerCrashFileDescriptor)
    } else {
      try? data.write(to: inAppDebuggerCrashReportURL, options: .atomic)
    }
  }

  private func closeCrashPersistenceLocked() {
    if inAppDebuggerCrashFileDescriptor >= 0 {
      Darwin.close(inAppDebuggerCrashFileDescriptor)
      inAppDebuggerCrashFileDescriptor = -1
    }
  }

  private func replayPersistedCrashReportIfNeeded() {
    guard
      let data = try? Data(contentsOf: inAppDebuggerCrashReportURL),
      !data.isEmpty
    else {
      return
    }

    let report = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !report.isEmpty else {
      return
    }

    InAppDebuggerStore.shared.appendNativeLog(
      type: "error",
      message: "Previous launch ended unexpectedly.",
      stream: "previous-launch crash report",
      details: report,
      date: Date()
    )
  }

  private func installCrashHandlersIfNeeded() {
    guard !didInstallCrashHandlers else {
      return
    }

    NSSetUncaughtExceptionHandler(inAppDebuggerHandleUncaughtException)
    inAppDebuggerFatalSignals.forEach { Darwin.signal($0, inAppDebuggerHandleSignal) }
    didInstallCrashHandlers = true
  }

  private func installReader(pipe: Pipe, stream: String, originalFD: Int32) {
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        return
      }

      self?.writeData(data, fd: originalFD)
      self?.queue.async {
        self?.process(data: data, stream: stream)
      }
    }
  }

  private func restore(originalStdout: Int32, originalStderr: Int32) {
    if originalStdout >= 0 {
      dup2(originalStdout, STDOUT_FILENO)
    }
    if originalStderr >= 0 {
      dup2(originalStderr, STDERR_FILENO)
    }
  }

  private func writeData(_ data: Data, fd: Int32) {
    guard fd >= 0 else {
      return
    }

    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return
      }

      var offset = 0
      while offset < data.count {
        let written = Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
        if written <= 0 {
          break
        }
        offset += written
      }
    }
  }

  private func startOSLogPolling() {
    guard captureEnabled, panelActive, osLogTimer == nil else {
      return
    }

    do {
      osLogStore = try OSLogStore(scope: .currentProcessIdentifier)
      lastOSLogDate = Date().addingTimeInterval(-8)
    } catch {
      osLogStore = nil
      return
    }

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.35, repeating: 0.5)
    timer.setEventHandler { [weak self] in
      self?.pollOSLogStore()
    }
    osLogTimer = timer
    timer.resume()
  }

  private func stopOSLogPollingLocked() {
    osLogTimer?.cancel()
    osLogTimer = nil
    osLogStore = nil
  }

  private func pollOSLogStore() {
    guard captureEnabled, panelActive, let osLogStore else {
      stopOSLogPollingLocked()
      return
    }

    let startDate = lastOSLogDate
    let position = osLogStore.position(date: startDate)
    do {
      let entries = try osLogStore.getEntries(at: position)
      var newestDate = startDate
      var emittedCount = 0

      for entry in entries {
        guard entry.date > startDate else {
          continue
        }

        newestDate = max(newestDate, entry.date)
        emit(osLogEntry: entry)
        emittedCount += 1

        if emittedCount >= 400 {
          break
        }
      }

      lastOSLogDate = newestDate
    } catch {
      osLogTimer?.cancel()
      osLogTimer = nil
      self.osLogStore = nil
    }
  }

  private func startLifecycleObserversIfNeeded() {
    OperationQueue.main.addOperation(BlockOperation { [weak self] in
      guard let self, self.captureEnabled, self.panelActive, self.lifecycleObservers.isEmpty else {
        return
      }

      let center = NotificationCenter.default
      self.lifecycleObservers = [
        center.addObserver(
          forName: UIApplication.didBecomeActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordApplicationEvent(
            event: "didBecomeActive",
            type: "info",
            message: "Application became active."
          )
        },
        center.addObserver(
          forName: UIApplication.willResignActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordApplicationEvent(
            event: "willResignActive",
            type: "warn",
            message: "Application will resign active."
          )
        },
        center.addObserver(
          forName: UIApplication.didEnterBackgroundNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordApplicationEvent(
            event: "didEnterBackground",
            type: "info",
            message: "Application entered background."
          )
        },
        center.addObserver(
          forName: UIApplication.willEnterForegroundNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordApplicationEvent(
            event: "willEnterForeground",
            type: "info",
            message: "Application will enter foreground."
          )
        },
        center.addObserver(
          forName: UIApplication.didReceiveMemoryWarningNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordApplicationEvent(
            event: "didReceiveMemoryWarning",
            type: "warn",
            message: "Application received a memory warning."
          )
        },
        center.addObserver(
          forName: UIApplication.significantTimeChangeNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordApplicationEvent(
            event: "significantTimeChange",
            type: "info",
            message: "System significant time change observed."
          )
        },
        center.addObserver(
          forName: UIApplication.protectedDataDidBecomeAvailableNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordApplicationEvent(
            event: "protectedDataDidBecomeAvailable",
            type: "info",
            message: "Protected data became available."
          )
        },
        center.addObserver(
          forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordApplicationEvent(
            event: "protectedDataWillBecomeUnavailable",
            type: "warn",
            message: "Protected data will become unavailable."
          )
        },
        center.addObserver(
          forName: UIApplication.willTerminateNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordApplicationEvent(
            event: "willTerminate",
            type: "error",
            message: "Application will terminate."
          )
        },
      ]
    })
  }

  private func stopLifecycleObserversLocked() {
    let observers = lifecycleObservers
    lifecycleObservers.removeAll(keepingCapacity: false)
    guard !observers.isEmpty else {
      return
    }
    OperationQueue.main.addOperation {
      observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
  }

  private func startDiagnosticObserversIfNeeded() {
    OperationQueue.main.addOperation(BlockOperation { [weak self] in
      guard let self, self.captureEnabled, self.panelActive, self.diagnosticObservers.isEmpty else {
        return
      }

      let center = NotificationCenter.default
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      self.diagnosticObservers = [
        center.addObserver(
          forName: ProcessInfo.thermalStateDidChangeNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordRuntimeDiagnosticEvent(
            event: "thermalStateDidChange",
            type: ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
              ? "warn"
              : "info",
            message: "Thermal state changed."
          )
        },
        center.addObserver(
          forName: Notification.Name.NSProcessInfoPowerStateDidChange,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordRuntimeDiagnosticEvent(
            event: "powerStateDidChange",
            type: ProcessInfo.processInfo.isLowPowerModeEnabled ? "warn" : "info",
            message: "Power mode changed."
          )
        },
        center.addObserver(
          forName: UIDevice.orientationDidChangeNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.recordRuntimeDiagnosticEvent(
            event: "orientationDidChange",
            type: "info",
            message: "Device orientation changed."
          )
        },
      ]
    })
  }

  private func stopDiagnosticObserversLocked() {
    let observers = diagnosticObservers
    diagnosticObservers.removeAll(keepingCapacity: false)
    guard !observers.isEmpty else {
      return
    }
    OperationQueue.main.addOperation {
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
      observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
  }

  private func startNetworkPathMonitoringIfNeeded() {
    guard captureEnabled, panelActive, pathMonitor == nil else {
      return
    }

    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      self?.recordNetworkPathUpdate(path)
    }
    monitor.start(queue: queue)
    pathMonitor = monitor
  }

  private func stopNetworkPathMonitoringLocked() {
    pathMonitor?.cancel()
    pathMonitor = nil
  }

  private func logSessionStartIfNeeded() {
    OperationQueue.main.addOperation(BlockOperation { [weak self] in
      guard let self, self.captureEnabled, self.panelActive, !self.didLogSessionStart else {
        return
      }

      self.didLogSessionStart = true
      let bundle = Bundle.main
      let processInfo = ProcessInfo.processInfo
      let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
      let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
      let applicationState = self.applicationStateDescription(UIApplication.shared.applicationState)

      InAppDebuggerStore.shared.appendNativeLog(
        type: "info",
        message: "native capture started for the current process.",
        stream: "session.start · \(processInfo.processName)(\(processInfo.processIdentifier))",
        details: self.buildDetailsString([
          ("collector", "session-start"),
          ("bundleIdentifier", bundle.bundleIdentifier ?? ""),
          ("version", version),
          ("build", build),
          ("process", processInfo.processName),
          ("pid", "\(processInfo.processIdentifier)"),
          ("systemName", UIDevice.current.systemName),
          ("systemVersion", UIDevice.current.systemVersion),
          ("deviceModel", UIDevice.current.model),
          ("locale", Locale.current.identifier),
          ("appState", applicationState),
          ("backgroundRefreshStatus", self.backgroundRefreshStatusDescription(UIApplication.shared.backgroundRefreshStatus)),
          ("lowPowerMode", processInfo.isLowPowerModeEnabled ? "true" : "false"),
          ("thermalState", self.thermalStateDescription(processInfo.thermalState)),
          ("deviceOrientation", self.orientationDescription(UIDevice.current.orientation)),
          ("fatalSignals", inAppDebuggerFatalSignals.map { "\(inAppDebuggerSignalName($0))(\($0))" }.joined(separator: ", ")),
        ]),
        date: Date()
      )
    })
  }

  private func recordApplicationEvent(event: String, type: String, message: String) {
    guard captureEnabled, panelActive else {
      return
    }
    let processInfo = ProcessInfo.processInfo
    let details = buildDetailsString([
      ("collector", "app-lifecycle"),
      ("event", event),
      ("appState", applicationStateDescription(UIApplication.shared.applicationState)),
      ("backgroundRefreshStatus", backgroundRefreshStatusDescription(UIApplication.shared.backgroundRefreshStatus)),
      ("protectedDataAvailable", UIApplication.shared.isProtectedDataAvailable ? "true" : "false"),
      ("lowPowerMode", processInfo.isLowPowerModeEnabled ? "true" : "false"),
      ("thermalState", thermalStateDescription(processInfo.thermalState)),
      ("deviceOrientation", orientationDescription(UIDevice.current.orientation)),
      ("process", processInfo.processName),
      ("pid", "\(processInfo.processIdentifier)"),
      ("thread", Thread.isMainThread ? "main" : "background"),
    ])

    InAppDebuggerStore.shared.appendNativeLog(
      type: type,
      message: message,
      stream: "app.lifecycle · \(event)",
      details: details,
      date: Date()
    )
  }

  private func recordRuntimeDiagnosticEvent(event: String, type: String, message: String) {
    guard captureEnabled, panelActive else {
      return
    }
    let processInfo = ProcessInfo.processInfo
    let details = buildDetailsString([
      ("collector", "runtime-diagnostic"),
      ("event", event),
      ("appState", applicationStateDescription(UIApplication.shared.applicationState)),
      ("backgroundRefreshStatus", backgroundRefreshStatusDescription(UIApplication.shared.backgroundRefreshStatus)),
      ("lowPowerMode", processInfo.isLowPowerModeEnabled ? "true" : "false"),
      ("thermalState", thermalStateDescription(processInfo.thermalState)),
      ("deviceOrientation", orientationDescription(UIDevice.current.orientation)),
      ("protectedDataAvailable", UIApplication.shared.isProtectedDataAvailable ? "true" : "false"),
      ("process", processInfo.processName),
      ("pid", "\(processInfo.processIdentifier)"),
      ("thread", Thread.isMainThread ? "main" : "background"),
    ])

    InAppDebuggerStore.shared.appendNativeLog(
      type: type,
      message: message,
      stream: "runtime.diagnostic · \(event)",
      details: details,
      date: Date()
    )
  }

  private func recordNetworkPathUpdate(_ path: NWPath) {
    guard captureEnabled, panelActive else {
      return
    }
    let processInfo = ProcessInfo.processInfo
    let status = networkPathStatusDescription(path.status)
    let interfaces = activeInterfaceDescriptions(for: path).joined(separator: ", ")
    let details = buildDetailsString([
      ("collector", "network-path"),
      ("status", status),
      ("interfaces", interfaces),
      ("isExpensive", path.isExpensive ? "true" : "false"),
      ("isConstrained", path.isConstrained ? "true" : "false"),
      ("supportsDNS", path.supportsDNS ? "true" : "false"),
      ("supportsIPv4", path.supportsIPv4 ? "true" : "false"),
      ("supportsIPv6", path.supportsIPv6 ? "true" : "false"),
      ("availableInterfaces", path.availableInterfaces.map { "\(networkInterfaceTypeDescription($0.type)):\($0.name)" }.joined(separator: ", ")),
      ("process", processInfo.processName),
      ("pid", "\(processInfo.processIdentifier)"),
    ])

    let message = interfaces.isEmpty
      ? "Network path updated: \(status)."
      : "Network path updated: \(status) via \(interfaces)."

    InAppDebuggerStore.shared.appendNativeLog(
      type: path.status == .unsatisfied ? "warn" : "info",
      message: message,
      stream: "network.path",
      details: details,
      date: Date()
    )
  }

  private func process(data: Data, stream: String) {
    guard captureEnabled, panelActive else {
      return
    }
    if stream == "stdout" {
      stdoutBuffer.append(data)
      drainBuffer(&stdoutBuffer, stream: stream)
    } else {
      stderrBuffer.append(data)
      drainBuffer(&stderrBuffer, stream: stream)
    }
  }

  private func drainBuffer(_ buffer: inout Data, stream: String) {
    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
      var lineData = Data(buffer[..<newlineIndex])
      buffer.removeSubrange(...newlineIndex)
      if lineData.last == 0x0D {
        lineData.removeLast()
      }
      emit(lineData: lineData, stream: stream)
    }

    if buffer.count > 16 * 1024 {
      let lineData = buffer
      buffer.removeAll(keepingCapacity: true)
      emit(lineData: lineData, stream: stream)
    }
  }

  private func emit(lineData: Data, stream: String) {
    guard !lineData.isEmpty else {
      return
    }

    let message = inAppDebuggerTrimmedMessage(String(decoding: lineData, as: UTF8.self))
    guard !message.isEmpty else {
      return
    }

    let metadata = streamMetadata(for: stream)
    InAppDebuggerStore.shared.appendNativeLog(
      type: inferLevel(from: message),
      message: message,
      stream: metadata.context,
      details: metadata.details,
      date: Date()
    )
  }

  private func emit(osLogEntry entry: OSLogEntry) {
    guard captureEnabled, panelActive else {
      return
    }
    let message = inAppDebuggerTrimmedMessage(entry.composedMessage)
    guard !message.isEmpty else {
      return
    }

    InAppDebuggerStore.shared.appendNativeLog(
      type: osLogLevel(for: entry),
      message: message,
      stream: osLogContext(for: entry),
      details: osLogDetails(for: entry),
      date: entry.date
    )
  }

  private func osLogLevel(for entry: OSLogEntry) -> String {
    guard let logEntry = entry as? OSLogEntryLog else {
      return inferLevel(from: entry.composedMessage)
    }

    switch logEntry.level {
    case .debug:
      return "debug"
    case .info:
      return "info"
    case .error, .fault:
      return "error"
    case .notice, .undefined:
      return "log"
    @unknown default:
      return inferLevel(from: entry.composedMessage)
    }
  }

  private func osLogContext(for entry: OSLogEntry) -> String {
    var parts = [osLogCollectorName(for: entry)]
    if let payload = entry as? OSLogEntryWithPayload {
      appendNonEmpty(payload.subsystem, to: &parts)
      appendNonEmpty(payload.category, to: &parts)
    }
    if let process = entry as? OSLogEntryFromProcess {
      appendNonEmpty(process.sender, to: &parts)
      parts.append("\(process.process)(\(process.processIdentifier))")
      parts.append("thread \(process.threadIdentifier)")
    }
    return parts.joined(separator: " · ")
  }

  private func osLogDetails(for entry: OSLogEntry) -> String? {
    var rows: [(String, String?)] = [
      ("collector", osLogCollectorName(for: entry)),
      ("storeCategory", osLogStoreCategory(entry.storeCategory)),
    ]

    if let logEntry = entry as? OSLogEntryLog {
      rows.append(("level", osLogEntryLevel(logEntry.level)))
    }
    if let payload = entry as? OSLogEntryWithPayload {
      rows.append(("subsystem", payload.subsystem))
      rows.append(("category", payload.category))
      rows.append(("formatString", payload.formatString))
    }
    if let process = entry as? OSLogEntryFromProcess {
      rows.append(("process", process.process))
      rows.append(("pid", "\(process.processIdentifier)"))
      rows.append(("sender", process.sender))
      rows.append(("thread", "\(process.threadIdentifier)"))
      rows.append(("activityIdentifier", "\(process.activityIdentifier)"))
    }

    return buildDetailsString(rows)
  }

  private func osLogCollectorName(for entry: OSLogEntry) -> String {
    if entry is OSLogEntrySignpost {
      return "oslog.signpost"
    }
    if entry is OSLogEntryActivity {
      return "oslog.activity"
    }
    return "oslog"
  }

  private func osLogStoreCategory(_ category: OSLogEntry.StoreCategory) -> String {
    switch category {
    case .metadata:
      return "metadata"
    case .shortTerm:
      return "shortTerm"
    case .longTermAuto:
      return "longTermAuto"
    case .longTerm1:
      return "longTerm1"
    case .longTerm3:
      return "longTerm3"
    case .longTerm7:
      return "longTerm7"
    case .longTerm14:
      return "longTerm14"
    case .longTerm30:
      return "longTerm30"
    case .undefined:
      return "undefined"
    @unknown default:
      return "unknown"
    }
  }

  private func osLogEntryLevel(_ level: OSLogEntryLog.Level) -> String {
    switch level {
    case .debug:
      return "debug"
    case .info:
      return "info"
    case .notice:
      return "notice"
    case .error:
      return "error"
    case .fault:
      return "fault"
    case .undefined:
      return "undefined"
    @unknown default:
      return "unknown"
    }
  }

  private func inferLevel(from message: String) -> String {
    if inAppDebuggerErrorLevelKeywords.contains(where: { inAppDebuggerContainsASCIIKeyword(message, keyword: $0) }) {
      return "error"
    }
    if inAppDebuggerContainsASCIIKeyword(message, keyword: inAppDebuggerWarnLevelKeyword) {
      return "warn"
    }
    if inAppDebuggerContainsASCIIKeyword(message, keyword: inAppDebuggerDebugLevelKeyword) {
      return "debug"
    }
    if inAppDebuggerContainsASCIIKeyword(message, keyword: inAppDebuggerInfoLevelKeyword) {
      return "info"
    }
    return "log"
  }

  private func streamMetadata(for stream: String) -> (context: String, details: String?) {
    if let metadata = streamMetadataCache[stream] {
      return metadata
    }
    let metadata = (
      context: "\(stream) · \(processName)(\(processIdentifier))",
      details: buildDetailsString([
        ("collector", stream),
        ("process", processName),
        ("pid", "\(processIdentifier)"),
      ])
    )
    streamMetadataCache[stream] = metadata
    return metadata
  }

  private func applicationStateDescription(_ state: UIApplication.State) -> String {
    switch state {
    case .active:
      return "active"
    case .background:
      return "background"
    case .inactive:
      return "inactive"
    @unknown default:
      return "unknown"
    }
  }

  private func backgroundRefreshStatusDescription(_ status: UIBackgroundRefreshStatus) -> String {
    switch status {
    case .available:
      return "available"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    @unknown default:
      return "unknown"
    }
  }

  private func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
      return "nominal"
    case .fair:
      return "fair"
    case .serious:
      return "serious"
    case .critical:
      return "critical"
    @unknown default:
      return "unknown"
    }
  }

  private func orientationDescription(_ orientation: UIDeviceOrientation) -> String {
    switch orientation {
    case .portrait:
      return "portrait"
    case .portraitUpsideDown:
      return "portraitUpsideDown"
    case .landscapeLeft:
      return "landscapeLeft"
    case .landscapeRight:
      return "landscapeRight"
    case .faceUp:
      return "faceUp"
    case .faceDown:
      return "faceDown"
    case .unknown:
      return "unknown"
    @unknown default:
      return "unknown"
    }
  }

  private func networkPathStatusDescription(_ status: NWPath.Status) -> String {
    switch status {
    case .satisfied:
      return "satisfied"
    case .unsatisfied:
      return "unsatisfied"
    case .requiresConnection:
      return "requiresConnection"
    @unknown default:
      return "unknown"
    }
  }

  private func activeInterfaceDescriptions(for path: NWPath) -> [String] {
    var interfaces: [String] = []
    let types: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .loopback, .other]
    for type in types where path.usesInterfaceType(type) {
      interfaces.append(networkInterfaceTypeDescription(type))
    }
    return interfaces
  }

  private func networkInterfaceTypeDescription(_ type: NWInterface.InterfaceType) -> String {
    switch type {
    case .wifi:
      return "wifi"
    case .cellular:
      return "cellular"
    case .wiredEthernet:
      return "wiredEthernet"
    case .loopback:
      return "loopback"
    case .other:
      return "other"
    @unknown default:
      return "unknown"
    }
  }

  private func buildDetailsString(_ rows: [(String, String?)]) -> String? {
    let lines = rows.compactMap { key, value -> String? in
      guard let value, !value.isEmpty else {
        return nil
      }
      if value.contains("\n") {
        return "\(key):\n\(value)"
      }
      return "\(key): \(value)"
    }

    guard !lines.isEmpty else {
      return nil
    }
    return lines.joined(separator: "\n")
  }

  private func appendNonEmpty(_ value: String, to parts: inout [String]) {
    guard !value.isEmpty else {
      return
    }
    parts.append(value)
  }
}

private let nativeWebSocketClockFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "HH:mm:ss.SSS"
  return formatter
}()

private let nativeWebSocketByteCountFormatter: ByteCountFormatter = {
  let formatter = ByteCountFormatter()
  formatter.allowedUnits = [.useBytes, .useKB, .useMB]
  formatter.countStyle = .file
  formatter.includesUnit = true
  formatter.isAdaptive = true
  return formatter
}()

private struct PendingWebSocketMetadata {
  let method: String
  let url: String
  let requestHeaders: [String: String]
  let requestedProtocols: String?
}

private final class TrackedWebSocketState {
  let id: String
  let socketId: Int
  let timelineSequence: Int
  var kind = "websocket"
  var method: String
  var url: String
  var origin = "js"
  var state: String
  var startedAt: Int
  var updatedAt: Int
  var endedAt: Int?
  var durationMs: Int?
  var status: Int?
  var requestHeaders: [String: String]
  var responseHeaders: [String: String] = [:]
  var error: String?
  var `protocol`: String?
  var requestedProtocols: String?
  var closeReason: String?
  var closeCode: Int?
  var requestedCloseCode: Int?
  var requestedCloseReason: String?
  var cleanClose: Bool?
  var messageCountIn = 0
  var messageCountOut = 0
  var bytesIn = 0
  var bytesOut = 0
  var eventsBuffer = InAppDebuggerCappedStringBuffer(capacity: nativeNetworkEventHistoryLimit)
  var messagesBuffer = InAppDebuggerCappedStringBuffer(capacity: nativeNetworkMessageHistoryLimit)
  private var cachedEvents: String?
  private var cachedMessages: String?
  private var eventsDirty = false
  private var messagesDirty = false
  var lastStoreEmissionAt = 0

  init(
    socketId: Int,
    timelineSequence: Int,
    method: String,
    url: String,
    state: String,
    startedAt: Int,
    requestHeaders: [String: String],
    requestedProtocols: String?
  ) {
    self.id = "ws_\(socketId)"
    self.socketId = socketId
    self.timelineSequence = timelineSequence
    self.method = method
    self.url = url
    self.state = state
    self.startedAt = startedAt
    self.updatedAt = startedAt
    self.requestHeaders = requestHeaders
    self.requestedProtocols = requestedProtocols
  }

  func appendEventLine(_ line: String) {
    eventsBuffer.append(line)
    eventsDirty = true
  }

  func appendMessageBlock(_ block: String) {
    messagesBuffer.append(block)
    messagesDirty = true
  }

  func asEntry() -> DebugNetworkEntry {
    if eventsDirty {
      cachedEvents = eventsBuffer.makeJoinedString(separator: "\n")
      eventsDirty = false
    }
    if messagesDirty {
      cachedMessages = messagesBuffer.makeJoinedString(separator: "\n\n")
      messagesDirty = false
    }
    return DebugNetworkEntry(
      id: id,
      kind: kind,
      method: method,
      url: url,
      origin: origin,
      state: state,
      startedAt: startedAt,
      updatedAt: updatedAt,
      endedAt: endedAt,
      durationMs: durationMs,
      status: status,
      requestHeaders: requestHeaders,
      responseHeaders: responseHeaders,
      error: error,
      protocol: `protocol`,
      requestedProtocols: requestedProtocols,
      closeReason: closeReason,
      closeCode: closeCode,
      requestedCloseCode: requestedCloseCode,
      requestedCloseReason: requestedCloseReason,
      cleanClose: cleanClose,
      messageCountIn: messageCountIn,
      messageCountOut: messageCountOut,
      bytesIn: bytesIn,
      bytesOut: bytesOut,
      events: cachedEvents,
      messages: cachedMessages,
      timelineSequence: timelineSequence
    )
  }
}

final class InAppDebuggerNativeWebSocketCapture {
  static let shared = InAppDebuggerNativeWebSocketCapture()

  private let lock = NSLock()
  private var enabled = false
  private var panelActive = false
  private var trackedSockets: [Int: TrackedWebSocketState] = [:]
  private var pendingSockets: [String: PendingWebSocketMetadata] = [:]
  private let liveUpdateThrottleMs = 120

  private init() {}

  func setEnabled(_ enabled: Bool) {
    lock.lock()
    self.enabled = enabled
    if !enabled {
      panelActive = false
      trackedSockets.removeAll(keepingCapacity: false)
      pendingSockets.removeAll(keepingCapacity: false)
    }
    lock.unlock()

    if enabled {
      InAppDebuggerNativeWebSocketHookInstaller.installIfNeeded()
    }
  }

  func setPanelActive(_ active: Bool) {
    var snapshots: [DebugNetworkEntry] = []
    let timestamp = currentTimestamp()
    var shouldRefresh = false

    lock.lock()
    panelActive = enabled && active
    shouldRefresh = panelActive
    if panelActive {
      snapshots.reserveCapacity(trackedSockets.count)
      for tracked in trackedSockets.values {
        tracked.lastStoreEmissionAt = timestamp
        snapshots.append(tracked.asEntry())
      }
    }
    lock.unlock()

    guard shouldRefresh else {
      return
    }

    for entry in snapshots {
      InAppDebuggerStore.shared.upsertNetworkEntry(entry)
    }
  }

  func refreshVisibleEntries() {
    var snapshots: [DebugNetworkEntry] = []
    let timestamp = currentTimestamp()

    lock.lock()
    if enabled {
      snapshots.reserveCapacity(trackedSockets.count)
      for tracked in trackedSockets.values {
        tracked.lastStoreEmissionAt = timestamp
        snapshots.append(tracked.asEntry())
      }
    }
    lock.unlock()

    for entry in snapshots {
      InAppDebuggerStore.shared.upsertNetworkEntry(entry)
    }
  }

  fileprivate func recordInitializedSocket(_ socket: AnyObject, request: URLRequest, protocols: [String]?) {
    lock.lock()
    defer { lock.unlock() }
    guard enabled else {
      return
    }

    pendingSockets[objectKey(for: socket)] = PendingWebSocketMetadata(
      method: webSocketMethod(for: request.url?.absoluteString ?? ""),
      url: request.url?.absoluteString ?? "",
      requestHeaders: request.allHTTPHeaderFields ?? [:],
      requestedProtocols: protocols?.joined(separator: ", ").nilIfEmpty
    )
  }

  fileprivate func recordOpenRequested(_ socket: AnyObject) {
    mutateSocket(socket, defaultState: "connecting") { tracked, timestamp, _ in
      tracked.state = "connecting"
      tracked.updatedAt = timestamp
      tracked.endedAt = nil
      tracked.durationMs = nil
      tracked.error = nil
      tracked.closeCode = nil
      tracked.closeReason = nil
      tracked.cleanClose = nil
      tracked.requestedCloseCode = nil
      tracked.requestedCloseReason = nil
      appendEvent("connect", to: tracked, at: timestamp)
      return .emitVisibleImmediate
    }
  }

  fileprivate func recordOpened(_ socket: AnyObject) {
    mutateSocket(socket, defaultState: "open") { tracked, timestamp, _ in
      tracked.state = "open"
      tracked.updatedAt = timestamp
      tracked.protocol = socketStringValue(socket, selectorName: "protocol") ?? tracked.protocol
      appendEvent(
        tracked.protocol.nilIfEmpty.map { "open protocol=\($0)" } ?? "open",
        to: tracked,
        at: timestamp
      )
      return .emitVisibleImmediate
    }
  }

  fileprivate func recordSendString(_ socket: AnyObject, text: String) {
    mutateSocket(socket, defaultState: "open") { tracked, timestamp, isPanelActive in
      let byteCount = text.lengthOfBytes(using: .utf8)
      tracked.state = tracked.state == "connecting" ? "open" : tracked.state
      tracked.updatedAt = timestamp
      tracked.messageCountOut += 1
      tracked.bytesOut += byteCount
      if isPanelActive {
        appendMessage(
          direction: ">>",
          kind: "text",
          payload: storedMessageText(text),
          byteCount: byteCount,
          to: tracked,
          at: timestamp
        )
      }
      return .emitVisibleThrottled
    }
  }

  fileprivate func recordSendData(_ socket: AnyObject, data: Data?) {
    mutateSocket(socket, defaultState: "open") { tracked, timestamp, isPanelActive in
      let payload = data ?? Data()
      tracked.state = tracked.state == "connecting" ? "open" : tracked.state
      tracked.updatedAt = timestamp
      tracked.messageCountOut += 1
      tracked.bytesOut += payload.count
      if isPanelActive {
        appendMessage(
          direction: ">>",
          kind: "binary",
          payload: hexPreview(for: payload),
          byteCount: payload.count,
          to: tracked,
          at: timestamp
        )
      }
      return .emitVisibleThrottled
    }
  }

  fileprivate func recordPing(_ socket: AnyObject, data: Data?) {
    mutateSocket(socket, defaultState: "open") { tracked, timestamp, isPanelActive in
      tracked.updatedAt = timestamp
      if isPanelActive {
        appendEvent("ping \(formatByteCount(data?.count ?? 0))", to: tracked, at: timestamp)
      }
      return .emitVisibleThrottled
    }
  }

  fileprivate func recordReceivedMessage(_ socket: AnyObject, message: Any?) {
    mutateSocket(socket, defaultState: "open") { tracked, timestamp, isPanelActive in
      tracked.state = tracked.state == "connecting" ? "open" : tracked.state
      tracked.updatedAt = timestamp

      let payload = describeMessagePayload(message, includeBody: isPanelActive)
      tracked.messageCountIn += 1
      tracked.bytesIn += payload.byteCount

      if isPanelActive {
        appendMessage(
          direction: "<<",
          kind: payload.kind,
          payload: payload.body,
          byteCount: payload.byteCount,
          to: tracked,
          at: timestamp
        )
      }
      return .emitVisibleThrottled
    }
  }

  fileprivate func recordCloseRequested(_ socket: AnyObject, code: Int, reason: String?) {
    mutateSocket(socket, defaultState: "closing") { tracked, timestamp, _ in
      tracked.state = "closing"
      tracked.updatedAt = timestamp
      tracked.requestedCloseCode = code
      tracked.requestedCloseReason = reason?.nilIfEmpty
      appendEvent(
        "close requested code=\(code)\(formatReasonSuffix(reason))",
        to: tracked,
        at: timestamp
      )
      return .emitVisibleImmediate
    }
  }

  fileprivate func recordFailed(_ socket: AnyObject, error: NSError) {
    finishSocket(socket) { tracked, timestamp, _ in
      tracked.state = "error"
      tracked.updatedAt = timestamp
      tracked.endedAt = timestamp
      tracked.durationMs = max(0, timestamp - tracked.startedAt)
      tracked.error = error.localizedDescription.nilIfEmpty ?? "WebSocket error"
      appendEvent("error \(tracked.error ?? "WebSocket error")", to: tracked, at: timestamp)
      return .emitAlways
    }
  }

  fileprivate func recordClosed(_ socket: AnyObject, code: Int, reason: String?, wasClean: Bool) {
    finishSocket(socket) { tracked, timestamp, _ in
      tracked.state = tracked.error == nil ? "closed" : "error"
      tracked.updatedAt = timestamp
      tracked.endedAt = timestamp
      tracked.durationMs = max(0, timestamp - tracked.startedAt)
      tracked.closeCode = code
      tracked.closeReason = reason?.nilIfEmpty
      tracked.cleanClose = wasClean
      appendEvent(
        "closed code=\(code) clean=\(wasClean ? "true" : "false")\(formatReasonSuffix(reason))",
        to: tracked,
        at: timestamp
      )
      return .emitAlways
    }
  }

  private enum SocketMutationResult {
    case none
    case emitVisibleImmediate
    case emitVisibleThrottled
    case emitAlways
  }

  private func mutateSocket(
    _ socket: AnyObject,
    defaultState: String,
    mutation: (_ tracked: TrackedWebSocketState, _ timestamp: Int, _ isPanelActive: Bool) -> SocketMutationResult
  ) {
    var emittedEntry: DebugNetworkEntry?

    lock.lock()
    guard enabled, let tracked = trackedSocket(for: socket, defaultState: defaultState) else {
      lock.unlock()
      return
    }

    let timestamp = currentTimestamp()
    let shouldEmit = mutation(tracked, timestamp, panelActive)
    emittedEntry = preparedSocketEntry(tracked, timestamp: timestamp, emission: shouldEmit)
    lock.unlock()

    if let emittedEntry {
      InAppDebuggerStore.shared.upsertNetworkEntry(emittedEntry)
    }
  }

  private func finishSocket(
    _ socket: AnyObject,
    mutation: (_ tracked: TrackedWebSocketState, _ timestamp: Int, _ isPanelActive: Bool) -> SocketMutationResult
  ) {
    var emittedEntry: DebugNetworkEntry?

    lock.lock()
    guard enabled, let tracked = trackedSocket(for: socket, defaultState: "open") else {
      lock.unlock()
      return
    }

    let timestamp = currentTimestamp()
    let shouldEmit = mutation(tracked, timestamp, panelActive)
    emittedEntry = preparedSocketEntry(tracked, timestamp: timestamp, emission: shouldEmit)
    trackedSockets.removeValue(forKey: tracked.socketId)
    pendingSockets.removeValue(forKey: objectKey(for: socket))
    lock.unlock()

    if let emittedEntry {
      InAppDebuggerStore.shared.upsertNetworkEntry(emittedEntry)
    }
  }

  private func trackedSocket(for socket: AnyObject, defaultState: String) -> TrackedWebSocketState? {
    guard let socketObject = socket as? NSObject,
          let socketId = socketID(for: socketObject) else {
      return nil
    }

    if let tracked = trackedSockets[socketId] {
      if tracked.url.isEmpty, let socketURL = socketURL(for: socketObject) {
        tracked.url = socketURL
        tracked.method = webSocketMethod(for: socketURL)
      }
      if tracked.protocol == nil {
        tracked.protocol = socketStringValue(socketObject, selectorName: "protocol")
      }
      return tracked
    }

    let metadata = pendingSockets.removeValue(forKey: objectKey(for: socketObject))
    let url = metadata?.url.nilIfEmpty ?? socketURL(for: socketObject) ?? ""
    let tracked = TrackedWebSocketState(
      socketId: socketId,
      timelineSequence: InAppDebuggerStore.shared.nextNativeTimelineSequence(),
      method: metadata?.method ?? webSocketMethod(for: url),
      url: url,
      state: defaultState,
      startedAt: currentTimestamp(),
      requestHeaders: metadata?.requestHeaders ?? [:],
      requestedProtocols: metadata?.requestedProtocols
    )
    tracked.protocol = socketStringValue(socketObject, selectorName: "protocol")
    trackedSockets[socketId] = tracked
    return tracked
  }
}

private extension InAppDebuggerNativeWebSocketCapture {
  private func preparedSocketEntry(
    _ tracked: TrackedWebSocketState,
    timestamp: Int,
    emission: SocketMutationResult
  ) -> DebugNetworkEntry? {
    switch emission {
    case .none:
      return nil
    case .emitVisibleImmediate:
      guard panelActive else {
        return nil
      }
    case .emitVisibleThrottled:
      guard panelActive, timestamp - tracked.lastStoreEmissionAt >= liveUpdateThrottleMs else {
        return nil
      }
    case .emitAlways:
      break
    }

    tracked.lastStoreEmissionAt = timestamp
    return tracked.asEntry()
  }

  func currentTimestamp() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
  }

  func appendEvent(_ text: String, to tracked: TrackedWebSocketState, at timestamp: Int) {
    tracked.appendEventLine("\(formatClock(timestamp)) \(text)")
  }

  func appendMessage(
    direction: String,
    kind: String,
    payload: String?,
    byteCount: Int,
    to tracked: TrackedWebSocketState,
    at timestamp: Int
  ) {
    var lines = ["[\(formatClock(timestamp))] \(direction) \(kind.uppercased())", formatByteCount(byteCount)]
    if let payload = payload?.nilIfEmpty {
      lines.append(payload)
    }
    tracked.appendMessageBlock(lines.joined(separator: "\n"))
  }

  func formatClock(_ timestamp: Int) -> String {
    nativeWebSocketClockFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000))
  }

  func objectKey(for object: AnyObject) -> String {
    String(UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque()))
  }

  func webSocketMethod(for url: String) -> String {
    guard let scheme = URL(string: url)?.scheme?.lowercased() else {
      return "WS"
    }
    return scheme == "wss" ? "WSS" : "WS"
  }

  func socketID(for socket: NSObject) -> Int? {
    guard socket.responds(to: NSSelectorFromString("reactTag")),
          let tag = socket.perform(NSSelectorFromString("reactTag"))?.takeUnretainedValue() as? NSNumber else {
      return nil
    }
    return tag.intValue
  }

  func socketURL(for socket: NSObject) -> String? {
    guard socket.responds(to: NSSelectorFromString("url")),
          let url = socket.perform(NSSelectorFromString("url"))?.takeUnretainedValue() as? NSURL else {
      return nil
    }
    return (url as URL).absoluteString
  }

  func socketStringValue(_ object: AnyObject, selectorName: String) -> String? {
    guard let object = object as? NSObject else {
      return nil
    }
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector),
          let value = object.perform(selector)?.takeUnretainedValue() as? NSString else {
      return nil
    }
    return (value as String).nilIfEmpty
  }

  func describeMessagePayload(
    _ message: Any?,
    includeBody: Bool = true
  ) -> (kind: String, body: String?, byteCount: Int) {
    if let text = message as? String {
      return ("text", includeBody ? storedMessageText(text) : nil, text.lengthOfBytes(using: .utf8))
    }
    if let string = message as? NSString {
      let value = string as String
      return ("text", includeBody ? storedMessageText(value) : nil, value.lengthOfBytes(using: .utf8))
    }
    if let data = message as? Data {
      return ("binary", includeBody ? hexPreview(for: data) : nil, data.count)
    }
    if let data = message as? NSData {
      let value = data as Data
      return ("binary", includeBody ? hexPreview(for: value) : nil, value.count)
    }
    let fallback = message.map { String(describing: $0) } ?? ""
    return ("unknown", includeBody ? storedMessageText(fallback) : nil, fallback.lengthOfBytes(using: .utf8))
  }

  func storedMessageText(_ text: String, limit: Int = 32_000) -> String? {
    let normalized = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    guard !normalized.isEmpty else {
      return nil
    }
    guard normalized.count > limit else {
      return normalized
    }

    let endIndex = normalized.index(normalized.startIndex, offsetBy: limit)
    return String(normalized[..<endIndex]) + "\n...[truncated]"
  }

  func sanitizeTextPreview(_ text: String) -> String {
    let normalized = text
      .replacingOccurrences(of: "\r\n", with: "\\n")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
    if normalized.count <= 240 {
      return normalized
    }
    let endIndex = normalized.index(normalized.startIndex, offsetBy: 240)
    return String(normalized[..<endIndex]) + "..."
  }

  func hexPreview(for data: Data) -> String {
    guard !data.isEmpty else {
      return "empty"
    }
    let previewBytes = data.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
    return data.count > 24 ? "\(previewBytes) ..." : previewBytes
  }

  func formatByteCount(_ count: Int) -> String {
    nativeWebSocketByteCountFormatter.string(fromByteCount: Int64(max(0, count)))
  }

  func formatReasonSuffix(_ reason: String?) -> String {
    guard let reason = reason?.nilIfEmpty else {
      return ""
    }
    return " reason=\(sanitizeTextPreview(reason))"
  }
}

private extension String {
  var nilIfEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

private extension Optional where Wrapped == String {
  var nilIfEmpty: String? {
    switch self {
    case .some(let value):
      return value.nilIfEmpty
    case .none:
      return nil
    }
  }
}

private enum InAppDebuggerNativeWebSocketHookInstaller {
  private static let lock = NSLock()
  private static var didInstall = false

  private typealias InitWithURLRequestProtocolsIMP = @convention(c) (
    AnyObject,
    Selector,
    NSURLRequest,
    NSArray?
  ) -> AnyObject
  private typealias OpenIMP = @convention(c) (AnyObject, Selector) -> Void
  private typealias SendStringIMP = @convention(c) (
    AnyObject,
    Selector,
    NSString,
    UnsafeMutablePointer<NSError?>?
  ) -> Bool
  private typealias SendDataIMP = @convention(c) (
    AnyObject,
    Selector,
    NSData?,
    UnsafeMutablePointer<NSError?>?
  ) -> Bool
  private typealias SendPingIMP = @convention(c) (
    AnyObject,
    Selector,
    NSData?,
    UnsafeMutablePointer<NSError?>?
  ) -> Bool
  private typealias CloseWithCodeIMP = @convention(c) (
    AnyObject,
    Selector,
    Int,
    NSString?
  ) -> Void
  private typealias WebSocketDidOpenIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void
  private typealias DidReceiveMessageIMP = @convention(c) (AnyObject, Selector, AnyObject, Any?) -> Void
  private typealias DidFailWithErrorIMP = @convention(c) (AnyObject, Selector, AnyObject, NSError) -> Void
  private typealias DidCloseWithCodeIMP = @convention(c) (
    AnyObject,
    Selector,
    AnyObject,
    Int,
    NSString?,
    ObjCBool
  ) -> Void

  static func installIfNeeded() {
    lock.lock()
    defer { lock.unlock() }
    guard !didInstall else {
      return
    }

    guard let socketClass = NSClassFromString("SRWebSocket"),
          let moduleClass = NSClassFromString("RCTWebSocketModule") else {
      return
    }

    installInitHook(on: socketClass)
    installOpenHook(on: socketClass)
    installSendStringHook(on: socketClass)
    installSendDataHook(on: socketClass)
    installSendPingHook(on: socketClass)
    installCloseWithCodeHook(on: socketClass)
    installDidOpenHook(on: moduleClass)
    installDidReceiveMessageHook(on: moduleClass)
    installDidFailHook(on: moduleClass)
    installDidCloseHook(on: moduleClass)

    didInstall = true
  }

  private static func installInitHook(on socketClass: AnyClass) {
    let selector = NSSelectorFromString("initWithURLRequest:protocols:")
    guard let method = class_getInstanceMethod(socketClass, selector) else {
      return
    }
    let original = unsafeBitCast(method_getImplementation(method), to: InitWithURLRequestProtocolsIMP.self)
    let block: @convention(block) (AnyObject, NSURLRequest, NSArray?) -> AnyObject = { receiver, request, protocols in
      let socket = original(receiver, selector, request, protocols)
      InAppDebuggerNativeWebSocketCapture.shared.recordInitializedSocket(
        socket,
        request: request as URLRequest,
        protocols: protocols as? [String]
      )
      return socket
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func installOpenHook(on socketClass: AnyClass) {
    let selector = NSSelectorFromString("open")
    guard let method = class_getInstanceMethod(socketClass, selector) else {
      return
    }
    let original = unsafeBitCast(method_getImplementation(method), to: OpenIMP.self)
    let block: @convention(block) (AnyObject) -> Void = { receiver in
      InAppDebuggerNativeWebSocketCapture.shared.recordOpenRequested(receiver)
      original(receiver, selector)
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func installSendStringHook(on socketClass: AnyClass) {
    let selector = NSSelectorFromString("sendString:error:")
    guard let method = class_getInstanceMethod(socketClass, selector) else {
      return
    }
    let original = unsafeBitCast(method_getImplementation(method), to: SendStringIMP.self)
    let block: @convention(block) (AnyObject, NSString, UnsafeMutablePointer<NSError?>?) -> Bool = {
      receiver, text, error in
      let result = original(receiver, selector, text, error)
      if result {
        InAppDebuggerNativeWebSocketCapture.shared.recordSendString(receiver, text: text as String)
      }
      return result
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func installSendDataHook(on socketClass: AnyClass) {
    let selector = NSSelectorFromString("sendData:error:")
    guard let method = class_getInstanceMethod(socketClass, selector) else {
      return
    }
    let original = unsafeBitCast(method_getImplementation(method), to: SendDataIMP.self)
    let block: @convention(block) (AnyObject, NSData?, UnsafeMutablePointer<NSError?>?) -> Bool = {
      receiver, data, error in
      let result = original(receiver, selector, data, error)
      if result {
        InAppDebuggerNativeWebSocketCapture.shared.recordSendData(receiver, data: data as Data?)
      }
      return result
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func installSendPingHook(on socketClass: AnyClass) {
    let selector = NSSelectorFromString("sendPing:error:")
    guard let method = class_getInstanceMethod(socketClass, selector) else {
      return
    }
    let original = unsafeBitCast(method_getImplementation(method), to: SendPingIMP.self)
    let block: @convention(block) (AnyObject, NSData?, UnsafeMutablePointer<NSError?>?) -> Bool = {
      receiver, data, error in
      let result = original(receiver, selector, data, error)
      if result {
        InAppDebuggerNativeWebSocketCapture.shared.recordPing(receiver, data: data as Data?)
      }
      return result
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func installCloseWithCodeHook(on socketClass: AnyClass) {
    let selector = NSSelectorFromString("closeWithCode:reason:")
    guard let method = class_getInstanceMethod(socketClass, selector) else {
      return
    }
    let original = unsafeBitCast(method_getImplementation(method), to: CloseWithCodeIMP.self)
    let block: @convention(block) (AnyObject, Int, NSString?) -> Void = { receiver, code, reason in
      InAppDebuggerNativeWebSocketCapture.shared.recordCloseRequested(
        receiver,
        code: code,
        reason: reason as String?
      )
      original(receiver, selector, code, reason)
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func installDidOpenHook(on moduleClass: AnyClass) {
    let selector = NSSelectorFromString("webSocketDidOpen:")
    guard let method = class_getInstanceMethod(moduleClass, selector) else {
      return
    }
    let original = unsafeBitCast(method_getImplementation(method), to: WebSocketDidOpenIMP.self)
    let block: @convention(block) (AnyObject, AnyObject) -> Void = { receiver, socket in
      InAppDebuggerNativeWebSocketCapture.shared.recordOpened(socket)
      original(receiver, selector, socket)
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func installDidReceiveMessageHook(on moduleClass: AnyClass) {
    let selector = NSSelectorFromString("webSocket:didReceiveMessage:")
    guard let method = class_getInstanceMethod(moduleClass, selector) else {
      return
    }
    let original = unsafeBitCast(method_getImplementation(method), to: DidReceiveMessageIMP.self)
    let block: @convention(block) (AnyObject, AnyObject, Any?) -> Void = { receiver, socket, message in
      InAppDebuggerNativeWebSocketCapture.shared.recordReceivedMessage(socket, message: message)
      original(receiver, selector, socket, message)
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func installDidFailHook(on moduleClass: AnyClass) {
    let selector = NSSelectorFromString("webSocket:didFailWithError:")
    guard let method = class_getInstanceMethod(moduleClass, selector) else {
      return
    }
    let original = unsafeBitCast(method_getImplementation(method), to: DidFailWithErrorIMP.self)
    let block: @convention(block) (AnyObject, AnyObject, NSError) -> Void = { receiver, socket, error in
      InAppDebuggerNativeWebSocketCapture.shared.recordFailed(socket, error: error)
      original(receiver, selector, socket, error)
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func installDidCloseHook(on moduleClass: AnyClass) {
    let selector = NSSelectorFromString("webSocket:didCloseWithCode:reason:wasClean:")
    guard let method = class_getInstanceMethod(moduleClass, selector) else {
      return
    }
    let original = unsafeBitCast(method_getImplementation(method), to: DidCloseWithCodeIMP.self)
    let block: @convention(block) (AnyObject, AnyObject, Int, NSString?, ObjCBool) -> Void = {
      receiver, socket, code, reason, wasClean in
      InAppDebuggerNativeWebSocketCapture.shared.recordClosed(
        socket,
        code: code,
        reason: reason as String?,
        wasClean: wasClean.boolValue
      )
      original(receiver, selector, socket, code, reason, wasClean)
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }
}
