import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Retries only requests explicitly known to be safe to repeat.
public enum AppleNetworkTransport {
    @TaskLocal public static var authenticationUserAgent = "AuthKit/1 (Macintosh; OS X 26.6) (com.apple.dt.Xcode/26.0)"
    @TaskLocal public static var diagnosticHandler: (@Sendable (String) -> Void)?

    /// nil means the server requested a wait longer than an interactive sign-in allows.
    public static func retryDelay(for response: HTTPURLResponse, attempt: Int, now: Date = Date()) -> Double? {
        let fallback = pow(2, Double(attempt + 1))
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return fallback }
        let delay: Double
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            delay = seconds
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: value) else { return fallback }
            delay = max(0, date.timeIntervalSince(now))
        }
        return delay <= 30 ? max(fallback, delay) : nil
    }

    public static func data(for request: URLRequest, session: URLSession,
                            retryTransientFailure: Bool = false,
                            wait: @Sendable (Double) async throws -> Void = { seconds in
                                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                            }) async throws -> (Data, URLResponse) {
        var activeSession = session
        var retrySession: URLSession?
        defer { retrySession?.finishTasksAndInvalidate() }
        let endpoint = request.url.map { "\($0.host ?? "unknown")\($0.path)" } ?? "unknown"
        for attempt in 0...2 {
            try Task.checkCancellation()
            let delay: Double
            do {
                diagnosticHandler?("Request \(endpoint), attempt \(attempt + 1)")
                let result = try await activeSession.data(for: request)
                let http = result.1 as? HTTPURLResponse
                diagnosticHandler?("Response \(endpoint): HTTP \(http?.statusCode ?? 0), \(result.0.count) bytes")
                guard attempt < 2, retryTransientFailure, let http,
                      [502, 503, 504].contains(http.statusCode),
                      let retryDelay = retryDelay(for: http, attempt: attempt) else {
                    return result
                }
                delay = retryDelay
            } catch {
                let nsError = error as NSError
                // Connection-loss retries stay limited to one; never replay other errors.
                guard attempt == 0, retryTransientFailure, nsError.domain == NSURLErrorDomain,
                      nsError.code == URLError.networkConnectionLost.rawValue else {
                    throw contextualError(error, request: request)
                }
                delay = 2
            }
            diagnosticHandler?("Transient failure; retrying in \(delay) seconds")
            try await wait(delay)
            try Task.checkCancellation()
            retrySession?.finishTasksAndInvalidate()
            let freshSession = URLSession(configuration: session.configuration)
            retrySession = freshSession
            activeSession = freshSession
        }
        throw URLError(.badServerResponse)
    }

    private static func contextualError(_ error: Error, request: URLRequest) -> Error {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain,
              nsError.code != URLError.cancelled.rawValue else { return error }
        // Do not include query strings, headers or bodies containing credentials.
        let endpoint = request.url.map { "\($0.host ?? "unknown")\($0.path)" } ?? "unknown"
        return NSError(domain: nsError.domain, code: nsError.code, userInfo: [
            NSLocalizedDescriptionKey: "Apple request failed: \(endpoint)\n\(nsError.localizedDescription)",
            NSLocalizedRecoverySuggestionErrorKey: "If the connection keeps dropping, try another Wi-Fi or cellular network and temporarily disconnect any VPN. Then sign in again.",
            NSUnderlyingErrorKey: error
        ])
    }
}

public enum ServerResponseDecoder {
    public enum Format: String {
        case json = "JSON"
        case propertyList = "plist"
    }

    public static func decodePropertyList<Value: Decodable>(_ type: Value.Type,
                                                            from dictionary: [String: Any]) throws -> Value {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        return try PropertyListDecoder().decode(type, from: data)
    }

