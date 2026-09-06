import Cocoa

/// Azioni di sistema. Mission Control si apre tramite LaunchServices
/// (come `open -a "Mission Control"`); lanciato come processo diretto
/// il binario viene ucciso da macOS. Aprirlo di nuovo mentre e' attivo lo chiude.
///   nessun argomento = Mission Control, "1" = App Expose', "2" = Scrivania
enum SystemActions {
    static func perform(_ a: Float) {
        let active = isMissionControlActive()
        switch a {
        case Action.missionControl:
            if !active { launch([]) }
        case Action.dismissMissionControl:
            if active { launch([]) }
        case Action.appExpose:
            launch(["1"])
        case Action.showDesktop:
            launch(["2"])
        case Action.launchpad:
            if !isAppsViewOpen() { toggleAppsView() }
        case Action.closeLaunchpad:
            if isAppsViewOpen() { toggleAppsView() }
        default: break
        }
    }

    /// Su macOS 26 la vista "App" (ex Launchpad) e' una finestra di Spotlight alta;
    /// la barra di ricerca di Spotlight e' bassa e non conta.
    static func isAppsViewOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Spotlight" || (w[kCGWindowOwnerName as String] as? String) == "Launchpad" {
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            if (b["Height"] as? Double ?? 0) > 400 { return true }
        }
        return false
    }

    /// `open -a Apps` apre la vista e, se e' gia' aperta, la chiude.
    static func toggleAppsView() {
        let candidates = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { _, error in
            if let error { log.error("vista App: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Con Mission Control (o App Expose') attivo il Dock ha finestre a schermo
    /// intero sui livelli 18-20; a riposo ha solo gli sfondi (livello negativo).
    static func isMissionControlActive() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Dock" {
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = b["Width"] as? Double ?? 0
            if layer >= 18 && width >= 800 { return true }
        }
        return false
    }

    private static func launch(_ args: [String]) {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = args
        cfg.activates = false
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            if let error { log.error("Mission Control: \\(error.localizedDescription, privacy: .public)") }
        }
    }
}
