import Foundation
import ObjectiveC.runtime

private let inAppDebuggerNativeRequestHandledKey = "expo.inappdebugger.native-network.handled"
private let inAppDebuggerNativeRequestOriginKey = "expo.inappdebugger.native-network.origin"
private let inAppDebuggerNativeJSOriginValue = "js"

private final class InAppDebuggerNativeHTTPState {
  let id: String
  let origin: String
  let startedAt: Int
  var method: String
  var url: String
  var state: String
  var updatedAt: Int
  var endedAt: Int?
  var durationMs: Int?
  var status: Int?
  var requestHeaders: [String: String]
  var responseHeaders: [String: String] = [:]
  var requestBody: String?
  var responseBody: String?
  var responsePreviewData = Data()
  var responseBytesReceived = 0
  var responseType: String?
  var responseContentType: String?
  var responseSize: Int?
  var error: String?
  var lastStoreEmissionAt = 0

  init(
    id: String,
    origin: String,
    method: String,
    url: String,
    startedAt: Int,
    requestHeaders: [String: String],
    requestBody: String?
  ) {
    self.id = id
    self.origin = origin
    self.method = method
    self.url = url
    self.startedAt = startedAt
    self.updatedAt = startedAt
    self.state = "pending"
    self.requestHeaders = requestHeaders
    self.requestBody = requestBody
  }

  func asEntry() -> DebugNetworkEntry {
    DebugNetworkEntry(
      id: id,
      kind: "http",
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
      requestBody: requestBody,
      responseBody: responseBody,
      responseType: responseType,
      responseContentType: responseContentType,
      responseSize: responseSize,
      error: error
    )
  }
}

private final class InAppDebuggerNativeURLSessionWebSocketState {
  let id: String
  let objectKey: String
  let origin = "native"
  let kind = "websocket"
  let startedAt: Int
  var method: String
  var url: String
  var state: String
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
  var eventsList: [String] = []
  var messagesList: [String] = []
  var lastStoreEmissionAt = 0

  init(
    objectKey: String,
    method: String,
    url: String,
    startedAt: Int,
    requestHeaders: [String: String],
    requestedProtocols: String?
  ) {
    self.id = "native_ws_\(objectKey)"
    self.objectKey = objectKey
    self.method = method
    self.url = url
    self.startedAt = startedAt
    self.updatedAt = startedAt
    self.state = "pending"
    self.requestHeaders = requestHeaders
    self.requestedProtocols = requestedProtocols
  }

  func asEntry() -> DebugNetworkEntry {
    DebugNetworkEntry(
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
      events: eventsList.joined(separator: "\n"),
      messages: messagesList.joined(separator: "\n\n")
    )
  }
}

private final class InAppDebuggerNativeHTTPURLProtocol: URLProtocol, URLSessionDataDelegate, URLSessionTaskDelegate {
  private var session: URLSession?
  private var loadingTask: URLSessionDataTask?
  private var requestID: String?

