//
//  LoginViewModel.swift
//  GetMoreRam
//
//  Created by s s on 2025/3/15.
//
import SwiftUI
import UIKit
import StosSign_API
import StosSign_Auth
import StosSign_Common

@MainActor
class LoginViewModel: ObservableObject {
    @Published var appleID = ""
    @Published var password = ""
    @Published var needVerificationCode = false
    @Published var verificationCode = ""
    @Published var loginModalShow = false
    @Published var teamSelectionShow = false
    @Published var isLoginInProgress = false
    @Published private(set) var isVerificationCodeSubmitting = false
    @Published private(set) var logs = ""
    @Published var availableTeams: [Team] = []
    
    var logExportText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "GetMoreRam \(version) (\(build))\niOS \(UIDevice.current.systemVersion)\nExported: \(Date().ISO8601Format())\n\n\(logs)"
    }

    func clearLogs() {
        logs = ""
    }

    func appendLog(_ text: String) {
        let helper = AnisetteDataHelper.shared
        let safeText = DiagnosticLogSanitizer.sanitize(text, secrets: [
            appleID, password, verificationCode,
            Keychain.shared.appleIDEmailAddress ?? "", Keychain.shared.appleIDPassword ?? "",
            Keychain.shared.identifier ?? "", Keychain.shared.adiPb ?? "",
            Keychain.shared.onDeviceIdentifier ?? "", Keychain.shared.onDeviceAdiPb?.base64EncodedString() ?? "",
            helper.mdLu ?? "", helper.deviceId ?? ""
        ])
        logs.append("[\(Date().ISO8601Format())] \(safeText)\n")
        // Keep diagnostics bounded during repeated login attempts.
        if logs.count > 100_000 { logs = String(logs.suffix(100_000)) }
    }

    var hasCredentials: Bool {
        !appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }
    
    private var verificationCodeHandler: ((String?) -> Void)?
    private var isAuthenticationCancellationRequested = false
    
    func submitVerificationCode() {
        guard !isVerificationCodeSubmitting,
              let verificationCodeHandler else { return }

        self.verificationCodeHandler = nil
        isVerificationCodeSubmitting = true
        verificationCodeHandler(verificationCode)
    }

    func cancelAuthentication() {
        guard isLoginInProgress else { return }

        isAuthenticationCancellationRequested = true

        let verificationCodeHandler = verificationCodeHandler
        self.verificationCodeHandler = nil
        needVerificationCode = false
        verificationCode = ""
        isVerificationCodeSubmitting = false

        verificationCodeHandler?(nil)
    }
    
    func authenticate() async throws -> Bool {
        if isLoginInProgress {
            return false
        }
        
        guard hasCredentials else {
            throw "Please enter your Apple ID and password."
        }
        
        appendLog("Starting sign-in")
        isLoginInProgress = true
        isAuthenticationCancellationRequested = false
        
        func logging(text: String) {
            Task { @MainActor [weak self] in
                self?.appendLog(text)
            }
        }
        
        AnisetteDataHelper.shared.loggingFunc = logging

        defer {
            AnisetteDataHelper.shared.loggingFunc = nil
            verificationCodeHandler = nil
            appleID = ""
            password = ""
            needVerificationCode = false
            verificationCode = ""
            isLoginInProgress = false
            isVerificationCodeSubmitting = false
            isAuthenticationCancellationRequested = false
        }

        var stage = "Fetching Anisette data"
        do {
            appendLog(stage)
            let settings = DataManager.shared.model
            for value in [settings.anisetteClientInfo, settings.anisetteUserAgent, settings.authenticationUserAgent] {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !value.contains("\r"), !value.contains("\n") else {
                    throw "Client headers must be non-empty single-line values. Check Anisette & Sign-In Headers in Settings."
                }
            }
            let anisetteData: AnisetteData
            if settings.useOnDeviceAnisette {
                appendLog("Anisette provider: on-device (Unicorn TCI)")
                let fingerprint = settings.anisetteClientInfo + "\n" + settings.anisetteUserAgent
                if UserDefaults.standard.string(forKey: "OnDeviceAnisetteIdentity") != fingerprint {
                    Keychain.shared.onDeviceAdiPb = nil
                    try await OnDeviceAnisette.shared.reset()
                    UserDefaults.standard.set(fingerprint, forKey: "OnDeviceAnisetteIdentity")
                }
                let identifier = Keychain.shared.onDeviceIdentifier.flatMap(UUID.init(uuidString:)) ?? UUID()
                Keychain.shared.onDeviceIdentifier = identifier.uuidString
                let (data, blob) = try await OnDeviceAnisette.shared.generate(identifier: identifier,
                    blob: Keychain.shared.onDeviceAdiPb, clientInfo: settings.anisetteClientInfo,
                    userAgent: settings.anisetteUserAgent, log: { [weak self] message in
                        Task { @MainActor in self?.appendLog(message) }
                    })
                if let blob { Keychain.shared.onDeviceAdiPb = blob }
                anisetteData = data
            } else {
                appendLog("Anisette provider: remote")
                anisetteData = try await AnisetteDataHelper.shared.getAnisetteData()
            }

            stage = "Apple sign-in"
            appendLog(stage)
            let (account, session) = try await AppleNetworkTransport.$diagnosticHandler.withValue({ [weak self] message in
                Task { @MainActor in self?.appendLog(message) }
            }) {
                try await AppleNetworkTransport.$authenticationUserAgent.withValue(settings.authenticationUserAgent) {
                    try await AppleAPI.shared.authenticate(appleID: appleID, password: password, anisetteData: anisetteData) { [weak self] completionHandler in
                        guard let self else {
                            completionHandler(nil)
                            return
                        }

                        self.prepareForVerification(using: completionHandler)
                    }
                }
            }

            guard !isAuthenticationCancellationRequested else {
                throw CancellationError()
            }

            logging(text: "Successfully signed in")

            DataManager.shared.model.account = account
            DataManager.shared.model.session = session
            Keychain.shared.appleIDEmailAddress = appleID
            Keychain.shared.appleIDPassword = password

            stage = "Fetching Apple developer teams"
            appendLog(stage)
            let teams = try await fetchTeams(for: account, session: session)
            logging(text: "Successfully fetched teams")
            availableTeams = teams

            return true
        } catch {
            if isAuthenticationCancellationRequested {
                appendLog("Sign-in cancelled")
                throw CancellationError()
            }
            appendLog("\(stage) failed\n\(error.detailedDescription)")
            let original = error as NSError
            throw NSError(domain: original.domain, code: original.code, userInfo: [
                NSLocalizedDescriptionKey: "\(stage)\n\(original.localizedDescription)",
                NSUnderlyingErrorKey: error
            ])
        }
    }

    private func prepareForVerification(using handler: @escaping (String?) -> Void) {
        guard !isAuthenticationCancellationRequested else {
            handler(nil)
            return
        }

        appendLog("Waiting for verification code")
        verificationCodeHandler = handler
        verificationCode = ""
        needVerificationCode = true
        isVerificationCodeSubmitting = false
    }
    
    func fetchTeams(for account: Account, session: AppleAPISession) async throws -> [Team]
    {

        let fetchedTeams = try await AppleAPI.shared.fetchTeamsForAccount(account: account, session: session)
        guard !fetchedTeams.isEmpty else {
            throw "Unable to Fetch Team!"
        }
        
        return fetchedTeams
    }
}
