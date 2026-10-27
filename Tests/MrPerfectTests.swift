import XCTest
@testable import MrPerfect

final class MrPerfectTests: XCTestCase {
    func testFitToSelectionKeepsSurroundingWhitespaceAndStripsTags() {
        XCTAssertEqual(fitToSelection("  <text>\nHello there.\n</text>\n", original: " hi there\n"), " Hello there.\n")
        XCTAssertEqual(fitToSelection("Hello", original: "hi"), "Hello")
    }

    func testClaudeParseSkipsThinkingBlocks() throws {
        let body = #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"Better."}]}"#
        XCTAssertEqual(try Claude.parse(Data(body.utf8), status: 200), "Better.")
    }

    func testClaudeParseErrors() {
        let refusal = #"{"stop_reason":"refusal","content":[]}"#
        XCTAssertThrowsError(try Claude.parse(Data(refusal.utf8), status: 200))
        let bad = #"{"type":"error","error":{"type":"invalid_request_error","message":"nope"}}"#
        XCTAssertThrowsError(try Claude.parse(Data(bad.utf8), status: 400)) {
            XCTAssertEqual($0.localizedDescription, "Claude error (400): nope")
        }
    }

    func testGemmaParse() throws {
        XCTAssertEqual(try Gemma.parse(Data(#"{"message":{"role":"assistant","content":"Ok."}}"#.utf8), status: 200), "Ok.")
        XCTAssertThrowsError(try Gemma.parse(Data(#"{"error":"model 'x' not found"}"#.utf8), status: 404))
    }

    func testSelectionButtonSitsLeftOfFirstCharacter() {
        // First character at x=100, top y=200 (AX, top-left origin), 16pt tall, on a 1000pt-tall primary screen.
        let f = SelectionButton.buttonFrame(forFirstCharacter: CGRect(x: 100, y: 200, width: 8, height: 16), primaryHeight: 1000)
        XCTAssertEqual(f, NSRect(x: 76, y: 782, width: 20, height: 20))  // 1000 - 208 (line centre) - 10
    }

    func testPanelHangsUnderSelectionAndFlipsNearScreenBottom() {
        // Selection: first line top at y=300 (AX), 16pt lines, two lines tall, on a 1000pt primary screen.
        let a = Selection.anchorRect(first: CGRect(x: 100, y: 300, width: 8, height: 16),
                                     all: CGRect(x: 100, y: 300, width: 300, height: 32), primaryHeight: 1000)
        XCTAssertEqual(a, NSRect(x: 76, y: 668, width: 1, height: 32))
        let screen = NSRect(x: 0, y: 0, width: 1400, height: 1000)
        XCTAssertEqual(KeyPanel.origin(size: NSSize(width: 200, height: 60), anchor: a, visible: screen), NSPoint(x: 76, y: 602))
        let low = NSRect(x: 76, y: 40, width: 1, height: 16)
        XCTAssertEqual(KeyPanel.origin(size: NSSize(width: 200, height: 60), anchor: low, visible: screen), NSPoint(x: 76, y: 62))
    }

    func testTranslationGoesSpanishToEnglishOtherwiseToSpanish() {
        XCTAssertEqual(Action.translationTarget("¿Puedes mover la reunión al jueves? Gracias."), "English")
        XCTAssertEqual(Action.translationTarget("hola, nos vemos mañana"), "English")
        XCTAssertEqual(Action.translationTarget("Can we move the meeting to Thursday? Thanks."), "Spanish")
        XCTAssertEqual(Action.translationTarget("see you tomorrow"), "Spanish")
        XCTAssertEqual(Action.translate.title(for: "buenos días a todos"), "Translate to English")
    }

    func testGuessedButtonFromGesture() {
        // Drag left-to-right on one line: button left of where the drag started.
        XCTAssertEqual(SelectionButton.guessedFrame(down: NSPoint(x: 100, y: 500), up: NSPoint(x: 300, y: 502), clicks: 1),
                       NSRect(x: 76, y: 490, width: 20, height: 20))
        // Drag upward over lines: the selection starts at the higher point (the mouse-up).
        XCTAssertEqual(SelectionButton.guessedFrame(down: NSPoint(x: 300, y: 400), up: NSPoint(x: 120, y: 460), clicks: 1)?.origin,
                       NSPoint(x: 96, y: 450))
        // Double-click: just under the click. A plain click: no button.
        XCTAssertEqual(SelectionButton.guessedFrame(down: NSPoint(x: 200, y: 300), up: NSPoint(x: 200, y: 300), clicks: 2),
                       NSRect(x: 190, y: 270, width: 20, height: 20))
        XCTAssertNil(SelectionButton.guessedFrame(down: NSPoint(x: 200, y: 300), up: NSPoint(x: 203, y: 300), clicks: 1))
    }

    func testMenuOrderIsFixed() {
        XCTAssertEqual(Action.allCases, [.prompt, .message, .translate, .custom])  // ↩, 2, 3, 4
    }

    func testInstructionIsSentSeparatelyFromTheText() {
        XCTAssertEqual(wrap("hi", instruction: "more formal"), "<instruction>\nmore formal\n</instruction>\n<text>\nhi\n</text>")
        XCTAssertEqual(wrap("hi"), "<text>\nhi\n</text>")
    }
}
