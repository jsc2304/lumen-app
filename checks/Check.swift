import Foundation
import CryptoKit

// Self-checks for pure logic. Each feature keeps its checks in checks/<Feature>.swift; run ./check.sh.

func expect(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL:", what); exit(1) }
}

@main
enum Check {
    static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen-all-checks-" + UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        Store.useForChecks(SecureStorage(root: root, key: { _ in key }))
        defer { try? FileManager.default.removeItem(at: root) }
        checkSecureStorage()
        checkLauncherHotkeys()
        checkCore()
        checkFoundation()
        checkSystem()
        checkWindows()
        checkNavigation()
        checkSnippets()
        checkQuicklinks()
        checkEmoji()
        checkClipboard()
        checkSchedule()
        checkMite()
        checkGitHub()
        checkAILimits()
        checkAIChat()
        checkCodex()
        checkAICommands()
        checkNotes()
        checkScripts()
        checkLookup()
        checkFiles()
        checkFocus()
        checkAppTools()
        print("check: ok")
    }
}
