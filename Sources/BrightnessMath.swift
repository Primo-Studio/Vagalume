import Foundation

/// Central place for every tunable constant and brightness/dimming computation.
/// Keeping these here (instead of scattered literals) makes the behaviour easy to
/// audit and adjust, and lets the math be unit-tested in isolation.
enum BrightnessMath {
    // MARK: Tunables

    /// Below this requested brightness a DDC display stops dimming in hardware
    /// (many external panels flicker or cut out near zero) and a software overlay
    /// takes over for "sub-zero" dimming.
    static let ddcDimmingFloor = 0.2

    /// Requested brightness below which native displays add a soft overlay to go
    /// darker than the hardware minimum ("sub-zero"). The overlay ramps in with a
    /// curve that is tangent to zero at the threshold, so there is no visible
    /// step where it starts — the hardware keeps dimming smoothly the whole time.
    static let nativeSubZeroThreshold = 0.2

    /// Maximum opacity of the black dimming overlay. Never fully opaque so the
    /// cursor and content stay faintly visible.
    static let maxSoftwareDimOpacity = 0.88

    /// Default peak-luminance estimates used until the user edits them.
    static let defaultBuiltInMaxNits = 500.0
    static let defaultExternalMaxNits = 300.0

    /// Bounds for the user-editable max-nits value.
    static let minConfigurableNits = 80.0
    static let maxConfigurableNits = 2_000.0
    static let maxNitsStep = 50.0

    /// Brightness step applied per brightness-key press.
    static let keyboardStep = 0.05

    /// Quick presets shown in the footer row.
    static let presets: [Double] = [0.05, 0.2, 0.5, 1.0]

    /// Raw DDC scale assumed when a display does not report its VCP maximum.
    static let fallbackDDCMaxValue = 100.0

    // MARK: Clamping

    static func clampedBrightness(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    static func clampedMaxNits(_ value: Double) -> Double {
        min(max(value, minConfigurableNits), maxConfigurableNits)
    }

    private static func clamped01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func clampedOpacity(_ value: Double) -> Double {
        min(max(value, 0), maxSoftwareDimOpacity)
    }

    // MARK: Per-display dimming model

    /// Requested brightness below which the hardware stops dimming for a given
    /// control kind. Native displays keep dimming in hardware all the way down
    /// (DisplayServices handles the whole range), so they have no floor — the
    /// "step" that used to appear at 20% is gone. DDC keeps a floor because many
    /// external panels cut out near zero.
    static func hardwareFloor(for kind: BrightnessControlKind) -> Double {
        switch kind {
        case .ddc:
            return ddcDimmingFloor
        case .native, .software, .unsupported:
            return 0
        }
    }

    /// Hardware brightness (0...1) to send to the panel for a requested value.
    static func hardwareBrightness(forRequestedBrightness value: Double, kind: BrightnessControlKind) -> Double {
        let brightness = clampedBrightness(value)
        let floor = hardwareFloor(for: kind)
        return brightness <= floor ? floor : brightness
    }

    /// Opacity (0...maxSoftwareDimOpacity) of the black overlay used to dim below
    /// what the hardware can reach (native/DDC sub-zero) or to dim software-only
    /// displays. The native ramp is quadratic and tangent to zero at the
    /// threshold, so dimming stays smooth — no step where the overlay engages.
    static func overlayOpacity(forRequestedBrightness value: Double, kind: BrightnessControlKind) -> Double {
        let brightness = clampedBrightness(value)

        switch kind {
        case .software:
            return clampedOpacity((1 - brightness) * maxSoftwareDimOpacity)
        case .ddc:
            guard brightness < ddcDimmingFloor else { return 0 }
            return clampedOpacity((1 - brightness / ddcDimmingFloor) * maxSoftwareDimOpacity)
        case .native:
            guard brightness < nativeSubZeroThreshold else { return 0 }
            let progress = (nativeSubZeroThreshold - brightness) / nativeSubZeroThreshold
            return clampedOpacity(progress * progress * maxSoftwareDimOpacity)
        case .unsupported:
            return 0
        }
    }

    /// Perceived brightness factor (0...1) after hardware + overlay, used to
    /// estimate the nits a display is currently emitting.
    static func perceivedFactor(forRequestedBrightness value: Double, kind: BrightnessControlKind) -> Double {
        switch kind {
        case .software:
            return clamped01(1 - overlayOpacity(forRequestedBrightness: value, kind: .software))
        case .unsupported:
            return clampedBrightness(value)
        case .native, .ddc:
            let hardware = hardwareBrightness(forRequestedBrightness: value, kind: kind)
            let opacity = overlayOpacity(forRequestedBrightness: value, kind: kind)
            return clamped01(hardware * (1 - opacity))
        }
    }

    static func estimatedNits(maxNits: Double, brightness: Double, controlKind: BrightnessControlKind) -> Int {
        let factor = perceivedFactor(forRequestedBrightness: brightness, kind: controlKind)
        return Int((maxNits * factor).rounded())
    }

    /// Converts a normalized brightness (0...1) into a raw DDC value for the
    /// display's reported VCP maximum.
    static func ddcValue(forHardwareBrightness value: Double, ddcMax: Double) -> UInt16 {
        let max = Swift.max(ddcMax, 1)
        let scaled = (clamped01(value) * max).rounded()
        return UInt16(min(Swift.max(scaled, 0), max))
    }
}
