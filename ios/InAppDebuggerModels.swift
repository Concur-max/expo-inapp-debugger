import Foundation

struct DebugConfig: Equatable {
  var enabled: Bool = false
  var initialVisible: Bool = true
  var enableNetworkTab: Bool = true
  var maxLogs: Int = 2000
  var maxErrors: Int = 100
  var maxRequests: Int = 100
  var locale: String = "zh-CN"
  var strings: [String: String] = [:]
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
  }

  init(
    id: String,
    type: String,
    origin: String,
    context: String?,
    details: String?,
    message: String,
    timestamp: String,
    fullTimestamp: String
  ) {
    self.id = id
    self.type = type
    self.origin = origin
    self.context = context
    self.details = details
    self.message = message
    self.timestamp = timestamp
    self.fullTimestamp = fullTimestamp
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
    ]
  }
}

struct DebugErrorEntry: Equatable {
  let id: String
  let source: String
  let message: String
  let timestamp: String
  let fullTimestamp: String

  init?(map: [String: Any]) {
    guard let id = map.string("id") else {
      return nil
    }
    self.id = id
    self.source = map.string("source") ?? "console"
    self.message = map.string("message") ?? ""
    self.timestamp = map.string("timestamp") ?? ""
    self.fullTimestamp = map.string("fullTimestamp") ?? ""
  }

  func asDictionary() -> [String: Any] {
    [
      "id": id,
      "source": source,
      "message": message,
      "timestamp": timestamp,
      "fullTimestamp": fullTimestamp,
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
    messages: String? = nil
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
