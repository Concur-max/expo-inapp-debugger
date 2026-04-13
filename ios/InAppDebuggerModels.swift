import Foundation

struct DebugConfig: Equatable {
  var enabled: Bool = false
  var initialVisible: Bool = true
  var enableNetworkTab: Bool = true
  var maxLogs: Int = 2000
  var maxErrors: Int = 100
  var maxRequests: Int = 100
}

struct DebugLogEntry: Equatable {
  let id: String
  let type: String
  let origin: String
  let context: String?
  let details: String?
  let message: String
  let timestamp: String
  let fullTimestamp: String
  let timelineTimestampMillis: Int?
  let timelineSequence: Int?

  init?(map: [String: Any]) {
    guard let id = map.string("id") else {
      return nil
    }
    self.id = id
    self.type = map.string("type") ?? "log"
    self.origin = map.string("origin") ?? "js"
    self.context = map.string("context")
    self.details = map.string("details")
    self.message = map.string("message") ?? ""
    self.timestamp = map.string("timestamp") ?? ""
    self.fullTimestamp = map.string("fullTimestamp") ?? ""
    self.timelineTimestampMillis =
      map.int("timelineTimestampMillis") ?? resolveTimelineTimestampMillis(from: self.fullTimestamp)
    self.timelineSequence = map.int("timelineSequence") ?? resolveTimelineSequence(from: id)
  }

  init?(wire: [Any]) {
    guard let id = wire.string(at: 0) else {
      return nil
    }
    self.id = id
    self.type = wire.string(at: 1) ?? "log"
    self.origin = wire.string(at: 2) ?? "js"
    self.context = wire.string(at: 3)
    self.details = wire.string(at: 4)
    self.message = wire.string(at: 5) ?? ""
    self.timestamp = wire.string(at: 6) ?? ""
    self.fullTimestamp = wire.string(at: 7) ?? ""
    self.timelineTimestampMillis =
      wire.int(at: 8) ?? resolveTimelineTimestampMillis(from: self.fullTimestamp)
    self.timelineSequence = wire.int(at: 9) ?? resolveTimelineSequence(from: id)
  }

  init(
    id: String,
    type: String,
    origin: String,
    context: String?,
    details: String?,
    message: String,
    timestamp: String,
    fullTimestamp: String,
    timelineTimestampMillis: Int? = nil,
    timelineSequence: Int? = nil
  ) {
    self.id = id
    self.type = type
    self.origin = origin
    self.context = context
    self.details = details
    self.message = message
    self.timestamp = timestamp
    self.fullTimestamp = fullTimestamp
    self.timelineTimestampMillis =
      timelineTimestampMillis ?? resolveTimelineTimestampMillis(from: fullTimestamp)
    self.timelineSequence = timelineSequence ?? resolveTimelineSequence(from: id)
  }

  func asDictionary() -> [String: Any] {
    [
      "id": id,
      "type": type,
      "origin": origin,
      "context": context as Any,
      "details": details as Any,
      "message": message,
      "timestamp": timestamp,
      "fullTimestamp": fullTimestamp,
      "timelineTimestampMillis": timelineTimestampMillis as Any,
      "timelineSequence": timelineSequence as Any,
    ]
  }
}

struct DebugErrorEntry: Equatable {
  let id: String
  let source: String
  let message: String
  let timestamp: String
  let fullTimestamp: String
  let timelineTimestampMillis: Int?
  let timelineSequence: Int?

  init?(map: [String: Any]) {
    guard let id = map.string("id") else {
      return nil
    }
    self.id = id
    self.source = map.string("source") ?? "console"
    self.message = map.string("message") ?? ""
    self.timestamp = map.string("timestamp") ?? ""
    self.fullTimestamp = map.string("fullTimestamp") ?? ""
    self.timelineTimestampMillis =
      map.int("timelineTimestampMillis") ?? resolveTimelineTimestampMillis(from: self.fullTimestamp)
    self.timelineSequence = map.int("timelineSequence") ?? resolveTimelineSequence(from: id)
  }

  init?(wire: [Any]) {
    guard let id = wire.string(at: 0) else {
      return nil
    }
    self.id = id
    self.source = wire.string(at: 1) ?? "console"
    self.message = wire.string(at: 2) ?? ""
    self.timestamp = wire.string(at: 3) ?? ""
    self.fullTimestamp = wire.string(at: 4) ?? ""
    self.timelineTimestampMillis =
      wire.int(at: 5) ?? resolveTimelineTimestampMillis(from: self.fullTimestamp)
    self.timelineSequence = wire.int(at: 6) ?? resolveTimelineSequence(from: id)
  }