  override class func canInit(with request: URLRequest) -> Bool {
    guard InAppDebuggerNativeNetworkCapture.shared.shouldIntercept(request: request) else {
      return false
    }
    return URLProtocol.property(forKey: inAppDebuggerNativeRequestHandledKey, in: request) as? Bool != true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override class func canInit(with task: URLSessionTask) -> Bool {
    guard let request = task.currentRequest ?? task.originalRequest else {
      return false
    }
    return canInit(with: request)
  }

  override func startLoading() {
    let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest
      ?? NSMutableURLRequest(url: request.url ?? URL(string: "about:blank")!)
    URLProtocol.setProperty(true, forKey: inAppDebuggerNativeRequestHandledKey, in: mutableRequest)

    requestID = InAppDebuggerNativeNetworkCapture.shared.beginHTTPRequest(mutableRequest as URLRequest)

    let configuration = URLSessionConfiguration.default
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    let task = session.dataTask(with: mutableRequest as URLRequest)
    self.session = session
    self.loadingTask = task
    task.resume()
  }

  override func stopLoading() {
    loadingTask?.cancel()
    session?.finishTasksAndInvalidate()
    session = nil
    loadingTask = nil
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let requestID {
      InAppDebuggerNativeNetworkCapture.shared.httpRequest(requestID, didReceive: response)
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    if let requestID {
      InAppDebuggerNativeNetworkCapture.shared.httpRequest(requestID, didReceive: data)
    }
    client?.urlProtocol(self, didLoad: data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let redirectedRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest
      ?? NSMutableURLRequest(url: request.url ?? URL(string: "about:blank")!)
    URLProtocol.setProperty(true, forKey: inAppDebuggerNativeRequestHandledKey, in: redirectedRequest)

    if let requestID {
      InAppDebuggerNativeNetworkCapture.shared.httpRequest(requestID, didRedirectTo: redirectedRequest as URLRequest)
    }
    completionHandler(redirectedRequest as URLRequest)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let requestID {
      InAppDebuggerNativeNetworkCapture.shared.finishHTTPRequest(requestID, error: error)
    }
    if let error {
      client?.urlProtocol(self, didFailWithError: error)
    } else {
      client?.urlProtocolDidFinishLoading(self)
    }
    session.finishTasksAndInvalidate()
    self.session = nil
    self.loadingTask = nil
  }
}

final class InAppDebuggerNativeNetworkCapture {
  static let shared = InAppDebuggerNativeNetworkCapture()

  private enum StoreEmissionPolicy {
    case visibleImmediate
    case visibleThrottled
    case always
  }

  private let lock = NSLock()
  private var enabled = false
  private var panelActive = false
  private var activeHTTPRequests: [String: InAppDebuggerNativeHTTPState] = [:]
  private var activeNativeWebSockets: [String: InAppDebuggerNativeURLSessionWebSocketState] = [:]
  private let liveUpdateThrottleMs = 120

  private init() {}

  func setEnabled(_ enabled: Bool) {
    lock.lock()
    self.enabled = enabled
    if !enabled {
      panelActive = false
      activeHTTPRequests.removeAll(keepingCapacity: false)
      activeNativeWebSockets.removeAll(keepingCapacity: false)
    }
    lock.unlock()

    guard enabled else {
      return
    }
    InAppDebuggerNativeNetworkHookInstaller.installIfNeeded()
  }

  func setPanelActive(_ active: Bool) {
    let shouldRefresh = lock.withLock {
      panelActive = enabled && active
      return panelActive
    }

    guard shouldRefresh else {
      return
    }
    refreshVisibleEntries()
  }

  func refreshVisibleEntries() {
    let timestamp = currentTimestamp()
    let entries: [DebugNetworkEntry] = lock.withLock {
      let httpEntries = activeHTTPRequests.values.map { state -> DebugNetworkEntry in
        state.lastStoreEmissionAt = timestamp
        return state.asEntry()
      }
      let webSocketEntries = activeNativeWebSockets.values.map { state -> DebugNetworkEntry in
        state.lastStoreEmissionAt = timestamp
        return state.asEntry()
      }
      return (httpEntries + webSocketEntries).sorted { lhs, rhs in
        if lhs.updatedAt != rhs.updatedAt {
          return lhs.updatedAt > rhs.updatedAt
        }
        if lhs.startedAt != rhs.startedAt {
          return lhs.startedAt > rhs.startedAt
        }
        return lhs.id > rhs.id
      }
    }
    entries.forEach { InAppDebuggerStore.shared.upsertNetworkEntry($0) }
  }

  fileprivate func shouldIntercept(request: URLRequest) -> Bool {
    guard lock.withLock({ enabled }) else {
      return false
    }
    guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return false
    }
    return requestOrigin(for: request) != inAppDebuggerNativeJSOriginValue
  }

  fileprivate func beginHTTPRequest(_ request: URLRequest) -> String? {
    guard shouldIntercept(request: request) else {
      return nil
    }

    let timestamp = currentTimestamp()
    let requestID = "native_http_\(UUID().uuidString)"
    var entry: DebugNetworkEntry?
    let state = InAppDebuggerNativeHTTPState(
      id: requestID,
      origin: "native",
      method: request.httpMethod?.uppercased() ?? "GET",
      url: request.url?.absoluteString ?? "",
      startedAt: timestamp,
      requestHeaders: request.allHTTPHeaderFields ?? [:],
      requestBody: requestBodyPreview(for: request)
    )

    lock.withLock {
      activeHTTPRequests[requestID] = state
      entry = preparedHTTPEntryLocked(state, timestamp: timestamp, policy: .visibleImmediate)
    }
    if let entry {
      InAppDebuggerStore.shared.upsertNetworkEntry(entry)
    }
    return requestID
  }

  fileprivate func httpRequest(_ requestID: String, didReceive response: URLResponse) {
    var entry: DebugNetworkEntry?

    lock.withLock {
      guard let state = activeHTTPRequests[requestID] else {
        return
      }
      state.updatedAt = currentTimestamp()
      if let httpResponse = response as? HTTPURLResponse {
        state.status = httpResponse.statusCode
        state.responseHeaders = headerDictionary(from: httpResponse.allHeaderFields)
        state.responseContentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType
      } else {
        state.responseContentType = response.mimeType
      }
      state.responseType = normalizedResponseType(for: response)
      state.url = response.url?.absoluteString ?? state.url
      entry = preparedHTTPEntryLocked(state, timestamp: state.updatedAt, policy: .visibleThrottled)
    }

    if let entry {
      InAppDebuggerStore.shared.upsertNetworkEntry(entry)
    }
  }

  fileprivate func httpRequest(_ requestID: String, didReceive data: Data) {
    var entry: DebugNetworkEntry?

    lock.withLock {
      guard let state = activeHTTPRequests[requestID] else {
        return
      }
      state.updatedAt = currentTimestamp()
      state.responseBytesReceived += data.count
      let combinedData = appendPreviewData(
        existing: state.responsePreviewData,
        incoming: data,
        contentType: state.responseContentType
      )
      state.responsePreviewData = combinedData.previewData
      state.responseBody = combinedData.previewText
      state.responseSize = state.responseBytesReceived
      entry = preparedHTTPEntryLocked(state, timestamp: state.updatedAt, policy: .visibleThrottled)
    }

    if let entry {
      InAppDebuggerStore.shared.upsertNetworkEntry(entry)
    }
  }

  fileprivate func httpRequest(_ requestID: String, didRedirectTo request: URLRequest) {
    var entry: DebugNetworkEntry?

    lock.withLock {
      guard let state = activeHTTPRequests[requestID] else {
        return
      }
      state.updatedAt = currentTimestamp()
      state.url = request.url?.absoluteString ?? state.url
      entry = preparedHTTPEntryLocked(state, timestamp: state.updatedAt, policy: .visibleThrottled)
    }

    if let entry {
      InAppDebuggerStore.shared.upsertNetworkEntry(entry)
    }
  }

  fileprivate func finishHTTPRequest(_ requestID: String, error: Error?) {
    var entry: DebugNetworkEntry?

    lock.withLock {
      guard let state = activeHTTPRequests.removeValue(forKey: requestID) else {
        return
      }
      let endedAt = currentTimestamp()
      state.updatedAt = endedAt
      state.endedAt = endedAt
      state.durationMs = max(0, endedAt - state.startedAt)
      if let error {
        state.state = "error"
        state.error = (error as NSError).localizedDescription
      } else {
        state.state = (state.status ?? 0) >= 400 ? "error" : "success"
      }
      entry = preparedHTTPEntryLocked(state, timestamp: endedAt, policy: .always)
    }

    if let entry {
      InAppDebuggerStore.shared.upsertNetworkEntry(entry)
    }
  }

  fileprivate func registerNativeWebSocketTask(
    _ task: URLSessionWebSocketTask,
    request: URLRequest,
    requestedProtocols: [String]?
  ) {
    guard lock.withLock({ enabled }) else {
      return
    }

    let timestamp = currentTimestamp()
    let objectKey = objectKey(for: task)
    let method = webSocketMethod(for: request.url?.absoluteString ?? "")
    let url = request.url?.absoluteString ?? ""
    let requestHeaders = request.allHTTPHeaderFields ?? [:]
    let protocolsDescription = requestedProtocols?.joined(separator: ", ").nilIfEmpty
    var entry: DebugNetworkEntry?

    lock.withLock {
      if let state = activeNativeWebSockets[objectKey] {
        state.method = method
        state.url = url
        if !requestHeaders.isEmpty {
          state.requestHeaders = requestHeaders
        }
        if let protocolsDescription {
          state.requestedProtocols = protocolsDescription
        }
        entry = preparedNativeWebSocketEntryLocked(state, timestamp: timestamp, policy: .visibleImmediate)
        return
      }

      let state = InAppDebuggerNativeURLSessionWebSocketState(
        objectKey: objectKey,
        method: method,
        url: url,
        startedAt: timestamp,
        requestHeaders: requestHeaders,
        requestedProtocols: protocolsDescription
      )
      activeNativeWebSockets[objectKey] = state
      entry = preparedNativeWebSocketEntryLocked(state, timestamp: timestamp, policy: .visibleImmediate)
    }

    if let entry {
      InAppDebuggerStore.shared.upsertNetworkEntry(entry)
    }
  }

  fileprivate func nativeWebSocketDidResume(_ task: URLSessionWebSocketTask) {
    mutateNativeWebSocket(task, policy: .visibleImmediate) { state in
      state.state = "connecting"
      state.error = nil
      state.closeReason = nil
      state.closeCode = nil
      state.cleanClose = nil
      state.requestedCloseCode = nil
      state.requestedCloseReason = nil
      appendEvent("connect", to: state)
    }
  }

  fileprivate func nativeWebSocketDidSend(_ task: URLSessionWebSocketTask, message: AnyObject) {
    mutateNativeWebSocket(task, policy: .visibleThrottled) { state in
      hydrateNativeWebSocketHandshake(for: task, state: state)
      openNativeWebSocketIfNeeded(state)
      let payload = describeWebSocketMessage(message)
      state.messageCountOut += 1
      state.bytesOut += payload.byteCount
      appendMessage(direction: ">>", payload: payload, to: state)
    }
  }

  fileprivate func nativeWebSocketDidReceive(_ task: URLSessionWebSocketTask, message: AnyObject?) {
    guard let message else {
      return
    }
    mutateNativeWebSocket(task, policy: .visibleThrottled) { state in
      hydrateNativeWebSocketHandshake(for: task, state: state)
      openNativeWebSocketIfNeeded(state)
      let payload = describeWebSocketMessage(message)
      state.messageCountIn += 1
      state.bytesIn += payload.byteCount
      appendMessage(direction: "<<", payload: payload, to: state)
    }
  }

  fileprivate func nativeWebSocketDidFail(_ task: URLSessionWebSocketTask, error: NSError) {
    finishNativeWebSocket(task, policy: .always) { state in
      state.state = "error"
      state.error = error.localizedDescription.nilIfEmpty ?? "WebSocket error"
      appendEvent("error \(state.error ?? "WebSocket error")", to: state)
    }
  }

  fileprivate func nativeWebSocketDidPing(_ task: URLSessionWebSocketTask, error: NSError?) {
    if let error {
      nativeWebSocketDidFail(task, error: error)
      return
    }
    mutateNativeWebSocket(task, policy: .visibleThrottled) { state in
      hydrateNativeWebSocketHandshake(for: task, state: state)
      appendEvent("ping", to: state)
    }
  }

  fileprivate func nativeWebSocketDidCancel(
    _ task: URLSessionWebSocketTask,
    closeCode: Int,
    reasonData: Data?
  ) {
    finishNativeWebSocket(task, policy: .always) { state in
      state.state = "closed"
      state.closeCode = closeCode
      state.cleanClose = true
      if let reasonData, !reasonData.isEmpty {
        state.closeReason = decodeTextPreview(from: reasonData, contentType: "text/plain")
      }
      state.requestedCloseCode = closeCode
      state.requestedCloseReason = state.closeReason
      appendEvent(
        "close requested code=\(closeCode)\(state.closeReason?.nilIfEmpty.map { " reason=\(sanitizeInlineText($0))" } ?? "")",
        to: state
      )
    }
  }

  private func mutateNativeWebSocket(
    _ task: URLSessionWebSocketTask,
    policy: StoreEmissionPolicy,
    mutation: (InAppDebuggerNativeURLSessionWebSocketState) -> Void
  ) {
    var entry: DebugNetworkEntry?

    lock.withLock {
      let objectKey = objectKey(for: task)
      guard let state = activeNativeWebSockets[objectKey] else {
        return
      }
      state.updatedAt = currentTimestamp()
      mutation(state)
      entry = preparedNativeWebSocketEntryLocked(state, timestamp: state.updatedAt, policy: policy)
    }

    if let entry {
      InAppDebuggerStore.shared.upsertNetworkEntry(entry)
    }
  }

  private func finishNativeWebSocket(
    _ task: URLSessionWebSocketTask,
    policy: StoreEmissionPolicy,
    mutation: (InAppDebuggerNativeURLSessionWebSocketState) -> Void
  ) {
    var entry: DebugNetworkEntry?

    lock.withLock {
      let objectKey = objectKey(for: task)
      guard let state = activeNativeWebSockets.removeValue(forKey: objectKey) else {
        return
      }
      let endedAt = currentTimestamp()
      hydrateNativeWebSocketHandshake(for: task, state: state)
      state.updatedAt = endedAt
      state.endedAt = endedAt
      state.durationMs = max(0, endedAt - state.startedAt)
      mutation(state)
      entry = preparedNativeWebSocketEntryLocked(state, timestamp: endedAt, policy: policy)
    }

    if let entry {
      InAppDebuggerStore.shared.upsertNetworkEntry(entry)
    }
  }

  private func preparedHTTPEntryLocked(
    _ state: InAppDebuggerNativeHTTPState,
    timestamp: Int,
    policy: StoreEmissionPolicy
  ) -> DebugNetworkEntry? {
    guard shouldEmitToStore(
      lastEmissionAt: state.lastStoreEmissionAt,
      timestamp: timestamp,
      policy: policy
    ) else {
      return nil
    }
    state.lastStoreEmissionAt = timestamp
    return state.asEntry()
  }

  private func preparedNativeWebSocketEntryLocked(
    _ state: InAppDebuggerNativeURLSessionWebSocketState,
    timestamp: Int,
    policy: StoreEmissionPolicy
  ) -> DebugNetworkEntry? {
    guard shouldEmitToStore(
      lastEmissionAt: state.lastStoreEmissionAt,
      timestamp: timestamp,
      policy: policy
    ) else {
      return nil
    }
    state.lastStoreEmissionAt = timestamp
    return state.asEntry()
  }

  private func shouldEmitToStore(
    lastEmissionAt: Int,
    timestamp: Int,
    policy: StoreEmissionPolicy
  ) -> Bool {
    switch policy {
    case .always:
      return true
    case .visibleImmediate:
      return panelActive
    case .visibleThrottled:
      return panelActive && (timestamp - lastEmissionAt >= liveUpdateThrottleMs)
    }
  }

  private func openNativeWebSocketIfNeeded(_ state: InAppDebuggerNativeURLSessionWebSocketState) {
    guard state.state == "pending" || state.state == "connecting" else {
      return
    }
    state.state = "open"
    if let `protocol` = state.protocol?.nilIfEmpty {
      appendEvent("open protocol=\(`protocol`)", to: state)
    } else {
      appendEvent("open", to: state)
    }
  }

  private func hydrateNativeWebSocketHandshake(
    for task: URLSessionWebSocketTask,
    state: InAppDebuggerNativeURLSessionWebSocketState
  ) {
    guard let response = task.response as? HTTPURLResponse else {
      return
    }
    state.status = response.statusCode
    state.responseHeaders = headerDictionary(from: response.allHeaderFields)
    state.protocol = response.value(forHTTPHeaderField: "Sec-WebSocket-Protocol")?.nilIfEmpty
    state.url = response.url?.absoluteString ?? state.url
  }

  private func appendEvent(_ text: String, to state: InAppDebuggerNativeURLSessionWebSocketState) {
    state.eventsList.append("\(formatClock(currentTimestamp())) \(text)")
    if state.eventsList.count > 120 {
      state.eventsList.removeFirst(state.eventsList.count - 120)
    }
  }

  private func appendMessage(
    direction: String,
    payload: (kind: String, body: String?, byteCount: Int),
    to state: InAppDebuggerNativeURLSessionWebSocketState
  ) {
    var lines = ["[\(formatClock(currentTimestamp()))] \(direction) \(payload.kind.uppercased())", formatByteCount(payload.byteCount)]
    if let body = payload.body?.nilIfEmpty {
      lines.append(body)
    }
    state.messagesList.append(lines.joined(separator: "\n"))
    if state.messagesList.count > 100 {
      state.messagesList.removeFirst(state.messagesList.count - 100)
    }
  }

  private func currentTimestamp() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
  }

  private func formatClock(_ timestamp: Int) -> String {
    InAppDebuggerNativeNetworkFormatters.clock.string(
      from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    )
  }

  private func formatByteCount(_ count: Int) -> String {
    InAppDebuggerNativeNetworkFormatters.byteCount.string(fromByteCount: Int64(max(0, count)))
  }

  private func requestOrigin(for request: URLRequest) -> String? {
    URLProtocol.property(forKey: inAppDebuggerNativeRequestOriginKey, in: request) as? String
  }

  private func requestBodyPreview(for request: URLRequest) -> String? {
    if let body = request.httpBody, !body.isEmpty {
      return decodeTextPreview(from: body, contentType: request.value(forHTTPHeaderField: "Content-Type"))
    }
    if request.httpBodyStream != nil {
      return "[streamed body]"
    }
    return nil
  }

  private func appendPreviewData(
    existing: Data,
    incoming: Data,
    contentType: String?
  ) -> (previewData: Data, previewText: String?) {
    let previewLimit = 32_000
    let remainingCapacity = max(previewLimit - existing.count, 0)
    var appendedData = existing
    if remainingCapacity > 0 {
      appendedData.append(incoming.prefix(remainingCapacity))
    }
    let previewText = decodeTextPreview(from: appendedData, contentType: contentType)
    return (appendedData, previewText)
  }

  private func normalizedResponseType(for response: URLResponse) -> String? {
    let mimeType = response.mimeType?.lowercased() ?? ""
    if mimeType.contains("json") {
      return "json"
    }
    if mimeType.hasPrefix("text/") {
      return "text"
    }
    if mimeType.hasPrefix("image/") || mimeType.hasPrefix("audio/") || mimeType.hasPrefix("video/") {
      return "binary"
    }
    return mimeType.nilIfEmpty
  }

  private func decodeTextPreview(from data: Data, contentType: String?) -> String? {
    guard !data.isEmpty else {
      return nil
    }

    let lowercaseContentType = contentType?.lowercased() ?? ""
    if lowercaseContentType.hasPrefix("image/") ||
      lowercaseContentType.hasPrefix("audio/") ||
      lowercaseContentType.hasPrefix("video/") ||
      lowercaseContentType.contains("application/octet-stream") {
      return binaryPreview(for: data)
    }

    if let text = String(data: data, encoding: .utf8) {
      return truncatedTextPreview(text)
    }
    if let text = String(data: data, encoding: .utf16) {
      return truncatedTextPreview(text)
    }
    if let text = String(data: data, encoding: .isoLatin1) {
      return truncatedTextPreview(text)
    }
    return binaryPreview(for: data)
  }

  private func binaryPreview(for data: Data) -> String {
    let previewBytes = data.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ")
    return data.count > 48 ? "\(previewBytes) ..." : previewBytes
  }

  private func truncatedTextPreview(_ text: String, limit: Int = 32_000) -> String {
    let normalized = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    guard normalized.count > limit else {
      return normalized
    }
    let endIndex = normalized.index(normalized.startIndex, offsetBy: limit)
    return String(normalized[..<endIndex]) + "\n...[truncated]"
  }

  private func headerDictionary(from rawHeaders: [AnyHashable: Any]) -> [String: String] {
    rawHeaders.reduce(into: [:]) { partialResult, item in
      partialResult[String(describing: item.key)] = item.value as? String ?? String(describing: item.value)
    }
  }

  private func webSocketMethod(for url: String) -> String {
    guard let scheme = URL(string: url)?.scheme?.lowercased() else {
      return "WS"
    }
    return scheme == "wss" ? "WSS" : "WS"
  }

  private func objectKey(for object: AnyObject) -> String {
    String(UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque()))
  }

