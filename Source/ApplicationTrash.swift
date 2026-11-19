import AppKit
import Carbon

enum ApplicationTrash {
    // Finder reports afpAccessDenied for protected applications as well as POSIX permission errors.
    static func isPermissionError(_ error: NSError) -> Bool {
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
             (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)),
             (NSOSStatusErrorDomain, Int(permErr)), (NSOSStatusErrorDomain, Int(afpAccessDenied)):
            return true
        default:
            return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isPermissionError) ?? false
        }
    }

    static func isCancellation(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError) ||
        (error.domain == NSOSStatusErrorDomain && error.code == Int(userCanceledErr))
    }

    // Pass the directory and leaf name as data. Finder moves the selected entry itself,
    // including when it is a symlink, and owns any authorization dialog.
    static let finderScript = """
        on run argv
            set parentFolder to POSIX file (item 1 of argv) as alias
            set entryName to item 2 of argv
            try
                tell application id "com.apple.finder"
                    move item entryName of parentFolder to trash
                end tell
                return "0"
            on error reason number code
                return (code as text) & linefeed & reason
            end try
        end run
        """

    static func moveWithFinder(_ url: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", finderScript, url.deletingLastPathComponent().path, url.lastPathComponent]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let reply = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if task.terminationStatus == 0, reply == "0" { return }
        let parts = reply.split(separator: "\n", maxSplits: 1)
        let code = parts.first.flatMap { Int($0) } ?? Int(errAEEventFailed)
        let message = parts.count == 2 ? String(parts[1]) : "Finder не смог переместить приложение в Корзину."
        throw NSError(domain: NSOSStatusErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
