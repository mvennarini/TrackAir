import Cocoa

/// Genera gli eventi mouse e tastiera di sistema con CoreGraphics.
/// Lo scorrimento e' emesso come un vero trackpad (continuo, con fasi e
/// inerzia), cosi' funzionano l'effetto elastico e lo swipe indietro di Safari.
final class MouseController {
    private var leftDown = false
    private var rightDown = false
    private var lastClickTime: TimeInterval = 0
    private var clickCount: Int64 = 1
    private var inScroll = false
    private var inMomentum = false
    private let source = CGEventSource(stateID: .hidSystemState)

    // fasi (valori di IOKit/CGEvent)
    private let phaseBegan: Int64 = 1, phaseChanged: Int64 = 2, phaseEnded: Int64 = 4
    private let momBegin: Int64 = 1, momContinue: Int64 = 2, momEnd: Int64 = 3

    private func location() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func clamp(_ p: CGPoint, from cur: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        let rects = (0..<Int(count)).map { CGDisplayBounds(ids[$0]) }
        if rects.contains(where: { $0.contains(p) }) { return p }
        let home = rects.first(where: { $0.contains(cur) }) ?? rects.first ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return CGPoint(x: min(max(p.x, home.minX), home.maxX - 1),
                       y: min(max(p.y, home.minY), home.maxY - 1))
    }

    func move(dx: CGFloat, dy: CGFloat) {
        let cur = location()
        let p = clamp(CGPoint(x: cur.x + dx, y: cur.y + dy), from: cur)
        let type: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : .mouseMoved)
        let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                         mouseButton: rightDown ? .right : .left)
        ev?.post(tap: .cghidEventTap)
    }

    func button(_ btn: Int, down: Bool) {
        let p = location()
        let now = Date().timeIntervalSince1970
        if btn == 0 {
            if down {
                clickCount = (now - lastClickTime < 0.45) ? clickCount + 1 : 1
                lastClickTime = now
            }
            leftDown = down
            let ev = CGEvent(mouseEventSource: source, mouseType: down ? .leftMouseDown : .leftMouseUp,
                             mouseCursorPosition: p, mouseButton: .left)
            ev?.setIntegerValueField(.mouseEventClickState, value: clickCount)
            ev?.post(tap: .cghidEventTap)
        } else {
            rightDown = down
            let ev = CGEvent(mouseEventSource: source, mouseType: down ? .rightMouseDown : .rightMouseUp,
                             mouseCursorPosition: p, mouseButton: .right)
            ev?.setIntegerValueField(.mouseEventClickState, value: 1)
            ev?.post(tap: .cghidEventTap)
        }
    }

    // Modificatori tenuti premuti: una raffica di tasti con lo stesso modificatore
    // (pizzico = molti Cmd+/Cmd-) non deve diventare "Cmd premuto due volte",
    // che alcune app trattano come gesto. Il modificatore resta giu' finche'
    // i tasti si fermano per 0,35 s.
    private var heldMods = 0
    private var releaseWork: DispatchWorkItem?
    private let keyQueue = DispatchQueue(label: "trackair.keys")

    private static let modKeyCodes: [(bit: Int, code: CGKeyCode, flag: CGEventFlags)] = [
        (1, 55, .maskCommand), (2, 59, .maskControl), (4, 58, .maskAlternate), (8, 56, .maskShift)
    ]

    private func flags(for mods: Int) -> CGEventFlags {
        var f = CGEventFlags()
        for m in Self.modKeyCodes where mods & m.bit != 0 { f.insert(m.flag) }
        return f
    }

    /// Le scorciatoie di sistema (Spazi, Mission Control) guardano lo stato reale
    /// dei modificatori: quindi si premono davvero i tasti Cmd/Ctrl/Alt/Shift.
    func key(_ code: CGKeyCode, mods: Int) {
        keyQueue.sync {
            releaseWork?.cancel()
            // rilascia i modificatori che non servono piu', premi quelli nuovi
            for m in Self.modKeyCodes where heldMods & m.bit != 0 && mods & m.bit == 0 {
                heldMods &= ~m.bit
                let e = CGEvent(keyboardEventSource: source, virtualKey: m.code, keyDown: false)
                e?.flags = flags(for: heldMods); e?.post(tap: .cghidEventTap)
            }
            for m in Self.modKeyCodes where mods & m.bit != 0 && heldMods & m.bit == 0 {
                heldMods |= m.bit
                let e = CGEvent(keyboardEventSource: source, virtualKey: m.code, keyDown: true)
                e?.flags = flags(for: heldMods); e?.post(tap: .cghidEventTap)
                usleep(15_000)
            }
            var f = flags(for: mods)
            // Le frecce sulla tastiera vera portano i flag "fn" e "tastierino":
            // senza, la scorciatoia Ctrl+freccia per gli Spazi non scatta (verificato).
            if (123...126).contains(code) { f.insert(.maskSecondaryFn); f.insert(.maskNumericPad) }
            let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            down?.flags = f; up?.flags = f
            down?.post(tap: .cghidEventTap)
            usleep(15_000)
            up?.post(tap: .cghidEventTap)

            let work = DispatchWorkItem { [weak self] in self?.releaseHeldMods() }
            releaseWork = work
            keyQueue.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func releaseHeldMods() {
        for m in Self.modKeyCodes.reversed() where heldMods & m.bit != 0 {
            heldMods &= ~m.bit
            let e = CGEvent(keyboardEventSource: source, virtualKey: m.code, keyDown: false)
            e?.flags = flags(for: heldMods); e?.post(tap: .cghidEventTap)
        }
    }

    /// Digita testo Unicode qualsiasi (accenti, simboli, emoji) senza passare dai keycode.
    func type(_ text: String) {
        keyQueue.sync {
            releaseWork?.cancel(); releaseHeldMods()
            let units = Array(text.utf16)
            var i = 0
            while i < units.count {
                let chunk = Array(units[i..<min(i + 16, units.count)])
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
                i += chunk.count
            }
        }
    }

    // MARK: scorrimento stile trackpad

    private func postScroll(dx: CGFloat, dy: CGFloat, phase: Int64, momentum: Int64) {
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        ev.post(tap: .cghidEventTap)
    }

    func scroll(dx: CGFloat, dy: CGFloat) {
        if inMomentum { momentumEnd() }
        if !inScroll {
            inScroll = true
            postScroll(dx: 0, dy: 0, phase: phaseBegan, momentum: 0)
        }
        postScroll(dx: dx, dy: dy, phase: phaseChanged, momentum: 0)
    }

    func scrollEnd() {
        guard inScroll else { return }
        inScroll = false
        postScroll(dx: 0, dy: 0, phase: phaseEnded, momentum: 0)
    }

    func momentum(dx: CGFloat, dy: CGFloat) {
        if inScroll { scrollEnd() }
        let phase = inMomentum ? momContinue : momBegin
        inMomentum = true
        postScroll(dx: dx, dy: dy, phase: 0, momentum: phase)
    }

    func momentumEnd() {
        guard inMomentum else { return }
        inMomentum = false
        postScroll(dx: 0, dy: 0, phase: 0, momentum: momEnd)
    }
}
