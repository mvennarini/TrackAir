import SwiftUI
import UIKit

/// Superficie del trackpad. Replica le impostazioni del trackpad del Mac:
///  1 dito: muove. Tap: clic. Doppio tap: doppio clic.
///  2 dita: scorre (con fasi e inerzia come un trackpad vero). Tap: clic destro. Pizzico: zoom.
///  3 dita: trascina (trascinamento a tre dita).
///  4 dita: sinistra/destra = Spazi, in alto = Mission Control, in basso = App Expose' (se attivo).
struct TrackpadView: UIViewRepresentable {
    @EnvironmentObject var client: Client
    @EnvironmentObject var settings: Settings

    func makeUIView(context: Context) -> TouchPadUIView {
        let v = TouchPadUIView()
        v.backgroundColor = UIColor(white: 0.11, alpha: 1)
        bind(v)
        return v
    }

    func updateUIView(_ uiView: TouchPadUIView, context: Context) { bind(uiView) }

    private func bind(_ v: TouchPadUIView) {
        let sens = CGFloat(settings.sensitivity)
        let accel = settings.acceleration
        let natural = settings.naturalScroll
        let scrollSpeed = CGFloat(settings.scrollSpeed)
        v.tapToClick = settings.tapToClick
        v.twoFingerRightClick = settings.twoFingerRightClick
        v.tapDrag = settings.tapDrag
        v.holdToDrag = settings.holdToDrag
        v.showDebug = settings.showDebug
        v.threeFingerDrag = settings.threeFingerDrag
        v.pinchZoom = settings.pinchZoom
        v.fourSpaces = settings.fourFingerSpaces
        v.fourMissionControl = settings.fourFingerMissionControl
        v.fourAppExpose = settings.fourFingerAppExpose
        v.fourPinch = settings.fourFingerPinch
        v.haptics = settings.haptics
        v.momentumEnabled = settings.momentum
        v.onMove = { dx, dy, speed in
            // accelerazione sulla velocita' reale (punti al secondo, filtrata),
            // non sulla distanza del singolo evento che oscilla col ritmo dei pacchetti
            var g = sens
            if accel { g *= 0.5 + min(speed / 480, 2.0) }
            client.move(dx: dx * g, dy: dy * g)
        }
        let s = 1.5 * scrollSpeed * (natural ? 1 : -1)
        v.onScroll = { dx, dy in client.scroll(dx: dx * s, dy: dy * s) }
        v.onScrollEnd = { client.scrollEnd() }
        v.onMomentum = { dx, dy in client.momentum(dx: dx * s, dy: dy * s) }
        v.onMomentumEnd = { client.momentumEnd() }
        v.onButton = { b, down in client.button(b, down: down) }
        v.onKey = { code, mods in client.key(code, mods: mods) }
        v.onAction = { a in client.action(a) }
    }
}

final class TouchPadUIView: UIView {
    var onMove: ((CGFloat, CGFloat, CGFloat) -> Void)?   // dx, dy, velocita' (pt/s)
    var onScroll: ((CGFloat, CGFloat) -> Void)?
    var onScrollEnd: (() -> Void)?
    var onMomentum: ((CGFloat, CGFloat) -> Void)?
    var onMomentumEnd: (() -> Void)?
    var onButton: ((Int, Bool) -> Void)?
    var onKey: ((Float, Float) -> Void)?
    var onAction: ((Float) -> Void)?

    var tapToClick = true
    var twoFingerRightClick = true
    var tapDrag = false
    var holdToDrag = true
    var showDebug = false { didSet { debugLabel.isHidden = !showDebug } }
    var threeFingerDrag = true
    var pinchZoom = true
    var fourSpaces = true
    var fourMissionControl = true
    var fourAppExpose = false
    var fourPinch = true
    var haptics = true
    var momentumEnabled = true