  init(
    id: String,
    source: String,
    message: String,
    timestamp: String,
    fullTimestamp: String,
    timelineTimestampMillis: Int? = nil,
    timelineSequence: Int? = nil
  ) {
    self.id = id
    self.source = source
    self.message = message
    self.timestamp = timestamp
    self.fullTimestamp = fullTimestamp
    self.timelineTimestampMillis =
      timelineTimestampMillis ?? resolveTimelineTimestampMillis(from: fullTimestamp)
    self.timelineSequence = timelineSequence ?? resolveTimelineSequence(from: id)
  }

  func asDictionary() -> [String: Any] {
    [
      "id": id,
      "source": source,
      "message": message,
      "timestamp": timestamp,
      "fullTimestamp": fullTimestamp,
      "timelineTimestampMillis": timelineTimestampMillis as Any,
      "timelineSequence": timelineSequence as Any,
    ]
  }
}

struct DebugNetworkEntry: Equatable {
  let id: String
  let kind: String
  let method: String
  let url: String
  let origin: String
  let state: String
  let startedAt: Int
  let updatedAt: Int
  let endedAt: Int?
  let durationMs: Int?
  let status: Int?
  let requestHeaders: [String: String]
  let responseHeaders: [String: String]
  let requestBody: String?
  let responseBody: String?
  let responseType: String?
  let responseContentType: String?
  let responseSize: Int?
  let error: String?
  let `protocol`: String?
  let requestedProtocols: String?
  let closeReason: String?
  let closeCode: Int?
  let requestedCloseCode: Int?
  let requestedCloseReason: String?
  let cleanClose: Bool?
  let messageCountIn: Int?
  let messageCountOut: Int?
  let bytesIn: Int?
  let bytesOut: Int?
  let events: String?
  let messages: String?
  let timelineSequence: Int?

  init(
    id: String,
    kind: String,
    method: String,
    url: String,
    origin: String = "js",
    state: String,
    startedAt: Int,
    updatedAt: Int,
    endedAt: Int? = nil,
    durationMs: Int? = nil,
    status: Int? = nil,
    requestHeaders: [String: String] = [:],
    responseHeaders: [String: String] = [:],
    requestBody: String? = nil,
    responseBody: String? = nil,
    responseType: String? = nil,
    responseContentType: String? = nil,
    responseSize: Int? = nil,
    error: String? = nil,
    protocol: String? = nil,
    requestedProtocols: String? = nil,
    closeReason: String? = nil,
    closeCode: Int? = nil,
    requestedCloseCode: Int? = nil,
    requestedCloseReason: String? = nil,
    cleanClose: Bool? = nil,
    messageCountIn: Int? = nil,
    messageCountOut: Int? = nil,
    bytesIn: Int? = nil,
    bytesOut: Int? = nil,
    events: String? = nil,
    messages: String? = nil,
    timelineSequence: Int? = nil
  ) {
    self.id = id
    self.kind = kind
    self.method = method
    self.url = url
    self.origin = origin
    self.state = state
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.endedAt = endedAt
    self.durationMs = durationMs
    self.status = status
    self.requestHeaders = requestHeaders
    self.responseHeaders = responseHeaders
    self.requestBody = requestBody
    self.responseBody = responseBody
    self.responseType = responseType
    self.responseContentType = responseContentType
    self.responseSize = responseSize
    self.error = error
    self.protocol = `protocol`
    self.requestedProtocols = requestedProtocols
    self.closeReason = closeReason
    self.closeCode = closeCode
    self.requestedCloseCode = requestedCloseCode
    self.requestedCloseReason = requestedCloseReason
    self.cleanClose = cleanClose
    self.messageCountIn = messageCountIn
    self.messageCountOut = messageCountOut
    self.bytesIn = bytesIn
    self.bytesOut = bytesOut
    self.events = events
    self.messages = messages
    self.timelineSequence = timelineSequence ?? resolveTimelineSequence(from: id)
  }

