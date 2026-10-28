import Foundation

final class StubProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests = 0
    static var failure: URLError.Code = .networkConnectionLost
    static var alwaysFail = false

    static func reset(_ code: URLError.Code = .networkConnectionLost, always: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        requests = 0
        failure = code
        alwaysFail = always
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let fail = Self.requests == 1 || Self.alwaysFail
        let code = Self.failure
        Self.lock.unlock()
        if fail {
            client?.urlProtocol(self, didFailWithError: URLError(code))
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ok".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main
struct TransportTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://gsa.apple.com/test?token=secret")!)
        request.httpMethod = "POST"

        StubProtocol.reset()
        let (data, _) = try await AppleNetworkTransport.data(for: request, session: session,
                                                           retryConnectionLoss: true)
        assert(String(decoding: data, as: UTF8.self) == "ok")
        assert(StubProtocol.requests == 2, "Safe initialization must retry once")

        StubProtocol.reset()
        do {
            _ = try await AppleNetworkTransport.data(for: request, session: session)
            fatalError("Non-replayable requests must fail")
        } catch {
            let error = error as NSError
            assert(error.code == -1005)
            assert(error.localizedDescription.contains("gsa.apple.com/test"))
            assert(!error.localizedDescription.contains("secret"))
            assert(error.userInfo[NSUnderlyingErrorKey] != nil)
            assert(StubProtocol.requests == 1, "Never replay verification or mutations")
        }

        StubProtocol.reset(always: true)
        do {
            _ = try await AppleNetworkTransport.data(for: request, session: session,
                                                    retryConnectionLoss: true)
            fatalError("Repeated connection loss must fail")
        } catch {
            assert(StubProtocol.requests == 2, "Retries must be bounded")
        }

        for code in [URLError.Code.cancelled, .timedOut] {
            StubProtocol.reset(code)
            do {
                _ = try await AppleNetworkTransport.data(for: request, session: session,
                                                        retryConnectionLoss: true)
                fatalError("Other errors must fail without retry")
            } catch {
                assert((error as NSError).code == code.rawValue)
                assert(StubProtocol.requests == 1)
            }
        }
        print("Network transport regression checks passed")
    }
}
