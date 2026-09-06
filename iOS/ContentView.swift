import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var client: Client
    @EnvironmentObject var settings: Settings
    @State private var showSettings = false
    @State private var showKeyboard = false
    @State private var resizeStart: CGSize? = nil
    @State private var searchingSince = Date()

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if isPad && settings.padWidth > 0 {
                    padResizable(in: geo)
                } else {
                    TrackpadView().ignoresSafeArea()
                }
                overlay
                if !client.isConnected { statusCard }
                KeyboardBridge(active: $showKeyboard).frame(width: 0, height: 0)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $client.showPINEntry) { PairingSheet() }
    }

    private var statusText: String {
        switch client.state {
        case .searching: return String(localized: "Looking for your Mac…")
        case .connecting(let n): return String(localized: "Connecting to \(n)…")
        case .pairing(let n): return String(localized: "Pairing with \(n)…")
        case .connected(let n): return String(localized: "Connected to \(n)")
        }
    }

    /// Pallino di stato e ingranaggio nella fascia in alto (accanto alla Dynamic Island).
    private var overlay: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Spacer()
            Button { showKeyboard.toggle() } label: {
                Image(systemName: showKeyboard ? "keyboard.fill" : "keyboard")
                    .font(.system(size: 14))
                    .foregroundStyle(showKeyboard ? Color.accentColor : .secondary)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(String(localized: "Keyboard"))
            .disabled(!client.isConnected)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(String(localized: "Settings"))
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    /// Scheda al centro quando non si e' collegati: stato o istruzioni.
    private var statusCard: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.white)
            Text(statusText).font(.headline).foregroundStyle(.white)
            if case .searching = client.state, client.found.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "No Mac found yet. Make sure that:")).font(.subheadline.weight(.semibold))
                    Label(String(localized: "TrackAir is open on your Mac (icon in the menu bar)"), systemImage: "1.circle")
                    Label(String(localized: "Mac and this device are on the same Wi-Fi network"), systemImage: "2.circle")
                    Label(String(localized: "Local Network access is allowed for TrackAir in Settings"), systemImage: "3.circle")
                }
                .font(.footnote).foregroundStyle(.white.opacity(0.85))
            }
            if case .pairing = client.state {
                Button(String(localized: "Enter PIN")) { client.showPINEntry = true }
                    .buttonStyle(.borderedProminent)
            }
            if client.stalled {
                Text(String(localized: "The Mac is not answering. Check that both are on the same Wi-Fi network."))
                    .font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                HStack {
                    Button(String(localized: "Try again")) { client.retry() }.buttonStyle(.bordered)
                    Button(String(localized: "Pair again")) { client.repair() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }

    /// Su iPad: trackpad ridotto e centrato, con maniglia per ridimensionarlo.
    private func padResizable(in geo: GeometryProxy) -> some View {
        let avail = CGSize(width: geo.size.width - 24, height: geo.size.height - 24)
        let w = min(CGFloat(settings.padWidth), avail.width)
        let h = min(CGFloat(settings.padHeight > 0 ? settings.padHeight : avail.height), avail.height)
        return ZStack(alignment: .bottomTrailing) {
            TrackpadView()
                .frame(width: max(w, 200), height: max(h, 150))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            if resizeStart == nil { resizeStart = CGSize(width: w, height: h) }
                            guard let s = resizeStart else { return }
                            settings.padWidth = Double(min(max(s.width + v.translation.width, 200), avail.width))
                            settings.padHeight = Double(min(max(s.height + v.translation.height, 150), avail.height))
                        }
                        .onEnded { _ in resizeStart = nil }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Abbinamento: inquadra il codice sul Mac, oppure digita il PIN.
struct PairingSheet: View {
    @EnvironmentObject var client: Client
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var useCamera = true
    @State private var cameraDenied = false
    @State private var scanned = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if useCamera && !cameraDenied {
                    ZStack {
                        ScannerView { text in
                            guard !scanned else { return }
                            if client.submitCode(text) {
                                scanned = true
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.white.opacity(0.5), lineWidth: 2)
                            .padding(40)
                        if scanned { ProgressView().tint(.white).scaleEffect(1.6) }
                    }
                    .frame(maxWidth: 520)
                    .aspectRatio(1, contentMode: .fit)
                    Text(scanned
                         ? String(localized: "Code read. Pairing…")
                         : String(localized: "Point the camera at the code on your Mac's screen."))
                        .multilineTextAlignment(.center)
                    if let e = client.pairingError {
                        Text(e).foregroundStyle(.red).multilineTextAlignment(.center).font(.footnote)
                    }
                    Button(String(localized: "Type the PIN instead")) { useCamera = false }
                        .font(.footnote)
                } else {
                    Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(.tint)
                    Text(String(localized: "A 6-digit PIN is shown on your Mac's screen. Enter it here to pair securely."))
                        .multilineTextAlignment(.center)
                    TextField("000000", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .onChange(of: pin) { _, v in
                            let digits = v.filter(\.isNumber).prefix(Pairing.pinLength)
                            if String(digits) != v { pin = String(digits) }
                            if pin.count == Pairing.pinLength { client.submitPIN(pin) }
                        }
                    if let e = client.pairingError {
                        Text(e).foregroundStyle(.red).multilineTextAlignment(.center).font(.footnote)
                    }
                    Button(String(localized: "Pair")) { client.submitPIN(pin) }
                        .buttonStyle(.borderedProminent)
                        .disabled(pin.count != Pairing.pinLength)
                    if !cameraDenied {
                        Button(String(localized: "Scan the code instead")) { useCamera = true }.font(.footnote)
                    }
                    Button(String(localized: "I don't see a code on the Mac")) { client.knock(); pin = "" }
                        .font(.footnote)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle(String(localized: "Pair with Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(String(localized: "Cancel")) { dismiss() } }
            .onAppear { requestCamera() }
            .onChange(of: useCamera) { _, v in if !v { focused = true } }
        }
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraDenied = false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { cameraDenied = !ok; if !ok { useCamera = false } }
            }
        default: cameraDenied = true; useCamera = false
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var client: Client
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Mac")) {
                    if client.found.isEmpty {
                        Text(String(localized: "No Mac found. Open TrackAir on the Mac and stay on the same Wi-Fi network."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(client.found) { m in
                        Button { client.connect(to: m) } label: {
                            HStack {
                                Text(m.name)
                                Spacer()
                                if client.currentName == m.name && client.isConnected {
                                    Image(systemName: "checkmark").foregroundStyle(Color.green)
                                } else if m.macID.map({ client.store.peer($0) != nil }) ?? false {
                                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                    Button(String(localized: "Search again")) { client.startBrowsing() }
                }
                if !client.peers.isEmpty {
                    Section(String(localized: "Paired Macs")) {
                        ForEach(client.peers) { p in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(p.name)
                                    let when = p.pairedAt.formatted(date: .abbreviated, time: .omitted)
                                    Text(String(localized: "Paired \(when)"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(String(localized: "Forget"), role: .destructive) { client.forget(p.id) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section(String(localized: "Pointer and clicks")) {
                    VStack(alignment: .leading) {
                        let speed = String(format: "%.1f", settings.sensitivity)
                        Text(String(localized: "Pointer speed: \(speed)"))
                        Slider(value: $settings.sensitivity, in: 0.5...4, step: 0.1)
                    }
                    Toggle(String(localized: "Acceleration"), isOn: $settings.acceleration)
                    Toggle(String(localized: "Tap to click"), isOn: $settings.tapToClick)
                    Toggle(String(localized: "Secondary click with two fingers"), isOn: $settings.twoFingerRightClick)
                    Toggle(String(localized: "Three-finger drag"), isOn: $settings.threeFingerDrag)
                    Toggle(String(localized: "Hold one finger still to click and drag"), isOn: $settings.holdToDrag)
                    Toggle(String(localized: "Tap, then hold to drag"), isOn: $settings.tapDrag)
                    Toggle(String(localized: "Haptic feedback"), isOn: $settings.haptics)
                }
                Section(String(localized: "Scroll and zoom")) {
                    Toggle(String(localized: "Natural scrolling"), isOn: $settings.naturalScroll)
                    VStack(alignment: .leading) {
                        let speed = String(format: "%.1f", settings.scrollSpeed)
                        Text(String(localized: "Scroll speed: \(speed)"))
                        Slider(value: $settings.scrollSpeed, in: 0.3...3, step: 0.1)
                    }
                    Toggle(String(localized: "Momentum"), isOn: $settings.momentum)
                    Toggle(String(localized: "Pinch to zoom"), isOn: $settings.pinchZoom)
                }
                Section(String(localized: "Four fingers")) {
                    Toggle(String(localized: "Swipe between Spaces (left/right)"), isOn: $settings.fourFingerSpaces)
                    Toggle(String(localized: "Mission Control (up)"), isOn: $settings.fourFingerMissionControl)
                    Toggle(String(localized: "App Exposé (down)"), isOn: $settings.fourFingerAppExpose)
                    Toggle(String(localized: "Pinch: Apps view (close to open, spread to close)"), isOn: $settings.fourFingerPinch)
                }
                if UIDevice.current.userInterfaceIdiom == .pad {
                    Section("iPad") {
                        if settings.padWidth > 0 {
                            Button(String(localized: "Full-screen trackpad")) { settings.padWidth = 0; settings.padHeight = 0 }
                        } else {
                            Button(String(localized: "Resizable trackpad")) { settings.padWidth = 600; settings.padHeight = 400 }
                        }
                    }
                }
                Section(String(localized: "Diagnostics")) {
                    Toggle(String(localized: "Show recognized gestures"), isOn: $settings.showDebug)
                }
                Section(String(localized: "Gestures")) {
                    Text(String(localized: "One finger moves. Tap to click, double-tap to double-click.\nTwo fingers scroll with momentum. Two-finger tap for secondary click. Pinch to zoom.\nThree fingers drag.\nFour fingers left/right switch Spaces, up opens Mission Control, pinch opens the Apps view.\nKeyboard button: type on the Mac; the bar above the keys has Cmd, Ctrl, Alt, Shift, Esc, Tab and arrows for shortcuts. A hardware keyboard works too.\nDefaults mirror the Trackpad settings of your Mac."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                    Text(String(localized: "TrackAir \(version). Connections are encrypted end to end (ChaCha20-Poly1305) after pairing with a PIN. No data leaves your network."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("TrackAir")
            .toolbar { Button(String(localized: "Done")) { dismiss() } }
        }
    }
}
