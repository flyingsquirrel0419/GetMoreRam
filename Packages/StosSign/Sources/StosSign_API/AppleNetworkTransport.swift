import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Retries only requests explicitly known to be safe to repeat.
public enum AppleNetworkTransport {
    public static func data(for request: URLRequest, session: URLSession,
                            retryTransientFailure: Bool = false) async throws -> (Data, URLResponse) {
        var activeSession = session
        var retrySession: URLSession?
        defer { retrySession?.finishTasksAndInvalidate() }
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                let result = try await activeSession.data(for: request)
                let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
                if !(attempt == 0 && retryTransientFailure && [502, 503, 504].contains(status)) {
                    return result
                }
            } catch {
                let nsError = error as NSError
                guard attempt == 0, retryTransientFailure, nsError.domain == NSURLErrorDomain,
                      nsError.code == URLError.networkConnectionLost.rawValue else {
                    throw contextualError(error, request: request)
                }
            }
            // Only explicitly replayable requests may use a fresh connection once.
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
                                  url: URL? = nil, format: Format) throws -> [String: Any] {
        let http = response as? HTTPURLResponse
        let endpointURL = response?.url ?? url
        let endpoint = endpointURL.map { "\($0.host ?? "unknown")\($0.path)" } ?? "local authentication payload"
        let status = http.map { String($0.statusCode) } ?? "unavailable"
        let metadata = "Endpoint: \(endpoint)\nHTTP: \(status)\nContent-Type: \(response?.mimeType ?? "unknown")\nBytes: \(data.count)"
        let suggestion: String
        if http?.statusCode == 429 {
            suggestion = "The server is rate limiting requests. Wait before trying again."
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
