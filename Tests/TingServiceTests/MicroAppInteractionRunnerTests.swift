@testable import TingRuntime
import Foundation
import XCTest
import TingCore

final class MicroAppInteractionRunnerTests: XCTestCase {
    private func app(_ steps: String) throws -> MicroApp {
        try MicroAppChecker.check("format: ting.microapp/2\ndescription: d\ninput: none\nsteps:\n" + steps,
                                  fileName: "interactive.yaml").get()
    }

    private func runner() -> MicroAppRunner {
        var runner = MicroAppRunner()
        runner.path = { "/usr/bin:/bin" }
        runner.environment = [:]
        return runner
    }

    func testAnswersFlowAndTemplatesRender() async throws {
        let app = try app("""
          - text: seed
          - ask: First
            default: ${input}
            placeholder: A hint
            id: answer
          - text: '[{"title":"Report","value":"/tmp/a b"}]'
          - choose: Pick ${steps.answer}
            id: file
            details: true
          - text: ${steps.answer}|${steps.file}|${input}
        """)
        var runner = runner()
        runner.interact = { request in
            switch request {
            case .ask(let prompt, let initial, let placeholder, let multiline, let required):
                XCTAssertEqual(prompt, "First")
                XCTAssertEqual(initial, "seed")
                XCTAssertEqual(placeholder, "A hint")
                XCTAssertFalse(multiline)
                XCTAssertTrue(required)
                return "hello"
            case .preview: XCTFail("unexpected preview"); return ""
            case .choose(let prompt, let choices, let details):
                XCTAssertEqual(prompt, "Pick hello")
                XCTAssertTrue(details)
                return choices[0].value
            }
        }
        let result = await runner.run(app)
        guard case .success(let output) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(output.stdout, "hello|/tmp/a b|/tmp/a b")
    }

    func testPreviewPreservesInputAndAllowsCancellation() async throws {
        let flow = try app("  - text: hello\n  - preview: markdown\n  - command: cat\n    stream: true")
        var runner = runner()
        runner.interact = { request in
            XCTAssertEqual(request, .preview(text: "hello", style: .markdown)); return "ignore this answer"
        }
        guard case .success(let result) = await runner.run(flow) else { return XCTFail("preview failed") }
        XCTAssertEqual(result.stdout, "hello")
        runner.interact = { _ in throw CancellationError() }
        guard case .cancelled = await runner.run(flow) else { return XCTFail("not cancelled") }
    }

    func testWaitingDoesNotConsumeBudgetAndStreamingStartsAfterAnswer() async throws {
        let app = try app("""
          - ask: Answer
            timeout: 1
          - command: cat
            stream: true
        """)
        var runner = runner()
        runner.timeLimit = 0.15
        runner.interact = { _ in
            try await Task.sleep(for: .milliseconds(300))
            return "answer"
        }
        let result = await runner.run(app)
        guard case .success(let output) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(output.stdout, "answer")
    }

    func testCancellationStopsLaterSteps() async throws {
        let app = try app("  - ask: Answer\n  - text: should not run\n")
        var runner = runner()
        runner.interact = { _ in throw CancellationError() }
        let result = await runner.run(app)
        guard case .cancelled = result else { return XCTFail("\(result)") }
    }

    func testBadAnswersEmptyListsAndMissingFrontendFail() async throws {
        let asking = try app("  - ask: Answer\n")
        let missing = await runner().run(asking)
        guard case .stepFailed = missing else { return XCTFail("\(missing)") }
        var runner = runner()
        runner.interact = { _ in "" }
        let empty = await runner.run(asking)
        guard case .stepFailed = empty else { return XCTFail("\(empty)") }
        runner.interact = { _ in XCTFail("must not ask for an empty list"); return "" }
        let choices = try app("  - choose: Pick\n")
        let result = await runner.run(choices)
        guard case .stepFailed(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(failure.output.stderr.contains("No options"))
    }

    func testNestedLibraryWaitPausesOuterAndInnerBudgets() async throws {
        let libraries = MicroAppLibraries([.init(name: "dialog", file: "libs/dialog.yaml", text: """
        format: ting.microlib/1
        description: Ask in a library.
        steps:
          - ask: Answer
          - command: cat
        """)])
        let app = try MicroAppChecker.check("""
        format: ting.microapp/2
        description: Nested dialog.
        input: none
        steps:
          - call: dialog
            timeout: 1
          - command: cat
            stream: true
        """, fileName: "nested.yaml", libraries: libraries).get()
        var runner = runner()
        runner.timeLimit = 0.2
        runner.interact = { _ in try await Task.sleep(for: .milliseconds(350)); return "nested" }
        let result = await runner.run(app)
        guard case .success(let output) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(output.stdout, "nested")
    }

    func testExecutionAfterAQuestionStillTimesOut() async throws {
        let app = try app("  - ask: Answer\n  - command: sleep 2\n")
        var runner = runner()
        runner.timeLimit = 0.1
        runner.interact = { _ in try await Task.sleep(for: .milliseconds(150)); return "ok" }
        let result = await runner.run(app)
        guard case .timeout = result else { return XCTFail("\(result)") }
    }

    func testCLIRejectsInteractionsBeforeAnyEffects() throws {
        let app = try app("  - command: echo must-not-run\n  - ask: Answer\n")
        XCTAssertThrowsError(try MicroAppCLI.validate(.init(file: "interactive.yaml"), app: app))
    }
}