    // stato del gesto corrente
    private var active: [UITouch] = []
    private var startPoint: [UITouch: CGPoint] = [:]
    private var gestureStart: TimeInterval = 0
    private var travelled: CGFloat = 0
    private var maxFingers = 0
    private var lastTapEnd: TimeInterval = 0
    private var dragging = false          // trascinamento (tap-e-tieni o 3 dita)
    private var scrolling = false
    private var pinchStartDist: CGFloat = 0
    private var pinching = false
    private var swipeFired = false
    private var swipeAccum = CGPoint.zero
    private var spreadStart: CGFloat = 0
    private var countChangedAt: TimeInterval = 0
    private var holdTimer: Timer?
    private var speedEMA: CGFloat = 0
    private var lastMoveTime: TimeInterval = 0
    private var cancelledCount = 0

    private let debugLabel: UILabel = {
        let l = UILabel()
        l.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        l.textColor = UIColor(white: 0.7, alpha: 1)
        l.textAlignment = .center
        l.numberOfLines = 2
        l.isHidden = true
        l.isUserInteractionEnabled = false
        return l
    }()

    // inerzia
    private var samples: [(t: TimeInterval, dx: CGFloat, dy: CGFloat)] = []
    private var velocity = CGPoint.zero
    private var link: CADisplayLink?
    private var lastTick: TimeInterval = 0

    private let clickHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let rightHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let swipeHaptic = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = true
        clickHaptic.prepare()
        addSubview(debugLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        debugLabel.frame = CGRect(x: 0, y: bounds.height - 44, width: bounds.width, height: 36)
    }

    private func debug(_ text: String) {
        guard showDebug else { return }
        debugLabel.text = text
    }

    private var now: TimeInterval { CACurrentMediaTime() }

