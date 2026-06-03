import AppKit
import AppleSiliconDDC
import CoreGraphics
import Foundation
import IOKit
import IOKit.i2c

private let displayServicesLib: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
}()

private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

private let displayServicesSetBrightness: SetBrightnessFn? = {
    guard let lib = displayServicesLib,
          let symbol = dlsym(lib, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(symbol, to: SetBrightnessFn.self)
}()

private let displayServicesGetBrightness: GetBrightnessFn? = {
    guard let lib = displayServicesLib,
          let symbol = dlsym(lib, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(symbol, to: GetBrightnessFn.self)
}()

private let ddcBrightnessCommand: UInt8 = 0x10

@MainActor
final class BrightnessManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var optionHotkeysEnabled = false
    @Published var functionHotkeysEnabled = false
    @Published var brightnessKeyMode: BrightnessKeyMode = .disabled
    @Published var lastErrorMessage: String?
    @Published var isEnabled: Bool

    private let defaults = UserDefaults.standard
    private let prefsKey = "BrightBar.DisplayBrightness.v2"
    private let nitsPrefsKey = "BrightBar.DisplayMaxNits.v1"
    private let enabledPrefsKey = "BrightBar.Enabled.v1"
    private let hotkeyStep = BrightnessMath.keyboardStep
    private var dimmingWindows: [CGDirectDisplayID: NSWindow] = [:]
    private var pendingKeyboardDelta = 0.0
    private var keyboardAdjustmentTask: Task<Void, Never>?
    private var appleSiliconDDCServices: [CGDirectDisplayID: AppleSiliconDDC.IOregService] = [:]
    private var screenParametersObserver: NSObjectProtocol?
    private var displayRefreshTask: Task<Void, Never>?
    /// Raw DDC maximum (VCP feature limit) reported per display, used to scale
    /// brightness writes instead of assuming a fixed 0-100 range.
    private var ddcMaxValues: [CGDirectDisplayID: Double] = [:]
    /// Last DDC brightness known to have been accepted by the display. Slider
    /// changes are optimistic while the I2C write is pending, but failures roll
    /// back to this value instead of persisting a value the monitor rejected.
    private var ddcConfirmedBrightness: [CGDirectDisplayID: Double] = [:]
    /// Latest requested DDC value per display, flushed on a timer so dragging a
    /// slider does not flood the (slow) I2C bus and stutter.
    private var pendingDDCWrites: [CGDirectDisplayID: PendingDDCWrite] = [:]
    private var ddcFlushTask: Task<Void, Never>?

    var averageBrightness: Double {
        let controllable = displays.filter(\.isControllable)
        guard !controllable.isEmpty else { return 0.5 }
        let total = controllable.reduce(0.0) { $0 + $1.brightness }
        return total / Double(controllable.count)
    }

    var averageBrightnessPercent: Int {
        Int((averageBrightness * 100).rounded())
    }

    var hasSoftwareOnlyDisplays: Bool {
        displays.contains { $0.controlKind == .software }
    }

    var statusSummary: String {
        let controllable = displays.filter(\.isControllable).count
        let total = displays.count

        if total == 0 {
            return "Aucun ecran"
        }

        if controllable == total {
            return "\(total) ecran\(total > 1 ? "s" : "") controle\(total > 1 ? "s" : "")"
        }

        return "\(controllable)/\(total) ecrans controles"
    }

    init() {
        isEnabled = defaults.object(forKey: enabledPrefsKey) as? Bool ?? true
        refreshDisplays()
        let hotkeyStatus = HotkeyManager.shared.register { [weak self] isUp in
            Task { @MainActor in
                guard let self else { return }
                self.queueKeyboardAdjustment(isUp: isUp)
            }
        }
        optionHotkeysEnabled = hotkeyStatus.optionHotkeys
        functionHotkeysEnabled = hotkeyStatus.functionHotkeys
        brightnessKeyMode = hotkeyStatus.brightnessKeyMode
        if !isEnabled {
            setEnabled(false)
        }
        observeScreenParameterChanges()
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    /// Keeps the display list and dimming overlays in sync when monitors are
    /// connected, disconnected, rearranged, rescaled, or after the Mac wakes.
    private func observeScreenParameterChanges() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleDisplayRefresh()
            }
        }
    }

    /// Coalesces the bursts of notifications macOS posts during a single
    /// reconfiguration into one refresh, avoiding redundant DDC writes.
    private func scheduleDisplayRefresh() {
        displayRefreshTask?.cancel()
        displayRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            displayRefreshTask = nil
            refreshDisplays()
        }
    }

    func refreshKeyboardHooks() {
        guard isEnabled else {
            optionHotkeysEnabled = false
            functionHotkeysEnabled = false
            brightnessKeyMode = .disabled
            return
        }

        let hotkeyStatus = HotkeyManager.shared.setEnabled(true)
        optionHotkeysEnabled = hotkeyStatus.optionHotkeys
        functionHotkeysEnabled = hotkeyStatus.functionHotkeys
        brightnessKeyMode = hotkeyStatus.brightnessKeyMode
    }

    func requestKeyboardPermission() {
        guard isEnabled else { return }

        let hotkeyStatus = HotkeyManager.shared.requestAccessibilityPermission()
        optionHotkeysEnabled = hotkeyStatus.optionHotkeys
        functionHotkeysEnabled = hotkeyStatus.functionHotkeys
        brightnessKeyMode = hotkeyStatus.brightnessKeyMode
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: enabledPrefsKey)

        if enabled {
            refreshKeyboardHooks()
            reapplyCurrentBrightness()
        } else {
            cancelPendingKeyboardAdjustment()
            cancelPendingDDCWrites()
            let hotkeyStatus = HotkeyManager.shared.setEnabled(false)
            optionHotkeysEnabled = hotkeyStatus.optionHotkeys
            functionHotkeysEnabled = hotkeyStatus.functionHotkeys
            brightnessKeyMode = hotkeyStatus.brightnessKeyMode
            closeAllSoftwareDimming()
            lastErrorMessage = nil
        }
    }

    func refreshDisplays() {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        let result = CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount)

        guard result == .success else {
            lastErrorMessage = "Impossible de lire la liste des ecrans."
            displays = []
            return
        }

        let activeDisplayIDs = Set(displayIDs.prefix(Int(displayCount)))
        for staleID in Array(dimmingWindows.keys) where !activeDisplayIDs.contains(staleID) {
            closeSoftwareDimming(for: staleID)
        }
        for staleID in Array(ddcMaxValues.keys) where !activeDisplayIDs.contains(staleID) {
            ddcMaxValues.removeValue(forKey: staleID)
            ddcConfirmedBrightness.removeValue(forKey: staleID)
            pendingDDCWrites.removeValue(forKey: staleID)
        }

        var nextDisplays: [DisplayInfo] = []
        var savedValuesToApply: [(CGDirectDisplayID, Double)] = []
        appleSiliconDDCServices = Self.appleSiliconDDCServices(for: Array(displayIDs.prefix(Int(displayCount))))

        for displayID in displayIDs.prefix(Int(displayCount)) {
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let persistentID = Self.persistentDisplayID(for: displayID)
            let name = Self.displayName(for: displayID)
            let loadedBrightness = loadBrightness(for: persistentID)
            let current = readBrightness(for: displayID, isBuiltIn: isBuiltIn)
            let brightness = loadedBrightness ?? current.value ?? 0.5
            let maxNits = loadMaxNits(for: persistentID) ?? defaultMaxNits(isBuiltIn: isBuiltIn)
            let clampedBrightness = BrightnessMath.clampedBrightness(brightness)

            if current.kind == .ddc {
                ddcConfirmedBrightness[displayID] = BrightnessMath.clampedBrightness(current.value ?? clampedBrightness)
            }

            nextDisplays.append(
                DisplayInfo(
                    id: displayID,
                    persistentID: persistentID,
                    name: name,
                    isBuiltIn: isBuiltIn,
                    brightness: clampedBrightness,
                    controlKind: current.kind,
                    lastWriteFailed: false,
                    isSoftwareDimmed: dimmingWindows[displayID]?.isVisible == true,
                    maxNits: maxNits
                )
            )

            // Re-apply on detection for saved displays (restore the user's value)
            // and for software-only displays (so the dimming overlay matches the
            // brightness shown in the UI instead of leaving the screen undimmed).
            if loadedBrightness != nil || current.kind == .software {
                savedValuesToApply.append((displayID, clampedBrightness))
            }
        }

        displays = nextDisplays
        lastErrorMessage = nil

        for (displayID, value) in savedValuesToApply {
            setBrightness(for: displayID, to: value)
        }
    }

    /// Absolute set used by presets: every controllable display jumps to `value`.
    func setAllBrightness(to value: Double) {
        guard isEnabled else { return }

        for display in displays where display.isControllable {
            setBrightness(for: display.id, to: value)
        }
    }

    /// Relative move used by the global slider: shifts every controllable display
    /// by the same delta so each keeps its own offset instead of all snapping to
    /// the average (which caused a visible jump when grabbing the slider).
    func adjustAllBrightness(by delta: Double) {
        guard isEnabled else { return }

        for display in displays where display.isControllable {
            setBrightness(for: display.id, to: display.brightness + delta)
        }
    }

    private func queueKeyboardAdjustment(isUp: Bool) {
        guard isEnabled else { return }

        pendingKeyboardDelta += isUp ? hotkeyStep : -hotkeyStep

        guard keyboardAdjustmentTask == nil else { return }

        keyboardAdjustmentTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard !Task.isCancelled else { return }
            let delta = pendingKeyboardDelta
            pendingKeyboardDelta = 0
            keyboardAdjustmentTask = nil
            adjustAllBrightness(by: delta)
        }
    }

    func setMaxNits(for displayID: CGDirectDisplayID, to value: Double) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }

        let clamped = BrightnessMath.clampedMaxNits(value)
        var updatedDisplays = displays
        updatedDisplays[index].maxNits = clamped
        displays = updatedDisplays
        saveMaxNits(clamped, for: updatedDisplays[index].persistentID)
    }

    func setBrightness(for displayID: CGDirectDisplayID, to value: Double) {
        guard isEnabled else { return }
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        guard displays[index].isControllable else { return }

        let clamped = BrightnessMath.clampedBrightness(value)
        let display = displays[index]
        let hardwareValue = BrightnessMath.hardwareBrightness(forRequestedBrightness: clamped, kind: display.controlKind)
        let dimmingOpacity = BrightnessMath.overlayOpacity(forRequestedBrightness: clamped, kind: display.controlKind)
        let success: Bool

        switch display.controlKind {
        case .native:
            success = setBuiltInBrightness(displayID: displayID, value: hardwareValue)
        case .ddc:
            // Optimistic: queue the (slow) hardware write and trust it; the flush
            // confirms and saves it, or rolls back if the bus rejects the command.
            scheduleExternalBrightness(
                displayID: displayID,
                hardwareValue: hardwareValue,
                requestedBrightness: clamped,
                previousBrightness: ddcConfirmedBrightness[displayID] ?? display.brightness,
                persistentID: display.persistentID
            )
            success = true
        case .software:
            success = true
        case .unsupported:
            success = false
        }

        if success {
            setSoftwareDimming(for: displayID, opacity: dimmingOpacity)
            if display.controlKind != .ddc {
                saveBrightness(clamped, for: display.persistentID)
                lastErrorMessage = nil
            }
        } else {
            lastErrorMessage = "Impossible de regler \(display.name)."
        }

        var updatedDisplays = displays
        updatedDisplays[index].brightness = success ? clamped : display.brightness
        if display.controlKind != .ddc {
            updatedDisplays[index].lastWriteFailed = !success
        }
        updatedDisplays[index].isSoftwareDimmed = success && dimmingOpacity > 0
        displays = updatedDisplays
    }

    private func readBrightness(for displayID: CGDirectDisplayID, isBuiltIn: Bool) -> (value: Double?, kind: BrightnessControlKind) {
        if isBuiltIn {
            guard let getBrightness = displayServicesGetBrightness else {
                return (nil, .software)
            }

            var brightness: Float = 0.5
            guard getBrightness(displayID, &brightness) == kIOReturnSuccess else {
                return (nil, .native)
            }

            return (Double(brightness), .native)
        }

        if let service = appleSiliconDDCServices[displayID],
           let value = AppleSiliconDDC.read(service: service.service, command: ddcBrightnessCommand) {
            let maxValue = max(Double(value.max), 1)
            ddcMaxValues[displayID] = maxValue
            return (Double(value.current) / maxValue, .ddc)
        }

        guard let framebuffer = Self.framebufferPort(for: displayID) else {
            return (nil, .software)
        }
        IOObjectRelease(framebuffer)

        if let value = ddcRead(displayID: displayID, command: ddcBrightnessCommand) {
            let maxValue = max(Double(value.max), 1)
            ddcMaxValues[displayID] = maxValue
            return (Double(value.current) / maxValue, .ddc)
        }

        return (nil, .software)
    }

    private func setBuiltInBrightness(displayID: CGDirectDisplayID, value: Double) -> Bool {
        guard let setBrightness = displayServicesSetBrightness else { return false }
        return setBrightness(displayID, Float(value)) == kIOReturnSuccess
    }

    private func scheduleExternalBrightness(
        displayID: CGDirectDisplayID,
        hardwareValue: Double,
        requestedBrightness: Double,
        previousBrightness: Double,
        persistentID: String
    ) {
        pendingDDCWrites[displayID] = PendingDDCWrite(
            hardwareValue: hardwareValue,
            requestedBrightness: requestedBrightness,
            previousBrightness: previousBrightness,
            persistentID: persistentID
        )

        guard ddcFlushTask == nil else { return }

        ddcFlushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)
            ddcFlushTask = nil
            flushPendingDDCWrites()
        }
    }

    private func flushPendingDDCWrites() {
        let writes = pendingDDCWrites
        pendingDDCWrites.removeAll()
        guard !writes.isEmpty else { return }

        var updatedDisplays = displays
        var didChange = false

        for (displayID, write) in writes {
            let success = writeExternalBrightnessNow(displayID: displayID, value: write.hardwareValue)
            guard let index = updatedDisplays.firstIndex(where: { $0.id == displayID }) else { continue }

            if updatedDisplays[index].lastWriteFailed != !success {
                updatedDisplays[index].lastWriteFailed = !success
                didChange = true
            }

            if success {
                saveBrightness(write.requestedBrightness, for: write.persistentID)
                ddcConfirmedBrightness[displayID] = write.requestedBrightness
                if updatedDisplays[index].brightness != write.requestedBrightness {
                    updatedDisplays[index].brightness = write.requestedBrightness
                    didChange = true
                }
                let opacity = BrightnessMath.overlayOpacity(forRequestedBrightness: write.requestedBrightness, kind: updatedDisplays[index].controlKind)
                if updatedDisplays[index].isSoftwareDimmed != (opacity > 0) {
                    updatedDisplays[index].isSoftwareDimmed = opacity > 0
                    didChange = true
                }
                lastErrorMessage = nil
            } else {
                ddcConfirmedBrightness[displayID] = write.previousBrightness
                let opacity = BrightnessMath.overlayOpacity(forRequestedBrightness: write.previousBrightness, kind: updatedDisplays[index].controlKind)
                setSoftwareDimming(for: displayID, opacity: opacity)
                if updatedDisplays[index].brightness != write.previousBrightness {
                    updatedDisplays[index].brightness = write.previousBrightness
                    didChange = true
                }
                if updatedDisplays[index].isSoftwareDimmed != (opacity > 0) {
                    updatedDisplays[index].isSoftwareDimmed = opacity > 0
                    didChange = true
                }
                lastErrorMessage = "Impossible de regler \(updatedDisplays[index].name)."
            }
        }

        if didChange {
            displays = updatedDisplays
        }
    }

    private func cancelPendingDDCWrites() {
        ddcFlushTask?.cancel()
        ddcFlushTask = nil
        pendingDDCWrites.removeAll()
    }

    private func writeExternalBrightnessNow(displayID: CGDirectDisplayID, value: Double) -> Bool {
        let ddcMax = ddcMaxValues[displayID] ?? BrightnessMath.fallbackDDCMaxValue
        let ddcValue = BrightnessMath.ddcValue(forHardwareBrightness: value, ddcMax: ddcMax)
        if let service = appleSiliconDDCServices[displayID] {
            return AppleSiliconDDC.write(service: service.service, command: ddcBrightnessCommand, value: ddcValue)
        }
        return ddcWrite(displayID: displayID, command: ddcBrightnessCommand, value: ddcValue)
    }

    private func setSoftwareDimming(for displayID: CGDirectDisplayID, opacity: Double) {
        guard opacity > 0.001 else {
            hideSoftwareDimming(for: displayID)
            return
        }

        guard let screen = NSScreen.screen(for: displayID) else { return }

        if let window = dimmingWindows[displayID] {
            window.setFrame(screen.frame, display: true)
            window.alphaValue = CGFloat(opacity)
            if !window.isVisible {
                window.orderFrontRegardless()
            }
            return
        }

        let window = DimmingWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .black
        window.alphaValue = CGFloat(opacity)
        window.animationBehavior = .none
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.acceptsMouseMovedEvents = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.orderFrontRegardless()

        dimmingWindows[displayID] = window
    }

    private func hideSoftwareDimming(for displayID: CGDirectDisplayID) {
        guard let window = dimmingWindows[displayID] else { return }

        window.alphaValue = 0
        window.orderOut(nil)
    }

    private func closeSoftwareDimming(for displayID: CGDirectDisplayID) {
        dimmingWindows[displayID]?.orderOut(nil)
        dimmingWindows[displayID]?.close()
        dimmingWindows.removeValue(forKey: displayID)
    }

    private func closeAllSoftwareDimming() {
        for displayID in Array(dimmingWindows.keys) {
            closeSoftwareDimming(for: displayID)
        }

        var updatedDisplays = displays
        for index in updatedDisplays.indices {
            updatedDisplays[index].isSoftwareDimmed = false
        }
        displays = updatedDisplays
    }

    private func cancelPendingKeyboardAdjustment() {
        keyboardAdjustmentTask?.cancel()
        keyboardAdjustmentTask = nil
        pendingKeyboardDelta = 0
    }

    private func reapplyCurrentBrightness() {
        for display in displays where display.isControllable {
            setBrightness(for: display.id, to: display.brightness)
        }
    }

    private func saveBrightness(_ value: Double, for persistentID: String) {
        var prefs = defaults.dictionary(forKey: prefsKey) as? [String: Double] ?? [:]
        prefs[persistentID] = value
        defaults.set(prefs, forKey: prefsKey)
    }

    private func loadBrightness(for persistentID: String) -> Double? {
        let prefs = defaults.dictionary(forKey: prefsKey) as? [String: Double] ?? [:]
        return prefs[persistentID]
    }

    private func saveMaxNits(_ value: Double, for persistentID: String) {
        var prefs = defaults.dictionary(forKey: nitsPrefsKey) as? [String: Double] ?? [:]
        prefs[persistentID] = value
        defaults.set(prefs, forKey: nitsPrefsKey)
    }

    private func loadMaxNits(for persistentID: String) -> Double? {
        let prefs = defaults.dictionary(forKey: nitsPrefsKey) as? [String: Double] ?? [:]
        return prefs[persistentID]
    }

    private func defaultMaxNits(isBuiltIn: Bool) -> Double {
        isBuiltIn ? BrightnessMath.defaultBuiltInMaxNits : BrightnessMath.defaultExternalMaxNits
    }
}

