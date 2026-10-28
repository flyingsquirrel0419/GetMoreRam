//
//  FetchAnisetteDataOperation.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CryptoKit
import StosSign_API
import StosSign_Auth
import StosSign_Common

final class AnisetteDataHelper
{
    var socket: URLSessionWebSocketTask?
    
    var url: URL?
    var startProvisioningURL: URL?
    var endProvisioningURL: URL?
    
    var clientInfo: String?
    var userAgent: String?
    
    var mdLu: String?
    var deviceId: String?
    
    var menuAnisetteURL: String?
    
    static var shared: AnisetteDataHelper = AnisetteDataHelper()
    
    var loggingFunc: ((String)->Void)?
    
    func resetClientInfo() {
        clientInfo = nil
        userAgent = nil
        mdLu = nil
        deviceId = nil
    }
    
    func getAnisetteData(refresh: Bool = false) async throws -> AnisetteData
    {

        try configureServer(DataManager.shared.model.anisetteServerURL)
        guard let url else {
            throw "No Anisette Server Found!"
        }

        self.printOut("Anisette URL: \(url.absoluteString)")
        do {
            if let identifier = Keychain.shared.identifier,
               let adiPb = Keychain.shared.adiPb {
                return try await self.fetchAnisetteV3(identifier, adiPb)
            }
            return try await self.provision()
        } catch let error as URLError {
            let failedURL = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
                ?? (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
                ?? url.absoluteString
            throw NSError(
                domain: NSURLErrorDomain,
                code: error.code.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not connect while fetching Anisette data.\nURL: \(failedURL)",
                    NSLocalizedRecoverySuggestionErrorKey: "Check your internet connection and Anisette Server URL in Settings. If the Anisette server is unavailable, enter a working V3 server URL and try again. Server changes take effect immediately; restarting the app is not required.",
                    NSUnderlyingErrorKey: error
                ]
            )
        }
    }

    private func configureServer(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = URL(string: value),
              let scheme = candidate.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = candidate.host, !host.isEmpty,
              candidate.user == nil, candidate.password == nil,
              candidate.query == nil, candidate.fragment == nil else {
            throw "Invalid Anisette Server URL. Enter a full HTTP or HTTPS V3 server URL in Settings."
        }

        let previousServer = UserDefaults.standard.string(forKey: "AnisetteProvisioningServer")
            .flatMap { URL(string: $0) } ?? url
        if candidate != previousServer {
            // Provisioning data belongs to the server that created it.
            Keychain.shared.adiPb = nil
            resetClientInfo()
            startProvisioningURL = nil
            endProvisioningURL = nil
        }
        url = candidate
        UserDefaults.standard.set(candidate.absoluteString, forKey: "AnisetteProvisioningServer")
    }
    

    // MARK: - COMMON
    
