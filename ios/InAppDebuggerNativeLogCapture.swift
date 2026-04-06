import Darwin
import Foundation
import OSLog

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
  private var isRunning = false

  private init() {}

  func start() {
    queue.sync {
      guard !isRunning else {
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
      startOSLogPolling()
    }
  }

  private func installReader(pipe: Pipe, stream: String, originalFD: Int32) {
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        return
      }

      self?.writeToOriginal(data, fd: originalFD)
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

  private func writeToOriginal(_ data: Data, fd: Int32) {
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
    guard osLogTimer == nil else {
      return
    }

    do {
      osLogStore = try OSLogStore(scope: .currentProcessIdentifier)
      lastOSLogDate = Date().addingTimeInterval(-0.5)
    } catch {
      osLogStore = nil
      return
    }

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in
      self?.pollOSLogStore()
    }
    osLogTimer = timer
    timer.resume()
  }

  private func pollOSLogStore() {
    guard let osLogStore else {
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

        if emittedCount >= 200 {
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

  private func process(data: Data, stream: String) {
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

    InAppDebuggerStore.shared.appendNativeLog(
      type: inferLevel(from: trimmed),
      message: trimmed,
      stream: nativeContext(stream: stream)
    )
  }

  private func emit(osLogEntry entry: OSLogEntry) {
    let message = entry.composedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
      return
    }

    InAppDebuggerStore.shared.appendNativeLog(
      type: osLogLevel(for: entry),
      message: message,
      stream: osLogContext(for: entry),
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
    var parts = ["oslog"]
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

  private func inferLevel(from message: String) -> String {
    let lowercased = message.lowercased()
    if lowercased.contains("fatal") ||
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

  private func appendNonEmpty(_ value: String, to parts: inout [String]) {
    guard !value.isEmpty else {
      return
    }
    parts.append(value)
  }
}
