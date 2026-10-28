//
//  SettingsView.swift
//  GetMoreRam
//
//  Created by s s on 2025/3/14.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import StosSign_API
import StosSign_Auth
import StosSign_Common

struct SettingsView: View {

    @State var email = ""
    @State var teamId = ""
    @StateObject var viewModel : LoginViewModel
    @EnvironmentObject private var sharedModel : SharedModel
    
    @State private var headersShow = false
    @State private var resetAnisetteShow = false
    @State private var keepHeaders = true
    @State private var isResettingAnisette = false
    @State private var logsShow = false
    @State private var errorShow = false
    @State private var errorInfo = ""
    @State private var importResultShow = false
    @State private var importResultInfo = ""
    @State private var isImportingSideStoreAccount = false
    

    var body: some View {
        Form {

            Section {
                if sharedModel.isLogin {
                    HStack {
                        Text("Email")
                        Spacer()
                        Text(email)
                    }
                    HStack {
                        Text("Team ID")
                        Spacer()
                        Text(teamId)
                    }
                } else {
                    Button("Sign in") {
                        viewModel.loginModalShow = true
                    }
                    
                    Button("Import SideStore Account") {
                        isImportingSideStoreAccount = true
                    }
                }
            } header: {
                Text("Account")
            }
            
            Section {
                Toggle("On-Device Anisette", isOn: $sharedModel.useOnDeviceAnisette)
                    .disabled(viewModel.isLoginInProgress)
                if !sharedModel.useOnDeviceAnisette {
                    Picker("Server", selection: $sharedModel.anisetteServerURL) {
                        Text("SideStore").tag("https://ani.sidestore.io")
                        Text("jkcoxson (macOS)").tag("https://mac-ani.jkcoxson.com")
                        Text("jkcoxson (Windows ADI)").tag("https://ani.jkcoxson.com")
                        Text("SideStore (Windows ADI)").tag("https://win.ani.sidestore.io")
                        if !["https://ani.sidestore.io", "https://mac-ani.jkcoxson.com", "https://ani.jkcoxson.com", "https://win.ani.sidestore.io"].contains(sharedModel.anisetteServerURL) {
                            Text("Custom").tag(sharedModel.anisetteServerURL)
                        }
                    }
                    .disabled(viewModel.isLoginInProgress)
                    TextField("Anisette Server URL", text: $sharedModel.anisetteServerURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .disabled(viewModel.isLoginInProgress)
                }
                Button("Anisette & Sign-In Headers") { headersShow = true }
                    .disabled(viewModel.isLoginInProgress)
                Button("Reset adi.pb", role: .destructive) { resetAnisetteShow = true }
                    .disabled(viewModel.isLoginInProgress || isResettingAnisette)
            } header: {
                Text("Anisette")
            } footer: {
                Text("On-device mode runs ADI locally without JIT. First use downloads the required libraries; Apple provisioning still requires internet access.")
            }

            Section("Diagnostics") {
                Button("View Logs") { logsShow = true }
                ShareLink(item: viewModel.logExportText) {
                    Label("Share Logs", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.logs.isEmpty)
                Button("Clear Logs", role: .destructive) { viewModel.clearLogs() }
                    .disabled(viewModel.logs.isEmpty)
            }

            Section {
                Button("Clean Up Keychain") {
                    cleanUp()
                }
            } footer: {
                Text("If something went wrong during signing in, please try to clean up the keychain, repoen the app and try again. \n \nIf you use SideStore and are already signed in, please also try exporting SideStore Account from SideStore settings and import it here to sign in.")
            }
        }
        .alert("Error", isPresented: $errorShow){
            Button("OK".loc, action: {
            })
        } message: {
            Text(errorInfo)
        }
        .alert("SideStore Account", isPresented: $importResultShow){
            Button("OK".loc, action: {
            })
        } message: {
            Text(importResultInfo)
        }
        .fileImporter(
            isPresented: $isImportingSideStoreAccount,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importSideStoreAccount(result)
        }
        
        .sheet(isPresented: $viewModel.loginModalShow, onDismiss: {
            viewModel.cancelAuthentication()
        }) {
            loginModal
        }
        .sheet(isPresented: $headersShow) {
            NavigationView { anisetteHeadersView }
        }
        .sheet(isPresented: $resetAnisetteShow) {
            NavigationView {
                Form {
                    Section {
                        Toggle("Keep header customizations", isOn: $keepHeaders)
                    } footer: {
                        Text("Clears remote and on-device provisioning data and signs out. Your signing certificates and selected Anisette mode are preserved.")
                    }
                    Button("Reset & Sign Out", role: .destructive) {
                        Task { await resetAnisette(keepingHeaders: keepHeaders) }
                    }
                    .disabled(isResettingAnisette)
                    if isResettingAnisette { ProgressView() }
                }
                .navigationTitle("Reset adi.pb")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { resetAnisetteShow = false }
                            .disabled(isResettingAnisette)
                    }
                }
            }
            .interactiveDismissDisabled(isResettingAnisette)
        }
        .sheet(isPresented: $logsShow) {
            NavigationView { DiagnosticLogsView(viewModel: viewModel) }
        }
        .sheet(isPresented: $viewModel.teamSelectionShow) {
            teamSelectionView
        }
    }
    