    func extractAnisetteData(_ data: Data, _ response: HTTPURLResponse?, v3: Bool) async throws -> AnisetteData {
        // make sure this JSON is in the format we expect
        // convert data to json
        let headers = try ServerResponseDecoder.dictionary(from: data, response: response, url: url?.appendingPathComponent("v3/get_headers"), format: .json)
        if let json = headers as? [String: String] {
            if v3 {
                if json["result"] == "GetHeadersError" {
                    let message = json["message"]
                    self.printOut("Error getting V3 headers: \(message ?? "no message")")
                    if let message = message,
                       message.contains("-45061") {
                        self.printOut("Error message contains -45061 (not provisioned), resetting adi.pb and retrying")
                        Keychain.shared.adiPb = nil
                        return try await provision()
                    } else { throw message ?? "Unknown error" }
                }
            }
            
            // try to read out a dictionary
            // for some reason serial number isn't needed but it doesn't work unless it has a value
            var formattedJSON: [String: String] = ["deviceSerialNumber": "0"]
            if let machineID = json["X-Apple-I-MD-M"] { formattedJSON["machineID"] = machineID }
            if let oneTimePassword = json["X-Apple-I-MD"] { formattedJSON["oneTimePassword"] = oneTimePassword }
            if let routingInfo = json["X-Apple-I-MD-RINFO"] { formattedJSON["routingInfo"] = routingInfo }
            
            if v3 {
                formattedJSON["deviceDescription"] = self.clientInfo!
                formattedJSON["localUserID"] = self.mdLu!
                formattedJSON["deviceUniqueIdentifier"] = self.deviceId!
                
                // Generate date stuff on client
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
                let dateString = formatter.string(from: Date())
                formattedJSON["date"] = dateString
                formattedJSON["locale"] = Locale.current.identifier
                formattedJSON["timeZone"] = TimeZone.current.abbreviation()
            } else {
                if let deviceDescription = json["X-MMe-Client-Info"] { formattedJSON["deviceDescription"] = deviceDescription }
                if let localUserID = json["X-Apple-I-MD-LU"] { formattedJSON["localUserID"] = localUserID }
                if let deviceUniqueIdentifier = json["X-Mme-Device-Id"] { formattedJSON["deviceUniqueIdentifier"] = deviceUniqueIdentifier }
                
                if let date = json["X-Apple-I-Client-Time"] { formattedJSON["date"] = date }
                if let locale = json["X-Apple-Locale"] { formattedJSON["locale"] = locale }
                if let timeZone = json["X-Apple-I-TimeZone"] { formattedJSON["timeZone"] = timeZone }
            }
            
            if let response = response,
               let version = response.value(forHTTPHeaderField: "Implementation-Version") {
                self.printOut("Implementation-Version: \(version)")
            } else { self.printOut("No Implementation-Version header") }
            
            do {
                let jsonData = try JSONEncoder().encode(formattedJSON)
                let anisette = try JSONDecoder().decode(AnisetteData.self, from: jsonData)
                
                self.printOut("Anisette is valid!")
                return anisette
            } catch {
                self.printOut("Anisette is invalid!!!!")
                if v3 {
                    throw "Invalid anisette (the returned data may not have all the required fields)"
                } else {
                    throw "Invalid anisette (the returned data may not have all the required fields)"
                }
            }
        } else {
            if v3 {
                throw "Invalid anisette (the returned data may not be in JSON)"
            } else {
                throw "Invalid anisette (the returned data may not be in JSON)"
            }
        }
    }
    
    
    // MARK: - V3: PROVISIONING
    
