import AppKit
import CoreGraphics
import MetalKit

/// Experimental brightness boost beyond the macOS SDR cap (~500 nits) on
/// EDR-capable displays (e.g. the Liquid Retina XDR built-in panel).
///
/// Technique (same as the open-source xdr-boost / Vivid): a borderless, click-
/// through window per display hosts a `MTKView` that clears to white at an EDR
/// component value above 1.0, with the content layer set to `multiply`
/// compositing. Because the overlay *multiplies* the desktop instead of veiling
/// it, every pixel is scaled by the same factor in linear light: blacks stay
/// black and colour ratios/contrast are preserved, while the panel raises its
/// backlight to display the EDR values.
///
/// This is **not colorimetrically accurate** — multiplying changes absolute
/// luminance — so it is opt-in, off by default, and must be disabled for
/// colour-critical work. It is isolated from the core brightness pipeline.
@MainActor
final class XDRBoostController: ObservableObject {
    /// Requested multiplier per display (1.0 == boost off).
    @Published private(set) var boostLevels: [CGDirectDisplayID: Double] = [:]

    private let device: MTLDevice?
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var renderers: [CGDirectDisplayID: BoostRenderer] = [:]
    private var watchdog: Timer?
    private var screenObserver: NSObjectProtocol?

    /// Below this multiplier the boost is considered off (a 1.0 multiply is a
    /// no-op, so there is no point keeping a GPU overlay alive).
    private let offThreshold = 1.01

    init() {
        device = MTLCreateSystemDefaultDevice()
        observeScreenChanges()
        startWatchdog()
    }

    deinit {
        watchdog?.invalidate()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: Capability

    /// Highest multiplier the display's EDR headroom can sustain (1.0 == none).
    func maxBoost(for displayID: CGDirectDisplayID) -> Double {
        guard let screen = NSScreen.screen(for: displayID) else { return 1.0 }
        return Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
    }

    func isSupported(_ displayID: CGDirectDisplayID) -> Bool {
        device != nil && maxBoost(for: displayID) > offThreshold
    }

    func boostLevel(for displayID: CGDirectDisplayID) -> Double {
        boostLevels[displayID] ?? 1.0
    }

    func isBoosted(_ displayID: CGDirectDisplayID) -> Bool {
        boostLevel(for: displayID) > offThreshold
    }

    /// Sensible level when the user first flips the toggle on: a comfortable
    /// lift (≈ +60%) rather than the panel's full EDR headroom, which would clip
    /// highlights and blind the user. The slider can still go up to `maxBoost`.
    func defaultBoost(for displayID: CGDirectDisplayID) -> Double {
        min(maxBoost(for: displayID), 1.6)
    }

    // MARK: Control

    func setBoost(level: Double, for displayID: CGDirectDisplayID) {
        let clamped = min(max(level, 1.0), maxBoost(for: displayID))

        if clamped <= offThreshold {
            boostLevels[displayID] = 1.0
            removeOverlay(for: displayID)
            return
        }

        boostLevels[displayID] = clamped
        applyOverlay(level: clamped, for: displayID)
    }

    func disableAll() {
        for displayID in Array(windows.keys) {
            removeOverlay(for: displayID)
        }
        boostLevels = [:]
    }

    // MARK: Overlay lifecycle

    private func applyOverlay(level: Double, for displayID: CGDirectDisplayID) {
        guard let device, let screen = NSScreen.screen(for: displayID) else { return }
        let clearColor = MTLClearColor(red: level, green: level, blue: level, alpha: 1.0)

        if let window = windows[displayID], let view = window.contentView as? MTKView {
            view.clearColor = clearColor
            window.setFrame(screen.frame, display: true)
            if !window.isVisible {
                window.orderFrontRegardless()
            }
            return
        }

        let frame = screen.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.sharingType = .none // keep the boost out of screenshots and recordings
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = MTKView(frame: frame, device: device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 10
        view.clearColor = clearColor
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true

        let renderer = BoostRenderer(device: device)
        view.delegate = renderer
        view.wantsLayer = true

        window.contentView = view
        // Multiply against the desktop *behind* the window — this is what scales
        // luminance uniformly instead of washing the image out.
        window.contentView?.layer?.compositingFilter = "multiply"
        window.orderFrontRegardless()

        windows[displayID] = window
        renderers[displayID] = renderer
    }

    private func removeOverlay(for displayID: CGDirectDisplayID) {
        windows[displayID]?.orderOut(nil)
        windows[displayID] = nil
        renderers[displayID] = nil
    }

    // MARK: Resilience

    /// EDR overlays are torn down by the system on sleep, lid close, or lock.
    /// A light watchdog re-asserts any boost the user still wants.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reviveOverlays() }
        }
    }

    private func reviveOverlays() {
        for (displayID, level) in boostLevels where level > offThreshold {
            if let window = windows[displayID] {
                if !window.isVisible {
                    window.orderFrontRegardless()
                }
            } else {
                applyOverlay(level: level, for: displayID)
            }
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenChange() }
        }
    }

    private func handleScreenChange() {
        for (displayID, level) in boostLevels where level > offThreshold {
            let maxValue = maxBoost(for: displayID)

            // The display vanished or can no longer do EDR: drop the boost.
            guard NSScreen.screen(for: displayID) != nil, maxValue > offThreshold else {
                removeOverlay(for: displayID)
                boostLevels[displayID] = 1.0
                continue
            }

            // Recreate against the new geometry; the old EDR layer may be dead.
            let target = min(level, maxValue)
            removeOverlay(for: displayID)
            boostLevels[displayID] = target
            applyOverlay(level: target, for: displayID)
        }
    }
}

/// Minimal renderer: each frame clears the drawable to the configured EDR white
/// and presents it. The clear colour carries the boost; no geometry is drawn.
private final class BoostRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue?

    init(device: MTLDevice) {
        commandQueue = device.makeCommandQueue()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue?.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.endEncoding()
        if let drawable = view.currentDrawable {
            buffer.present(drawable)
        }
        buffer.commit()
    }
}
