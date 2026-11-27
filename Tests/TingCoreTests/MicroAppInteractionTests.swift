import XCTest
import TingCore

final class MicroAppInteractionTests: XCTestCase {
    func testLinesPreserveValuesAndDuplicateIdentity() throws {
        let choices = try MicroAppInteraction.choices(from: " /tmp/a b \r\n\nYes\nYes\n")
        XCTAssertEqual(choices.map(\.value), [" /tmp/a b ", "Yes", "Yes"])
        XCTAssertEqual(choices.map(\.id), [0, 1, 2])
    }

    func testJSONAndInvalidLists() throws {
        let choices = try MicroAppInteraction.choices(from: #"[{"title":"Report","subtitle":"PDF","value":"/tmp/report.pdf"},"Other"]"#)
        XCTAssertEqual(choices.first?.subtitle, "PDF")
        XCTAssertEqual(choices.first?.value, "/tmp/report.pdf")
        for input in ["", " \n", "[]", "[broken", "{}", "[4]", #"[{"title":"x"}]"#, #"[{"title":"x","value":3}]"#] {
            XCTAssertThrowsError(try MicroAppInteraction.choices(from: input), input)
        }
        let request = MicroAppInteraction.choose(prompt: "Pick", choices: choices)
        XCTAssertEqual(try request.validate("/tmp/report.pdf"), "/tmp/report.pdf")
        XCTAssertThrowsError(try request.validate("Report"))
    }

    func testRequiredAndOptionalText() throws {
        let required = MicroAppInteraction.ask(prompt: "Text", defaultValue: "", placeholder: "", multiline: true, required: true)
        XCTAssertThrowsError(try required.validate(" \n"))
        XCTAssertEqual(try required.validate(" a\nb "), " a\nb ")
        let optional = MicroAppInteraction.ask(prompt: "Text", defaultValue: "", placeholder: "", multiline: false, required: false)
        XCTAssertEqual(try optional.validate(""), "")
    }

    func testCheckerValidatesNewStepsAndTemplates() throws {
        let source = """
        format: ting.microapp/2
        description: Interactive example.
        input: none
        steps:
          - ask: Topic
            id: topic
            placeholder: A topic
            multiline: true
            required: false
          - ask: More about ${steps.topic}
            default: ${input}
          - choose: Pick one
          - choose: Pick a snippet
            details: true
        """
        let app = try MicroAppChecker.check(source, fileName: "test.yaml").get()
        XCTAssertEqual(app.steps.map(\.kind), [.ask, .ask, .choose, .choose])
        guard case .ask(let ask) = app.steps[0].action else { return XCTFail("not ask") }
        XCTAssertTrue(ask.multiline)
        XCTAssertFalse(ask.required)
        guard case .choose(_, let plain) = app.steps[2].action, case .choose(_, let details) = app.steps[3].action else {
            return XCTFail("not choose")
        }
        XCTAssertFalse(plain)
        XCTAssertTrue(details)
        for invalid in [source.replacingOccurrences(of: "multiline: true", with: "multiline: yes"),
                        source.replacingOccurrences(of: "details: true", with: "details: yes"),
                        source.replacingOccurrences(of: "choose: Pick one", with: "choose: Pick one\n    default: x"),
                        source.replacingOccurrences(of: "required: false", with: "required: false\n    stream: true")] {
            guard case .failure = MicroAppChecker.check(invalid, fileName: "test.yaml") else {
                return XCTFail("accepted invalid step")
            }
        }
    }

    func testFilterChoicesRanksTitleMatchesAboveSubtitleMatches() {
        let choices = [
            MicroAppInteraction.Choice(id: 0, title: "missy:remote",
                                       subtitle: "Ghostty · Put base on a machine over SSH, or update it",
                                       value: "remote"),
            MicroAppInteraction.Choice(id: 1, title: "missy:update",
                                       subtitle: "Fast-forward base and each installed layer",
                                       value: "update"),
            MicroAppInteraction.Choice(id: 2, title: "alpha:other",
                                       subtitle: "Match up tasks",
                                       value: "other"),
        ]

        // Word-start match in title beats word-start match in subtitle, even when subtitle appeared first.
        XCTAssertEqual(MicroAppInteraction.filterChoices(choices, matching: "upd").map(\.value), ["update", "remote"])

        // Fuzzy title match ("m u" -> "missy:update") beats subtitle word-start ("Match up").
        XCTAssertEqual(MicroAppInteraction.filterChoices(choices, matching: "m u").map(\.value).first, "update")

        // Subtitle-only matches still work when no title matches.
        XCTAssertEqual(MicroAppInteraction.filterChoices(choices, matching: "Ghostty").map(\.value), ["remote"])

        // Empty or punctuation-only query preserves original order.
        XCTAssertEqual(MicroAppInteraction.filterChoices(choices, matching: "").map(\.value), ["remote", "update", "other"])
        XCTAssertEqual(MicroAppInteraction.filterChoices(choices, matching: "   ").map(\.value), ["remote", "update", "other"])
    }

    func testFilterChoicesSubtitleMatchBeatsTypoOnlyTitleMatch() {
        let choices = [
            MicroAppInteraction.Choice(id: 0, title: "bosh", subtitle: "Quick view", value: "bosh"),
            MicroAppInteraction.Choice(id: 1, title: "shell", subtitle: "Run bash script", value: "shell"),
        ]
        // "bash" is a real word in subtitle ("shell") vs a 1-typo match in title ("bosh").
        XCTAssertEqual(MicroAppInteraction.filterChoices(choices, matching: "bash").map(\.value), ["shell", "bosh"])
    }

    func testFilterChoicesSupportsThreeLetterTypoFallback() {
        let choices = [
            MicroAppInteraction.Choice(id: 0, title: "deploy", subtitle: "Ship release", value: "deploy"),
            MicroAppInteraction.Choice(id: 1, title: "status", subtitle: "Check health", value: "status"),
        ]
        XCTAssertEqual(MicroAppInteraction.filterChoices(choices, matching: "dpx").map(\.value), ["deploy"])
    }
}
