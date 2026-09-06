import SwiftUI
import Cocoa

/// Gestisce il PIN di abbinamento e la finestra che lo mostra.
/// Il PIN vale 2 minuti; dopo 3 tentativi sbagliati si blocca per 30 secondi.
final class PairingController: ObservableObject {
    @Published var pin: String = ""
    @Published var secret: String = ""
    var codePayload: String { Pairing.codePayload(macID: LocalIdentity.id, secret: secret) }
    @Published var requester: String = ""
    @Published var message: String = ""
    @Published private(set) var active = false
    @Published var successAt: Date? = nil
    @Published var visible = false
    @Published var successName: String = ""

    private var expires = Date.distantPast
    private var failures = 0
    private var lockedUntil = Date.distantPast
    private var window: NSWindow?

    enum Result { case accepted(pin: String), wrongPIN, locked, notPairing }

    func begin(requestFrom name: String = "") {
        pin = Pairing.randomPIN()
        secret = Pairing.randomSecret()
        expires = Date().addingTimeInterval(120)
        failures = 0
        requester = name
        message = ""
        successAt = nil
        active = true
        showWindow()
    }

    func cancel() {
        active = false
        pin = ""; secret = ""
        hideWindow()
    }

    func finish(success: Bool, name: String) {
        if success {
            message = ""
            successName = name
            successAt = Date()
            active = false
            pin = ""; secret = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in self?.hideWindow() }
        }
    }

    /// Chiamato dalla coda di rete: decide se la richiesta e' valida.
    func evaluate(_ req: Pairing.Request) -> Result {
        var result: Result = .notPairing
        DispatchQueue.main.sync {
            if Date() < lockedUntil { result = .locked; return }
            guard active, Date() < expires, !pin.isEmpty else { result = .notPairing; return }
            if !secret.isEmpty && req.isValid(pin: secret) {
                result = .accepted(pin: secret)      // codice inquadrato con la fotocamera
            } else if req.isValid(pin: pin) {
                result = .accepted(pin: pin)
            } else {
                failures += 1
                message = String(localized: "Wrong PIN (\(failures) of 3).")
                if failures >= 3 {
                    lockedUntil = Date().addingTimeInterval(30)
                    active = false
                    pin = ""; secret = ""
                    message = String(localized: "Too many attempts. Pairing locked for 30 seconds.")
                    result = .locked
                } else {
                    result = .wrongPIN
                }
            }
        }
        return result
    }

    private func showWindow() {
        if window == nil {
            let w = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 920),
                                  styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false      // niente ombra: il bordo deve sfumare nel desktop
            w.isMovableByWindowBackground = true
            w.onCancel = { [weak self] in self?.cancel() }
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: PairingView(controller: self))
            host.frame = w.contentRect(forFrameRect: w.frame)
            host.autoresizingMask = [.width, .height]
            host.wantsLayer = true
            host.layer?.backgroundColor = .clear
            let container = NSView(frame: host.frame)
            container.wantsLayer = true
            container.layer?.backgroundColor = .clear
            container.addSubview(host)
            w.contentView = container
            // NSHostingView tende a rendere opaca la finestra: lo sfondo va rimesso a clear dopo
            w.isOpaque = false
            w.backgroundColor = .clear
            window = w
        }
        guard let w = window else { return }
        visible = true
        if !w.isVisible {
            w.center()
            w.alphaValue = 0
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.35; w.animator().alphaValue = 1 }
        } else {
            w.makeKeyAndOrderFront(nil)
        }
    }

    private func hideWindow() {
        guard let w = window, w.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.4; w.animator().alphaValue = 0 },
                                             completionHandler: { w.orderOut(nil); w.alphaValue = 1; self.visible = false })
    }
}

/// Finestra senza bordi che puo' ricevere la tastiera (Esc per annullare).
final class FloatingPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

struct PairingView: View {
    @ObservedObject var controller: PairingController

    var body: some View {
        ZStack {
            SphereMetalView(active: controller.visible, success: controller.successAt != nil)

            VStack(spacing: 6) {
                if let at = controller.successAt {
                    Text(String(localized: "\(controller.successName) is now paired."))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    PairingCodeView(payload: controller.codePayload, successAt: at)
                        .frame(width: 300, height: 300)
                    Text(String(localized: "You can start using it right away."))
                        .font(.callout).foregroundStyle(.secondary)
                } else if controller.active {
                    Text(controller.requester.isEmpty
                         ? String(localized: "Point your iPhone or iPad camera at the code")
                         : String(localized: "\(controller.requester) wants to pair. Point its camera at the code:"))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    PairingCodeView(payload: controller.codePayload, successAt: nil)
                        .frame(width: 300, height: 300)
                    Text(String(localized: "Or type this PIN: \(controller.pin.prefix(3)) \(controller.pin.suffix(3))"))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(String(localized: "Valid for 2 minutes. Only devices on your network can see this Mac."))
                        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                if !controller.message.isEmpty {
                    Text(controller.message).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .offset(y: -0.025 * 920)     // centrato sulla sfera, che sta un po' sopra il centro
            .rotation3DEffect(.degrees(-3), axis: (x: 0, y: 1, z: 0), perspective: 0.6)   // leggera prospettiva, come dentro il vetro
            .animation(.easeInOut(duration: 0.4), value: controller.successAt)
        }
        .overlay(alignment: .topTrailing) {
            if controller.successAt == nil {
                Button { controller.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.10), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 214)
                .padding(.trailing, 217)
                .accessibilityLabel(String(localized: "Cancel"))
            }
        }
        .frame(width: 880, height: 920)
        .colorScheme(.dark)
    }
}
