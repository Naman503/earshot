import XCTest
@testable import EarshotCore

final class TextPrepTests: XCTestCase {
    func testCleanRemovesURLsCitationsAndEmoji() {
        let s = TextPrep.clean("Read this[12] at https://x.com/a now 🚀.\n\n  Next   para ")
        XCTAssertEqual(s, "Read this at now.\nNext para")
    }

    func testChunksSplitSentencesAndKeepFirstShort() {
        let long = "This opening sentence is deliberately long, with several clauses, so that the first chunk has to be split early for a fast start. Short one."
        let chunks = TextPrep.chunks(long)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertLessThanOrEqual(chunks[0].count, 110)
        XCTAssertEqual(chunks.last, "Short one.")
    }

    func testSentenceAndParagraphUnits() {
        let text = "First one. Second one here.\nOther paragraph."
        XCTAssertEqual(TextUnits.substring(.sentence, in: text, at: 14), "Second one here.")
        XCTAssertEqual(TextUnits.substring(.paragraph, in: text, at: 2), "First one. Second one here.")
        XCTAssertEqual(TextUnits.substring(.fromHere, in: text, at: 14), "Second one here.\nOther paragraph.")
    }
}

final class TapRecognizerTests: XCTestCase {
    private func touch(_ n: Int, at t: Double, dx: CGFloat = 0) -> TapRecognizer.Frame {
        .init(time: t, points: (0..<n).map { CGPoint(x: 0.2 + CGFloat($0) * 0.1 + dx, y: 0.5) })
    }

    func testFourFingerTap() {
        var r = TapRecognizer()
        var out: [TrackpadTap] = []
        out += r.feed(touch(2, at: 0.00))
        out += r.feed(touch(4, at: 0.03))
        out += r.feed(touch(4, at: 0.10))
        out += r.feed(touch(0, at: 0.15))
        XCTAssertEqual(out, [TrackpadTap(fingers: 4, taps: 1)])
    }

    func testSwipeIsNotATap() {
        var r = TapRecognizer()
        var out = r.feed(touch(4, at: 0))
        out += r.feed(touch(4, at: 0.1, dx: 0.2))
        out += r.feed(touch(0, at: 0.2))
        XCTAssertTrue(out.isEmpty)
    }

    func testDoubleTapWaitsForSecondTap() {
        var r = TapRecognizer()
        r.multiTapFingers = [4]
        var out = r.feed(touch(4, at: 0)) + r.feed(touch(0, at: 0.1))
        XCTAssertTrue(out.isEmpty)
        out += r.feed(touch(4, at: 0.25)) + r.feed(touch(0, at: 0.32))
        XCTAssertEqual(out, [TrackpadTap(fingers: 4, taps: 2)])

        out = r.feed(touch(4, at: 1.0)) + r.feed(touch(0, at: 1.1))
        out += r.tick(now: 1.5)
        XCTAssertEqual(out, [TrackpadTap(fingers: 4, taps: 1)])
    }
}

final class OCRLayoutTests: XCTestCase {
    func testGroupsLinesIntoParagraphs() {
        let lines = [
            OCRLayout.Line(text: "Title", rect: CGRect(x: 10, y: 10, width: 200, height: 30)),
            OCRLayout.Line(text: "first line of a para-", rect: CGRect(x: 10, y: 60, width: 300, height: 16)),
            OCRLayout.Line(text: "graph continues", rect: CGRect(x: 10, y: 80, width: 280, height: 16)),
            OCRLayout.Line(text: "Second paragraph", rect: CGRect(x: 10, y: 130, width: 300, height: 16)),
        ]
        let blocks = OCRLayout.blocks(lines)
        XCTAssertEqual(blocks.map(\.text), ["Title", "first line of a paragraph continues", "Second paragraph"])
        XCTAssertEqual(OCRLayout.blockIndex(at: CGPoint(x: 50, y: 85), in: blocks), 1)
    }

    func testSpeedSplit() {
        XCTAssertEqual(speedSplit(1.0).model, 1.0)
        let s = speedSplit(2.0)
        XCTAssertEqual(s.model * s.stretch, 2.0, accuracy: 0.0001)
        XCTAssertEqual(s.model, 1.35)
    }
}

final class NotificationTests: XCTestCase {
    func testAppNameFromDescription() {
        XCTAssertEqual(BannerNote.appName(description: "Script Editor, Earshot test, From Rahul, Body", title: "Earshot test"), "Script Editor")
        XCTAssertEqual(BannerNote.appName(description: "WhatsApp, Rahul, hi", title: ""), "WhatsApp")
    }

    func testQuietHoursWrapMidnight() {
        XCTAssertTrue(inQuietHours(23, start: 22, end: 8))
        XCTAssertTrue(inQuietHours(3, start: 22, end: 8))
        XCTAssertFalse(inQuietHours(12, start: 22, end: 8))
        XCTAssertTrue(inQuietHours(13, start: 13, end: 14))
        XCTAssertFalse(inQuietHours(5, start: 0, end: 0))
    }
}
