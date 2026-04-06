import Foundation

struct DebugConfig {
  var enabled: Bool = false
  var initialVisible: Bool = true
  var enableNetworkTab: Bool = true
  var maxLogs: Int = 2000
  var maxErrors: Int = 100
  var maxRequests: Int = 100
  var locale: String = "zh-CN"
  var strings: [String: String] = [:]
}

struct DebugLogEntry {
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

struct DebugErrorEntry {
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

struct DebugNetworkEntry {
  let id: String
  let kind: String
  let method: String
  let url: String
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
  let closeReason: String?
  let messages: String?

  init?(map: [String: Any]) {
    guard let id = map.string("id") else {
      return nil
    }
    self.id = id
    self.kind = map.string("kind") ?? "http"
    self.method = map.string("method") ?? "GET"
    self.url = map.string("url") ?? ""
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
    self.closeReason = map.string("closeReason")
    self.messages = map.string("messages")
  }

  func asDictionary() -> [String: Any] {
    [
      "id": id,
      "kind": kind,
      "method": method,
      "url": url,
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
      "closeReason": closeReason as Any,
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

  func stringDictionary(_ key: String) -> [String: String] {
    guard let raw = self[key] as? [String: Any] else {
      return [:]
    }
    return raw.reduce(into: [:]) { partialResult, item in
      partialResult[item.key] = item.value as? String ?? "\(item.value)"
    }
  }
}
