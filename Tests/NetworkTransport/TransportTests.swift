import Foundation

final class StubProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests = 0
    static var failure: URLError.Code = .networkConnectionLost
    static var alwaysFail = false
    static var firstHTTPStatus: Int?

    static func reset(_ code: URLError.Code = .networkConnectionLost, always: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        firstHTTPStatus = nil
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
        let httpStatus = Self.requests == 1 ? Self.firstHTTPStatus : nil
        let useHTTP = Self.firstHTTPStatus != nil
        Self.lock.unlock()
        if fail && !useHTTP {
            client?.urlProtocol(self, didFailWithError: URLError(code))
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: httpStatus ?? 200,
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
                                                           retryTransientFailure: true)
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
                                                    retryTransientFailure: true)
            fatalError("Repeated connection loss must fail")
        } catch {
            assert(StubProtocol.requests == 2, "Retries must be bounded")
        }

        for code in [URLError.Code.cancelled, .timedOut] {
            StubProtocol.reset(code)
            do {
                _ = try await AppleNetworkTransport.data(for: request, session: session,
                                                        retryTransientFailure: true)
                fatalError("Other errors must fail without retry")
            } catch {
                assert((error as NSError).code == code.rawValue)
                assert(StubProtocol.requests == 1)
            }
        }
        for replayable in [true, false] {
            StubProtocol.reset()
            StubProtocol.firstHTTPStatus = 503
            let (_, response) = try await AppleNetworkTransport.data(for: request, session: session,
                retryTransientFailure: replayable)
            assert((response as? HTTPURLResponse)?.statusCode == (replayable ? 200 : 503))
            assert(StubProtocol.requests == (replayable ? 2 : 1))
        }
        let developer: [String: Any] = [
            "email": "test@example.com", "personId": 12345,
            "firstName": "Test", "lastName": "Account",
            "createdDate": Date(), "opaqueData": Data([0, 1, 2]),
            "memberships": [["expirationDate": Date()]]
        ]
        assert(!JSONSerialization.isValidJSONObject(developer), "Fixture must reproduce the old JSON conversion failure")
        let account = try ServerResponseDecoder.decodePropertyList(Account.self, from: developer)
        assert(account.appleID == "test@example.com")
        assert(account.identifier == 12345)
        assert(account.firstName == "Test" && account.lastName == "Account")
        let diagnostic = "user@example.com passwordValue https://user:pass@example.com/path?token=private#fragment"
        let sanitized = DiagnosticLogSanitizer.sanitize(diagnostic, secrets: ["passwordValue", ""])
        assert(!sanitized.contains("user@example.com"))
        assert(!sanitized.contains("passwordValue"))
        assert(!sanitized.contains("private"))
        assert(!sanitized.contains("user:pass"))
        assert(!sanitized.contains("fragment"))
        assert(sanitized.contains("https://example.com/path"))
        assert(DiagnosticLogSanitizer.sanitize("HTTP 503 gsa.apple.com/grandslam/GsService2", secrets: [])
               == "HTTP 503 gsa.apple.com/grandslam/GsService2")
        try testResponseDecoding()
        print("Network transport and response decoding regression checks passed")
    }
    static func testResponseDecoding() throws {
        let url = URL(string: "https://example.com/v3/get_headers?token=secret")!
        func response(_ status: Int, _ mime: String) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": mime])!
        }
        let validJSON = Data("{\"value\":\"ok\"}".utf8)
        let json = try ServerResponseDecoder.dictionary(from: validJSON,
            response: response(200, "application/json"), format: .json)
        assert(json["value"] as? String == "ok")
        for plistFormat in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["value": "ok"],
                                                         format: plistFormat, options: 0)
            let plist = try ServerResponseDecoder.dictionary(from: data,
                response: response(200, "text/x-xml-plist"), format: .propertyList)
            assert(plist["value"] as? String == "ok")
        }
        for (data, status, format) in [
            (Data("<html>private response body</html>".utf8), 503, ServerResponseDecoder.Format.json),
            (Data("<html>private response body</html>".utf8), 200, .json),
            (Data(), 200, .propertyList),
            (Data("[]".utf8), 200, .json),
            (Data("not a plist".utf8), 200, .propertyList),
            (validJSON, 429, .json)
        ] {
            do {
                _ = try ServerResponseDecoder.dictionary(from: data,
                    response: response(status, "text/plain"), format: format)
                fatalError("Invalid responses must fail")
            } catch {
                let error = error as NSError
                assert(error.domain == "GetMoreRam.ServerResponse")
                assert(error.localizedDescription.contains("example.com/v3/get_headers"))
                assert(error.localizedDescription.contains("HTTP: \(status)"))
                assert(!error.localizedDescription.contains("secret"))
                assert(!error.localizedDescription.contains("private response body"))
            }
        }
    }

}