  init?(map: [String: Any]) {
    guard let id = map.string("id") else {
      return nil
    }
    self.id = id
    self.kind = map.string("kind") ?? "http"
    self.method = map.string("method") ?? "GET"
    self.url = map.string("url") ?? ""
    self.origin = map.string("origin") ?? "js"
    self.state = map.string("state") ?? "pending"
    self.startedAt = map.int("startedAt") ?? 0
    self.updatedAt = map.int("updatedAt") ?? startedAt
    self.endedAt = map.int("endedAt")
    self.durationMs = map.int("durationMs")
    self.status = map.int("status")
    self.requestHeaders = map.stringDictionary("requestHeaders")
    self.responseHeaders = map.stringDictionary("responseHeaders")
    self.requestBody = map.string("requestBody")
    self.responseBody = map.string("responseBody")
    self.responseType = map.string("responseType")
    self.responseContentType = map.string("responseContentType")
    self.responseSize = map.int("responseSize")
    self.error = map.string("error")
    self.protocol = map.string("protocol")
    self.requestedProtocols = map.string("requestedProtocols")
    self.closeReason = map.string("closeReason")
    self.closeCode = map.int("closeCode")
    self.requestedCloseCode = map.int("requestedCloseCode")
    self.requestedCloseReason = map.string("requestedCloseReason")
    self.cleanClose = map.bool("cleanClose")
    self.messageCountIn = map.int("messageCountIn")
    self.messageCountOut = map.int("messageCountOut")
    self.bytesIn = map.int("bytesIn")
    self.bytesOut = map.int("bytesOut")
    self.events = map.string("events")
    self.messages = map.string("messages")
    self.timelineSequence = map.int("timelineSequence") ?? resolveTimelineSequence(from: id)
  }

  init?(wire: [Any]) {
    guard let id = wire.string(at: 0) else {
      return nil
    }
    let startedAt = wire.int(at: 6) ?? 0

    self.id = id
    self.kind = wire.string(at: 1) ?? "http"
    self.method = wire.string(at: 2) ?? "GET"
    self.url = wire.string(at: 3) ?? ""
    self.origin = wire.string(at: 4) ?? "js"
    self.state = wire.string(at: 5) ?? "pending"
    self.startedAt = startedAt
    self.updatedAt = wire.int(at: 7) ?? startedAt
    self.endedAt = wire.int(at: 8)
    self.durationMs = wire.int(at: 9)
    self.status = wire.int(at: 10)
    self.requestHeaders = wire.stringDictionary(at: 11)
    self.responseHeaders = wire.stringDictionary(at: 12)
    self.requestBody = wire.string(at: 13)
    self.responseBody = wire.string(at: 14)
    self.responseType = wire.string(at: 15)
    self.responseContentType = wire.string(at: 16)
    self.responseSize = wire.int(at: 17)
    self.error = wire.string(at: 18)
    self.protocol = wire.string(at: 19)
    self.requestedProtocols = wire.string(at: 20)
    self.closeReason = wire.string(at: 21)
    self.closeCode = wire.int(at: 22)
    self.requestedCloseCode = wire.int(at: 23)
    self.requestedCloseReason = wire.string(at: 24)
    self.cleanClose = wire.bool(at: 25)
    self.messageCountIn = wire.int(at: 26)
    self.messageCountOut = wire.int(at: 27)
    self.bytesIn = wire.int(at: 28)
    self.bytesOut = wire.int(at: 29)
    self.events = wire.string(at: 30)
    self.messages = wire.string(at: 31)
    self.timelineSequence = wire.int(at: 32) ?? resolveTimelineSequence(from: id)
  }

  func asDictionary() -> [String: Any] {
    [
      "id": id,
      "kind": kind,
      "method": method,
      "url": url,
      "origin": origin,
      "state": state,
      "startedAt": startedAt,
      "updatedAt": updatedAt,
      "endedAt": endedAt as Any,
      "durationMs": durationMs as Any,
      "status": status as Any,
      "requestHeaders": requestHeaders,
      "responseHeaders": responseHeaders,
      "requestBody": requestBody as Any,
      "responseBody": responseBody as Any,
      "responseType": responseType as Any,
      "responseContentType": responseContentType as Any,
      "responseSize": responseSize as Any,
      "error": error as Any,
      "protocol": `protocol` as Any,
      "requestedProtocols": requestedProtocols as Any,
      "closeReason": closeReason as Any,
      "closeCode": closeCode as Any,
      "requestedCloseCode": requestedCloseCode as Any,
      "requestedCloseReason": requestedCloseReason as Any,
      "cleanClose": cleanClose as Any,
      "messageCountIn": messageCountIn as Any,
      "messageCountOut": messageCountOut as Any,
      "bytesIn": bytesIn as Any,
      "bytesOut": bytesOut as Any,
      "events": events as Any,
      "messages": messages as Any,
      "timelineSequence": timelineSequence as Any,
    ]
  }
}