    var loginModal: some View {
        NavigationView {
            Form {
                Section {
                    TextField("", text: $viewModel.appleID)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .disabled(viewModel.isLoginInProgress)
                } header: {
                    Text("Apple ID")
                }
                Section {
                    SecureField("", text: $viewModel.password)
                        .disabled(viewModel.isLoginInProgress)
                } header: {
                    Text("Password")
                }
                if viewModel.needVerificationCode {
                    Section {
                        TextField("", text: $viewModel.verificationCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .disabled(viewModel.isVerificationCodeSubmitting)
                            .onChange(of: viewModel.verificationCode) { newValue in
                                let digits = String(newValue.filter(\.isNumber).prefix(6))
                                if digits != newValue {
                                    viewModel.verificationCode = digits
                                }
                            }
                    } header: {
                        Text("Verification Code")
                    }
                }
                Section {
                    Button("Continue") {
                        Task{ await loginButtonClicked() }
                    }
                    .disabled(continueButtonDisabled)
                }
                
                Section {
                    Text(viewModel.logs.isEmpty ? "No logs yet." : viewModel.logs)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(6)
                        .textSelection(.enabled)
                    NavigationLink("View, Share or Clear Logs") {
                        DiagnosticLogsView(viewModel: viewModel)
                    }
                } header: {
                    Text("Debugging")
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) {
                        viewModel.cancelAuthentication()
                        viewModel.loginModalShow = false
                    }
                }
            }
        }
        .onAppear {
            if let email = Keychain.shared.appleIDEmailAddress, let password = Keychain.shared.appleIDPassword {
                viewModel.appleID = email
                viewModel.password = password
            }
        }
    }
    
