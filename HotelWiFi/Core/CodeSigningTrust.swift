import Foundation
import Security
import CryptoKit

/// The local edition trusts only its own dedicated certificate, never all self-signed software.
/// Installing the certificate into the system trust store is neither necessary nor performed.
public struct CodeSigningTrust: Equatable, Sendable {
    public enum Kind: String, Sendable { case developerTeam, localCertificate }
    public let kind: Kind
    public let value: String
    public init?(team: String?, certificateSHA1: String?, certificateName: String?) {
        if let team, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil {
            kind = .developerTeam; value = team
        } else if let hash = certificateSHA1, certificateName?.hasPrefix("HotelWiFi Local ") == true,
                  hash.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil {
            kind = .localCertificate; value = hash.lowercased()
        } else { return nil }
    }
    public func requirement(identifiers: [String]) -> String? {
        let allowed = Set(["com.hotelwifi.app", "com.hotelwifi.cli", "com.hotelwifi.helper"])
        guard !identifiers.isEmpty, identifiers.allSatisfy(allowed.contains) else { return nil }
        let anchor = kind == .developerTeam ? "anchor apple generic and certificate leaf[subject.OU] = \"\(value)\"" : "anchor = H\"\(value)\""
        return anchor + " and (" + identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ") + ")"
    }
    public static func current() -> Self? {
        var code: SecCode?; var staticCode: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        let certificates = d[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let cert = certificates?.first
        let fingerprint = cert.map { Insecure.SHA1.hash(data: SecCertificateCopyData($0) as Data).hex }
        let name = cert.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        guard let trust = Self(team: d[kSecCodeInfoTeamIdentifier as String] as? String, certificateSHA1: fingerprint, certificateName: name),
              let identifier = d[kSecCodeInfoIdentifier as String] as? String,
              let source = trust.requirement(identifiers: [identifier]) else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess else { return nil }
        return trust
    }
    public static func hasLocationEntitlement() -> Bool {
        var code: SecCode?; var staticCode: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any], let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return (entitlements["com.apple.security.personal-information.location"] as? Bool) == true
    }
    public var description: String { kind == .localCertificate ? "本机专用证书签名；XPC 双向证书固定" : "Apple 团队签名；XPC 双向团队校验" }
}
