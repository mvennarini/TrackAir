import SwiftUI
import UIKit

/// Vista invisibile che riceve la tastiera (software o fisica) e inoltra al Mac.
/// Sopra la tastiera software c'e' una barra con modificatori a scatto, Esc, Tab e frecce.
struct KeyboardBridge: UIViewRepresentable {
    @Binding var active: Bool
    @EnvironmentObject var client: Client

    func makeUIView(context: Context) -> KeyboardInputView {
        let v = KeyboardInputView()
        v.client = client
        v.onDismiss = { active = false }
        return v
    }

    func updateUIView(_ v: KeyboardInputView, context: Context) {
        v.client = client
        if active && !v.isFirstResponder { DispatchQueue.main.async { v.becomeFirstResponder() } }
        if !active && v.isFirstResponder { DispatchQueue.main.async { v.resignFirstResponder() } }
    }
}

final class KeyboardInputView: UIView, UIKeyInput, UITextInputTraits {
    weak var client: Client?
    var onDismiss: (() -> Void)?

    // modificatori "a scatto": restano attivi per il prossimo tasto
    private var stickyMods: Float = 0
    private var modButtons: [Float: UIButton] = [:]

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardDidHideNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func keyboardHidden() { if isFirstResponder { resignFirstResponder(); onDismiss?() } }

    // MARK: barra sopra la tastiera

    private lazy var accessory: UIView = {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal; stack.spacing = 6; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        func button(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
            var cfg = UIButton.Configuration.gray()
            cfg.cornerStyle = .medium
            cfg.baseForegroundColor = .label
            if let symbol { cfg.image = UIImage(systemName: symbol) } else { cfg.title = title }
            cfg.contentInsets = .init(top: 6, leading: 12, bottom: 6, trailing: 12)
            let b = UIButton(configuration: cfg)
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            return b
        }
        for (title, bit) in [("Cmd", Mod.cmd), ("Ctrl", Mod.ctrl), ("Alt", Mod.alt), ("Shift", Mod.shift)] {
            let b = button(title) { [weak self] in self?.toggleMod(bit) }
            modButtons[bit] = b
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(button("Esc") { [weak self] in self?.sendKey(VK.escape) })
        stack.addArrangedSubview(button("Tab") { [weak self] in self?.sendKey(VK.tab) })
        for (sym, vk) in [("arrow.left", VK.left), ("arrow.up", VK.up), ("arrow.down", VK.down), ("arrow.right", VK.right)] {
            stack.addArrangedSubview(button("", symbol: sym) { [weak self] in self?.sendKey(vk) })
        }
        stack.addArrangedSubview(button("", symbol: "keyboard.chevron.compact.down") { [weak self] in self?.resignFirstResponder(); self?.onDismiss?() })
        scroll.addSubview(stack)
        bar.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor), scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        return bar
    }()

    override var inputAccessoryView: UIView? { accessory }

    private func toggleMod(_ bit: Float) {
        let on = Int(stickyMods) & Int(bit) == 0
        stickyMods = Float(on ? Int(stickyMods) | Int(bit) : Int(stickyMods) & ~Int(bit))
        refreshModButtons()
    }

    private func refreshModButtons() {
        for (bit, b) in modButtons {
            let on = Int(stickyMods) & Int(bit) != 0
            b.configuration?.baseBackgroundColor = on ? .tintColor : .tertiarySystemFill
            b.configuration?.baseForegroundColor = on ? .white : .label
        }
    }

    private func sendKey(_ vk: Float, mods: Float? = nil) {
        let m = mods ?? stickyMods
        client?.key(vk, mods: m)
        if mods == nil && stickyMods != 0 { stickyMods = 0; refreshModButtons() }
    }

    // MARK: UIKeyInput (tastiera software e caratteri della tastiera fisica)

    func insertText(_ text: String) {
        if text == "\n" { sendKey(VK.returnKey); return }
        if stickyMods != 0, text.count == 1, let vk = VK.ascii[Character(text.lowercased())] {
            sendKey(vk)      // scorciatoia: Cmd+C ecc.
            return
        }
        client?.text(text)
    }

    func deleteBackward() { sendKey(VK.delete, mods: stickyMods == 0 ? 0 : nil) }

    // MARK: tastiera fisica con modificatori (Cmd+Tab e simili non arrivano: se li tiene iPadOS)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            guard let key = p.key else { continue }
            let f = key.modifierFlags
            var mods: Float = 0
            if f.contains(.command) { mods += Mod.cmd }
            if f.contains(.control) { mods += Mod.ctrl }
            if f.contains(.alternate) { mods += Mod.alt }
            if f.contains(.shift) { mods += Mod.shift }
            let special: Float?
            switch key.keyCode {
            case .keyboardLeftArrow: special = VK.left
            case .keyboardRightArrow: special = VK.right
            case .keyboardUpArrow: special = VK.up
            case .keyboardDownArrow: special = VK.down
            case .keyboardEscape: special = VK.escape
            case .keyboardHome: special = VK.home
            case .keyboardEnd: special = VK.end
            case .keyboardPageUp: special = VK.pageUp
            case .keyboardPageDown: special = VK.pageDown
            case .keyboardDeleteForward: special = VK.forwardDelete
            default: special = nil
            }
            if let special {
                client?.key(special, mods: mods); handled = true
            } else if mods != 0 && (f.contains(.command) || f.contains(.control) || f.contains(.alternate)),
                      let ch = key.charactersIgnoringModifiers.lowercased().first, let vk = VK.ascii[ch] {
                client?.key(vk, mods: mods); handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}
