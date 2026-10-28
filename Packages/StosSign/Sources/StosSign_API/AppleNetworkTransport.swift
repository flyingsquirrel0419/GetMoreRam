import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Retries only requests explicitly known to be safe to repeat.
public enum AppleNetworkTransport {
    public static func data(for request: URLRequest, session: URLSession,
                            retryConnectionLoss: Bool = false) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            let nsError = error as NSError
            guard retryConnectionLoss, nsError.domain == NSURLErrorDomain,
                  nsError.code == URLError.networkConnectionLost.rawValue else {
                throw contextualError(error, request: request)
            }
            try Task.checkCancellation()
            // A fresh connection avoids reusing the connection that just failed.
            let retrySession = URLSession(configuration: session.configuration)
            defer { retrySession.finishTasksAndInvalidate() }
            do {
                return try await retrySession.data(for: request)
            } catch {
                throw contextualError(error, request: request)
            }
        }
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
