#!/usr/bin/env swift
import Foundation

// Scan every regular file in the final app, including every universal-binary
// slice. This is intentionally separate from runtime code and never reads user
// data. Only file names and issue categories are reported, never contents.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift Scripts/check_release_privacy.swift /path/to/Ting.app\n", stderr)
    exit(1)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
      let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
    fputs("Privacy check failed: app directory is missing.\n", stderr)
    exit(1)
}
let blockedPaths = ["/Users/", "/home/", "/private/var/folders/", "/var/folders/",
                    FileManager.default.homeDirectoryForCurrentUser.path + "/"]
let needles = blockedPaths.map { Data($0.utf8) }
var scanned = 0
var issues: [String] = []
do {
    for case let file as URL in enumerator {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        scanned += 1
        let name = file.lastPathComponent
        if name == ".env" || name.hasPrefix(".env.") || ["p8", "p12", "mobileprovision"].contains(file.pathExtension) {
            issues.append("private configuration/key file: \(name)")
        }
        let data = try Data(contentsOf: file)
        if needles.contains(where: { data.range(of: $0) != nil }) {
            issues.append("local build/home path in: \(name)")
        }
    }
} catch {
    fputs("Privacy check failed: unable to read all app files.\n", stderr)
    exit(1)
}
guard scanned > 0, issues.isEmpty else {
    for issue in issues { fputs("Privacy check failed: \(issue)\n", stderr) }
    if scanned == 0 { fputs("Privacy check failed: app directory is empty.\n", stderr) }
    exit(1)
}
print("PRIVACY_CHECK_PASSED: \(scanned) app files")
