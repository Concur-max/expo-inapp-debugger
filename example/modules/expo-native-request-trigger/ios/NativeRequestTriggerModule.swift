import ExpoModulesCore
import Foundation

private enum NativeRequestTriggerMethod: String {
  case get = "GET"
  case post = "POST"
}

private enum NativeRequestTriggerClient {
  static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    return URLSession(configuration: configuration)
  }()
}

public final class NativeRequestTriggerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("NativeRequestTrigger")

    AsyncFunction("sendHttpRequest") { (rawOptions: [String: Any]) in
      let urlString =
        (rawOptions["url"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !urlString.isEmpty, let url = URL(string: urlString) else {
        throw Exception(
          name: "ERR_NATIVE_REQUEST_TRIGGER_INVALID_URL",
          description: "NativeRequestTrigger.sendHttpRequest requires a valid url."
        )
      }

      let methodValue = ((rawOptions["method"] as? String) ?? NativeRequestTriggerMethod.get.rawValue)
        .uppercased()
      guard let method = NativeRequestTriggerMethod(rawValue: methodValue) else {
        throw Exception(
          name: "ERR_NATIVE_REQUEST_TRIGGER_UNSUPPORTED_METHOD",
          description: "NativeRequestTrigger only supports GET and POST, received \(methodValue)."
        )
      }

      let body = rawOptions["body"] as? String
      let userHeaders = rawOptions["headers"] as? [String: Any] ?? [:]
      var headers: [String: String] = [
        "Accept": "application/json",
        "X-Debug-Native-Plugin": "example-expo-module",
        "X-Debug-Native-Platform": "ios",
      ]
      userHeaders.forEach { key, value in
        headers[key] = String(describing: value)
      }

      var request = URLRequest(url: url, timeoutInterval: 20)
      request.httpMethod = method.rawValue

      if method == .post {
        request.httpBody = (body ?? "").data(using: .utf8)
        if headers.keys.first(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) == nil {
          headers["Content-Type"] = "application/json; charset=utf-8"
        }
      }

      headers.forEach { key, value in
        request.setValue(value, forHTTPHeaderField: key)
      }

      NativeRequestTriggerClient.session.dataTask(with: request) { data, response, error in
        if let error {
          NSLog("[NativeRequestTrigger] Native \(method.rawValue) failed for \(urlString): \(error.localizedDescription)")
          return
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        NSLog(
          "[NativeRequestTrigger] Native \(method.rawValue) completed for \(urlString) " +
            "status=\(statusCode) bytes=\(data?.count ?? 0)"
        )
      }.resume()
    }
  }
}
