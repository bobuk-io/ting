import Foundation
import Testing
@testable import TingCore

@Suite struct ConfigCodecTests {
    private func decode(_ json: String) throws -> Config { try ConfigCodec.decode(Data(json.utf8)) }

    @Test func defaults() throws {
        let c = try decode("{}")
        #expect(c == Config())
        #expect(c.version == 1)
        #expect(c.leader == nil)
        #expect(c.showDelay == 0.25)
        #expect(c.unknownKey == .shake)
        #expect(c.appearance == .dark)
        #expect(!c.launchAtLogin)
        #expect(c.showMenuBarIcon)
        #expect(c.showPanelHeader)
        #expect(c.playSound)
        #expect(c.items.isEmpty)
    }
    @Test func panelHeaderCompatibility() throws {
        #expect(try decode(#"{"leader":"home"}"#).showPanelHeader)
        #expect(try decode(#"{"showPanelHeader":true}"#).showPanelHeader)
        let hidden = try decode(#"{"showPanelHeader":false}"#)
        #expect(!hidden.showPanelHeader)
        #expect(try ConfigCodec.decode(ConfigCodec.encode(hidden)) == hidden)
    }
    @Test func exampleAndItemProperties() throws {
        let c = try decode(#"{"items":[{"key":"A","label":"Apps","items":[{"key":"s","app":"com.apple.Safari"},{"key":"g","label":"GitHub","url":"https://github.com","future":42}]}],"future":true}"#)
        let children: [Item] = [.app("s", "", "com.apple.Safari"), .url("g", "GitHub", "https://github.com")]
        #expect(c.items == [.group("a", "Apps", children)])
        #expect(c.items[0].isGroup)
        #expect(c.items[0].children == children)
        #expect(!children[0].isGroup)
        #expect(children[0].children == nil)
        #expect(!children[1].isGroup)
        #expect(children[1].children == nil)
    }
    @Test(arguments: [
        "not JSON", "[]", #"{"items":[{"key":"a"}]}"#,
        #"{"items":[{"key":"a","app":"x","url":"https://x"}]}"#,
        #"{"items":[{"key":"a","items":[],"app":"x"}]}"#,
        #"{"items":[{"key":"a","items":[],"url":"https://x"}]}"#,
        #"{"items":[{"key":"tab","app":"x"}]}"#,
        #"{"leader":"unknown"}"#, #"{"showDelay":"fast"}"#, #"{"showPanelHeader":"yes"}"#])
    func invalidFormat(_ json: String) {
        #expect(throws: (any Error).self) {
            do { _ = try decode(json) }
            catch ConfigError.invalidFormat { throw ConfigError.invalidFormat("expected") }
            catch { Issue.record("Expected invalidFormat, got \(error)") ; throw error }
        }
    }
    @Test func unsupportedVersion() {
        #expect(throws: ConfigError.unsupportedVersion(Config.currentVersion + 1)) {
            try decode("{\"version\":\(Config.currentVersion + 1)}")
        }
    }
    @Test(arguments: [-5.0, 0.0, 0.5, 2.0, 9.0]) func delayClamping(_ delay: Double) throws {
        #expect(try decode("{\"showDelay\":\(delay)}").showDelay == min(2, max(0, delay)))
    }
    @Test func encodingAndRoundTrips() throws {
        var full = Config()
        full.version = Config.currentVersion
        full.leader = .combo(keyCode: 3, modifiers: [.command, .option, .shift])
        full.showDelay = 1.75
        full.unknownKey = .close
        full.appearance = .light
        full.launchAtLogin = true
        full.showMenuBarIcon = false
        full.showPanelHeader = false
        full.playSound = false
        full.items = [.group("w", "Web", [.url("g", "GitHub", "https://github.com")]), .app("t", "Terminal", "com.apple.Terminal")]
        for c in [Config(), Config.sample, full] {
            let data = ConfigCodec.encode(c)
            #expect(try ConfigCodec.decode(data) == c)
            #expect(ConfigCodec.encode(c) == data)
            let text = String(decoding: data, as: UTF8.self)
            let rootKeys = ["appearance", "items", "launchAtLogin", "leader", "playSound", "showDelay", "showMenuBarIcon", "showPanelHeader", "unknownKey", "version"]
            let positions = rootKeys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
            #expect(positions == positions.sorted())
            #expect(text.hasSuffix("\n"))
            #expect(!text.contains("\\/"))
            #expect(text.contains("\n "))
        }
        let data = ConfigCodec.encode(full)
        #expect(String(decoding: data, as: UTF8.self).contains("https://github.com"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try #require(root["items"] as? [[String: Any]])
        #expect(Set(items[0].keys) == Set(["key", "label", "items"]))
        #expect(Set(items[1].keys) == Set(["key", "label", "app"]))
    }
    @Test func itemDecodingThrowsDataCorrupted() {
        for json in [#"{"key":"a"}"#, #"{"key":"ф","app":"x"}"#, #"{"key":"a","app":"x","url":"x"}"#] {
            do {
                _ = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
                Issue.record("Expected dataCorrupted")
            } catch DecodingError.dataCorrupted { } catch { Issue.record("Unexpected error: \(error)") }
        }
    }
    @Test func sample() {
        #expect(Config.sample.leader == nil)
        #expect(ConfigValidator.validate(Config.sample).map(\.kind) == [.missingLeader])
        #expect(Config.sample.items.contains { $0.key == "a" && $0.isGroup })
        #expect(Config.sample.items.contains { $0.key == "w" && $0.isGroup })
    }
}

@Suite struct ConfigValidatorTests {
    @Test func leaderIssues() {
        var c = Config()
        #expect(ConfigValidator.validate(c).map(\.kind) == [.missingLeader])
        #expect(ConfigValidator.validate(c).map(\.sequence) == [[]])
        c.leader = .modifierTap(.rightOption)
        #expect(ConfigValidator.validate(c).map(\.kind) == [.invalidLeader])
        #expect(ConfigValidator.validate(c).map(\.sequence) == [[]])
        c.leader = .combo(keyCode: 115, modifiers: [])
        #expect(ConfigValidator.validate(c).isEmpty)
    }
    @Test func depthFirstAndDuplicates() {
        var c = Config()
        c.leader = .combo(keyCode: 105, modifiers: [])
        c.items = [.group("a", "Apps", [.app("x", "Empty", ""), .url("y", "Bad", "relative/path"), .app("x", "Duplicate", "ok"), .app("x", "Third", "ok")]), .url("z", "Bad", "relative")]
        let issues = ConfigValidator.validate(c)
        #expect(issues.map(\.kind) == [.emptyTarget, .invalidURL, .duplicateKey, .duplicateKey, .invalidURL])
        #expect(issues.map(\.sequence) == [["a", "x"], ["a", "y"], ["a", "x"], ["a", "x"], ["z"]])
    }
    @Test func emptyURLAndValidSchemes() {
        var c = Config()
        c.leader = .combo(keyCode: 0, modifiers: [])
        c.items = [.url("a", "Empty", ""), .url("b", "Mail", "mailto:hello@example.com"), .url("c", "Web", "https://example.com")]
        #expect(ConfigValidator.validate(c).contains { $0.kind == .emptyTarget && $0.sequence == ["a"] })
        #expect(ConfigValidator.validate(c).allSatisfy { $0.sequence == ["a"] })
    }
}