private extension BrightnessManager {
    static func displayName(for displayID: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screen(for: displayID) {
            return screen.localizedName
        }

        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Ecran integre"
        }

        guard let info = displayInfoDictionary(for: displayID),
              let names = info[kDisplayProductName] as? [String: String],
              let name = names.values.first else {
            return "Ecran externe \(displayID)"
        }

        return name
    }

    static func persistentDisplayID(for displayID: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)

        if vendor != 0 || model != 0 || serial != 0 {
            return "\(vendor)-\(model)-\(serial)"
        }

        return String(displayID)
    }

    static func appleSiliconDDCServices(for displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: AppleSiliconDDC.IOregService] {
        let services = AppleSiliconDDC.getIoregServicesForMatching()
            .filter { $0.service != nil && !$0.productName.isEmpty }

        guard !services.isEmpty else { return [:] }

        var matches: [CGDirectDisplayID: AppleSiliconDDC.IOregService] = [:]
        var usedServiceLocations = Set<Int>()

        for displayID in displayIDs where CGDisplayIsBuiltin(displayID) == 0 {
            let displayName = Self.displayName(for: displayID).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let displaySerial = Int64(CGDisplaySerialNumber(displayID))

            let scored = services
                .filter { !usedServiceLocations.contains($0.serviceLocation) }
                .map { service -> (service: AppleSiliconDDC.IOregService, score: Int) in
                    var score = 0
                    if service.productName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == displayName {
                        score += 100
                    }
                    if service.serialNumber != 0 && service.serialNumber == displaySerial {
                        score += 25
                    }
                    if service.location == "External" {
                        score += 5
                    }
                    if service.transportUpstream != "" || service.transportDownstream != "" {
                        score += 2
                    }
                    return (service, score)
                }
                .sorted { $0.score > $1.score }

            guard let best = scored.first, best.score > 0 else { continue }
            matches[displayID] = best.service
            usedServiceLocations.insert(best.service.serviceLocation)
        }

        return matches
    }

    static func displayInfoDictionary(for displayID: CGDirectDisplayID) -> [String: Any]? {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let targetVendor = CGDisplayVendorNumber(displayID)
        let targetProduct = CGDisplayModelNumber(displayID)
        let targetSerial = CGDisplaySerialNumber(displayID)

        var service = IOIteratorNext(iterator)
        while service != 0 {
            let currentService = service
            service = IOIteratorNext(iterator)
            defer { IOObjectRelease(currentService) }

            guard let info = IODisplayCreateInfoDictionary(currentService, IOOptionBits(kIODisplayOnlyPreferredName))
                .takeRetainedValue() as? [String: Any] else {
                continue
            }

            let vendor = uint32Value(info[kDisplayVendorID])
            let product = uint32Value(info[kDisplayProductID])
            let serial = uint32Value(info[kDisplaySerialNumber])

            if vendor == targetVendor && product == targetProduct && (targetSerial == 0 || serial == targetSerial) {
                return info
            }
        }

        return nil
    }

    static func framebufferPort(for displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let targetVendor = CGDisplayVendorNumber(displayID)
        let targetProduct = CGDisplayModelNumber(displayID)
        let targetSerial = CGDisplaySerialNumber(displayID)

        var service = IOIteratorNext(iterator)

        while service != 0 {
            let currentService = service
            service = IOIteratorNext(iterator)
            defer { IOObjectRelease(currentService) }

            guard let info = IODisplayCreateInfoDictionary(currentService, IOOptionBits(kIODisplayOnlyPreferredName))
                .takeRetainedValue() as? [String: Any] else {
                continue
            }

            let vendor = uint32Value(info[kDisplayVendorID])
            let product = uint32Value(info[kDisplayProductID])
            let serial = uint32Value(info[kDisplaySerialNumber])
            let isMatch = vendor == targetVendor && product == targetProduct && (targetSerial == 0 || serial == targetSerial)
            let parent = framebufferParent(of: currentService)

            if isMatch, let parent {
                return parent
            }

            if let parent {
                IOObjectRelease(parent)
            }
        }

        return nil
    }

    static func framebufferParent(of displayService: io_service_t) -> io_service_t? {
        var current = displayService
        var parent: io_registry_entry_t = 0

        while IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == kIOReturnSuccess {
            if current != displayService {
                IOObjectRelease(current)
            }

            if IOObjectConformsTo(parent, "IOFramebuffer") != 0 {
                return parent
            }

            current = parent
        }

        if current != displayService {
            IOObjectRelease(current)
        }

        return nil
    }

    static func uint32Value(_ value: Any?) -> UInt32 {
        if let value = value as? UInt32 {
            return value
        }
        if let value = value as? Int {
            return UInt32(value)
        }
        if let value = value as? NSNumber {
            return value.uint32Value
        }
        return 0
    }
}

