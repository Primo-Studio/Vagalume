import CoreGraphics
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: BrightnessManager
    @EnvironmentObject private var updateManager: UpdateManager
    @EnvironmentObject private var boost: XDRBoostController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if manager.displays.isEmpty {
                EmptyStateView(refresh: manager.refreshDisplays)
            } else {
                GlobalBrightnessView()

                Divider()

                VStack(spacing: 12) {
                    ForEach(manager.displays) { display in
                        DisplaySliderView(displayID: display.id)
                    }
                }

                PresetRowView()
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            manager.refreshKeyboardHooks()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.yellow)
                .font(.title3)

            VStack(alignment: .leading, spacing: 1) {
                Text("BrightBar")
                    .font(.headline)
                Text(manager.statusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                let enabled = !manager.isEnabled
                manager.setEnabled(enabled)
                if !enabled {
                    boost.disableAll()
                }
            } label: {
                Image(systemName: manager.isEnabled ? "power.circle.fill" : "power.circle")
                    .foregroundStyle(manager.isEnabled ? .green : .orange)
            }
            .buttonStyle(.borderless)
            .help(manager.isEnabled ? "Activer/desactiver - Coupe BrightBar, libere F1/F2 et retire les overlays." : "Activer/desactiver - Reactive BrightBar et reapplique la luminosite actuelle.")
            .accessibilityLabel(manager.isEnabled ? "Desactiver BrightBar" : "Activer BrightBar")
            .accessibilityHint(manager.isEnabled ? "Coupe le controle de luminosite et rend F1/F2 a macOS." : "Reactive le controle de luminosite BrightBar.")

            Button {
                manager.refreshDisplays()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Actualiser les ecrans - Redetecte les moniteurs et resynchronise les niveaux.")
            .accessibilityLabel("Actualiser les ecrans")
            .accessibilityHint("Redetecte les moniteurs connectes et recharge leur luminosite.")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label(keyboardStatusText, systemImage: keyboardStatusIcon)
                .font(.caption)
                .foregroundStyle(keyboardStatusColor)
                .help(keyboardStatusHelp)

            Spacer()

            if let message = manager.lastErrorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Alerte - \(message)")
                    .accessibilityLabel("Alerte BrightBar")
                    .accessibilityHint(message)
            }

            if manager.isEnabled && manager.brightnessKeyMode != .intercepting {
                Button {
                    manager.requestKeyboardPermission()
                } label: {
                    Image(systemName: "keyboard.badge.ellipsis")
                }
                .buttonStyle(.borderless)
                .help("Autorisation clavier - Ouvre la demande Accessibilite pour intercepter les touches soleil/F1/F2.")
                .accessibilityLabel("Demander l'autorisation clavier")
                .accessibilityHint("Affiche la demande macOS Accessibilite pour permettre a BrightBar d'intercepter les touches de luminosite.")
            }

            Button {
                updateManager.checkForUpdates()
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!updateManager.canCheckForUpdates)
            .help("Mises a jour - Verifie manuellement s'il existe une nouvelle version de BrightBar.")
            .accessibilityLabel("Verifier les mises a jour")
            .accessibilityHint("Lance la verification Sparkle des mises a jour.")

            Button("Quitter") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Quitter - Ferme completement BrightBar.")
            .accessibilityHint("Ferme l'application BrightBar.")
        }
    }

    private var keyboardStatusText: String {
        guard manager.isEnabled else { return "BrightBar desactive" }

        return switch manager.brightnessKeyMode {
        case .intercepting:
            fallbackHotkeysText.map { "Soleil / \($0)" } ?? "Soleil actif"
        case .observing:
            fallbackHotkeysText.map { "\($0) actif" } ?? "Soleil observe"
        case .disabled:
            fallbackHotkeysText.map { "\($0) actif" } ?? "Clavier non actif"
        }
    }

    private var keyboardStatusIcon: String {
        guard manager.isEnabled else { return "power" }
        return manager.brightnessKeyMode != .disabled || hasFallbackHotkeys ? "keyboard" : "keyboard.badge.ellipsis"
    }

    private var keyboardStatusColor: Color {
        guard manager.isEnabled else { return .orange }

        return switch manager.brightnessKeyMode {
        case .intercepting:
            .secondary
        case .observing:
            .orange
        case .disabled:
            hasFallbackHotkeys ? .secondary : .orange
        }
    }

    private var keyboardStatusHelp: String {
        guard manager.isEnabled else {
            return "BrightBar ne capte plus F1/F2 et coupe le dimming logiciel."
        }

        return switch manager.brightnessKeyMode {
        case .intercepting:
            "BrightBar intercepte les touches soleil macOS et controle les ecrans."
        case .observing:
            "BrightBar utilise les raccourcis F1/F2 standards si disponibles, mais n'intercepte pas encore les touches soleil macOS. Autorise BrightBar dans Reglages Systeme > Confidentialite et securite > Accessibilite."
        case .disabled:
            hasFallbackHotkeys
                ? "Utilise les raccourcis clavier disponibles. Autorise BrightBar dans Accessibilite pour intercepter les touches soleil."
                : "Autorise BrightBar dans Reglages Systeme > Confidentialite et securite > Accessibilite."
        }
    }

    private var hasFallbackHotkeys: Bool {
        manager.functionHotkeysEnabled || manager.optionHotkeysEnabled
    }

    private var fallbackHotkeysText: String? {
        switch (manager.functionHotkeysEnabled, manager.optionHotkeysEnabled) {
        case (true, true):
            "F1/F2 + Opt"
        case (true, false):
            "F1/F2"
        case (false, true):
            "Opt+fleches"
        case (false, false):
            nil
        }
    }
}