    func provision() async throws -> AnisetteData {
        try await fetchClientInfo()
            self.printOut("Getting provisioning URLs")
            var request = self.buildAppleRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!)
            request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try ServerResponseDecoder.dictionary(from: data, response: response, format: .propertyList)
        if let plist = payload as? Dictionary<String, Dictionary<String, Any>>,
           let startProvisioningString = plist["urls"]?["midStartProvisioning"] as? String,
           let startProvisioningURL = URL(string: startProvisioningString),
           let endProvisioningString = plist["urls"]?["midFinishProvisioning"] as? String,
           let endProvisioningURL = URL(string: endProvisioningString) {
            self.startProvisioningURL = startProvisioningURL
            self.endProvisioningURL = endProvisioningURL
            self.printOut("startProvisioningURL: \(self.startProvisioningURL!.absoluteString)")
            self.printOut("endProvisioningURL: \(self.endProvisioningURL!.absoluteString)")
            self.printOut("Starting a provisioning session")
            return try await self.startProvisioningSession()
        } else {
            self.printOut("Apple did not return valid URLs")
            throw "Apple didn't give valid URLs. Please try again later"
        }

        
    }
    
    func startProvisioningSession() async throws -> AnisetteData {
        let provisioningSessionURL = self.webSocketURL(from: self.url!.appendingPathComponent("v3").appendingPathComponent("provisioning_session"))
        var wsRequest = URLRequest(url: provisioningSessionURL)
        wsRequest.timeoutInterval = 5
        let socket = URLSession.shared.webSocketTask(with: wsRequest)
        self.socket = socket
        socket.resume()
        try await self.receiveProvisioningMessages(from: socket)
        return try await self.fetchAnisetteV3(Keychain.shared.identifier!, Keychain.shared.adiPb!)
    }

    private func receiveProvisioningMessages(from socket: URLSessionWebSocketTask) async throws {
        self.printOut("Connected")
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket {
                self.socket = nil
            }
        }
        
        while true {
            let message = try await socket.receive()
            switch message {
            case .string(let string):
                if try await handleProvisioningMessage(string, socket: socket) {
                    return
                }
            case .data:
                throw "The server sent binary data instead of text"
            @unknown default:
                throw "The server sent an unknown WebSocket message"
            }
        }
    }
    
    private func handleProvisioningMessage(_ string: String, socket: URLSessionWebSocketTask) async throws -> Bool {
        guard let data = string.data(using: .utf8),
              !data.isEmpty else {
            throw "The Anisette provisioning server sent an empty message."
        }
        let json = try ServerResponseDecoder.dictionary(from: data,
            url: url?.appendingPathComponent("v3/provisioning_session"), format: .json)
        
        guard let result = json["result"] as? String else {
            self.printOut("The server didn't give us a result")
            throw "The server didn't give us a result"
        }
        
        self.printOut("Received result: \(result)")
        switch result {
        case "GiveIdentifier":
            self.printOut("Giving identifier")
            try await socket.sendJSON(["identifier": Keychain.shared.identifier!])
            
        case "GiveStartProvisioningData":
            self.printOut("Getting start provisioning data")
            let spim = try await self.fetchStartProvisioningData()
            self.printOut("Giving start provisioning data")
            try await socket.sendJSON(["spim": spim])
            
        case "GiveEndProvisioningData":
            self.printOut("Getting end provisioning data")
            guard let cpim = json["cpim"] as? String else {
                self.printOut("The server didn't give us a cpim")
                throw "The server didn't give us a cpim"
            }
            let endProvisioningData = try await self.fetchEndProvisioningData(cpim: cpim)
            self.printOut("Giving end provisioning data")
            try await socket.sendJSON(endProvisioningData)
            
        case "ProvisioningSuccess":
            self.printOut("Provisioning succeeded!")
            guard let adiPb = json["adi_pb"] as? String else {
                self.printOut("The server didn't give us an adi.pb file")
                throw "The server didn't give us an adi.pb file"
            }
            Keychain.shared.adiPb = adiPb
            return true
            
        default:
            if result.contains("Error") || result.contains("Invalid") || result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                self.printOut("Failing because of \(result)")
                throw result + (json["message"] as? String ?? "")
            }
        }
        
        return false
    }
    
    private func fetchStartProvisioningData() async throws -> String {
        let body = [
            "Header": [String: Any](),
            "Request": [String: Any](),
        ]
        var request = self.buildAppleRequest(url: self.startProvisioningURL!)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try ServerResponseDecoder.dictionary(from: data, response: response, format: .propertyList)
        if let plist = payload as? Dictionary<String, Dictionary<String, Any>>,
           let spim = plist["Response"]?["spim"] as? String {
            return spim
        } else {
            self.printOut("Apple did not return valid start provisioning data")
            throw "Apple didn't give valid start provisioning data. Please try again later"
        }
    }
    
    private func fetchEndProvisioningData(cpim: String) async throws -> [String: String] {
        let body = [
            "Header": [String: Any](),
            "Request": [
                "cpim": cpim,
            ],
        ]
        var request = self.buildAppleRequest(url: self.endProvisioningURL!)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try ServerResponseDecoder.dictionary(from: data, response: response, format: .propertyList)
        if let plist = payload as? Dictionary<String, Dictionary<String, Any>>,
           let ptm = plist["Response"]?["ptm"] as? String,
           let tk = plist["Response"]?["tk"] as? String {
            return ["ptm": ptm, "tk": tk]
        } else {
            self.printOut("Apple did not return valid end provisioning data")
            throw "Apple didn't give valid end provisioning data. Please try again later"
        }
    }
    
    private func webSocketURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        
        return components.url ?? url
    }
    
    func buildAppleRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(self.clientInfo!, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(self.userAgent!, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        request.setValue(self.mdLu!, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(self.deviceId!, forHTTPHeaderField: "X-Mme-Device-Id")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let dateString = formatter.string(from: Date())
        request.setValue(dateString, forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(TimeZone.current.abbreviation(), forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }
    
    // MARK: - V3: FETCHING
    
    func fetchClientInfo() async throws {
        if self.clientInfo == DataManager.shared.model.anisetteClientInfo &&
                self.userAgent == DataManager.shared.model.anisetteUserAgent &&
                self.mdLu != nil &&
                self.deviceId != nil &&
                Keychain.shared.identifier != nil {
            self.printOut("Skipping client_info fetch since all the properties we need aren't nil")
            return
        }
        
        let settings = DataManager.shared.model
        self.clientInfo = settings.anisetteClientInfo
        self.userAgent = settings.anisetteUserAgent
        self.printOut("Using configured Anisette client identity")
        self.printOut("Client-Info: \(self.clientInfo!)")
        self.printOut("User-Agent: \(self.userAgent!)")

        if Keychain.shared.identifier == nil {
            self.printOut("Generating identifier")
            var bytes = [Int8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            
            if status != errSecSuccess {
                self.printOut("ERROR GENERATING IDENTIFIER!!! \(status)")
                throw "Couldn't generate identifier"
            }
            
            Keychain.shared.identifier = Data(bytes: &bytes, count: bytes.count).base64EncodedString()
        }
        
        let decoded = Data(base64Encoded: Keychain.shared.identifier!)!
        self.mdLu = decoded.sha256().hexEncodedString()
        let uuid: UUID = decoded.object()
        self.deviceId = uuid.uuidString.uppercased()


    }
    
    func fetchAnisetteV3(_ identifier: String, _ adiPb: String) async throws -> AnisetteData {
        try await fetchClientInfo()
        self.printOut("Fetching anisette V3")
        let url = menuAnisetteURL
        var request = URLRequest(url: self.url!.appendingPathComponent("v3").appendingPathComponent("get_headers"))
        request.httpMethod = "POST"
        request.httpBody = try! JSONSerialization.data(withJSONObject: [
            "identifier": identifier,
            "adi_pb": adiPb
        ], options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await AppleNetworkTransport.data(for: request, session: URLSession.shared, retryTransientFailure: true)
        
        return try await self.extractAnisetteData(data, response as? HTTPURLResponse, v3: true)

    }
    
    
    private func printOut(_ text: String?){
        let isInternalLoggingEnabled = true
        if(isInternalLoggingEnabled){
            // logging enabled, so log it
            if let loggingFunc {
                loggingFunc(text ?? "\n")
            } else {
                text.map{ _ in print(text!) } ?? print()
            }

        }
    }
}

extension URLSessionWebSocketTask {
    func sendJSON(_ dictionary: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [])
        try await self.send(.string(String(data: data, encoding: .utf8)!))
    }
}

extension Data {
    // https://stackoverflow.com/a/25391020
    func sha256() -> Data {
        Data(SHA256.hash(data: self))
    }
    
    // https://stackoverflow.com/a/40089462
    func hexEncodedString() -> String {
        return self.map { String(format: "%02hhX", $0) }.joined()
    }
    
    // https://stackoverflow.com/a/59127761
    func object<T>() -> T { self.withUnsafeBytes { $0.load(as: T.self) } }
}
