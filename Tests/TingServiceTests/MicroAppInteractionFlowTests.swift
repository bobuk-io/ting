@testable import TingRuntime
import AppKit
import XCTest
import TingCore
@testable import Ting

@MainActor
final class MicroAppInteractionFlowTests: XCTestCase {
    private func flow(_ steps: String) throws -> MicroAppFlowController {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ting-interaction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let catalog = MicroAppCatalog.load([("dialog.yaml", "format: ting.microapp/2\ndescription: Dialog.\ninput: none\nsteps:\n" + steps + "\noutput:\n  to: [panel, clipboard]\n")])
        let entry = try XCTUnwrap(catalog.entries.first)
        XCTAssertEqual(entry.issues, [])
        let approvals = MicroAppApprovalStore(url: directory.appendingPathComponent("approvals.json"))
        try approvals.approve(id: "dialog", hash: entry.contentHash)
        let pasteboard = NSPasteboard(name: .init("io.bobuk.ting.tests." + UUID().uuidString))
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        pasteboard.setString("unchanged", forType: .string)
        var runner = MicroAppRunner()
        runner.path = { "/usr/bin:/bin" }
        runner.environment = [:]
        let flow = MicroAppFlowController(approvals: approvals,
            values: MicroAppValueStore(url: directory.appendingPathComponent("values.json")),
            runner: runner, pasteboard: pasteboard, presentsWindow: false)
        addTeardownBlock { @MainActor in flow.close() }
        flow.setCatalog(catalog)
        flow.start(id: "dialog")
        return flow
    }

    private func waitForQuestion(_ flow: MicroAppFlowController) async throws -> MicroAppInteractionModel {
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if case .interaction = flow.session.state, let model = flow.session.interaction { return model }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw XCTUnwrapFailure()
    }

    private struct XCTUnwrapFailure: Error {}

    func testAskThenChooseThenResultWithoutShowingAWindow() async throws {
        let flow = try flow("""
          - ask: Topic
            id: topic
          - text: |
              One
              Two
          - choose: Pick ${steps.topic}
          - text: ${steps.topic}|${input}
        """)
        let ask = try await waitForQuestion(flow)
        flow.handle(.enter)
        XCTAssertNotNil(ask.error)
        XCTAssertNotNil(flow.session.interaction)
        ask.text = "hello"
        flow.handle(.enter)
        let choose = try await waitForQuestion(flow)
        XCTAssertEqual(choose.request.prompt, "Pick hello")
        XCTAssertTrue(flow.flowPanel?.choosing == true)
        flow.handle(.down)
        flow.handle(.enter)
        let end = Date().addingTimeInterval(3)
        while case .working = flow.session.state, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        guard case .result(let content) = flow.session.state else { return XCTFail("no result") }
        XCTAssertEqual(content.text, "hello|Two")
        XCTAssertNil(flow.session.interaction)
        XCTAssertFalse(try XCTUnwrap(flow.flowPanel).isVisible)
    }

    func testEscapeCancelsAndDoesNotLeakAnOldAnswerIntoNewRun() async throws {
        let flow = try flow("  - ask: Answer\n  - text: should not run\n")
        _ = try await waitForQuestion(flow)
        flow.handle(.escape)
        XCTAssertEqual(flow.session.state, .closed)
        XCTAssertNil(flow.session.interaction)
        flow.start(id: "dialog")
        let next = try await waitForQuestion(flow)
        XCTAssertEqual(next.text, "")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(flow.session.interaction === next)
        flow.close()
    }

    func testMultilineDefaultsAndChoiceFiltering() async throws {
        let flow = try flow("  - ask: Notes\n    multiline: true\n    default: Initial\n    required: false\n")
        let model = try await waitForQuestion(flow)
        XCTAssertEqual(model.text, "Initial")
        XCTAssertTrue(flow.flowPanel?.multilineInput == true)
        model.text = "line one\nline two"
        flow.handle(.commandEnter)
        let choices = MicroAppInteractionModel(.choose(prompt: "Pick", choices: [
            .init(id: 0, title: "Report", subtitle: "PDF", value: "path"),
            .init(id: 1, title: "Question", value: "q")]))
        XCTAssertEqual(choices.filteredChoices.map(\.value), ["path", "q"])
        choices.query = "pdf"
        XCTAssertEqual(choices.filteredChoices.map(\.value), ["path"])
        choices.query = "missing"
        XCTAssertNil(choices.selectedID)
        XCTAssertNil(choices.answer())
        choices.query = ""
        XCTAssertEqual(choices.filteredChoices.map(\.value), ["path", "q"])
        choices.move(1)
        XCTAssertEqual(choices.answer(), "q")
    }
}
