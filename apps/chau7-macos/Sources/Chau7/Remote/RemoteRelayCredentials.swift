import Foundation
import Darwin
import Chau7Core

/// The separate owner-only provisioned credential bundle; never pairing state.
struct RemoteRelayCredentials: Codable, Equatable {
    let deviceID: String
    let keyID: String
    let macSecret: String
    let iosSecret: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case keyID = "key_id"
        case macSecret = "mac_secret"
        case iosSecret = "ios_secret"
    }

    func isValid(for deviceID: String) -> Bool {
        self.deviceID == deviceID && RelayToken.isValidIdentifier(deviceID, maximum: 128)
            && RelayToken.isValidIdentifier(keyID, maximum: 32)
            && RelayToken.isStrongCredential(macSecret) && RelayToken.isStrongCredential(iosSecret)
            && macSecret != iosSecret
    }

    static func load(from url: URL, deviceID: String) throws -> Self {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw provisioningError }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFREG,
              [mode_t(0o600), mode_t(0o400)].contains(metadata.st_mode & 0o777),
              metadata.st_size >= 0, metadata.st_size <= 8192,
              let data = try file.read(upToCount: 8193), data.count <= 8192,
              let credentials = try? JSONDecoder().decode(Self.self, from: data),
              credentials.isValid(for: deviceID) else { throw provisioningError }
        return credentials
    }

    private static var provisioningError: NSError {
        NSError(domain: "Chau7.RemoteCredentials", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Remote needs an owner-only credential file matching this Mac. Run chau7-remote identity, then chau7-remote provision --bundle <file> --state <state.json>."])
    }
}
