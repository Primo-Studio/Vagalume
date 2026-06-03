import AppKit
import CoreGraphics
import Foundation

enum BrightnessControlKind: String {
    case native = "macOS"
    case ddc = "DDC/CI"
    case software = "Logiciel"
    case unsupported = "Non pris en charge"

    var isControllable: Bool {
        self != .unsupported
    }
}

/// Represents a connected display with its properties.
struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let persistentID: String
    let name: String
    let isBuiltIn: Bool
    var brightness: Double
    var controlKind: BrightnessControlKind
    var lastWriteFailed: Bool
    var isSoftwareDimmed: Bool
    var maxNits: Double

    var maxBrightness: Double { 1.0 }
    var minBrightness: Double { 0.0 }
    var isControllable: Bool { controlKind.isControllable }

    /// Human-readable brightness percentage
    var brightnessPercent: Int {
        Int((brightness * 100).rounded())
    }

    static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension NSScreen {
    /// Resolves the `NSScreen` backing a Core Graphics display ID, or nil if the
    /// display is no longer attached.
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }

            return number.uint32Value == displayID
        }
    }
}