private struct GlobalBrightnessView: View {
    @EnvironmentObject private var manager: BrightnessManager
    /// Local thumb position so the slider follows the pointer exactly. Driving it
    /// from the average made it stutter when one display saturated; instead we
    /// apply the incremental delta and only re-sync to the average when idle.
    @State private var sliderValue = 0.0
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Tous les ecrans", systemImage: "rectangle.3.group")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(manager.averageBrightnessPercent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Image(systemName: "sun.min")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Minimum - Glisser vers la gauche baisse la luminosite.")
                    .accessibilityHidden(true)

                Slider(
                    value: $sliderValue,
                    in: 0...1,
                    onEditingChanged: { editing in
                        isEditing = editing
                        if !editing {
                            sliderValue = manager.averageBrightness
                        }
                    }
                )
                .disabled(!manager.isEnabled)
                .help("Luminosite globale - Ajuste tous les ecrans controlables en conservant leurs ecarts.")
                .accessibilityLabel("Luminosite de tous les ecrans")
                .accessibilityHint("Modifie la luminosite de tous les ecrans controles par BrightBar.")
                .onChange(of: sliderValue) { oldValue, newValue in
                    guard isEditing else { return }
                    manager.adjustAllBrightness(by: newValue - oldValue)
                }
                .onChange(of: manager.averageBrightness) { _, average in
                    if !isEditing {
                        sliderValue = average
                    }
                }
                .onAppear { sliderValue = manager.averageBrightness }

                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Maximum - Glisser vers la droite augmente la luminosite.")
                    .accessibilityHidden(true)
            }

            if manager.hasSoftwareOnlyDisplays {
                Label("Les ecrans en Logiciel dimment seulement: pas de boost hardware.", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !manager.isEnabled {
                Label("BrightBar est desactive: dimming coupe, F1/F2 rendus a macOS.", systemImage: "power")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DisplaySliderView: View {
    let displayID: CGDirectDisplayID
    @EnvironmentObject private var manager: BrightnessManager
    @EnvironmentObject private var boost: XDRBoostController

    var body: some View {
        if let display {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                        .foregroundStyle(.secondary)
                        .help(display.isBuiltIn ? "Ecran integre - Controle via macOS." : "Ecran externe - Controle via DDC/CI si disponible, sinon dimming logiciel.")
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(display.name)
                            .font(.subheadline)
                            .lineLimit(1)

                        Text(display.controlKind.rawValue)
                            .font(.caption2)
                            .foregroundStyle(statusColor(for: display))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(display.brightnessPercent)%")
                        Text(nitsText(for: display))
                    }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .trailing)
                }

                Slider(
                    value: Binding(
                        get: { self.display?.brightness ?? display.brightness },
                        set: { manager.setBrightness(for: displayID, to: $0) }
                    ),
                    in: display.minBrightness...display.maxBrightness,
                    step: 0.01
                )
                .disabled(!manager.isEnabled || !display.isControllable)
                .help("Luminosite \(display.name) - Ajuste uniquement cet ecran.")
                .accessibilityLabel("Luminosite \(display.name)")
                .accessibilityHint("Modifie la luminosite de cet ecran seulement.")

                if display.lastWriteFailed {
                    Label("Echec DDC: active DDC/CI dans le menu de l'ecran.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let dimmingStatus = dimmingStatus(for: display) {
                    Label(dimmingStatus, systemImage: "moon.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }

                if display.controlKind == .software {
                    Label("DDC indisponible: BrightBar peut dimmer, pas booster le hardware.", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Stepper(
                    value: Binding(
                        get: { self.display?.maxNits ?? display.maxNits },
                        set: { manager.setMaxNits(for: displayID, to: $0) }
                    ),
                    in: BrightnessMath.minConfigurableNits...BrightnessMath.maxConfigurableNits,
                    step: BrightnessMath.maxNitsStep
                ) {
                    Text("Max \(Int(display.maxNits)) nits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .disabled(!manager.isEnabled)
                .help("Max nits - Regle le pic lumineux theorique de \(display.name), utilise seulement pour estimer les nits affiches.")
                .accessibilityLabel("Max nits \(display.name)")
                .accessibilityHint("Change la valeur de reference utilisee pour calculer l'estimation en nits.")

                if boost.isSupported(displayID) {
                    boostControl
                }
            }
        }
    }

    @ViewBuilder
    private var boostControl: some View {
        let maxBoost = boost.maxBoost(for: displayID)
        let isOn = boost.isBoosted(displayID)

        Divider().opacity(0.4)

        Toggle(isOn: Binding(
            get: { isOn },
            set: { boost.setBoost(level: $0 ? boost.defaultBoost(for: displayID) : 1.0, for: displayID) }
        )) {
            Label("Boost XDR (experimental)", systemImage: "sun.max.trianglebadge.exclamationmark")
                .font(.caption2)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(!manager.isEnabled)
        .help("Boost XDR - Active un overlay EDR experimental pour depasser le plafond macOS sur les ecrans compatibles.")
        .accessibilityLabel("Boost XDR experimental")
        .accessibilityHint("Active ou desactive le boost lumineux EDR pour cet ecran.")

        if isOn {
            HStack(spacing: 8) {
                Image(systemName: "sun.max")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Niveau de boost XDR - Plus haut augmente l'effet EDR.")
                    .accessibilityHidden(true)

                Slider(
                    value: Binding(
                        get: { boost.boostLevel(for: displayID) },
                        set: { boost.setBoost(level: $0, for: displayID) }
                    ),
                    in: 1.0...maxBoost
                )
                .disabled(!manager.isEnabled)
                .help("Niveau Boost XDR - Regle l'intensite de l'overlay EDR experimental.")
                .accessibilityLabel("Niveau Boost XDR")
                .accessibilityHint("Augmente ou reduit l'intensite du boost XDR.")

                Text(String(format: "x%.2f", boost.boostLevel(for: displayID)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            Label("Depasse 500 nits via overlay EDR. Peut alterer les couleurs: coupe-le pour l'etalonnage.", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var display: DisplayInfo? {
        manager.displays.first { $0.id == displayID }
    }

    private func statusColor(for display: DisplayInfo) -> Color {
        switch display.controlKind {
        case .native, .ddc:
            display.lastWriteFailed ? .orange : .secondary
        case .software:
            .blue
        case .unsupported:
            .orange
        }
    }

    private func nitsText(for display: DisplayInfo) -> String {
        let estimate = BrightnessMath.estimatedNits(
            maxNits: display.maxNits,
            brightness: display.brightness,
            controlKind: display.controlKind
        )
        return display.controlKind == .software ? "<=\(estimate) nits" : "~\(estimate) nits"
    }

    private func dimmingStatus(for display: DisplayInfo) -> String? {
        guard display.isSoftwareDimmed else { return nil }
        return display.controlKind == .software ? "Dimming logiciel actif" : "Sub-zero actif"
    }
}

private struct PresetRowView: View {
    @EnvironmentObject private var manager: BrightnessManager
    private let presets = BrightnessMath.presets

    var body: some View {
        HStack(spacing: 8) {
            ForEach(presets, id: \.self) { preset in
                Button("\(Int(preset * 100))%") {
                    manager.setAllBrightness(to: preset)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!manager.isEnabled)
                .help("Preset \(Int(preset * 100))% - Met tous les ecrans controlables a \(Int(preset * 100))%.")
                .accessibilityLabel("Preset luminosite \(Int(preset * 100)) pour cent")
            }
        }
    }
}

private struct EmptyStateView: View {
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Aucun ecran detecte")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Reessayer", action: refresh)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reessayer - Relance la detection des ecrans.")
                .accessibilityHint("Relance la detection des moniteurs connectes.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}
