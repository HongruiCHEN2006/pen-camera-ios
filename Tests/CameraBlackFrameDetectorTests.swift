import UIKit
import XCTest
@testable import PenCamera

final class CameraBlackFrameDetectorTests: XCTestCase {
    func testNearBlackFrameAndBrightFrame() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let dark = renderer.jpegData(withCompressionQuality: 0.8) { context in
            UIColor(white: 0.015, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let light = renderer.jpegData(withCompressionQuality: 0.8) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let coveredLens = renderer.jpegData(withCompressionQuality: 0.8) { context in
            UIColor(white: 19.0 / 255.0, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }

        XCTAssertEqual(CameraBlackFrameDetector.isBlack(dark), true)
        XCTAssertEqual(CameraBlackFrameDetector.isBlack(coveredLens), true)
        XCTAssertEqual(CameraBlackFrameDetector.isBlack(light), false)
        XCTAssertNil(CameraBlackFrameDetector.isBlack(Data([0, 1, 2])))
    }
}
