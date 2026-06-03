import XCTest
@testable import Vagalume

final class BrightnessMathTests: XCTestCase {
    func testBrightnessClamping() {
        XCTAssertEqual(BrightnessMath.clampedBrightness(-0.5), 0)
        XCTAssertEqual(BrightnessMath.clampedBrightness(0.42), 0.42)
        XCTAssertEqual(BrightnessMath.clampedBrightness(1.4), 1)
    }

    func testMaxNitsClampedToConfigurableBounds() {
        XCTAssertEqual(BrightnessMath.clampedMaxNits(10), BrightnessMath.minConfigurableNits)
        XCTAssertEqual(BrightnessMath.clampedMaxNits(9_999), BrightnessMath.maxConfigurableNits)
        XCTAssertEqual(BrightnessMath.clampedMaxNits(450), 450)
    }

    func testNativeHardwareUsesFullRangeWithoutFloor() {
        // Native panels keep dimming in hardware all the way down (no frozen
        // floor), which is what removes the "step" that used to appear at 20%.
        XCTAssertEqual(BrightnessMath.hardwareBrightness(forRequestedBrightness: 0, kind: .native), 0)
        XCTAssertEqual(BrightnessMath.hardwareBrightness(forRequestedBrightness: 0.1, kind: .native), 0.1)
        XCTAssertEqual(BrightnessMath.hardwareBrightness(forRequestedBrightness: 0.8, kind: .native), 0.8)
    }

    func testNativeSubZeroOverlayIsSmoothAndTangentAtThreshold() {
        let threshold = BrightnessMath.nativeSubZeroThreshold
        // No overlay above the threshold; exactly zero at it (tangent, no step).
        XCTAssertEqual(BrightnessMath.overlayOpacity(forRequestedBrightness: threshold + 0.1, kind: .native), 0)
        XCTAssertEqual(BrightnessMath.overlayOpacity(forRequestedBrightness: threshold, kind: .native), 0)
        // Below the threshold it ramps up to allow going darker than the floor.
        XCTAssertEqual(BrightnessMath.overlayOpacity(forRequestedBrightness: 0, kind: .native), BrightnessMath.maxSoftwareDimOpacity)
        let justBelow = BrightnessMath.overlayOpacity(forRequestedBrightness: threshold - 0.001, kind: .native)
        XCTAssertGreaterThan(justBelow, 0)
        XCTAssertLessThan(justBelow, 0.01) // quadratic: very small right below the knee
    }

    func testDDCHardwareBrightnessNeverDropsBelowFloor() {
        XCTAssertEqual(BrightnessMath.hardwareBrightness(forRequestedBrightness: 0, kind: .ddc), BrightnessMath.ddcDimmingFloor)
        XCTAssertEqual(BrightnessMath.hardwareBrightness(forRequestedBrightness: 0.05, kind: .ddc), BrightnessMath.ddcDimmingFloor)
        XCTAssertEqual(BrightnessMath.hardwareBrightness(forRequestedBrightness: 0.8, kind: .ddc), 0.8)
    }

    func testDDCSubZeroOverlayOnlyAppliesBelowFloor() {
        XCTAssertEqual(BrightnessMath.overlayOpacity(forRequestedBrightness: 0.2, kind: .ddc), 0)
        XCTAssertEqual(BrightnessMath.overlayOpacity(forRequestedBrightness: 1, kind: .ddc), 0)
        XCTAssertEqual(BrightnessMath.overlayOpacity(forRequestedBrightness: 0, kind: .ddc), BrightnessMath.maxSoftwareDimOpacity)
    }

    func testSoftwareOverlayDimsAcrossWholeRange() {
        XCTAssertEqual(BrightnessMath.overlayOpacity(forRequestedBrightness: 1, kind: .software), 0)
        XCTAssertEqual(BrightnessMath.overlayOpacity(forRequestedBrightness: 0, kind: .software), BrightnessMath.maxSoftwareDimOpacity)
        XCTAssertEqual(BrightnessMath.overlayOpacity(forRequestedBrightness: 0.5, kind: .software), 0.44, accuracy: 0.0001)
    }

    func testEstimatedNitsForNativeDisplays() {
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 500, brightness: 1, controlKind: .native), 500)
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 500, brightness: 0.5, controlKind: .native), 250)
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 500, brightness: 0, controlKind: .native), 0)
    }

    func testEstimatedNitsForSoftwareOnlyDisplays() {
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 350, brightness: 1, controlKind: .software), 350)
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 350, brightness: 0.5, controlKind: .software), 196)
        XCTAssertEqual(BrightnessMath.estimatedNits(maxNits: 350, brightness: 0, controlKind: .software), 42)
    }

    func testDDCValueScalesToReportedMaximum() {
        XCTAssertEqual(BrightnessMath.ddcValue(forHardwareBrightness: 1, ddcMax: 100), 100)
        XCTAssertEqual(BrightnessMath.ddcValue(forHardwareBrightness: 0.5, ddcMax: 100), 50)
        // A monitor whose VCP brightness maxes out at 255 must scale to 255, not 100.
        XCTAssertEqual(BrightnessMath.ddcValue(forHardwareBrightness: 1, ddcMax: 255), 255)
        XCTAssertEqual(BrightnessMath.ddcValue(forHardwareBrightness: 0.5, ddcMax: 255), 128)
        XCTAssertEqual(BrightnessMath.ddcValue(forHardwareBrightness: 2, ddcMax: 255), 255)
    }
}
