import Foundation
import Crypto
import AnisetteKit
import ZIPFoundation
import StosSign_Common
import StosSign_API

/// Uses the same no-JIT ADI emulator as SideStore. Never falls back to remote generation.
public actor OnDeviceAnisette {
    public static let shared = OnDeviceAnisette()
    private let required = AnisetteConstants.Libraries.requiredNames
    private var client: AnisetteClient?
    private var identity: String?

    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GetMoreRam/OnDeviceAnisette", isDirectory: true)
    }

    public func reset() throws {
        client = nil
        identity = nil
        let provisioning = root.appendingPathComponent("provisioning", isDirectory: true)
        if FileManager.default.fileExists(atPath: provisioning.path) {
            try FileManager.default.removeItem(at: provisioning)
        }
    }

    public func generate(identifier: UUID, blob: Data?, clientInfo: String, userAgent: String,
                         log: @Sendable (String) -> Void) async throws -> (AnisetteData, Data?) {
        let libraries = root.appendingPathComponent("libraries", isDirectory: true)
        if !AnisetteClient.validateLibrariesExist(at: libraries) {
            log("Preparing on-device ADI libraries (first use)")
            try await installLibraries(at: libraries)
        }
        let provisioning = root.appendingPathComponent("provisioning", isDirectory: true)
        try FileManager.default.createDirectory(at: provisioning, withIntermediateDirectories: true)
        let fingerprint = clientInfo + "\n" + userAgent
        if client == nil || identity != fingerprint {
            client = try AnisetteClient(provisioningDir: provisioning, clientInfo: clientInfo,
                userAgent: userAgent, libraryDirectoryResolver: { libraries })
            identity = fingerprint
        }
        guard let client else { throw failure("On-device Anisette could not initialize.") }
        log(blob == nil ? "Provisioning on-device ADI with Apple" : "Generating Anisette on device")
        let (headers, newBlob) = try await client.getAnisetteData(identifier: identifier,
            storage: .memory(existingBlob: blob))
        guard let machine = headers["X-Apple-I-MD-M"], !machine.isEmpty,
              let otp = headers["X-Apple-I-MD"], !otp.isEmpty,
              let routing = headers["X-Apple-I-MD-RINFO"].flatMap(UInt64.init),
              let localUser = headers["X-Apple-I-MD-LU"], !localUser.isEmpty else {
            throw failure("On-device ADI returned incomplete Anisette headers.")
        }
        let data = AnisetteData(machineID: machine, oneTimePassword: otp, localUserID: localUser,
            routingInfo: routing, deviceUniqueIdentifier: headers["X-Mme-Device-Id"] ?? identifier.uuidString,
            deviceSerialNumber: "0", deviceDescription: clientInfo, date: Date(),
            locale: Locale.current, timeZone: TimeZone.current)
        log("On-device Anisette is valid (no remote Anisette server used)")
        return (data, newBlob)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "GetMoreRam.OnDeviceAnisette", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func installLibraries(at destination: URL) async throws {
        // SideStore's default on-device ADI metadata; no account credentials are sent here.
        let metadataURL = URL(string: "https://zzz.haus/oda.json")!
        let (metadata, response) = try await URLSession.shared.data(from: metadataURL)
        let info = try ServerResponseDecoder.dictionary(from: metadata, response: response, format: .json)
        guard let payload = info["l"] as? String, let expectedHash = info["s"] as? String else {
            throw failure("On-device library metadata is missing its payload or SHA-256 checksum.")
        }
        let archiveData: Data
        if let url = URL(string: payload), url.scheme == "https" {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw failure("On-device ADI library download failed.")
            }
            archiveData = data
        } else if let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) {
            archiveData = data
        } else {
            throw failure("On-device ADI library metadata has an invalid payload.")
        }
        let actualHash = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        // The current SideStore metadata advertises a stale checksum. Accept only
        // its advertised hash or the exact archive verified during this integration.
        let knownArchiveHash = "a2f9aeef4cc31efda69ecdceeadd0f1bbd04199e6339b880636c14a3ecba2b96"
        guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame || actualHash == knownArchiveHash else {
            throw failure("On-device ADI library checksum does not match. Try setup again later.")
        }
        let staging = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = try Archive(data: archiveData, accessMode: .read)
        for name in required {
            let entries = archive.filter { $0.type == .file && URL(fileURLWithPath: $0.path).lastPathComponent == name }
            guard entries.count == 1, let entry = entries.first, entry.uncompressedSize <= 64_000_000 else {
                throw failure("On-device ADI archive is missing a required library: \(name)")
            }
            _ = try archive.extract(entry, to: staging.appendingPathComponent(name))
        }
        guard AnisetteClient.validateLibrariesExist(at: staging) else {
            throw failure("On-device ADI libraries could not be installed.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}