    // MARK: tocchi

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopMomentum(notify: true)
        let t = now
        let fresh = active.isEmpty
        for touch in touches where !active.contains(touch) {
            active.append(touch)
            startPoint[touch] = touch.location(in: self)
        }
        maxFingers = max(maxFingers, active.count)
        countChangedAt = t
        holdTimer?.invalidate(); holdTimer = nil
        if fresh {
            gestureStart = t
            travelled = 0
            speedEMA = 0
            lastMoveTime = 0
            scrolling = false
            pinching = false
            swipeFired = false
            swipeAccum = .zero
            samples.removeAll()
            if tapDrag && active.count == 1 && t - lastTapEnd < 0.28 {
                dragging = true
                onButton?(0, true)
            } else if holdToDrag && active.count == 1 {
                // dito fermo per 0,35 s = clic tenuto (come premere il trackpad)
                holdTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                    guard let self, self.active.count == 1, self.travelled < 6, !self.dragging else { return }
                    self.dragging = true
                    self.onButton?(0, true)
                    if self.haptics { self.clickHaptic.impactOccurred(intensity: 1.0) }
                    self.debug("clic tenuto: trascina")
                }
            }
        } else {
            endScrollIfNeeded()
        }
        if active.count == 2 { pinchStartDist = distance(active[0], active[1]) }
        if active.count >= 4 { spreadStart = spread() }
        debug("dita: \(active.count)")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if let s = startPoint[touch] {
                let p = touch.location(in: self)
                travelled = max(travelled, hypot(p.x - s.x, p.y - s.y))
            }
        }
        let moved = active.filter { touches.contains($0) }
        guard !moved.isEmpty else { return }
        let avg = averageDelta(moved)
        if travelled > 6 { holdTimer?.invalidate(); holdTimer = nil }

        // mentre si trascina (clic tenuto o 3 dita) qualunque dito muove il puntatore
        if dragging {
            emitMove(moved[0], event: event, fallback: avg)
            return
        }
        // le dita non atterrano tutte insieme: aspetto che il numero sia stabile
        guard now - countChangedAt > 0.05 else { return }

        switch active.count {
        case 1:
            emitMove(moved[0], event: event, fallback: avg)

        case 2:
            // pizzico: cambia la distanza tra le dita
            if pinchZoom && pinchStartDist > 0 {
                let dist = distance(active[0], active[1])
                let ratio = dist / pinchStartDist
                if ratio > 1.2 || ratio < 0.83 {
                    pinching = true
                    endScrollIfNeeded()
                    onKey?(ratio > 1 ? VK.equal : VK.minus, Mod.cmd)
                    pinchStartDist = dist
                    if haptics { swipeHaptic.selectionChanged() }
                    return
                }
                if moved.count == 2 {
                    let a = delta(moved[0]), b = delta(moved[1])
                    if a.x * b.x + a.y * b.y < 0 && hypot(a.x, a.y) > 1 && hypot(b.x, b.y) > 1 { return }
                }
            }
            if pinching { return }
            scrolling = true
            samples.append((now, avg.x, avg.y))
            if samples.count > 12 { samples.removeFirst() }
            onScroll?(avg.x, avg.y)

        case 3:
            guard threeFingerDrag else { debug("3 dita: trascinamento disattivato"); return }
            if travelled > 4 {
                dragging = true
                onButton?(0, true)
                if haptics { clickHaptic.impactOccurred(intensity: 0.6) }
                debug("3 dita: trascino")
                emitMove(moved[0], event: event, fallback: avg)
            }

        default:
            guard !swipeFired else { return }
            // pizzico a 4 dita: le dita si avvicinano (vista App) o si allargano (chiude)
            if fourPinch && spreadStart > 0 {
                let ratio = spread() / spreadStart
                if ratio < 0.68 { swipeFired = true; onAction?(Action.launchpad); debug("4 dita: vista App"); if haptics { swipeHaptic.selectionChanged() }; return }
                if ratio > 1.4 { swipeFired = true; onAction?(Action.closeLaunchpad); debug("4 dita: chiudi vista App"); if haptics { swipeHaptic.selectionChanged() }; return }
            }
            swipeAccum.x += avg.x
            swipeAccum.y += avg.y
            debug("4 dita: \(Int(swipeAccum.x)), \(Int(swipeAccum.y))")
            guard hypot(swipeAccum.x, swipeAccum.y) > 60 else { return }
            swipeFired = true
            if abs(swipeAccum.x) > abs(swipeAccum.y) {
                guard fourSpaces else { return }
                // il contenuto segue le dita: a sinistra = Spazio a destra
                onKey?(swipeAccum.x < 0 ? VK.right : VK.left, Mod.ctrl)
                debug(swipeAccum.x < 0 ? "4 dita: Spazio a destra" : "4 dita: Spazio a sinistra")
            } else if swipeAccum.y < 0 {
                guard fourMissionControl else { return }
                onAction?(Action.missionControl)
                debug("4 dita: Mission Control")
            } else if fourAppExpose {
                onAction?(Action.appExpose)
                debug("4 dita: App Expose'")
            } else {
                onAction?(Action.dismissMissionControl)
                debug("4 dita: chiudi Mission Control")
            }
            if haptics { swipeHaptic.selectionChanged() }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelledCount += 1
        debug("touches cancelled by iOS (\(cancelledCount)x, \(active.count) fingers)")
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        let before = active.count
        let anchorLifted = active.first.map { touches.contains($0) } ?? false
        active.removeAll { touches.contains($0) }
        for t in touches { startPoint.removeValue(forKey: t) }
        countChangedAt = now
        holdTimer?.invalidate(); holdTimer = nil

        // clic tenuto: si rilascia quando si alza il dito che lo teneva
        if dragging && maxFingers < 3 && anchorLifted {
            dragging = false
            onButton?(0, false)
            debug("rilasciato")
        }

        // fine dello scorrimento a 2 dita: fase "ended" e poi inerzia
        if before >= 2 && active.count < 2 && scrolling {
            scrolling = false
            onScrollEnd?()
            startMomentum()
        }
        // trascinamento a 3 dita: si rilascia quando le dita scendono sotto 3
        if maxFingers == 3 && dragging && active.count < 3 {
            dragging = false
            onButton?(0, false)
        }
        guard active.isEmpty else { return }

        let t = now
        let duration = t - gestureStart
        let isTap = duration < 0.3 && travelled < 10
        if dragging {
            dragging = false
            onButton?(0, false)
            lastTapEnd = isTap ? t : 0
        } else if isTap {
            switch maxFingers {
            case 1 where tapToClick:
                onButton?(0, true); onButton?(0, false)
                if haptics { clickHaptic.impactOccurred(intensity: 0.8) }
                lastTapEnd = t
            case 2 where twoFingerRightClick:
                stopMomentum(notify: true)
                onButton?(1, true); onButton?(1, false)
                if haptics { rightHaptic.impactOccurred() }
            default: break
            }
        }
        maxFingers = 0
        pinchStartDist = 0
        pinching = false
    }

    private func endScrollIfNeeded() {
        if scrolling { scrolling = false; onScrollEnd?() }
    }

    // MARK: inerzia

    private func startMomentum() {
        guard momentumEnabled, samples.count >= 2 else { return }
        let t = now
        let recent = samples.filter { t - $0.t < 0.09 }
        guard let first = recent.first, recent.count >= 2 else { return }
        let span = max(t - first.t, 0.016)
        let vx = recent.map(\.dx).reduce(0, +) / span
        let vy = recent.map(\.dy).reduce(0, +) / span
        guard hypot(vx, vy) > 120 else { return }
        velocity = CGPoint(x: vx, y: vy)
        lastTick = t
        link?.invalidate()
        let l = CADisplayLink(target: self, selector: #selector(momentumTick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func momentumTick() {
        let t = now
        let dt = min(t - lastTick, 0.05)
        lastTick = t
        onMomentum?(velocity.x * dt, velocity.y * dt)
        let decay = pow(0.965, dt * 60)
        velocity.x *= decay; velocity.y *= decay
        if hypot(velocity.x, velocity.y) < 12 { stopMomentum(notify: true) }
    }

    private func stopMomentum(notify: Bool) {
        guard link != nil else { return }
        link?.invalidate(); link = nil
        velocity = .zero
        if notify { onMomentumEnd?() }
    }

    /// Manda lo spostamento del dito usando tutti i campioni intermedi del touch
    /// (fino a 120 al secondo sui display ProMotion) e la velocita' filtrata.
    private func emitMove(_ touch: UITouch, event: UIEvent?, fallback: CGPoint) {
        var dx: CGFloat = 0, dy: CGFloat = 0
        var samples = 0
        if let co = event?.coalescedTouches(for: touch), co.count > 1 {
            for t in co { let d = delta(t); dx += d.x; dy += d.y; samples += 1 }
        } else {
            dx = fallback.x; dy = fallback.y; samples = 1
        }
        let t = touch.timestamp
        let dt = lastMoveTime > 0 ? max(t - lastMoveTime, 0.004) : 1.0 / 60.0
        lastMoveTime = t
        let inst = hypot(dx, dy) / CGFloat(dt)
        speedEMA += (inst - speedEMA) * 0.35
        onMove?(dx, dy, speedEMA)
    }

    // MARK: utilita'

    private func delta(_ t: UITouch) -> CGPoint {
        let p = t.location(in: self), q = t.previousLocation(in: self)
        return CGPoint(x: p.x - q.x, y: p.y - q.y)
    }
    private func averageDelta(_ ts: [UITouch]) -> CGPoint {
        var dx: CGFloat = 0, dy: CGFloat = 0
        for t in ts { let d = delta(t); dx += d.x; dy += d.y }
        return CGPoint(x: dx / CGFloat(ts.count), y: dy / CGFloat(ts.count))
    }
    /// Distanza media delle dita dal loro centro: misura quanto la mano e' "aperta".
    private func spread() -> CGFloat {
        let pts = active.map { $0.location(in: self) }
        guard pts.count >= 2 else { return 0 }
        let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count), cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        return pts.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / CGFloat(pts.count)
    }
    private func distance(_ a: UITouch, _ b: UITouch) -> CGFloat {
        let p = a.location(in: self), q = b.location(in: self)
        return hypot(p.x - q.x, p.y - q.y)
    }
}
