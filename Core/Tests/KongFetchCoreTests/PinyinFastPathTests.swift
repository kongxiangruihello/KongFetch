import XCTest
@testable import KongFetchCore
import KongFetchLegacy32
import KongFetchTestSupport

/// The per-character pinyin path must give exactly what transliterating the
/// whole name gives (3.2's method), for every kind of name.
final class PinyinFastPathTests: XCTestCase {
    static let han = Array("合同年度报告讲稿论语思想史课程会议纪要草稿发票照片重庆音乐银行长沙学生名单期末考试教案申报书明清读书笔记行乐长朝厦门的了是不我一有在人这中大为上个国和地到以说时要就出会可也你对生能而子那得于着下自之过发后作里用道鑫燚龘丨乂亍㐀䶵")
    static let ascii = Array("abcxyzABCXYZ0123456789")
    static let neutral = Array(" _-.,()[]{}#@&+~!'%$=^")
    static let latin = Array("éüßÀçñ")
    static let cjkPunctuation = Array("、，。（）【】《》—…·「」：；！？")
    static let fullwidth = Array("ＡＢｃ１２＿")
    static let otherScripts = Array("あいカナ한글Жλ🎉")

    func testFastPathMatchesWholeNameTransform() {
        var random = SeededRandom(seed: 2026)
        var names: [String] = []
        let pools: [[Character]] = [Self.han, Self.han, Self.han, Self.ascii, Self.neutral, Self.latin, Self.cjkPunctuation, Self.fullwidth, Self.otherScripts]
        for _ in 0..<6000 {
            let length = 1 + random.below(12)
            var name = ""
            for _ in 0..<length {
                let pool = random.pick(pools)
                name.append(random.pick(pool))
            }
            names.append(name)
        }
        for a in SyntheticTree.chineseWords {
            for b in SyntheticTree.chineseWords + SyntheticTree.englishWords {
                names += [a + b, a + " " + b, a + "_" + b + " 2024", b + a, a + "（" + b + "）", "2024" + a + "v2"]
            }
        }
        names += ["银行流水", "行长讲话", "重新整理", "重量", "长沙", "长大了", "音乐会", "快乐", "朝阳区", "厦门大学", "乐乐的音乐", "合同abc", "abc合同", "合同2024", "2024合同", "合同.pdf", "合 同", "合  同"]
        let report = Pinyin.verifyFastPath(names)
        XCTAssertTrue(report.mismatches.isEmpty, "\(report.mismatches.count) mismatches:\n" + report.mismatches.prefix(20).joined(separator: "\n"))
        XCTAssertGreaterThan(report.namesWithCJK, 5000)
        // Names with kana, hangul, CJK punctuation and so on fall back to the slow path.
        XCTAssertLessThan(report.slowPathNames, report.namesWithCJK)
    }

    func testFormsStillMatch32() {
        for name in ["合同", "银行流水 2024", "重庆火锅", "朝阳区地图", "论语（草稿）", "hello", "ニュース合同", "한글 합동"] {
            XCTAssertEqual(Pinyin.forms(name), pinyinForms(name), name)
            XCTAssertEqual(Pinyin.slowForms(name), pinyinForms(name), name)
        }
    }
}
