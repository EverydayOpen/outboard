import XCTest
@testable import OutboardCore

/// The line the sheet offers for pasting into a shell. What a POSIX shell would do with it is the point, so each odd drive name is checked
/// by its text: the whole path is one single-quoted word, and the only way out of the quote is a `'` written as `'\''`.
final class EnvLineTests: XCTestCase {
    private func sheet(_ recipeID: String, driveName: String) -> ConsentSheet {
        let r = T.recipe(recipeID)
        let d = T.drive(name: driveName)
        let report = Eligibility.evaluate(volume: d, recipe: r, source: SourceNeeds(logicalBytes: 1_000_000_000, isCaseSensitive: .no), policy: .release)
        return ConsentSheetText.sheet(recipe: r, scan: T.scan(recipeID, bytes: 1_000_000_000), drive: T.volumeRef(name: d.name), mountPoint: d.mountPoint,
                                      report: report, free: 45_000_000_000, unverified: true)
    }

    func testTheLineQuotesTheMountPointLikeAShell() {
        let cases: [(name: String, expected: String)] = [
            ("Backup SSD", #"export OLLAMA_MODELS='/Volumes/Backup SSD/Outboard/ollama-models/models'"#),
            (#"x"; touch /tmp/pwned; ""#, #"export OLLAMA_MODELS='/Volumes/x"; touch /tmp/pwned; "/Outboard/ollama-models/models'"#),
            ("$(touch /tmp/pwned)", #"export OLLAMA_MODELS='/Volumes/$(touch /tmp/pwned)/Outboard/ollama-models/models'"#),
            ("`touch /tmp/pwned`", #"export OLLAMA_MODELS='/Volumes/`touch /tmp/pwned`/Outboard/ollama-models/models'"#),
            ("Ann's SSD", #"export OLLAMA_MODELS='/Volumes/Ann'\''s SSD/Outboard/ollama-models/models'"#),
            ("'; touch /tmp/pwned; '", #"export OLLAMA_MODELS='/Volumes/'\''; touch /tmp/pwned; '\''/Outboard/ollama-models/models'"#),
        ]
        for c in cases {
            XCTAssertEqual(sheet("ollama-models", driveName: c.name).envLine, c.expected, c.name)
        }
    }

    func testTheGuidedCardQuotesTheSameWay() {
        let card = GuidedText.card(recipe: T.recipe("android-sdk"), drive: nil, driveName: "Ann's SSD")
        XCTAssertEqual(card.envLine, #"export ANDROID_HOME='/Volumes/Ann'\''s SSD/Outboard/android-sdk/sdk'"#)
        let real = GuidedText.card(recipe: T.recipe("android-sdk"), drive: nil, driveName: "Name", mountPoint: "/Volumes/Name 1")
        XCTAssertEqual(real.envLine, "export ANDROID_HOME='/Volumes/Name 1/Outboard/android-sdk/sdk'", "the real mount point wins over the name")
    }

    func testALineWithAControlCharacterIsNotPrintedAndTheSheetSaysSo() {
        for name in ["two\nlines", "tab\there", "bell\u{07}", "escape\u{1B}[31m", "right\u{202E}left", "line\u{2028}sep"] {
            let s = sheet("ollama-models", driveName: name)
            XCTAssertNil(s.envLine, name)
            XCTAssertTrue(s.warnings.contains(EnvLine.setYourself), name)
            let card = GuidedText.card(recipe: T.recipe("android-sdk"), drive: nil, driveName: name)
            XCTAssertNil(card.envLine, name)
            XCTAssertTrue(card.notes.contains(EnvLine.setYourself), name)
        }
        XCTAssertEqual(BannedPhrases.hits(in: EnvLine.setYourself), [])
        XCTAssertNil(EnvLine.render("no placeholder here", mountPoint: "/Volumes/X", recipeID: "r"))
    }

    func testARecipeLineNeverQuotesThePlaceholderItself() {
        for r in Catalogue.all {
            guard let line = r.envLine else { continue }
            XCTAssertFalse(line.contains("\"") || line.contains("'"), r.id)
            XCTAssertNotNil(EnvLine.render(line, mountPoint: "/Volumes/Outboard", recipeID: r.id), r.id)
        }
    }
}
