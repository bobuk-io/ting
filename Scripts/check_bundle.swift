#!/usr/bin/env swift
import Foundation

// Read-only release validation. This never launches Ting and never reads the user's config.
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("Bundle check failed: \(message)\n", stderr); exit(1) }
}
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift Scripts/check_bundle.swift /path/to/Ting.app\n", stderr)
    exit(1)
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard let app = Bundle(url: appURL), let resources = app.resourceURL, let info = app.infoDictionary else {
    fputs("Bundle check failed: app bundle is missing or unreadable\n", stderr)
    exit(1)
}
func string(_ key: String) -> String? { info[key] as? String }

require(app.bundleIdentifier == "io.bobuk.ting", "unexpected bundle identifier")
require(string("CFBundleExecutable") == "Ting", "unexpected executable name")
require(info["LSUIElement"] as? Bool == true, "Ting must be a menu-bar app (LSUIElement)")
require(string("LSMinimumSystemVersion") == "14.0", "unexpected minimum macOS version")

// The version must match version.env next to the scripts.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
if let env = try? String(contentsOf: root.appendingPathComponent("version.env"), encoding: .utf8) {
    var values: [String: String] = [:]
    for line in env.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { values[parts[0]] = parts[1] }
    }
    require(string("CFBundleShortVersionString") == values["MARKETING_VERSION"], "marketing version differs from version.env")
    require(string("CFBundleVersion") == values["BUILD_NUMBER"], "build number differs from version.env")
}

// App icon.
require(string("CFBundleIconFile") == "Icon", "unexpected app icon reference")
guard let icon = try? Data(contentsOf: resources.appendingPathComponent("Icon.icns")) else {
    fputs("Bundle check failed: app icon is missing\n", stderr)
    exit(1)
}
require(icon.count > 8 && icon.prefix(4) == Data("icns".utf8), "invalid ICNS icon")

// Sparkle: feed, key and the embedded framework.
require(string("SUFeedURL") == "https://github.com/bobuk-io/ting/releases/latest/download/appcast.xml", "unexpected Sparkle feed URL")
require(string("SUPublicEDKey") == "AJCnH5OGe+uet2nuKtN2kzn5nxrCHoGo85K6b3OabA4=", "unexpected Sparkle public key")
let sparkle = appURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
require(Bundle(url: sparkle)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "2.10.1",
        "Sparkle 2.10.1 framework is missing")

// License texts ship with every binary.
for notice in ["LICENSE", "THIRD_PARTY_NOTICES.md"] {
    require(FileManager.default.fileExists(atPath: resources.appendingPathComponent(notice).path), "\(notice) is missing")
}
print("BUNDLE_CHECK_PASSED: \(string("CFBundleShortVersionString") ?? "?") (\(string("CFBundleVersion") ?? "?"))")