  private func describeWebSocketMessage(_ message: AnyObject) -> (kind: String, body: String?, byteCount: Int) {
    if message.responds(to: NSSelectorFromString("string")),
       let text = message.perform(NSSelectorFromString("string"))?.takeUnretainedValue() as? NSString {
      let value = text as String
      return ("text", truncatedTextPreview(value), value.lengthOfBytes(using: .utf8))
    }

    if message.responds(to: NSSelectorFromString("data")),
       let data = message.perform(NSSelectorFromString("data"))?.takeUnretainedValue() as? NSData {
      let value = data as Data
      return ("binary", binaryPreview(for: value), value.count)
    }

    let fallback = String(describing: message)
    return ("unknown", truncatedTextPreview(fallback), fallback.lengthOfBytes(using: .utf8))
  }

  private func sanitizeInlineText(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\r\n", with: "\\n")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
  }
}

private enum InAppDebuggerNativeNetworkHookInstaller {
  private static let lock = NSLock()
  private static var didInstall = false
  private static var swizzledURLSessionConfigurationClasses: Set<String> = []

  private typealias ProtocolClassesIMP = @convention(c) (AnyObject, Selector) -> NSArray?
  private typealias RCTHTTPRequestSendRequestIMP = @convention(c) (AnyObject, Selector, NSURLRequest, AnyObject) -> AnyObject?
  private typealias URLSessionWebSocketTaskWithURLIMP = @convention(c) (AnyObject, Selector, NSURL) -> URLSessionWebSocketTask
  private typealias URLSessionWebSocketTaskWithURLProtocolsIMP = @convention(c) (
    AnyObject,
    Selector,
    NSURL,
    NSArray?
  ) -> URLSessionWebSocketTask
  private typealias URLSessionWebSocketTaskWithRequestIMP = @convention(c) (
    AnyObject,
    Selector,
    NSURLRequest
  ) -> URLSessionWebSocketTask
  private typealias ResumeIMP = @convention(c) (AnyObject, Selector) -> Void
  private typealias CancelWithCloseCodeIMP = @convention(c) (AnyObject, Selector, Int, NSData?) -> Void
  private typealias SendMessageCompletion = @convention(block) (NSError?) -> Void
  private typealias ReceiveMessageCompletion = @convention(block) (AnyObject?, NSError?) -> Void
  private typealias SendMessageIMP = @convention(c) (AnyObject, Selector, AnyObject, SendMessageCompletion?) -> Void
  private typealias ReceiveMessageIMP = @convention(c) (AnyObject, Selector, @escaping ReceiveMessageCompletion) -> Void
  private typealias SendPingIMP = @convention(c) (AnyObject, Selector, SendMessageCompletion?) -> Void

