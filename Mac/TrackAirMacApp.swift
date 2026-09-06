import SwiftUI
import Cocoa
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.request()
    }
}

enum Permissions {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func request() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { log.error("login item: \(error.localizedDescription, privacy: .public)") }
    }
}

@main
struct TrackAirMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var server = Server()
    @State private var loginItem = LoginItem.enabled
    @State private var trusted = Permissions.trusted

    var body: some Scene {
        MenuBarExtra("TrackAir", systemImage: server.connected.isEmpty ? "hand.point.up.left" : "hand.point.up.left.fill") {
            if !trusted {
                Button(String(localized: "Grant Accessibility permission…")) {
                    Permissions.request(); Permissions.openSettings()
                }
                Divider()
            }
            if server.connected.isEmpty {
                Text(String(localized: "No device connected"))
            } else {
                ForEach(server.connected) { d in
                    Text(String(localized: "Connected: \(d.name)"))
                }
            }
            Divider()
            Button(String(localized: "Pair a new device…")) { server.pairing.begin() }
            if let web = server.web {
                Button(String(localized: "Copy web address: \(web.url)")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(web.url, forType: .string)
                }
            }
            if !server.peers.isEmpty {
                Menu(String(localized: "Paired devices")) {
                    ForEach(server.peers) { p in
                        Button(String(localized: "Forget \(p.name)")) { server.forget(p.id) }
                    }
                }
            }
            Divider()
            Toggle(String(localized: "Launch at login"), isOn: Binding(
                get: { loginItem },
                set: { LoginItem.set($0); loginItem = LoginItem.enabled }))
            Divider()
            Text("TrackAir \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
            Button(String(localized: "Quit")) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onChange(of: server.connected) { _ in trusted = Permissions.trusted }
    }
}
