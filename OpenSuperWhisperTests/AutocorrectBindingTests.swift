import XCTest
@testable import OpenSuperWhisper

/// The app links `libautocorrect_swift.dylib`, which `run.sh` builds from the
/// `autocorrect-swift` binding and the AutoCorrect library in the
/// `asian-autocorrect` submodule. These tests call it through the wrapper
/// dictation uses, so a build that drops the library, breaks its C interface,
/// or changes how AutoCorrect spaces mixed text fails here. The expected text
/// is what AutoCorrect 2.14.3 returns.
final class AutocorrectBindingTests: XCTestCase {
    func testLibraryIsLinkedAndAnswers() {
        XCTAssertTrue(AutocorrectWrapper.isAvailable())
    }

    func testSpacesChineseJapaneseAndKoreanAroundLatinTextAndNumbers() {
        XCTAssertEqual(AutocorrectWrapper.format("你好world"), "你好 world")
        XCTAssertEqual(
            AutocorrectWrapper.format("今天是2024年5月1日,天气很好."),
            "今天是 2024 年 5 月 1 日，天气很好。"
        )
        XCTAssertEqual(
            AutocorrectWrapper.format("こんにちはWorld、今日はいい天気ですね"),
            "こんにちは World、今日はいい天気ですね"
        )
        XCTAssertEqual(AutocorrectWrapper.format("한국어English혼합 텍스트"), "한국어 English 혼합 텍스트")
    }

    func testLeavesPlainEnglishAndEmptyTextUnchanged() {
        let english = "Hello, world! This is plain English with no CJK text at all."
        XCTAssertEqual(AutocorrectWrapper.format(english), english)
        XCTAssertEqual(AutocorrectWrapper.format(""), "")
    }

    func testKeepsLineBreaksAndSurroundingSpaces() {
        XCTAssertEqual(
            AutocorrectWrapper.format("第一行text\n第二行more text\n\n第三段English混合"),
            "第一行 text\n第二行 more text\n\n第三段 English 混合"
        )
        XCTAssertEqual(AutocorrectWrapper.format("   前后有空格的text   "), "   前后有空格的 text   ")
    }

    func testFormatsForAFileType() {
        XCTAssertEqual(AutocorrectWrapper.format("你好world", for: "dictation.md"), "你好 world")
    }
}
