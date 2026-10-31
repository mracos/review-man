import XCTest
@testable import PRReviewDesktop

final class DiffTextSizeTests: XCTestCase {

    func testStepsOnePointAndClampsToTheRange() {
        XCTAssertEqual(DiffTextSize.stepped(12, by: 1), 13)
        XCTAssertEqual(DiffTextSize.stepped(12, by: -1), 11)
        XCTAssertEqual(DiffTextSize.stepped(DiffTextSize.maximum, by: 1), DiffTextSize.maximum)
        XCTAssertEqual(DiffTextSize.stepped(DiffTextSize.minimum, by: -1), DiffTextSize.minimum)
    }

    func testDefaultSizeKeepsTheOriginalMetrics() {
        XCTAssertEqual(AppKitDiffLayoutMetrics.forFontSize(DiffTextSize.defaultSize), AppKitDiffLayoutMetrics.default)
    }

    func testMetricsScaleWithTheFont() {
        let metrics = AppKitDiffLayoutMetrics.forFontSize(18)

        XCTAssertEqual(metrics.lineHeight, 27)
        XCTAssertEqual(metrics.characterWidth, 10.8, accuracy: 0.001)
        XCTAssertEqual(metrics.fontSize, 18)
    }
}