  static func installIfNeeded() {
    lock.lock()
    defer { lock.unlock() }
    guard !didInstall else {
      return
    }

    installURLProtocolRegistration()
    installURLSessionConfigurationHooks()
    installRCTHTTPRequestHandlerHook()
    installURLSessionWebSocketHooks()
    didInstall = true
  }

  private static func installURLProtocolRegistration() {
    URLProtocol.registerClass(InAppDebuggerNativeHTTPURLProtocol.self)
  }

  private static func installURLSessionConfigurationHooks() {
    let configurations: [URLSessionConfiguration] = {
      var values: [URLSessionConfiguration] = [
        URLSessionConfiguration.default,
        URLSessionConfiguration.ephemeral,
      ]
      if #available(iOS 13.0, *) {
        values.append(
          URLSessionConfiguration.background(
            withIdentifier: "expo.inappdebugger.capture.\(UUID().uuidString)"
          )
        )
      }
      return values
    }()

    configurations.forEach(installProtocolClassesHookIfNeeded)
  }

  private static func installProtocolClassesHookIfNeeded(for configuration: URLSessionConfiguration) {
    guard let configurationClass = object_getClass(configuration) else {
      return
    }

    let className = NSStringFromClass(configurationClass)
    guard !swizzledURLSessionConfigurationClasses.contains(className) else {
      return
    }

    let selector = #selector(getter: URLSessionConfiguration.protocolClasses)
    guard let method = class_getInstanceMethod(configurationClass, selector) else {
      return
    }

    let original = unsafeBitCast(method_getImplementation(method), to: ProtocolClassesIMP.self)
    let block: @convention(block) (AnyObject) -> NSArray? = { receiver in
      let existing = original(receiver, selector) as? [AnyClass] ?? []
      if existing.contains(where: { $0 == InAppDebuggerNativeHTTPURLProtocol.self }) {
        return existing as NSArray
      }
      return ([InAppDebuggerNativeHTTPURLProtocol.self] + existing) as NSArray
    }

    method_setImplementation(method, imp_implementationWithBlock(block))
    swizzledURLSessionConfigurationClasses.insert(className)
  }

  private static func installRCTHTTPRequestHandlerHook() {
    guard let requestHandlerClass = NSClassFromString("RCTHTTPRequestHandler") else {
      return
    }

    let selector = NSSelectorFromString("sendRequest:withDelegate:")
    guard let method = class_getInstanceMethod(requestHandlerClass, selector) else {
      return
    }

    let original = unsafeBitCast(method_getImplementation(method), to: RCTHTTPRequestSendRequestIMP.self)
    let block: @convention(block) (AnyObject, NSURLRequest, AnyObject) -> AnyObject? = { receiver, request, delegate in
      let mutableRequest = (request.mutableCopy() as? NSMutableURLRequest) ?? NSMutableURLRequest(url: request.url ?? URL(string: "about:blank")!)
      URLProtocol.setProperty(inAppDebuggerNativeJSOriginValue, forKey: inAppDebuggerNativeRequestOriginKey, in: mutableRequest)
      return original(receiver, selector, mutableRequest, delegate)
    }

    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func installURLSessionWebSocketHooks() {
    installURLSessionTaskCreationHook(
      selectorName: "webSocketTaskWithURL:",
      installer: { method, selector in
        let original = unsafeBitCast(method_getImplementation(method), to: URLSessionWebSocketTaskWithURLIMP.self)
        let block: @convention(block) (AnyObject, NSURL) -> URLSessionWebSocketTask = { receiver, url in
          let task = original(receiver, selector, url)
          let request = URLRequest(url: url as URL)
          InAppDebuggerNativeNetworkCapture.shared.registerNativeWebSocketTask(task, request: request, requestedProtocols: nil)
          return task
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
      }
    )

    installURLSessionTaskCreationHook(
      selectorName: "webSocketTaskWithURL:protocols:",
      installer: { method, selector in
        let original = unsafeBitCast(method_getImplementation(method), to: URLSessionWebSocketTaskWithURLProtocolsIMP.self)
        let block: @convention(block) (AnyObject, NSURL, NSArray?) -> URLSessionWebSocketTask = { receiver, url, protocols in
          let task = original(receiver, selector, url, protocols)
          let request = URLRequest(url: url as URL)
          InAppDebuggerNativeNetworkCapture.shared.registerNativeWebSocketTask(
            task,
            request: request,
            requestedProtocols: protocols as? [String]
          )
          return task
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
      }
    )

    installURLSessionTaskCreationHook(
      selectorName: "webSocketTaskWithRequest:",
      installer: { method, selector in
        let original = unsafeBitCast(method_getImplementation(method), to: URLSessionWebSocketTaskWithRequestIMP.self)
        let block: @convention(block) (AnyObject, NSURLRequest) -> URLSessionWebSocketTask = { receiver, request in
          let task = original(receiver, selector, request)
          InAppDebuggerNativeNetworkCapture.shared.registerNativeWebSocketTask(task, request: request as URLRequest, requestedProtocols: nil)
          return task
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
      }
    )

    let webSocketTaskClass: AnyClass = URLSessionWebSocketTask.self

    installSimpleHook(on: webSocketTaskClass, selectorName: "resume") { method, selector in
      let original = unsafeBitCast(method_getImplementation(method), to: ResumeIMP.self)
      let block: @convention(block) (AnyObject) -> Void = { receiver in
        if let task = receiver as? URLSessionWebSocketTask {
          InAppDebuggerNativeNetworkCapture.shared.nativeWebSocketDidResume(task)
        }
        original(receiver, selector)
      }
      method_setImplementation(method, imp_implementationWithBlock(block))
    }

    installSimpleHook(on: webSocketTaskClass, selectorName: "cancelWithCloseCode:reason:") { method, selector in
      let original = unsafeBitCast(method_getImplementation(method), to: CancelWithCloseCodeIMP.self)
      let block: @convention(block) (AnyObject, Int, NSData?) -> Void = { receiver, closeCode, reason in
        if let task = receiver as? URLSessionWebSocketTask {
          InAppDebuggerNativeNetworkCapture.shared.nativeWebSocketDidCancel(task, closeCode: closeCode, reasonData: reason as Data?)
        }
        original(receiver, selector, closeCode, reason)
      }
      method_setImplementation(method, imp_implementationWithBlock(block))
    }

    installSimpleHook(on: webSocketTaskClass, selectorName: "sendMessage:completionHandler:") { method, selector in
      let original = unsafeBitCast(method_getImplementation(method), to: SendMessageIMP.self)
      let block: @convention(block) (AnyObject, AnyObject, SendMessageCompletion?) -> Void = { receiver, message, completion in
        let wrapped: SendMessageCompletion = { error in
          if let task = receiver as? URLSessionWebSocketTask {
            if let error {
              InAppDebuggerNativeNetworkCapture.shared.nativeWebSocketDidFail(task, error: error)
            } else {
              InAppDebuggerNativeNetworkCapture.shared.nativeWebSocketDidSend(task, message: message)
            }
          }
          completion?(error)
        }
        original(receiver, selector, message, wrapped)
      }
      method_setImplementation(method, imp_implementationWithBlock(block))
    }

    installSimpleHook(on: webSocketTaskClass, selectorName: "receiveMessageWithCompletionHandler:") { method, selector in
      let original = unsafeBitCast(method_getImplementation(method), to: ReceiveMessageIMP.self)
      let block: @convention(block) (AnyObject, @escaping ReceiveMessageCompletion) -> Void = { receiver, completion in
        let wrapped: ReceiveMessageCompletion = { message, error in
          if let task = receiver as? URLSessionWebSocketTask {
            if let error {
              InAppDebuggerNativeNetworkCapture.shared.nativeWebSocketDidFail(task, error: error)
            } else {
              InAppDebuggerNativeNetworkCapture.shared.nativeWebSocketDidReceive(task, message: message)
            }
          }
          completion(message, error)
        }
        original(receiver, selector, wrapped)
      }
      method_setImplementation(method, imp_implementationWithBlock(block))
    }

    installSimpleHook(on: webSocketTaskClass, selectorName: "sendPingWithPongReceiveHandler:") { method, selector in
      let original = unsafeBitCast(method_getImplementation(method), to: SendPingIMP.self)
      let block: @convention(block) (AnyObject, SendMessageCompletion?) -> Void = { receiver, completion in
        let wrapped: SendMessageCompletion = { error in
          if let task = receiver as? URLSessionWebSocketTask {
            InAppDebuggerNativeNetworkCapture.shared.nativeWebSocketDidPing(task, error: error)
          }
          completion?(error)
        }
        original(receiver, selector, wrapped)
      }
      method_setImplementation(method, imp_implementationWithBlock(block))
    }
  }

  private static func installURLSessionTaskCreationHook(
    selectorName: String,
    installer: (Method, Selector) -> Void
  ) {
    let selector = NSSelectorFromString(selectorName)
    guard let method = class_getInstanceMethod(URLSession.self, selector) else {
      return
    }
    installer(method, selector)
  }

  private static func installSimpleHook(
    on cls: AnyClass,
    selectorName: String,
    installer: (Method, Selector) -> Void
  ) {
    let selector = NSSelectorFromString(selectorName)
    guard let method = class_getInstanceMethod(cls, selector) else {
      return
    }
    installer(method, selector)
  }
}

private enum InAppDebuggerNativeNetworkFormatters {
  static let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()

  static let byteCount: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter
  }()
}

private extension NSLock {
  func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}

private extension String {
  var nilIfEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