    var teamSelectionView: some View {
        NavigationView {
            List {
                ForEach(Array(viewModel.availableTeams.enumerated()), id: \.offset) { _, team in
                    Button {
                        selectTeam(team)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(team.name)
                                .foregroundStyle(.primary)
                            Text("\(team.identifier) · \(teamTypeDescription(team.type))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Choose Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) {
                        cancelTeamSelection()
                    }
                }
            }
        }
    }
    
    func loginButtonClicked() async {
        do {
            if viewModel.needVerificationCode {
                viewModel.submitVerificationCode()
                return
            }
            
            let result = try await viewModel.authenticate()
            if result {
                await MainActor.run {
                    viewModel.loginModalShow = false
                    email = sharedModel.account!.appleID
                    teamId = ""
                }

                if viewModel.availableTeams.count == 1,
                   let team = viewModel.availableTeams.first {
                    await MainActor.run {
                        selectTeam(team)
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await MainActor.run {
                        viewModel.teamSelectionShow = true
                    }
                }
            }
            
        } catch is CancellationError {
            return
        } catch {
            errorInfo = error.detailedDescription
            errorShow = true
        }
    }

    private var continueButtonDisabled: Bool {
        if viewModel.needVerificationCode {
            return viewModel.isVerificationCodeSubmitting ||
                viewModel.verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return viewModel.isLoginInProgress || !viewModel.hasCredentials
    }
    
    var anisetteHeadersView: some View {
        Form {
            Section("Anisette Client-Info") {
                TextEditor(text: $sharedModel.anisetteClientInfo)
                    .frame(minHeight: 100)
            }
            Section("Anisette User-Agent") {
                TextEditor(text: $sharedModel.anisetteUserAgent)
                    .frame(minHeight: 70)
            }
            Section("Apple Sign-In User-Agent") {
                TextEditor(text: $sharedModel.authenticationUserAgent)
                    .frame(minHeight: 70)
            }
            Section {
                Button("Restore Default Headers") {
                    sharedModel.anisetteClientInfo = AnisetteClientDefaults.clientInfo
                    sharedModel.anisetteUserAgent = AnisetteClientDefaults.userAgent
                    sharedModel.authenticationUserAgent = AnisetteClientDefaults.authenticationUserAgent
                }
            } footer: {
                Text("Changes apply on the next sign-in. Use matching client identities for your ADI provider.")
            }
        }
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .navigationTitle("Client Headers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { headersShow = false }
            }
        }
    }

    func cleanUp() {
        Task { await resetAnisette(keepingHeaders: true) }
    }

    @MainActor
    func resetAnisette(keepingHeaders: Bool) async {
        guard !viewModel.isLoginInProgress, !isResettingAnisette else { return }
        isResettingAnisette = true
        defer { isResettingAnisette = false }
        do {
            try await OnDeviceAnisette.shared.reset()
            Keychain.shared.adiPb = nil
            Keychain.shared.identifier = nil
            Keychain.shared.onDeviceAdiPb = nil
            Keychain.shared.onDeviceIdentifier = nil
            Keychain.shared.appleIDPassword = nil
            Keychain.shared.appleIDEmailAddress = nil
            AnisetteClientDefaults.resetProvisioningPreferences(keepingHeaders: keepingHeaders)
            if !keepingHeaders {
                sharedModel.anisetteClientInfo = AnisetteClientDefaults.clientInfo
                sharedModel.anisetteUserAgent = AnisetteClientDefaults.userAgent
                sharedModel.authenticationUserAgent = AnisetteClientDefaults.authenticationUserAgent
            }
            AnisetteDataHelper.shared.resetClientInfo()
            sharedModel.session = nil
            sharedModel.account = nil
            sharedModel.team = nil
            sharedModel.isLogin = false
            viewModel.appleID = ""
            viewModel.password = ""
            viewModel.availableTeams = []
            viewModel.teamSelectionShow = false
            email = ""
            teamId = ""
            viewModel.appendLog("Reset remote and on-device adi.pb; headers \(keepingHeaders ? "preserved" : "restored to defaults"); signing certificates preserved")
            resetAnisetteShow = false
        } catch {
            viewModel.appendLog("Reset adi.pb failed: \(error.detailedDescription)")
            resetAnisetteShow = false
            errorInfo = error.detailedDescription
            errorShow = true
        }
    }

    func importSideStoreAccount(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                throw "No file selected."
            }
            
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            let data = try Data(contentsOf: url)
            let account = try SideStoreAccountImporter.importAccount(from: data)
            
            viewModel.appleID = account.email
            viewModel.password = account.password
            sharedModel.session = nil
            sharedModel.account = nil
            sharedModel.team = nil
            sharedModel.isLogin = false
            viewModel.availableTeams = []
            viewModel.teamSelectionShow = false
            email = account.email
            teamId = ""
            importResultInfo = "Imported \(account.email).\nTap \"Sign In\" to continue."
            importResultShow = true
        } catch {
            errorInfo = error.detailedDescription
            errorShow = true
        }
    }
    
    func selectTeam(_ team: Team) {
        sharedModel.team = team
        sharedModel.isLogin = true
        email = sharedModel.account?.appleID ?? email
        teamId = team.identifier
        viewModel.availableTeams = []
        viewModel.teamSelectionShow = false
    }
    
    func cancelTeamSelection() {
        viewModel.availableTeams = []
        viewModel.teamSelectionShow = false
        sharedModel.session = nil
        sharedModel.account = nil
        sharedModel.team = nil
        sharedModel.isLogin = false
        email = ""
        teamId = ""
    }
    
    func teamTypeDescription(_ type: TeamType) -> String {
        switch type {
        case .free:
            return "Free"
        case .individual:
            return "Individual"
        case .organization:
            return "Organization"
        case .unknown:
            return "Unknown"
        }
    }
    
}


private struct DiagnosticLogsView: View {
    @ObservedObject var viewModel: LoginViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(viewModel.logs.isEmpty ? "No logs yet." : viewModel.logs)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                ShareLink(item: viewModel.logExportText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.logs.isEmpty)
                Spacer()
                Button {
                    UIPasteboard.general.string = viewModel.logExportText
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(viewModel.logs.isEmpty)
                Spacer()
                Button("Clear", role: .destructive) {
                    viewModel.clearLogs()
                    copied = false
                }
                .disabled(viewModel.logs.isEmpty)
            }
        }
        .onChange(of: viewModel.logs) { _ in copied = false }
    }
}
