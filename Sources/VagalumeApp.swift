import ApplicationServices
import Carbon.HIToolbox
import IOKit.hidsystem
import SwiftUI

@main
struct VagalumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var brightnessManager = BrightnessManager()
    @StateObject private var updateManager = UpdateManager()
    @StateObject private var boostController = XDRBoostController()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(brightnessManager)
                .environmentObject(updateManager)
                .environmentObject(boostController)
        } label: {
            Image(systemName: "sun.max.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var optionBrightnessUp: EventHotKeyRef?
    private var optionBrightnessDown: EventHotKeyRef?
    private var functionBrightnessUp: EventHotKeyRef?
    private var functionBrightnessDown: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var brightnessKeyController: BrightnessKeyController?
    private var callback: ((_ isUp: Bool) -> Void)?
    private var registrationStatus = HotkeyRegistrationStatus(
        optionHotkeys: false,
        functionHotkeys: false,
        brightnessKeyMode: .disabled
    )
    private var isEnabled = true

    @discardableResult
    func register(callback: @escaping (_ isUp: Bool) -> Void) -> HotkeyRegistrationStatus {
        self.callback = callback

        if brightnessKeyController == nil {
            brightnessKeyController = BrightnessKeyController(callback: callback)
        }

        return refresh()
    }

    @discardableResult
    func refresh() -> HotkeyRegistrationStatus {
        guard isEnabled else {
            return HotkeyRegistrationStatus(optionHotkeys: false, functionHotkeys: false, brightnessKeyMode: .disabled)
        }

        let canHandleCarbonHotkeys = installCarbonHotkeyHandler()
        let optionHotkeys = canHandleCarbonHotkeys && registerOptionHotkeys()
        let functionHotkeys = canHandleCarbonHotkeys && registerFunctionHotkeys()
        let brightnessKeyMode = brightnessKeyController?.refreshMode() ?? .disabled

        registrationStatus = HotkeyRegistrationStatus(
            optionHotkeys: optionHotkeys,
            functionHotkeys: functionHotkeys,
            brightnessKeyMode: brightnessKeyMode
        )
        return registrationStatus
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> HotkeyRegistrationStatus {
        isEnabled = enabled

        guard enabled else {
            unregisterCarbonHotkeys()
            _ = brightnessKeyController?.setEnabled(false)
            registrationStatus = HotkeyRegistrationStatus(
                optionHotkeys: false,
                functionHotkeys: false,
                brightnessKeyMode: .disabled
            )
            return registrationStatus
        }

        _ = brightnessKeyController?.setEnabled(true)
        return refresh()
    }

    @discardableResult
    func requestAccessibilityPermission() -> HotkeyRegistrationStatus {
        guard isEnabled else {
            return HotkeyRegistrationStatus(optionHotkeys: false, functionHotkeys: false, brightnessKeyMode: .disabled)
        }

        brightnessKeyController?.requestAccessibilityPermission()
        return refresh()
    }

    private func installCarbonHotkeyHandler() -> Bool {
        if eventHandler != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            DispatchQueue.main.async {
                guard HotkeyManager.shared.isEnabled else { return }

                switch hotKeyID.id {
                case 1, 3:
                    HotkeyManager.shared.callback?(true)
                case 2, 4:
                    HotkeyManager.shared.callback?(false)
                default:
                    break
                }
            }

            return noErr
        }

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        return handlerStatus == noErr
    }

    private func registerOptionHotkeys() -> Bool {
        if optionBrightnessUp != nil, optionBrightnessDown != nil {
            return true
        }

        unregisterOptionHotkeysOnly()

        let upID = EventHotKeyID(signature: OSType(0x42425550), id: 1) // BBUP
        var nextOptionBrightnessUp: EventHotKeyRef?
        let upStatus = RegisterEventHotKey(
            UInt32(kVK_UpArrow),
            UInt32(optionKey),
            upID,
            GetApplicationEventTarget(),
            0,
            &nextOptionBrightnessUp
        )

        guard upStatus == noErr else { return false }

        let downID = EventHotKeyID(signature: OSType(0x4242444E), id: 2) // BBDN
        var nextOptionBrightnessDown: EventHotKeyRef?
        let downStatus = RegisterEventHotKey(
            UInt32(kVK_DownArrow),
            UInt32(optionKey),
            downID,
            GetApplicationEventTarget(),
            0,
            &nextOptionBrightnessDown
        )

        guard downStatus == noErr else {
            if let nextOptionBrightnessUp {
                UnregisterEventHotKey(nextOptionBrightnessUp)
            }
            return false
        }

        optionBrightnessUp = nextOptionBrightnessUp
        optionBrightnessDown = nextOptionBrightnessDown
        return true
    }

    private func registerFunctionHotkeys() -> Bool {
        if functionBrightnessUp != nil, functionBrightnessDown != nil {
            return true
        }

        unregisterFunctionHotkeysOnly()

        let upID = EventHotKeyID(signature: OSType(0x42424632), id: 3) // BBF2
        var nextFunctionBrightnessUp: EventHotKeyRef?
        let upStatus = RegisterEventHotKey(
            UInt32(kVK_F2),
            0,
            upID,
            GetApplicationEventTarget(),
            0,
            &nextFunctionBrightnessUp
        )

        guard upStatus == noErr else { return false }

        let downID = EventHotKeyID(signature: OSType(0x42424631), id: 4) // BBF1
        var nextFunctionBrightnessDown: EventHotKeyRef?
        let downStatus = RegisterEventHotKey(
            UInt32(kVK_F1),
            0,
            downID,
            GetApplicationEventTarget(),
            0,
            &nextFunctionBrightnessDown
        )

        guard downStatus == noErr else {
            if let nextFunctionBrightnessUp {
                UnregisterEventHotKey(nextFunctionBrightnessUp)
            }
            return false
        }

        functionBrightnessUp = nextFunctionBrightnessUp
        functionBrightnessDown = nextFunctionBrightnessDown
        return true
    }

    private func unregisterCarbonHotkeys() {
        unregisterOptionHotkeysOnly()
        unregisterFunctionHotkeysOnly()
    }

    private func unregisterOptionHotkeysOnly() {
        if let optionBrightnessUp {
            UnregisterEventHotKey(optionBrightnessUp)
            self.optionBrightnessUp = nil
        }

        if let optionBrightnessDown {
            UnregisterEventHotKey(optionBrightnessDown)
            self.optionBrightnessDown = nil
        }
    }

    private func unregisterFunctionHotkeysOnly() {
        if let functionBrightnessUp {
            UnregisterEventHotKey(functionBrightnessUp)
            self.functionBrightnessUp = nil
        }

        if let functionBrightnessDown {
            UnregisterEventHotKey(functionBrightnessDown)
            self.functionBrightnessDown = nil
        }
    }
}

struct HotkeyRegistrationStatus {
    let optionHotkeys: Bool
    let functionHotkeys: Bool
    let brightnessKeyMode: BrightnessKeyMode
}

enum BrightnessKeyMode: Equatable {
    case disabled
    case observing
    case intercepting
}

fileprivate final class BrightnessKeyController {
    private let callback: (_ isUp: Bool) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lastFallbackEventTime: TimeInterval = 0
    private var isEnabled = true

    init(callback: @escaping (_ isUp: Bool) -> Void) {
        self.callback = callback
    }

    deinit {
        stopFallbackMonitors()
        stopInterceptingTap()
    }

    func refreshMode() -> BrightnessKeyMode {
        guard isEnabled else { return .disabled }

        if resumeOrStartInterceptingTap(promptForAccessibility: false) {
            stopFallbackMonitors()
            return .intercepting
        }

        if localMonitor == nil && globalMonitor == nil {
            startFallbackMonitors()
        }
        return localMonitor != nil || globalMonitor != nil ? .observing : .disabled
    }

    func setEnabled(_ enabled: Bool) -> BrightnessKeyMode {
        isEnabled = enabled

        guard enabled else {
            stopInterceptingTap()
            stopFallbackMonitors()
            return .disabled
        }

        return refreshMode()
    }

    func requestAccessibilityPermission() {
        _ = isAccessibilityTrusted(prompt: true)
    }

    private func resumeOrStartInterceptingTap(promptForAccessibility: Bool) -> Bool {
        if let eventTap {
            if CFMachPortIsValid(eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                return CGEvent.tapIsEnabled(tap: eventTap)
            }

            stopInterceptingTap()
        }

        return startInterceptingTap(promptForAccessibility: promptForAccessibility)
    }

    private func startInterceptingTap(promptForAccessibility: Bool) -> Bool {
        guard isAccessibilityTrusted(prompt: promptForAccessibility) else {
            return false
        }

        let systemDefinedEventType = CGEventType(rawValue: 14)!
        let mask = CGEventMask(1 << systemDefinedEventType.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: brightnessEventTapCallback,
            userInfo: context
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func isAccessibilityTrusted(prompt: Bool) -> Bool {
        if !prompt {
            return AXIsProcessTrusted()
        }

        let trustOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(trustOptions)
    }

    private func stopInterceptingTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func startFallbackMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, let direction = Self.brightnessDirection(from: event) else {
                return event
            }

            self.handleFallback(direction: direction)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, let direction = Self.brightnessDirection(from: event) else { return }
            self.handleFallback(direction: direction)
        }
    }

    private func stopFallbackMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handleFallback(direction: BrightnessDirection) {
        guard isEnabled else { return }

        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastFallbackEventTime > 0.035 else { return }
        lastFallbackEventTime = now

        callback(direction == .up)
    }

    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isEnabled else {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let direction = Self.brightnessDirection(from: event) else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async {
            self.callback(direction == .up)
        }

        return nil
    }

    private static func brightnessDirection(from event: CGEvent) -> BrightnessDirection? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
        return brightnessDirection(from: nsEvent)
    }

    private static func brightnessDirection(from event: NSEvent) -> BrightnessDirection? {
        guard event.type == .systemDefined,
              event.subtype.rawValue == 8 else {
            return nil
        }

        let keyCode = Int32((event.data1 & 0xFFFF0000) >> 16)
        let keyState = (event.data1 & 0xFF00) >> 8
        guard keyState == 0xA else { return nil }

        if keyCode == NX_KEYTYPE_BRIGHTNESS_UP {
            return .up
        }

        if keyCode == NX_KEYTYPE_BRIGHTNESS_DOWN {
            return .down
        }

        return nil
    }
}

private func brightnessEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let controller = Unmanaged<BrightnessKeyController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()

    return controller.handleTap(type: type, event: event)
}

private enum BrightnessDirection {
    case up
    case down
}
