import Foundation
import UIKit

/// ULID (26 Crockford base32 characters: 48-bit millisecond time + 80 random bits), used as the
/// `clientId` of every outgoing message.
enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func make(date: Date = Date()) -> String {
        var generator = SystemRandomNumberGenerator()
        return make(date: date, using: &generator)
    }

    static func make<G: RandomNumberGenerator>(date: Date, using generator: inout G) -> String {
        let millis = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var chars: [Character] = []
        chars.reserveCapacity(26)
        for i in stride(from: 9, through: 0, by: -1) {
            chars.append(alphabet[Int((millis >> (UInt64(i) * 5)) & 0x1F)])
        }
        for _ in 0..<16 {
            chars.append(alphabet[Int(generator.next() & 0x1F)])
        }
        return String(chars)
    }

    static func isValid(_ value: String) -> Bool {
        value.count == 26 && value.allSatisfy { alphabet.contains($0) }
    }
}

/// Reads claims from an identity JWT without verifying it (the server verifies). Used only to
/// spot a user switch so the previous user's local state can be cleared.
enum JWTClaims {
    static func userID(from token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let string = object["user_id"] as? String, !string.isEmpty { return string }
        if let number = object["user_id"] as? NSNumber { return number.stringValue }
        return nil
    }
}

/// Input validation for PROTOCOL §2 limits.
enum Validation {
    static let messageTextLimit = 4000
    static let attachmentsPerMessage = 5
    static let maxImageBytes = 1024 * 1024
    static let maxImagePixels: CGFloat = 2048
    static let maxFileBytes = 10 * 1024 * 1024

    private static let identifierCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")

    /// 1–64 characters of `[A-Za-z0-9_.-]`, used for metadata keys, paywall IDs and event names.
    static func isIdentifier(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { identifierCharacters.contains($0) }
    }

    static func utf16Length(_ value: String) -> Int { value.utf16.count }

    static func metadata(_ input: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in input.keys.sorted() {
            guard let value = input[key] else { continue }
            guard isIdentifier(key) else {
                Log.error("Metadata key is invalid (1–64 characters of A–Z, a–z, 0–9, _ . -); it was left out.")
                continue
            }
            guard value.count <= 512 else {
                Log.error("Metadata value for key \(key) is over 512 characters; it was left out.")
                continue
            }
            guard result.count < 30 else {
                Log.error("Metadata has more than 30 entries; extra keys were left out.")
                break
            }
            result[key] = value
        }
        return result
    }

    static func paywalls(_ input: [SupportPaywall]) -> [SupportPaywall] {
        var seen = Set<String>()
        var result: [SupportPaywall] = []
        for var paywall in input {
            paywall.id = paywall.id.trimmingCharacters(in: .whitespacesAndNewlines)
            paywall.title = paywall.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isIdentifier(paywall.id), (1...60).contains(paywall.title.count) else {
                Log.error("Paywall \"\(paywall.id)\" is invalid (id: 1–64 of A–Z a–z 0–9 _ . -, title: 1–60 characters); it was left out.")
                continue
            }
            guard seen.insert(paywall.id).inserted else { continue }
            guard result.count < 20 else {
                Log.error("More than 20 paywalls; the rest were left out.")
                break
            }
            result.append(paywall)
        }
        return result
    }

    static func clipped(_ value: String?, max: Int, field: String) -> String? {
        guard let value else { return nil }
        guard value.count <= max else {
            Log.error("\(field) is over \(max) characters; it was left out.")
            return nil
        }
        return value
    }
}

/// What the SDK reports about the device in `register` and `PATCH /device`.
enum DeviceInfoProvider {
    @MainActor
    static func current(language: String) -> DeviceInfo {
        let bundle = Bundle.main
        return DeviceInfo(
            model: modelIdentifier(),
            osVersion: UIDevice.current.systemVersion,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            bundleId: bundle.bundleIdentifier,
            locale: Locale.current.identifier,
            language: language,
            timeZone: TimeZone.current.identifier
        )
    }

    static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Resolves `PushEnvironment.automatic` from the embedded provisioning profile.
enum ProvisioningProfile {
    static func resolve(_ environment: PushEnvironment, profileURL: URL? = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")) -> String? {
        switch environment {
        case .sandbox: return "sandbox"
        case .production: return "production"
        case .automatic:
            #if targetEnvironment(simulator)
            return "sandbox"
            #else
            guard let profileURL else { return "production" }
            guard let data = try? Data(contentsOf: profileURL) else { return nil }
            return apsEnvironment(fromProfile: data)
            #endif
        }
    }

    /// Extracts `Entitlements.aps-environment` from a CMS-wrapped provisioning profile and maps it
    /// to `sandbox` / `production`.
    static func apsEnvironment(fromProfile data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        switch entitlements["aps-environment"] as? String {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil // push isn't enabled for this profile
        }
    }
}

extension Data {
    /// Lowercase hexadecimal, as APNs tokens are sent to the server.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