private extension BrightnessManager {
    func ddcWrite(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        guard let framebufferPort = Self.framebufferPort(for: displayID) else { return false }
        defer { IOObjectRelease(framebufferPort) }

        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebufferPort, &busCount) == kIOReturnSuccess,
              busCount > 0 else { return false }

        let valueHigh = UInt8((value >> 8) & 0xFF)
        let valueLow = UInt8(value & 0xFF)

        var data: [UInt8] = [
            0x51,
            0x84,
            0x03,
            command,
            valueHigh,
            valueLow,
        ]

        var checksum: UInt8 = 0x6E
        for byte in data {
            checksum ^= byte
        }
        data.append(checksum)

        for bus in 0..<busCount {
            if sendDDC(bytes: data, to: framebufferPort, bus: bus, expectsReply: false) != nil {
                return true
            }
        }

        return false
    }

    func ddcRead(displayID: CGDirectDisplayID, command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let framebufferPort = Self.framebufferPort(for: displayID) else { return nil }
        defer { IOObjectRelease(framebufferPort) }

        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebufferPort, &busCount) == kIOReturnSuccess,
              busCount > 0 else { return nil }

        var data: [UInt8] = [
            0x51,
            0x82,
            0x01,
            command,
        ]

        var checksum: UInt8 = 0x6E
        for byte in data {
            checksum ^= byte
        }
        data.append(checksum)

        for bus in 0..<busCount {
            guard let reply = sendDDC(bytes: data, to: framebufferPort, bus: bus, expectsReply: true),
                  let value = parseDDCBrightnessReply(reply, command: command) else {
                continue
            }

            return value
        }

        return nil
    }

    func sendDDC(bytes: [UInt8], to framebufferPort: io_service_t, bus: IOItemCount, expectsReply: Bool) -> [UInt8]? {
        var i2cInterface: io_service_t = 0
        guard IOFBCopyI2CInterfaceForBus(framebufferPort, bus, &i2cInterface) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(i2cInterface) }

        var connect: IOI2CConnectRef?
        guard IOI2CInterfaceOpen(i2cInterface, 0, &connect) == kIOReturnSuccess,
              let connection = connect else {
            return nil
        }
        defer { IOI2CInterfaceClose(connection, 0) }

        var sendBuffer = bytes
        var replyBuffer = [UInt8](repeating: 0, count: expectsReply ? 12 : 0)
        var request = IOI2CRequest()
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendAddress = 0x6E
        request.sendBytes = UInt32(sendBuffer.count)
        request.replyTransactionType = expectsReply
            ? IOOptionBits(kIOI2CSimpleTransactionType)
            : IOOptionBits(kIOI2CNoTransactionType)
        request.replyAddress = 0x6F
        request.replyBytes = UInt32(replyBuffer.count)

        let result = sendBuffer.withUnsafeMutableBufferPointer { sendPointer -> kern_return_t in
            request.sendBuffer = vm_address_t(bitPattern: sendPointer.baseAddress)

            if expectsReply {
                return replyBuffer.withUnsafeMutableBufferPointer { replyPointer -> kern_return_t in
                    request.replyBuffer = vm_address_t(bitPattern: replyPointer.baseAddress)
                    return IOI2CSendRequest(connection, 0, &request)
                }
            }

            return IOI2CSendRequest(connection, 0, &request)
        }

        guard result == kIOReturnSuccess, request.result == kIOReturnSuccess else {
            return nil
        }

        return expectsReply ? replyBuffer : []
    }

    func parseDDCBrightnessReply(_ reply: [UInt8], command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let commandIndex = reply.firstIndex(of: command) else { return nil }

        // Standard VCP feature reply layout after the opcode:
        //   +1 type, +2 maxHigh, +3 maxLow, +4 currentHigh, +5 currentLow.
        let maxHigh = commandIndex + 2
        let currentHigh = commandIndex + 4

        guard currentHigh + 1 < reply.count else { return nil }

        let current = (UInt16(reply[currentHigh]) << 8) | UInt16(reply[currentHigh + 1])

        var max: UInt16 = UInt16(BrightnessMath.fallbackDDCMaxValue)
        if maxHigh + 1 < reply.count {
            let parsedMax = (UInt16(reply[maxHigh]) << 8) | UInt16(reply[maxHigh + 1])
            if parsedMax > 0 {
                max = parsedMax
            }
        }

        guard current <= max else { return nil }
        return (current, max)
    }
}

private final class DimmingWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PendingDDCWrite {
    let hardwareValue: Double
    let requestedBrightness: Double
    let previousBrightness: Double
    let persistentID: String
}
