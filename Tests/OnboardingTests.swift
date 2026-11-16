import SwiftUI
import XCTest
@testable import Notestrand

@MainActor
final class OnboardingTests: XCTestCase {
    func testKeyRejectionDistinguishesCredentialsFromAvailability() {
        for code in [400, 401, 403] {
            XCTAssertTrue(OnboardingView.keyRejected(LLMError.http(code, "rejected")))
        }
        for code in [402, 429, 500, 503] {
            XCTAssertFalse(OnboardingView.keyRejected(LLMError.http(code, "unavailable")))
        }
        XCTAssertFalse(OnboardingView.keyRejected(URLError(.notConnectedToInternet)))
        XCTAssertFalse(OnboardingView.keyRejected(URLError(.timedOut)))
    }

    func testWelcomeLogoStaysCenteredInWideAndTallFrames() {
        for size in [CGSize(width: 88, height: 88), CGSize(width: 160, height: 88), CGSize(width: 88, height: 160)] {
            let frame = CGRect(origin: .zero, size: size)
            let path = NStrand().path(in: frame)
            let bounds = path.boundingRect
            XCTAssertFalse(path.isEmpty)
            XCTAssertTrue(frame.contains(bounds))
            XCTAssertEqual(bounds.midX, frame.midX, accuracy: 0.01)
            XCTAssertEqual(bounds.midY, frame.midY, accuracy: 0.01)
        }
    }
}
