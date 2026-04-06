import Darwin
import Foundation
import Network
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
      prepareLocked()
      captureEnabled = enabled
      if enabled {
        ensureStreamCaptureLocked()
        startLifecycleObserversIfNeeded()
        logSessionStartIfNeeded()
      } else {
        panelActive = false
        stopDetailedCollectorsLocked()
        stopLifecycleObserversLocked()
        stopStreamCaptureLocked()
      }
      refreshDetailedCollectorsLocked()
    }
  }

  func setPanelActive(_ active: Bool) {
    queue.async {
      self.panelActive = active
      self.refreshDetailedCollectorsLocked()
    }
  }

  private func prepareLocked() {
    guard !isPrepared else {
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

  private func refreshDetailedCollectorsLocked() {
    guard captureEnabled else {
      stopDetailedCollectorsLocked()
      return
    }

    if panelActive {
      startOSLogPolling()
      startNetworkPathMonitoringIfNeeded()
      startDiagnosticObserversIfNeeded()
    } else {
      stopDetailedCollectorsLocked()
    }
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
    if inAppDebuggerCrashFileDescriptor >= 0 {
      Darwin.close(inAppDebuggerCrashFileDescriptor)
      inAppDebuggerCrashFileDescriptor = -1
    }

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
      guard let self, self.captureEnabled, self.lifecycleObservers.isEmpty else {
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
      guard let self, self.captureEnabled, !self.didLogSessionStart else {
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
        message: "Native capture started for the current process.",
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
    guard captureEnabled else {
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
    guard captureEnabled else {
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
    let newline = Data([0x0A])
    while let range = buffer.firstRange(of: newline) {
      var lineData = buffer.subdata(in: 0..<range.lowerBound)
      buffer.removeSubrange(0..<range.upperBound)
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

    let message = String(data: lineData, encoding: .utf8)
      ?? String(decoding: lineData, as: UTF8.self)
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return
    }

    let processInfo = ProcessInfo.processInfo
    InAppDebuggerStore.shared.appendNativeLog(
      type: inferLevel(from: trimmed),
      message: trimmed,
      stream: nativeContext(stream: stream),
      details: buildDetailsString([
        ("collector", stream),
        ("process", processInfo.processName),
        ("pid", "\(processInfo.processIdentifier)"),
      ]),
      date: Date()
    )
  }

  private func emit(osLogEntry entry: OSLogEntry) {
    guard captureEnabled, panelActive else {
      return
    }
    let message = entry.composedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
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
    let lowercased = message.lowercased()
    if lowercased.contains("fatal") ||
      lowercased.contains("fault") ||
      lowercased.contains("error") ||
      lowercased.contains("exception") ||
      lowercased.contains("crash") {
      return "error"
    }
    if lowercased.contains("warn") {
      return "warn"
    }
    if lowercased.contains("debug") {
      return "debug"
    }
    if lowercased.contains("info") {
      return "info"
    }
    return "log"
  }

  private func nativeContext(stream: String) -> String {
    let processInfo = ProcessInfo.processInfo
    return "\(stream) · \(processInfo.processName)(\(processInfo.processIdentifier))"
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
