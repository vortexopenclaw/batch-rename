import XCTest
@testable import RenameCore

final class PresentationTests: XCTestCase {
    func testSuffixAndPrependRevealUnicodeAnchors() throws {
        let name = String(repeating: "long", count: 40) + "👩🏽‍💻e\u{301}.MP4"
        var op = RenameOperation(); op.text = " 🐈 added"
        let preview = try op.preview(name)
        let stem = String(name.dropLast(4))
        XCTAssertEqual(preview.sourceMatches, [NSRange(location: stem.utf16.count, length: 0)])
        XCTAssertEqual((preview.name as NSString).substring(with: RenamePresentation.revealRange(in: preview.name, changes: preview.replacements)), op.text)
        XCTAssertEqual((name as NSString).substring(with: RenamePresentation.revealRange(in: name, changes: preview.sourceMatches)), ".")
        op.action = .prepend
        let prefix = try op.preview(name)
        XCTAssertEqual(prefix.sourceMatches.first?.location, 0)
        XCTAssertEqual((prefix.name as NSString).substring(with: RenamePresentation.revealRange(in: prefix.name, changes: prefix.replacements)), op.text)
    }
    func testArbitraryReplacementAndDeletionRevealWithUnicode() throws {
        let name = "👩🏽‍💻" + String(repeating: "a", count: 90) + "e\u{301}TARGET" + String(repeating: "z", count: 90) + ".mp4"
        var op = RenameOperation(); op.action = .replace; op.search = "e\u{301}TARGET"; op.text = "🌊new"
        let p = try op.preview(name)
        XCTAssertEqual((name as NSString).substring(with: RenamePresentation.revealRange(in: name, changes: p.sourceMatches)), op.search)
        XCTAssertEqual((p.name as NSString).substring(with: RenamePresentation.revealRange(in: p.name, changes: p.replacements)), op.text)
        XCTAssertGreaterThan(p.sourceMatches[0].location, 90)
        op.text = ""
        let deleted = try op.preview(name)
        XCTAssertTrue(deleted.deletion)
        XCTAssertEqual((deleted.name as NSString).substring(with: RenamePresentation.revealRange(in: deleted.name, changes: deleted.replacements)), "z")
        XCTAssertEqual(RenamePresentation.revealRange(in: "👩🏽‍💻", changes: [NSRange(location: 7, length: 0)]), NSRange(location: 0, length: 7))
        XCTAssertEqual(RenamePresentation.revealRange(in: "", changes: [NSRange(location: 0, length: 0)]), NSRange(location: 0, length: 0))
    }
    func testCompletionWording() {
        XCTAssertEqual(RenamePresentation.completion(files: 8, folders: 0), "Renamed 8 files.")
        XCTAssertEqual(RenamePresentation.completion(files: 1, folders: 0), "Renamed 1 file.")
        XCTAssertEqual(RenamePresentation.completion(files: 0, folders: 1), "Renamed 1 folder.")
        XCTAssertEqual(RenamePresentation.completion(files: 2, folders: 3), "Renamed 2 files and 3 folders.")
        XCTAssertEqual(RenamePresentation.completion(files: 1, folders: 1), "Renamed 1 file and 1 folder.")
        XCTAssertEqual(RenamePresentation.completion(files: 0, folders: 0), "Renamed 0 files.")
    }
}