    public static func dictionary(from data: Data, response: URLResponse? = nil,
                                  url: URL? = nil, operation: String? = nil, format: Format) throws -> [String: Any] {
        let http = response as? HTTPURLResponse
        let endpointURL = response?.url ?? url
        let endpoint = endpointURL.map { "\($0.host ?? "unknown")\($0.path)" } ?? "local authentication payload"
        let status = http.map { String($0.statusCode) } ?? "unavailable"
        let operationInfo = operation.map { "Operation: \($0)\n" } ?? ""
        let metadata = operationInfo + "Endpoint: \(endpoint)\nHTTP: \(status)\nContent-Type: \(response?.mimeType ?? "unknown")\nBytes: \(data.count)"
        let suggestion: String
        if http?.statusCode == 429 {
            suggestion = "The server is rate limiting requests. Wait before trying again."
        } else if endpointURL?.host?.hasSuffix("apple.com") == true {
            suggestion = "Apple sign-in is temporarily unavailable or the network returned an error. Wait a few minutes, then retry. If it persists, try another network without a VPN or HTTP proxy. Changing the Anisette URL will not fix an Apple endpoint error."
        } else {
            suggestion = "Try again later or on another network. For an Anisette endpoint, check the V3 server URL in Settings."
        }
        func invalid(_ reason: String, code: Int) -> NSError {
            NSError(domain: "GetMoreRam.ServerResponse", code: code, userInfo: [
                NSLocalizedDescriptionKey: "\(reason)\n\(metadata)",
                NSLocalizedRecoverySuggestionErrorKey: suggestion
            ])
        }
        if let http, !(200..<300).contains(http.statusCode) {
            throw invalid("Server returned HTTP \(http.statusCode).", code: http.statusCode)
        }
        guard !data.isEmpty else {
            throw invalid("Server returned an empty response; expected \(format.rawValue).", code: 1)
        }
        let object: Any
        do {
            switch format {
            case .json:
                object = try JSONSerialization.jsonObject(with: data)
            case .propertyList:
                object = try PropertyListSerialization.propertyList(from: data, format: nil)
            }
        } catch {
            // Never echo response bodies: they can contain passwords or session tokens.
            throw invalid("Server returned invalid \(format.rawValue).", code: 2)
        }
        guard let dictionary = object as? [String: Any] else {
            throw invalid("Expected a \(format.rawValue) object, but received another value.", code: 3)
        }
        return dictionary
    }
}

public enum DiagnosticLogSanitizer {
    public static func sanitize(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in Set(secrets).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        // Strip URL credentials, query strings and fragments from diagnostics.
        if let pattern = try? NSRegularExpression(pattern: #"https?://[^\s<>\"]+"#) {
            for match in pattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result),
                      var url = URLComponents(string: String(result[range])) else { continue }
                url.user = nil
                url.password = nil
                url.query = nil
                url.fragment = nil
                result.replaceSubrange(range, with: url.string ?? "[URL]")
            }
        }
        if let emails = try? NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: .caseInsensitive) {
            result = emails.stringByReplacingMatches(in: result,
                range: NSRange(result.startIndex..., in: result), withTemplate: "[EMAIL]")
        }
        return result
    }
}

/// Client identity defaults shared by remote and on-device Anisette.
public enum AnisetteClientDefaults {
    public static let clientInfo = "<MacBookPro18,3> <macOS;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    public static let userAgent = "AuthKit/1 (Macintosh; OS X 26.6) (com.apple.akd/1.0)"
    public static let authenticationUserAgent = "AuthKit/1 (Macintosh; OS X 26.6) (com.apple.dt.Xcode/26.0)"
    public static let headerKeys = ["AnisetteClientInfo", "AnisetteUserAgent", "AppleAuthenticationUserAgent"]

    public static func resetProvisioningPreferences(keepingHeaders: Bool, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "AnisetteProvisioningServer")
        defaults.removeObject(forKey: "OnDeviceAnisetteIdentity")
        if !keepingHeaders {
            for key in headerKeys { defaults.removeObject(forKey: key) }
        }
    }
}