extension Dictionary where Key == String, Value == Any {
  func string(_ key: String) -> String? {
    self[key] as? String
  }

  func int(_ key: String) -> Int? {
    (self[key] as? NSNumber)?.intValue
  }

  func bool(_ key: String) -> Bool? {
    (self[key] as? NSNumber)?.boolValue
  }

  func stringDictionary(_ key: String) -> [String: String] {
    guard let raw = self[key] as? [String: Any] else {
      return [:]
    }
    return raw.reduce(into: [:]) { partialResult, item in
      partialResult[item.key] = item.value as? String ?? "\(item.value)"
    }
  }
}

private extension Array where Element == Any {
  func string(at index: Int) -> String? {
    wireString(value(at: index))
  }

  func int(at index: Int) -> Int? {
    wireInt(value(at: index))
  }

  func bool(at index: Int) -> Bool? {
    wireBool(value(at: index))
  }

  func stringDictionary(at index: Int) -> [String: String] {
    wireStringDictionary(value(at: index))
  }

  private func value(at index: Int) -> Any? {
    indices.contains(index) ? self[index] : nil
  }
}

private func wireString(_ value: Any?) -> String? {
  switch value {
  case nil, is NSNull:
    return nil
  case let value as String:
    return value
  default:
    return nil
  }
}

private func wireInt(_ value: Any?) -> Int? {
  switch value {
  case nil, is NSNull:
    return nil
  case let value as NSNumber:
    return value.intValue
  case let value as Int:
    return value
  case let value as Double:
    return Int(value)
  default:
    return nil
  }
}

private func wireBool(_ value: Any?) -> Bool? {
  switch value {
  case nil, is NSNull:
    return nil
  case let value as Bool:
    return value
  case let value as NSNumber:
    return value.boolValue
  default:
    return nil
  }
}

private func wireStringDictionary(_ value: Any?) -> [String: String] {
  switch value {
  case nil, is NSNull:
    return [:]
  case let value as [String: String]:
    return value
  case let value as [String: Any]:
    return value.reduce(into: [:]) { partialResult, item in
      guard !(item.value is NSNull) else {
        return
      }
      partialResult[item.key] = item.value as? String ?? "\(item.value)"
    }
  case let value as [Any]:
    var result: [String: String] = [:]
    var index = 0
    while index + 1 < value.count {
      if let key = wireString(value[index]) {
        let rawValue = value[index + 1]
        if !(rawValue is NSNull) {
          result[key] = rawValue as? String ?? "\(rawValue)"
        }
      }
      index += 2
    }
    return result
  default:
    return [:]
  }
}

private let debugTimelineISOFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

private func resolveTimelineTimestampMillis(from fullTimestamp: String) -> Int? {
  guard !fullTimestamp.isEmpty else {
    return nil
  }
  guard let date = debugTimelineISOFormatter.date(from: fullTimestamp) else {
    return nil
  }
  return Int(date.timeIntervalSince1970 * 1000)
}

private func resolveTimelineSequence(from id: String) -> Int? {
  guard let separatorIndex = id.lastIndex(of: "_") else {
    return nil
  }
  let suffix = id[id.index(after: separatorIndex)...]
  guard !suffix.isEmpty else {
    return nil
  }

  if suffix.allSatisfy(\.isNumber) {
    return Int(suffix)
  }

  var value = 0
  for character in suffix.lowercased() {
    guard let digit = character.wholeNumberValue ?? base36Digit(for: character) else {
      return nil
    }
    let multiplied = value.multipliedReportingOverflow(by: 36)
    guard !multiplied.overflow else {
      return nil
    }
    let added = multiplied.partialValue.addingReportingOverflow(digit)
    guard !added.overflow else {
      return nil
    }
    value = added.partialValue
  }
  return value
}

private func base36Digit(for character: Character) -> Int? {
  guard let ascii = character.asciiValue else {
    return nil
  }
  switch ascii {
  case 97...122:
    return Int(ascii - 87)
  default:
    return nil
  }
}
