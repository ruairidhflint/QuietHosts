import Foundation
import Security
import Testing
@testable import QuietHostsCore

@Suite("XPC code-signing requirements")
struct CodeSigningTests {
    @Test("Requirement strings parse (a malformed one would crash NSXPCConnection)")
    func parses() {
        for id in [HelperConstants.appBundleIdentifier, HelperConstants.helperBundleIdentifier] {
            var requirement: SecRequirement?
            let text = CodeSigningIdentity.requirement(identifier: id, teamIdentifier: "ABCDE12345")
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            #expect(text.contains("get-task-allow"))
        }
    }

    @Test("Only well-formed team identifiers are accepted")
    func teamIdentifier() {
        #expect(CodeSigningIdentity.isPlausibleTeamIdentifier("ABCDE12345"))
        #expect(!CodeSigningIdentity.isPlausibleTeamIdentifier("ABCDE1234"))
        #expect(!CodeSigningIdentity.isPlausibleTeamIdentifier("abcde12345"))
        #expect(!CodeSigningIdentity.isPlausibleTeamIdentifier("ABCDE\"2345"))
    }
}
