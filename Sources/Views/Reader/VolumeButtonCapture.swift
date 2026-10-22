import AVFoundation
import MediaPlayer
import SwiftUI

/// Botão de volume físico pressionado.
enum VolumeButton {
    case up
    case down
}

extension View {
    /// Usa os botões de volume como controle enquanto `isEnabled` for true.
    ///
    /// O iOS não tem API pública para isso: o volume do sistema é observado e, a cada
    /// clique, devolvido ao valor anterior. Um `MPVolumeView` invisível esconde o HUD de
    /// volume. Desligado, os botões voltam a controlar o volume normalmente.
    func onVolumeButton(isEnabled: Bool = true, perform action: @escaping (VolumeButton) -> Void) -> some View {
        background(
            VolumeButtonCapture(isEnabled: isEnabled, action: action)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

private struct VolumeButtonCapture: UIViewRepresentable {
    let isEnabled: Bool
    let action: (VolumeButton) -> Void

    func makeCoordinator() -> VolumeButtonMonitor {
        VolumeButtonMonitor()
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        // Precisa estar visível na janela para o sistema não mostrar o HUD de volume.
        view.alpha = 0.0001
        view.isUserInteractionEnabled = false
        context.coordinator.volumeView = view
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        context.coordinator.action = action
        context.coordinator.setEnabled(isEnabled)
    }

    static func dismantleUIView(_ uiView: MPVolumeView, coordinator: VolumeButtonMonitor) {
        coordinator.setEnabled(false)
    }
}

@MainActor
private final class VolumeButtonMonitor {
    /// Cada clique no botão muda o volume em 1/16.
    private static let step: Float = 1.0 / 16.0

    weak var volumeView: MPVolumeView?
    var action: ((VolumeButton) -> Void)?

    private var isEnabled = false
    private var observation: NSKeyValueObservation?
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Volume do usuário antes da captura, para restaurar ao sair.
    private var originalVolume: Float?
    /// Volume ao qual o sistema é devolvido depois de cada clique.
    private var baseline: Float = 0.5

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        // Escondido, o MPVolumeView deixa o HUD do sistema aparecer de novo.
        volumeView?.isHidden = !enabled

        if enabled {
            observeAppLifecycle()
            if UIApplication.shared.applicationState == .active {
                start()
            }
        } else {
            lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
            lifecycleObservers = []
            stop()
        }
    }

    /// Fora do app (Central de Controle, outro app) os botões devem mexer no volume.
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
        ]
    }

    private func start() {
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // .ambient mistura com outros apps: a música que estiver tocando continua.
        try? session.setCategory(.ambient)
        try? session.setActive(true)

        let current = session.outputVolume
        originalVolume = current
        // Base num degrau da escala e longe dos extremos, para os dois botões sempre
        // mudarem o volume (no máximo, "aumentar" não dispara nada).
        let snapped = (current / Self.step).rounded() * Self.step
        baseline = min(max(snapped, Self.step), 1 - Self.step)
        if baseline != current {
            setSystemVolume(baseline)
        }

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            Task { @MainActor in self?.volumeDidChange(to: volume) }
        }
    }

    private func stop() {
        guard let observation else { return }
        observation.invalidate()
        self.observation = nil
        // Só restaura quando a base foi afastada de um extremo; o ajuste ao degrau é inaudível
        // e restaurá-lo faria o HUD piscar.
        if let originalVolume, abs(originalVolume - baseline) > Self.step / 2 {
            setSystemVolume(originalVolume)
        }
        originalVolume = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func volumeDidChange(to volume: Float) {
        guard observation != nil else { return }
        // Menos de meio degrau de diferença é o eco do nosso próprio reset, não um clique.
        guard abs(volume - baseline) > Self.step / 2 else { return }

        let button: VolumeButton = volume > baseline ? .up : .down
        if !setSystemVolume(baseline) {
            // Sem como resetar, acompanha o volume real para o próximo clique ainda ser detectado.
            baseline = volume
        }
        action?(button)
    }

    /// A posição do slider dentro do MPVolumeView não é documentada, então procura na árvore toda.
    /// No simulador ele não existe ("No Volume Available").
    private var volumeSlider: UISlider? {
        var pending: [UIView] = volumeView.map { [$0] } ?? []
        while !pending.isEmpty {
            let view = pending.removeFirst()
            if let slider = view as? UISlider { return slider }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    @discardableResult
    private func setSystemVolume(_ volume: Float) -> Bool {
        guard let slider = volumeSlider else {
            return false
        }
        // O slider do MPVolumeView ignora valores definidos logo após ser criado.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            slider.value = volume
        }
        return true
    }
}
