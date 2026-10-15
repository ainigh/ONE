import AVFoundation
import Cocoa
import ServiceManagement
import WebKit

// MARK: - Model

/// The two modes a session alternates between (Specification §1).
enum Mode: String {
    case opened, closed

    var title: String { self == .opened ? "Opened" : "Closed" }
    var other: Mode { self == .opened ? .closed : .opened }
}

enum Config {
    /// Allowed slot values, in minutes (§2).
    static let slots = [4, 8, 16]
    static let defaultSlots: [Mode: Int] = [.opened: 16, .closed: 4]
    /// Session lengths offered at activation, in minutes (§4). The 10-minute one is for trying
    /// the flow: with 4-minute slots it runs Opened, Closed, then Opened again before it ends.
    static let sessionMinutes = [10, 60, 120, 240, 480]

    /// "10 minutes", "1 hour", "2 hours".
    static func sessionTitle(minutes: Int) -> String {
        if minutes % 60 != 0 { return "\(minutes) minutes" }
        return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
    }
    static let pauseMinutes = 20                   // §7
    static let puzzleAttempts = 3                  // §6
    static let lockoutMinutes = 2                  // §6: after the third wrong answer
    static let cooldownMinutes = 60                // §6: one escape per hour
    static let primeLimit = 50                     // §6: primes below 50

    /// Real seconds in one of the app's minutes: 60, unless launched with `-minute N` (1...60)
    /// to try the whole cycle quickly. Every duration in the spec is scaled by it.
    static var secondsPerMinute: Double {
        let v = UserDefaults.standard.object(forKey: "minute") != nil
            ? UserDefaults.standard.integer(forKey: "minute") : 60
        return (1...60).contains(v) ? Double(v) : 60
    }

    static var muted: Bool { UserDefaults.standard.bool(forKey: "mute") }

    /// How much louder than the system plays them the sounds are, in dB (0...24, default 18).
    /// A peak limiter after the boost keeps it from clipping.
    static var soundBoost: Float {
        guard UserDefaults.standard.object(forKey: "soundBoost") != nil else { return 18 }
        return min(max(UserDefaults.standard.float(forKey: "soundBoost"), 0), 24)
    }
    /// The loudness choices in the Sound menu, in dB of boost.
    static let loudness: [(title: String, boost: Float)] = [
        ("As macOS plays them", 0), ("Loud", 12), ("Louder", 18), ("Loudest", 24),
    ]

    static func seconds(minutes: Int) -> TimeInterval { Double(minutes) * secondsPerMinute }

    /// `mm:ss` of a real interval, in the app's minutes, rounded up so a full minute reads 01:00.
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(ceil(interval / secondsPerMinute * 60 - 0.0001)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// `mm:ss` of a whole number of minutes.
    static func clock(minutes: Int) -> String { String(format: "%02d:%02d", minutes, 0) }

    /// "3 h 12 min", "12 min", "under a minute": a longer stretch, in the app's minutes.
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(ceil(interval / secondsPerMinute - 0.0001))
        if minutes <= 0 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// The wall-clock time an interval from now lands on, as the Mac shows times ("3:46 PM").
    static func wallTime(in interval: TimeInterval) -> String {
        timeFormatter.string(from: Date().addingTimeInterval(interval))
    }
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Reminder marks for a slot (§5): halving intervals, none under one minute from the end.
    static func reminders(forSlot slot: Int) -> [Int] {
        var marks: [Int] = []
        var m = slot / 2
        while m >= 1 {
            marks.append(m)
            m /= 2
        }
        return marks
    }

    static let usage = """
    CountdownOverlay — the Opened / Closed session timer from Specification.md.

    usage: CountdownOverlay [-minute SECONDS] [-mute YES] [-soundBoost DB]

      -minute N       real seconds per app minute, 1...60 (default 60), to try the cycle quickly
      -mute YES       no sounds at transitions
      -soundBoost N   how much louder than the system the sounds play, 0...24 dB (default 18)
      -preview DIR    draw the blocked screens, a pop-up and the menu into PNGs in DIR, then quit
      -h, --help      show this help
      --version       print the version and commit this copy was built from
    """
}

// MARK: - Sound (Specification §9)

/// Sounds at transition points, from the system set in /System/Library/Sounds.
enum Sound: String {
    case confirmation = "Glass"       // a confirmation box appears: a mode is about to change
    case opened = "Hero"              // Opened begins
    case closed = "Submarine"         // Closed begins
    case reminder = "Tink"            // a reminder (§5)
    case wrong = "Basso"              // a wrong puzzle answer
    case escaped = "Pop"              // the puzzle was solved: the pause begins
    case pauseOver = "Blow"           // the pause is over: back to a confirmation
    case sessionOver = "Funk"         // the session has ended

    /// Times it plays in a row: the shortest ones are over before you notice them otherwise.
    var times: Int {
        switch self {
        case .reminder, .escaped: return 3
        default: return 1
        }
    }

    func play() {
        guard !Config.muted else { return }
        SoundPlayer.shared.play(rawValue, times: times)
    }
}

/// Plays the system sounds louder than NSSound can (its volume tops out at what the system plays):
/// player → gain → peak limiter → output, so the boost raises the loudness without clipping. The
/// engine only runs while something is playing. Without an output device it falls back to NSSound.
final class SoundPlayer {
    static let shared = SoundPlayer()

    private let engine = AVAudioEngine()
    private let bus = AVAudioMixerNode()             // takes each sound in its own format
    private let gain = AVAudioUnitEQ(numberOfBands: 0)
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var active: [ObjectIdentifier: AVAudioPlayerNode] = [:]   // playing right now
    private var stopWork: DispatchWorkItem?

    private init() {
        gain.globalGain = Config.soundBoost
        for node in [bus, gain, limiter] as [AVAudioNode] { engine.attach(node) }
        engine.connect(bus, to: gain, format: nil)
        engine.connect(gain, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
        // Headphones plugged in or out, a new output device: the engine stops itself, and the
        // sounds that were playing never report back. Let go of them; the next sound restarts it.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in self?.reset() }
    }

    /// Picks up a new loudness from the Sound menu.
    func updateBoost() { gain.globalGain = Config.soundBoost }

    func play(_ name: String, times: Int) {
        guard let buffer = buffer(named: name), start() else {
            // `NSSound(named:)` hands back a shared instance that ignores play() while it is
            // already playing; a copy plays every time.
            (NSSound(named: NSSound.Name(name))?.copy() as? NSSound)?.play()
            return
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: bus, format: buffer.format)
        // Repeats follow each other with a short gap, on the player's own clock.
        let rate = buffer.format.sampleRate
        let step = Double(buffer.frameLength) / rate + 0.09
        let count = max(times, 1)
        for i in 0..<count {
            let at = AVAudioTime(sampleTime: AVAudioFramePosition(Double(i) * step * rate), atRate: rate)
            let last = i == count - 1
            player.scheduleBuffer(buffer, at: at, options: [], completionCallbackType: .dataPlayedBack) { _ in
                guard last else { return }
                DispatchQueue.main.async { [weak self] in self?.finished(player) }
            }
        }
        active[ObjectIdentifier(player)] = player
        stopWork?.cancel()
        player.play()
    }

    private func finished(_ player: AVAudioPlayerNode) {
        // Already let go of (by a reset): nothing to do.
        guard active.removeValue(forKey: ObjectIdentifier(player)) != nil else { return }
        player.stop()
        engine.detach(player)
        scheduleStop()
    }

    private func reset() {
        let players = Array(active.values)
        active.removeAll()
        for player in players {
            player.stop()
            engine.detach(player)
        }
        scheduleStop()
    }

    /// Lets go of the audio hardware once it's been quiet for a moment.
    private func scheduleStop() {
        guard active.isEmpty else { return }
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.active.isEmpty, self.engine.isRunning else { return }
            self.engine.stop()
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func start() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            NSLog("sound: couldn't start the audio engine: %@", error.localizedDescription)
            return false
        }
    }

    private func buffer(named name: String) -> AVAudioPCMBuffer? {
        if let buffer = buffers[name] { return buffer }
        let fm = FileManager.default
        let dirs = ["/System/Library/Sounds", "/Library/Sounds",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds").path]
        guard let path = dirs.map({ "\($0)/\(name).aiff" }).first(where: fm.fileExists(atPath:)),
              let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        buffers[name] = buffer
        return buffer
    }
}

/// The escape puzzle (§6): two random primes below 50, summed or multiplied.
struct Puzzle {
    static let primes: [Int] = (2..<Config.primeLimit).filter { n in
        !(2..<n).contains(where: { n % $0 == 0 })
    }

    let question: String
    let answer: Int
    var attemptsLeft = Config.puzzleAttempts

    static func random() -> Puzzle {
        let a = primes.randomElement()!, b = primes.randomElement()!
        return Bool.random()
            ? Puzzle(question: "\(a) + \(b) = ?", answer: a + b)
            : Puzzle(question: "\(a) × \(b) = ?", answer: a * b)
    }
}

/// What survives the app being killed or the Mac restarting (§8): enough to reopen to a
/// confirmation for the interrupted mode, plus the slots, the escape cooldown and the session's
/// tally of Closed rounds.
enum Store {
    private static let d = UserDefaults.standard

    static var sessionEnd: Date? {
        get { d.object(forKey: "session.end") as? Date }
        set { d.set(newValue, forKey: "session.end") }
    }
    /// The mode that was running, confirming, or (for a pause) due next.
    static var interruptedMode: Mode? {
        get { d.string(forKey: "session.mode").flatMap(Mode.init(rawValue:)) }
        set { d.set(newValue?.rawValue, forKey: "session.mode") }
    }
    /// Closed rounds finished in this session, and their minutes.
    static var closedRounds: Int {
        get { d.integer(forKey: "session.closedRounds") }
        set { d.set(newValue, forKey: "session.closedRounds") }
    }
    static var closedMinutes: Int {
        get { d.integer(forKey: "session.closedMinutes") }
        set { d.set(newValue, forKey: "session.closedMinutes") }
    }
    static var lastEscape: Date? {
        get { d.object(forKey: "escape.last") as? Date }
        set { d.set(newValue, forKey: "escape.last") }
    }
    static func slot(for mode: Mode) -> Int {
        let v = d.integer(forKey: "slot.\(mode.rawValue)")
        return Config.slots.contains(v) ? v : Config.defaultSlots[mode]!
    }
    static func setSlot(_ minutes: Int, for mode: Mode) {
        d.set(minutes, forKey: "slot.\(mode.rawValue)")
    }
    static func clearSession() {
        sessionEnd = nil
        interruptedMode = nil
        closedRounds = 0
        closedMinutes = 0
    }
}

// MARK: - Look

/// The palette of the canvas (and "example style for node.md"), so every surface of the app
/// speaks the same language: teal for Opened, amber for Closed, on a dark green-grey ground.
enum Theme {
    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
    static let ground = color(0x141917)
    static let ink = color(0xe5eae6)
    static let muted = color(0x8d9a93)
    static let faint = color(0x5f6b65)
    static let opened = color(0x6fc3ad)
    static let closed = color(0xeba35a)
    static let rust = color(0xd6735c)
    static func tint(_ mode: Mode) -> NSColor { mode == .opened ? opened : closed }

    /// The rounded system face, with digits that don't jiggle as they count down.
    static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }

    static func label(_ text: String, font: NSFont, color: NSColor = ink,
                      align: NSTextAlignment = .center, wraps: Bool = true) -> NSTextField {
        let l = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color
        l.alignment = align
        return l
    }

    /// A small capsule naming a mode or state: "CLOSED", tinted.
    static func pill(_ text: String, tint: NSColor, size: CGFloat) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: tint,
            .kern: size * 0.14,
        ])
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        pill.layer?.borderColor = tint.withAlphaComponent(0.35).cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.cornerRadius = (size * 1.9) / 2
        pill.addSubview(label)
        pill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: size * 1.9),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: size * 0.9),
            // As wide as its words, wherever it sits (a stack would otherwise stretch it).
            pill.widthAnchor.constraint(equalTo: label.widthAnchor, constant: size * 1.65),
        ])
        pill.setAccessibilityElement(true)
        pill.setAccessibilityRole(.staticText)
        pill.setAccessibilityLabel(text)
        return pill
    }

    /// A rounded mask for visual-effect views, which ignore their layer's corner radius.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A thin rounded bar showing how much of something is left.
final class ProgressBar: NSView {
    private let fill = CALayer()
    private var draining = false

    var fraction: CGFloat = 1 {
        didSet { if abs(fraction - oldValue) > 0.0005 { needsLayout = true } }
    }
    var tint: NSColor = Theme.closed {
        didSet { fill.backgroundColor = tint.cgColor }
    }

    init(height: CGFloat, track: NSColor = NSColor(white: 1, alpha: 0.12)) {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: height))
        wantsLayer = true
        layer?.backgroundColor = track.cgColor
        layer?.cornerRadius = height / 2
        layer?.masksToBounds = true
        fill.backgroundColor = tint.cgColor
        fill.cornerRadius = height / 2
        layer?.addSublayer(fill)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if draining {
            fill.frame = bounds
        } else {
            fill.frame = NSRect(x: 0, y: 0, width: bounds.width * max(0, min(1, fraction)), height: bounds.height)
        }
        CATransaction.commit()
        setAccessibilityValue(NSNumber(value: Double(fraction)))
    }

    /// Empties smoothly from full over `seconds`, on its own (the pop-up's countdown).
    func drain(over seconds: TimeInterval) {
        draining = true
        layoutSubtreeIfNeeded()
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.frame = bounds
        let a = CABasicAnimation(keyPath: "transform.scale.x")
        a.fromValue = 1
        a.toValue = 0
        a.duration = seconds
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        fill.add(a, forKey: "drain")
    }
}

/// The menu-bar icon, drawn rather than picked: a ring whose pie is the time left in the mode,
/// so a glance at the menu bar says how far along you are. Template images, so they follow the
/// menu bar's colour.
enum StatusIcon {
    enum Kind: Hashable {
        case idle                                  // the cycle: half Opened, half Closed
        case ready                                 // waiting for Start
        case left(Int)                             // how many of `steps` of the mode are still to go
        case paused
    }
    static let steps = 48
    private static var cache: [Kind: NSImage] = [:]

    static func kind(left fraction: Double) -> Kind {
        .left(max(1, min(steps, Int(ceil(fraction * Double(steps))))))
    }

    static func image(_ kind: Kind) -> NSImage {
        if let image = cache[kind] { return image }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let ringRect = rect.insetBy(dx: 1.25, dy: 1.25)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let inner = ringRect.width / 2 - 2.25
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 1.5
            ring.stroke()
            switch kind {
            case .idle:
                let half = NSBezierPath()
                half.move(to: center)
                half.appendArc(withCenter: center, radius: inner, startAngle: 90, endAngle: 270)
                half.close()
                half.fill()
            case .ready:
                NSBezierPath(ovalIn: NSRect(x: center.x - 2.25, y: center.y - 2.25, width: 4.5, height: 4.5)).fill()
            case .left(let step):
                let sweep = 360 * CGFloat(step) / CGFloat(steps)
                if sweep >= 359.9 {
                    NSBezierPath(ovalIn: NSRect(x: center.x - inner, y: center.y - inner,
                                                width: inner * 2, height: inner * 2)).fill()
                } else {
                    let pie = NSBezierPath()
                    pie.move(to: center)
                    pie.appendArc(withCenter: center, radius: inner, startAngle: 90,
                                  endAngle: 90 - sweep, clockwise: true)
                    pie.close()
                    pie.fill()
                }
            case .paused:
                for dx in [-2.0, 1.0] as [CGFloat] {
                    NSBezierPath(roundedRect: NSRect(x: center.x + dx - 0.5, y: center.y - 3, width: 2, height: 6),
                                 xRadius: 0.8, yRadius: 0.8).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        cache[kind] = image
        return image
    }
}

// MARK: - Pop-up (reminders, Specification §5)

/// Reminders and the other things worth knowing mid-session, in the middle of every screen and
/// above everything, the blocked screen included. It never takes focus, so typing carries on;
/// it goes away by itself after a few seconds (the bar along its bottom counts them down), or at
/// a click. VoiceOver reads it out.
final class Popup {
    static let shared = Popup()
    private var panels: [PopupPanel] = []
    private var hideWork: DispatchWorkItem?

    func show(_ headline: String, _ detail: String, symbol: String, tint: NSColor,
              for seconds: TimeInterval = 6) {
        hideWork?.cancel()
        panels.forEach { $0.close() }
        panels = NSScreen.screens.map { screen in
            let panel = PopupPanel(screen: screen, headline: headline, detail: detail, symbol: symbol,
                                   tint: tint, seconds: seconds) { [weak self] in self?.hide() }
            let final = panel.frame
            panel.setFrame(final.offsetBy(dx: 0, dy: -14), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(final, display: true)
            }
            return panel
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "\(headline). \(detail)",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        let leaving = panels
        panels = []
        guard !leaving.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            leaving.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            leaving.forEach { $0.close() }
        })
    }
}

final class PopupPanel: NSPanel {
    /// Hands a click to the pop-up, even the first one while another app is active.
    private final class ClickView: NSView {
        var onClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick?() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }

    init(screen: NSScreen, headline: String, detail: String, symbol: String, tint: NSColor,
         seconds: TimeInterval, onClick: @escaping () -> Void) {
        let shortSide = min(screen.frame.width, screen.frame.height)
        let size = NSSize(width: min(max(shortSide * 0.5, 380), 560), height: min(max(shortSide * 0.3, 220), 300))
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(frame, display: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)  // above the overlay
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)

        let radius: CGFloat = 28
        let content = ClickView(frame: NSRect(origin: .zero, size: size))
        content.onClick = onClick

        let blur = NSVisualEffectView(frame: content.bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Theme.roundedMask(radius: radius)
        blur.autoresizingMask = [.width, .height]
        content.addSubview(blur)

        let tintWash = NSView(frame: content.bounds)
        tintWash.wantsLayer = true
        tintWash.layer?.cornerRadius = radius
        tintWash.layer?.backgroundColor = Theme.ground.withAlphaComponent(0.55).cgColor
        tintWash.layer?.borderWidth = 1
        tintWash.layer?.borderColor = tint.withAlphaComponent(0.35).cgColor
        tintWash.autoresizingMask = [.width, .height]
        content.addSubview(tintWash)

        var views: [NSView] = []
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size.height * 0.1, weight: .semibold)) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = tint
            views.append(icon)
        }
        views.append(Theme.label(headline, font: Theme.digits(size.height * 0.27, .bold), color: Theme.ink, wraps: false))
        views.append(Theme.label(detail, font: Theme.rounded(size.height * 0.085, .medium), color: Theme.ink.withAlphaComponent(0.78)))
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = size.height * 0.035
        stack.setCustomSpacing(size.height * 0.05, after: views[0])
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let bar = ProgressBar(height: 4, track: NSColor(white: 1, alpha: 0.08))
        bar.tint = tint.withAlphaComponent(0.85)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -4),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.86),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: radius),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -radius),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        contentView = content
        content.layoutSubtreeIfNeeded()
        bar.drain(over: seconds)
        setAccessibilityLabel("\(headline). \(detail)")
    }

    // Never takes focus: whatever you're typing in keeps the keys.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Canvas (what Closed shows on the main screen, Specification §10)

/// Canvas.html in a web view that lives as long as the app, so the surfaces and their undo history
/// survive from one Closed to the next. The page keeps its surfaces through `store`, which here
/// posts them to the app; they're saved in ~/Library/Application Support/CountdownOverlay/canvas.json.
final class Canvas: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private let page: URL
    private var saved: [String: String]

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CountdownOverlay")
    }
    static var fileURL: URL { folder.appendingPathComponent("canvas.json") }

    /// make-app.sh copies the page into the bundle; a bare binary looks beside itself and in the
    /// current directory for the source checkout's copy.
    static var pageURL: URL? {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.url(forResource: "Canvas", withExtension: "html"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Canvas.html"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Canvas.html"),
        ]
        return candidates.compactMap { $0 }.first { fm.fileExists(atPath: $0.path) }
    }

    /// nil when the page can't be found: Closed then shows the plain dark screen.
    init?(page: URL? = Canvas.pageURL) {
        guard let page = page else { return nil }
        self.page = page
        saved = Self.readSaved()
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "canvas")
        webView.navigationDelegate = self
        webView.setAccessibilityLabel("Canvas")
        load()
    }

    /// What was saved last time. A file that can't be read is set aside (never overwritten), and
    /// a good one is copied to canvas.previous.json first, so one bad moment can't lose the canvas.
    private static func readSaved() -> [String: String] {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        if let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            let previous = folder.appendingPathComponent("canvas.previous.json")
            try? fm.removeItem(at: previous)
            try? fm.copyItem(at: fileURL, to: previous)
            return saved
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = folder.appendingPathComponent("canvas.unreadable-\(stamp).json")
        try? fm.moveItem(at: fileURL, to: aside)
        NSLog("canvas: couldn't read %@; kept it as %@", fileURL.path, aside.path)
        return [:]
    }

    private func load() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let data = (try? JSONSerialization.data(withJSONObject: saved)) ?? Data("{}".utf8)
        // The saved surfaces, before the page's own script reads them. No context menu: its Look Up
        // and Search items would open other apps behind the overlay.
        let source = "window.canvasSaved = \(String(decoding: data, as: UTF8.self));"
            + "document.addEventListener('contextmenu', e => e.preventDefault());"
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    /// Ends a text edit in progress, so the page saves it (it saves when an edit is finished).
    func commitEdits() {
        webView.evaluateJavaScript("document.activeElement && document.activeElement.blur()",
                                   completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let key = body["key"] as? String, let value = body["value"] as? String else { return }
        saved[key] = value
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: saved).write(to: url, options: .atomic)
        } catch {
            NSLog("canvas: couldn't save %@: %@", url.path, error.localizedDescription)
        }
    }

    // If the page's process dies, bring it back with what was last saved.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { load() }

    // The page is the whole app: nothing navigates away from it.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

/// The canvas as an ordinary window, opened from its menu-bar icon while the screen isn't
/// blocked (§10). Closing it only hides it: the canvas lives on in the shared web view, which
/// moves into the overlay whenever the screen is blocked. Its title bar melts into the canvas.
final class CanvasWindow: NSWindow, NSWindowDelegate {
    private let canvas: Canvas

    init(canvas: Canvas) {
        self.canvas = canvas
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered,
                   defer: false)
        title = "Canvas"
        titlebarAppearsTransparent = true
        backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? Theme.ground : Theme.color(0xeef1ef)
        }
        tabbingMode = .disallowed
        isReleasedWhenClosed = false
        minSize = NSSize(width: 520, height: 380)
        contentView = NSView()
        delegate = self
        center()
        setFrameAutosaveName("CanvasWindow")       // reopens where it was last left
    }

    /// Takes the web view back (from the overlay, or wherever it was).
    func attach() {
        let web = canvas.webView
        guard let content = contentView, web.superview !== content else { return }
        web.removeFromSuperview()
        web.appearance = nil                       // the window follows the Mac's light or dark
        web.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: content.topAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    func windowWillClose(_ notification: Notification) { canvas.commitEdits() }
}

// MARK: - Overlay window (one per screen)

/// What the blocked screen can show. The clock, progress, slot and the lines of text are set
/// separately, every tick, without rebuilding the views.
enum OverlayContent: Equatable {
    case confirmation(heading: String, mode: Mode)
    case closed(escape: EscapeState)
    case puzzle(question: String, attemptsLeft: Int)
}

enum EscapeState: Equatable {
    case available
    case disabled                                  // after three wrong answers
    case hidden                                    // on cooldown
}

protocol OverlayActions: AnyObject {
    func overlayChoseSlot(_ minutes: Int)
    func overlayPressedStart()
    func overlayPressedEscape()
    func overlayAnswered(_ text: String)
    func overlayDismissedPuzzle()
}

final class OverlayWindow: NSWindow {
    weak var actions: OverlayActions?
    private(set) var content: OverlayContent?
    /// Another screen holds the canvas: Closed says where it is.
    var canvasElsewhere = false

    private let clockLabel = NSTextField(labelWithString: "")
    private let progress = ProgressBar(height: 6)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private var answerField: NSTextField?
    private var picker: NSSegmentedControl?
    private let headingSize: CGFloat
    private let textSize: CGFloat

    // Closed on the main screen (§10): the canvas fills it, under a strip with the clock, the
    // status line and I need out, and a hairline of progress along the strip's foot.
    private(set) var canvas: WKWebView?
    private let canvasPane = NSView()
    private let canvasBar = NSStackView()
    private let canvasClock = NSTextField(labelWithString: "")
    private let canvasStatus = NSTextField(labelWithString: "")
    private let canvasEscape = NSButton(title: "I need out", target: nil, action: nil)
    private let canvasProgress = ProgressBar(height: 3, track: NSColor(white: 1, alpha: 0.06))

    init(screen: NSScreen) {
        // Use the global-coordinate initializer: the `screen:` variant interprets
        // contentRect relative to that screen, which misplaces secondary displays.
        let shortSide = min(screen.frame.width, screen.frame.height)
        headingSize = min(max(shortSide * 0.055, 28), 60)
        textSize = min(max(shortSide * 0.024, 16), 30)
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        setFrame(screen.frame, display: false)

        level = .screenSaver                       // above everything, incl. full-screen apps
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false                 // swallow clicks so they don't fall through
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        appearance = NSAppearance(named: .darkAqua)  // dark controls on the dark screen

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        // Whatever was on screen goes out of focus under a deep shade: there, but unreadable.
        let blur = NSVisualEffectView(frame: content.bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        content.addSubview(blur)
        let shade = NSView(frame: content.bounds)
        shade.wantsLayer = true
        shade.layer?.backgroundColor = Theme.ground.withAlphaComponent(0.72).cgColor
        shade.autoresizingMask = [.width, .height]
        content.addSubview(shade)

        // Scale the digits with the screen so they fit on small displays
        // and stay legible on large ones.
        let clockSize = min(max(shortSide * 0.22, 64), 260)
        clockLabel.font = Theme.digits(clockSize, .bold)
        clockLabel.textColor = Theme.ink
        clockLabel.alignment = .center
        clockLabel.setAccessibilityLabel("Time left")
        progress.widthAnchor.constraint(equalToConstant: clockSize * 2.3).isActive = true

        statusLabel.font = Theme.rounded(textSize, .medium)
        statusLabel.textColor = Theme.ink.withAlphaComponent(0.8)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3
        noteLabel.font = Theme.rounded(textSize * 0.85, .regular)
        noteLabel.textColor = Theme.muted
        noteLabel.alignment = .center
        noteLabel.maximumNumberOfLines = 3

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = textSize
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.8),
        ])

        canvasClock.font = Theme.digits(textSize * 1.3, .bold)
        canvasClock.textColor = Theme.ink
        canvasClock.setAccessibilityLabel("Time left")
        canvasStatus.font = Theme.rounded(textSize * 0.8, .medium)
        canvasStatus.textColor = Theme.ink.withAlphaComponent(0.8)
        canvasStatus.lineBreakMode = .byTruncatingTail
        canvasStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        canvasEscape.target = self
        canvasEscape.action = #selector(escapePressed)
        canvasEscape.bezelStyle = .rounded
        canvasEscape.font = NSFont.systemFont(ofSize: textSize * 0.75, weight: .medium)
        canvasEscape.toolTip = "Solve a small sum to pause everything for \(Config.pauseMinutes) minutes"
        canvasProgress.tint = Theme.closed
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let pill = Theme.pill("Closed", tint: Theme.closed, size: textSize * 0.5)
        for view in [pill, canvasClock, canvasStatus, spacer, canvasEscape] as [NSView] { canvasBar.addArrangedSubview(view) }
        canvasBar.orientation = .horizontal
        canvasBar.alignment = .centerY
        canvasBar.spacing = textSize * 0.8
        canvasBar.edgeInsets = NSEdgeInsets(top: 10, left: textSize, bottom: 10, right: textSize)
        canvasBar.translatesAutoresizingMaskIntoConstraints = false
        canvasPane.wantsLayer = true
        // The canvas page's own ground colour, so the strip runs into it.
        canvasPane.layer?.backgroundColor = Theme.ground.cgColor
        canvasPane.translatesAutoresizingMaskIntoConstraints = false
        canvasPane.isHidden = true
        canvasPane.addSubview(canvasBar)
        canvasPane.addSubview(canvasProgress)
        content.addSubview(canvasPane)
        NSLayoutConstraint.activate([
            canvasPane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvasPane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvasPane.topAnchor.constraint(equalTo: content.topAnchor),
            canvasPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            canvasBar.leadingAnchor.constraint(equalTo: canvasPane.leadingAnchor),
            canvasBar.trailingAnchor.constraint(equalTo: canvasPane.trailingAnchor),
            canvasBar.topAnchor.constraint(equalTo: canvasPane.topAnchor, constant: topInset(of: screen)),
            canvasProgress.leadingAnchor.constraint(equalTo: canvasPane.leadingAnchor),
            canvasProgress.trailingAnchor.constraint(equalTo: canvasPane.trailingAnchor),
            canvasProgress.topAnchor.constraint(equalTo: canvasBar.bottomAnchor),
        ])
        contentView = content
    }

    /// Room for the camera housing on Macs that have one; nothing else covers the overlay.
    private func topInset(of screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) { return screen.safeAreaInsets.top }
        return 0
    }

    /// Hosts the canvas here (moving it from wherever it was), for Closed to show. The blocked
    /// screen is a dark place, so the canvas goes dark with it.
    func attachCanvas(_ webView: WKWebView) {
        webView.removeFromSuperview()
        webView.appearance = NSAppearance(named: .darkAqua)
        webView.translatesAutoresizingMaskIntoConstraints = false
        canvasPane.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: canvasProgress.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: canvasPane.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: canvasPane.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: canvasPane.bottomAnchor),
        ])
        canvas = webView
    }

    // MARK: Content

    /// Rebuilds the controls for `content`, unless it is already showing.
    func show(_ new: OverlayContent) {
        guard new != content else { return }
        content = new
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        answerField = nil
        picker = nil

        // Closed with the canvas here: it replaces the dark screen; everything else covers it.
        if case let .closed(escape) = new, let web = canvas {
            canvasEscape.isHidden = escape == .hidden
            canvasEscape.isEnabled = escape == .available
            stack.isHidden = true
            canvasPane.isHidden = false
            makeFirstResponder(web)
            return
        }
        canvasPane.isHidden = true
        stack.isHidden = false
        // Keys mustn't keep going to the hidden canvas (a confirmation or the puzzle covers it).
        if let web = canvas, let responder = firstResponder as? NSView, responder.isDescendant(of: web) {
            makeFirstResponder(nil)
        }

        styleStatus(quiet: { if case .confirmation = new { return true } else { return false } }())
        switch new {
        case let .confirmation(heading, mode):
            let tint = Theme.tint(mode)
            stack.addArrangedSubview(Theme.pill("Next · \(mode.title)", tint: tint, size: textSize * 0.6))
            let title = label(heading, size: headingSize, weight: .bold)
            stack.addArrangedSubview(title)
            stack.setCustomSpacing(textSize * 0.5, after: title)
            stack.addArrangedSubview(noteLabel)
            stack.setCustomSpacing(textSize * 1.6, after: noteLabel)
            let picker = NSSegmentedControl(labels: Config.slots.map { "\($0) min" },
                                            trackingMode: .selectOne,
                                            target: self, action: #selector(slotChanged(_:)))
            picker.font = Theme.rounded(textSize, .semibold)
            picker.controlSize = .large
            picker.segmentDistribution = .fillEqually
            picker.widthAnchor.constraint(equalToConstant: textSize * 16).isActive = true
            picker.setAccessibilityLabel("Length of \(mode.title)")
            stack.addArrangedSubview(picker)
            self.picker = picker
            stack.setCustomSpacing(textSize * 1.4, after: picker)
            let start = button("Start \(mode.title)", key: "\r", action: #selector(startPressed))
            start.bezelColor = tint
            start.widthAnchor.constraint(greaterThanOrEqualToConstant: textSize * 10).isActive = true
            stack.addArrangedSubview(start)
            stack.addArrangedSubview(statusLabel)
            stack.addArrangedSubview(label("Return starts  ·  ← → or 4, 8, 6 pick the length",
                                           size: textSize * 0.65, weight: .regular, color: Theme.faint))

        case let .closed(escape):
            stack.addArrangedSubview(Theme.pill("Closed", tint: Theme.closed, size: textSize * 0.6))
            stack.addArrangedSubview(clockLabel)
            stack.setCustomSpacing(textSize * 0.4, after: clockLabel)
            progress.tint = Theme.closed
            stack.addArrangedSubview(progress)
            stack.setCustomSpacing(textSize * 1.4, after: progress)
            stack.addArrangedSubview(statusLabel)
            if escape != .hidden {
                let out = button("I need out", key: "", action: #selector(escapePressed))
                out.isEnabled = escape == .available
                out.toolTip = "Solve a small sum to pause everything for \(Config.pauseMinutes) minutes"
                stack.addArrangedSubview(out)
            }
            if canvasElsewhere {
                stack.addArrangedSubview(label("Your canvas is on the main screen.",
                                               size: textSize * 0.7, weight: .regular, color: Theme.faint))
            }

        case let .puzzle(question, attemptsLeft):
            stack.addArrangedSubview(Theme.pill("I need out", tint: Theme.closed, size: textSize * 0.6))
            stack.addArrangedSubview(label("Solve it to pause everything for \(Config.pauseMinutes) minutes.",
                                           size: textSize * 0.85, weight: .regular, color: Theme.muted))
            let q = NSTextField(labelWithString: question)
            q.font = Theme.digits(headingSize * 1.25, .bold)
            q.textColor = Theme.ink
            q.alignment = .center
            stack.addArrangedSubview(q)
            let field = NSTextField(string: "")
            field.font = Theme.digits(headingSize * 0.8, .medium)
            field.alignment = .center
            field.placeholderString = "?"
            field.setAccessibilityLabel("Answer")
            field.widthAnchor.constraint(equalToConstant: headingSize * 5).isActive = true
            field.wantsLayer = true
            stack.addArrangedSubview(field)
            answerField = field
            let answer = button("Answer", key: "\r", action: #selector(answerPressed))
            answer.bezelColor = Theme.closed
            let row = NSStackView(views: [
                button("Never mind", key: "\u{1b}", action: #selector(dismissPuzzlePressed)),
                answer,
            ])
            row.orientation = .horizontal
            row.spacing = textSize
            stack.addArrangedSubview(row)
            // One dot per attempt: the used ones go dim.
            let dots = (0..<Config.puzzleAttempts).map { $0 < attemptsLeft ? "●" : "○" }.joined(separator: "  ")
            let tries = label(dots, size: textSize * 0.7, weight: .regular,
                              color: attemptsLeft == Config.puzzleAttempts ? Theme.faint : Theme.closed)
            tries.setAccessibilityLabel("\(attemptsLeft) of \(Config.puzzleAttempts) attempts left")
            stack.addArrangedSubview(tries)
            stack.addArrangedSubview(statusLabel)
            stack.setCustomSpacing(textSize * 2, after: statusLabel)
            stack.addArrangedSubview(clockLabel)
            clockLabel.font = Theme.digits(headingSize * 0.9, .semibold)
            clockLabel.textColor = Theme.muted
            return
        }
        clockLabel.font = Theme.digits(min(max(min(frame.width, frame.height) * 0.22, 64), 260), .bold)
        clockLabel.textColor = Theme.ink
        stack.layoutSubtreeIfNeeded()
    }

    func setClock(_ text: String) {
        if clockLabel.stringValue != text { clockLabel.stringValue = text }
        if canvasClock.stringValue != text { canvasClock.stringValue = text }
    }

    func setStatus(_ text: String) {
        if statusLabel.stringValue != text { statusLabel.stringValue = text }
        if canvasStatus.stringValue != text { canvasStatus.stringValue = text }
        statusLabel.isHidden = text.isEmpty
    }

    /// The confirmation's line about what Start leads to.
    func setNote(_ text: String) {
        if noteLabel.stringValue != text { noteLabel.stringValue = text }
    }

    /// How much of Closed is left, 0...1.
    func setProgress(_ fraction: Double) {
        progress.fraction = CGFloat(fraction)
        canvasProgress.fraction = CGFloat(fraction)
    }

    /// The slot the confirmation's picker shows.
    func setSlot(_ minutes: Int) {
        guard let picker = picker, let index = Config.slots.firstIndex(of: minutes),
              picker.selectedSegment != index else { return }
        picker.selectedSegment = index
    }

    /// Puts the cursor in the answer field, when the puzzle is showing.
    func focusAnswer() {
        if let field = answerField { makeFirstResponder(field) }
    }

    /// A wrong answer: the field shakes its head.
    func shakeAnswer() {
        guard let layer = answerField?.layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -14, 12, -9, 6, -3, 0]
        shake.duration = 0.42
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(shake, forKey: "shake")
    }

    /// The status line speaks up for reminders and the puzzle, and stays quiet on a confirmation.
    private func styleStatus(quiet: Bool) {
        statusLabel.font = Theme.rounded(quiet ? textSize * 0.75 : textSize, quiet ? .regular : .medium)
        statusLabel.textColor = quiet ? Theme.muted : Theme.ink.withAlphaComponent(0.8)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor = Theme.ink) -> NSTextField {
        Theme.label(text, font: Theme.rounded(size, weight), color: color)
    }

    private func button(_ title: String, key: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.font = NSFont.systemFont(ofSize: textSize * 0.9, weight: .medium)
        b.keyEquivalent = key
        return b
    }

    @objc private func slotChanged(_ sender: NSSegmentedControl) {
        guard Config.slots.indices.contains(sender.selectedSegment) else { return }
        actions?.overlayChoseSlot(Config.slots[sender.selectedSegment])
    }
    @objc private func startPressed() { actions?.overlayPressedStart() }
    @objc private func escapePressed() { actions?.overlayPressedEscape() }
    @objc private func dismissPuzzlePressed() { actions?.overlayDismissedPuzzle() }
    @objc private func answerPressed() { actions?.overlayAnswered(answerField?.stringValue ?? "") }

    // MARK: Keeping the user in

    // Allow the window to take focus so it captures key presses.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Keys that no control claims go nowhere: the window itself swallows them. On a
    /// confirmation, the arrows and 4 / 8 / 6 (for 16) pick the length.
    override func keyDown(with event: NSEvent) {
        guard case .confirmation = content, let picker = picker, !event.isARepeat || event.keyCode == 123 || event.keyCode == 124 else { return }
        var index = picker.selectedSegment
        switch (event.keyCode, event.charactersIgnoringModifiers ?? "") {
        case (123, _): index = max(0, index - 1)                               // ←
        case (124, _): index = min(Config.slots.count - 1, index + 1)          // →
        case (_, "4"): index = 0
        case (_, "8"): index = 1
        case (_, "6"), (_, "1"): index = 2
        default: return
        }
        guard index != picker.selectedSegment, Config.slots.indices.contains(index) else { return }
        picker.selectedSegment = index
        actions?.overlayChoseSlot(Config.slots[index])
    }
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    override func cancelOperation(_ sender: Any?) {}
    override func performClose(_ sender: Any?) {}  // Cmd-W from the main menu: not here

    /// Return still reaches the Start / Answer buttons and the canvas gets its shortcuts; the
    /// Edit menu (undo, cut, copy, paste, select all) comes next; any other Cmd-combination
    /// (Cmd-W, Cmd-Q, Cmd-H…) stops here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return event.modifierFlags.contains(.command)
    }

    // Swallow mouse interaction on the overlay itself (controls get theirs first).
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

// MARK: - Updater

/// Keeps the installed app on the newest commit of the branch it was built from (`main`, unless
/// install.sh was given another): checks at launch, every 6 hours, and from the menu; installs on
/// request. Installing takes GitHub's prebuilt release when it was made from that exact commit;
/// otherwise it downloads the source and builds it here with Apple's command line tools, so an
/// update never has to wait for GitHub Actions. The repository is public, so plain HTTPS is enough.
final class Updater {
    static let repo = "ainigh/ONE"
    static let appName = "CountdownOverlay.app"
    static let assetName = "CountdownOverlay.zip"
    static let checkInterval: TimeInterval = 6 * 3600

    struct Commit: Equatable {
        let sha: String
        let title: String
        var short: String { String(sha.prefix(7)) }
    }

    struct Release: Equatable {
        let tag: String
        let target: String?
        let assetURL: URL?
    }

    enum Plan: Equatable {
        case upToDate
        case prebuilt(Commit, Release)             // GitHub built this commit: download it
        case buildHere(Commit)                     // no release for it yet: build on this Mac
    }

    enum State {
        case idle, checking, upToDate
        case available(Plan)
        case installing(String)
        case failed(String)
    }

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: What this copy is (make-app.sh writes these into Info.plist)

    static var branch: String {
        let b = Bundle.main.object(forInfoDictionaryKey: "CountdownBranch") as? String ?? ""
        return b.isEmpty ? "main" : b
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var currentCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "CountdownCommit") as? String
    }

    /// A bare binary (`make build`, or swiftc by hand) isn't an installed app: don't update it.
    static var isInstalledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var versionLine: String {
        let commit = currentCommit.map { " (\($0.prefix(7)))" } ?? ""
        let branch = Self.branch == "main" ? "" : " · \(Self.branch)"
        return "CountdownOverlay \(currentVersion)\(commit)\(branch)"
    }

    // MARK: State

    private(set) var state: State = .idle {
        didSet { onChange?(state) }
    }
    /// Called on the main thread whenever `state` changes.
    var onChange: ((State) -> Void)?
    private var timer: Timer?
    private let work = DispatchQueue(label: "com.ainigh.CountdownOverlay.updater", qos: .utility)

    var isBusy: Bool {
        switch state {
        case .checking, .installing: return true
        default: return false
        }
    }

    /// Installing ends in a restart, which a session would refuse.
    var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    func start() {
        guard Self.isInstalledApp else { return }
        check(userInitiated: false)
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check(userInitiated: false)
        }
    }

    func check(userInitiated: Bool) {
        if isBusy { return }
        let before = state
        state = .checking
        work.async {
            let outcome: State
            do {
                let plan = try Self.findUpdate()
                outcome = plan == .upToDate ? .upToDate : .available(plan)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            DispatchQueue.main.async {
                // A quiet background check that fails shouldn't leave an error in the menu, and
                // an update it already found stays offered.
                if case .failed = outcome, !userInitiated {
                    if case .available = before { self.state = before } else { self.state = .idle }
                } else {
                    self.state = outcome
                }
            }
        }
    }

    func install() {
        guard case .available(let plan) = state else { return }
        state = .installing("Updating…")
        work.async {
            do {
                try Self.install(plan) { step in
                    DispatchQueue.main.async { self.state = .installing(step) }
                }
            } catch {
                Self.log("update failed: \(error.localizedDescription)")
                DispatchQueue.main.async { self.state = .failed("Update failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: What's new

    static func findUpdate() throws -> Plan {
        let head = try fetchHead()
        let release = try? fetchLatestRelease()
        return decide(head: head, installedCommit: currentCommit, latestRelease: release)
    }

    /// Compares the branch's newest commit with the one this copy was built from. A copy with no
    /// recorded commit (built by hand) updates to whatever the branch has.
    static func decide(head: Commit, installedCommit: String?, latestRelease: Release?) -> Plan {
        if let mine = installedCommit, !mine.isEmpty, mine != "unknown",
           head.sha.hasPrefix(mine) || mine.hasPrefix(head.sha) {
            return .upToDate
        }
        if let release = latestRelease, release.target == head.sha, release.assetURL != nil {
            return .prebuilt(head, release)
        }
        return .buildHere(head)
    }

    static func fetchHead() throws -> Commit {
        let json = try api("repos/\(repo)/commits/\(branch)")
        guard let sha = json["sha"] as? String,
              let details = json["commit"] as? [String: Any],
              let message = details["message"] as? String else {
            throw Problem("GitHub's answer for \(branch) had no commit in it")
        }
        return Commit(sha: sha, title: message.components(separatedBy: "\n").first ?? message)
    }

    static func fetchLatestRelease() throws -> Release {
        let json = try api("repos/\(repo)/releases/latest")
        guard let tag = json["tag_name"] as? String else { throw Problem("no release") }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let asset = assets.first { ($0["name"] as? String) == assetName }
        let url = (asset?["browser_download_url"] as? String).flatMap(URL.init(string:))
        return Release(tag: tag, target: json["target_commitish"] as? String, assetURL: url)
    }

    // MARK: Installing

    static func install(_ plan: Plan, step: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        let app = Bundle.main.bundleURL
        guard isInstalledApp else { throw Problem("this copy isn't an app bundle") }
        // On the app's own volume, so the swap at the end is a rename.
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: scratch) }

        let newApp: URL
        let commit: Commit
        switch plan {
        case .upToDate:
            return
        case let .prebuilt(head, release):
            commit = head
            step("Downloading \(release.tag)…")
            newApp = try downloadPrebuilt(release, into: scratch)
        case let .buildHere(head):
            commit = head
            newApp = try buildFromSource(head, in: scratch, step: step)
        }

        let newBundle = Bundle(url: newApp)
        guard let newID = newBundle?.bundleIdentifier, newID == Bundle.main.bundleIdentifier else {
            throw Problem("the new copy isn't \(app.lastPathComponent)")
        }
        // Never swap in something that isn't the commit we meant to install, or whose bundle was
        // damaged on the way (a truncated download, a half-finished build).
        guard newBundle?.object(forInfoDictionaryKey: "CountdownCommit") as? String == commit.sha else {
            throw Problem("the new copy wasn't built from \(commit.short)")
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        } catch {
            throw Problem("the new copy's signature doesn't check out: \(error.localizedDescription)")
        }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        step("Restarting…")
        _ = try fm.replaceItemAt(app, withItemAt: newApp)
        log("updated to \(commit.short)")
        // Start the new copy once this one has quit.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                              app.path]
        try relaunch.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    static func downloadPrebuilt(_ release: Release, into scratch: URL) throws -> URL {
        guard let url = release.assetURL else { throw Problem("the release has no \(assetName)") }
        let zip = scratch.appendingPathComponent(assetName)
        try download(url, to: zip)
        let unpacked = scratch.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        return unpacked.appendingPathComponent(appName)
    }

    /// Downloads the commit's source and runs scripts/make-app.sh on it (for this Mac only).
    static func buildFromSource(_ commit: Commit, in scratch: URL, step: (String) -> Void) throws -> URL {
        guard (try? run("/usr/bin/xcode-select", ["-p"])) != nil else {
            throw Problem("building needs Apple's command line tools: run xcode-select --install in Terminal")
        }
        step("Downloading \(commit.short)…")
        let tarball = scratch.appendingPathComponent("source.tar.gz")
        guard let url = URL(string: "https://codeload.github.com/\(repo)/tar.gz/\(commit.sha)") else {
            throw Problem("bad source URL")
        }
        try download(url, to: tarball)
        let src = scratch.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-xzf", tarball.path, "-C", src.path, "--strip-components", "1"])

        step("Building \(commit.short)…")
        log("building \(commit.short) in \(src.path)")
        let base = currentVersion.split(separator: "-").first.map(String.init) ?? "1.0"
        var env = ["VERSION": "\(base)-\(commit.short)", "COMMIT": commit.sha, "BRANCH": branch]
        if let identity = UserDefaults.standard.string(forKey: "signIdentity"), !identity.isEmpty {
            env["SIGN_IDENTITY"] = identity
        }
        try run("/bin/bash", [src.appendingPathComponent("scripts/make-app.sh").path],
                env: env, in: src, logOutput: true)
        return src.appendingPathComponent("build").appendingPathComponent(appName)
    }

    /// The error, plus the end of update.log when a build failed, for pasting somewhere.
    static func report(_ problem: String) -> String {
        guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return problem }
        let tail = log.components(separatedBy: "\n").suffix(60).joined(separator: "\n")
        return problem + "\n\n--- the end of \(logURL.path) ---\n" + tail
    }

    // MARK: GitHub

    /// GET https://api.github.com/<path>, as JSON.
    static func api(_ path: String) throws -> [String: Any] {
        guard let url = URL(string: "https://api.github.com/\(path)") else { throw Problem("bad path \(path)") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CountdownOverlay/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw Problem("GitHub can't find \(path)") }
        if status == 403 || status == 429 { throw Problem("GitHub's hourly limit: try again later") }
        guard status == 200 else { throw Problem("GitHub answered \(status)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Problem("GitHub's answer wasn't JSON")
        }
        return json
    }

    static func download(_ url: URL, to file: URL) throws {
        let (data, response) = try fetch(URLRequest(url: url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Problem("download failed (GitHub answered \(status)): \(url)") }
        try data.write(to: file)
    }

    static func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        final class Box { var result: Result<(Data, URLResponse), Error> = .failure(Problem("no answer")) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data, let response = response {
                box.result = .success((data, response))
            } else {
                box.result = .failure(error ?? Problem("no answer"))
            }
            done.signal()
        }.resume()
        done.wait()
        return try box.result.get()
    }

    // MARK: Helpers

    /// ~/Library/Logs/CountdownOverlay/update.log: what updates did, and a build's full output.
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CountdownOverlay/update.log")
    }

    static func log(_ line: String) {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    /// Runs a program and returns its output. Throws with the last line of its errors if it fails.
    /// `logOutput` also copies everything it printed into update.log.
    @discardableResult
    static func run(_ tool: String, _ args: [String], env extra: [String: String] = [:],
                    in dir: URL? = nil, logOutput: Bool = false) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if let dir = dir { process.currentDirectoryURL = dir }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.merge(extra) { $1 }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read stderr on another thread while stdout is read here, so a full pipe can't stall it.
        final class Box { var data = Data() }
        let errBox = Box()
        let errRead = DispatchGroup()
        errRead.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            errRead.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errRead.wait()
        let errData = errBox.data
        let name = (tool as NSString).lastPathComponent
        if logOutput {
            log("\(name) \(args.joined(separator: " "))\n\(String(decoding: data, as: UTF8.self))\(String(decoding: errData, as: UTF8.self))")
        }
        if process.terminationStatus != 0 {
            let lines = String(decoding: errData.isEmpty ? data : errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            let message = logOutput ? (lines.last(where: { $0.contains("error") }) ?? lines.last ?? "") : (lines.last ?? "")
            let tail = message.isEmpty ? "\(name) failed (\(process.terminationStatus))" : message
            throw Problem(logOutput ? "\(tail) (details in \(logURL.path))" : tail)
        }
        return data
    }
}



// MARK: - Menu header

/// The top of the timer's menu: what's happening, how long is left, and how far along it is,
/// kept live while the menu is open.
final class MenuHeader: NSView {
    private let stack = NSStackView()
    private var pill: NSView?
    private var pillKey = ""
    private let time = NSTextField(labelWithString: "")
    private let bar = ProgressBar(height: 4, track: NSColor.labelColor.withAlphaComponent(0.1))
    private let detail = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        time.font = Theme.digits(30, .bold)
        time.textColor = .labelColor
        detail.font = NSFont.systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 268
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 10, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [time, bar, detail] as [NSView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(8, after: bar)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            bar.widthAnchor.constraint(equalToConstant: 268),
            detail.widthAnchor.constraint(equalToConstant: 268),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(pill text: String, tint: NSColor, time value: String, fraction: Double?, detail line: String) {
        let key = text + tint.description
        if key != pillKey {
            pillKey = key
            pill?.removeFromSuperview()
            let new = Theme.pill(text, tint: tint, size: 9.5)
            stack.insertArrangedSubview(new, at: 0)
            pill = new
        }
        if time.stringValue != value { time.stringValue = value }
        bar.alphaValue = fraction == nil ? 0 : 1
        bar.tint = tint
        bar.fraction = CGFloat(fraction ?? 0)
        if detail.stringValue != line { detail.stringValue = line }
        setAccessibilityLabel("\(text). \(value). \(line)")
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, OverlayActions {
    /// Where the session is (§1, §3, §7). Everything else derives from it.
    enum Phase {
        case idle
        case confirming(Mode)                      // blocked, timer frozen
        case running(Mode, deadline: Date)
        case paused(until: Date)                   // unblocked, timers frozen
    }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let menuHeader = MenuHeader()
    private var menuIsOpen = false
    private var overlays: [OverlayWindow] = []
    private var timer: Timer?
    private var keyMonitor: Any?
    private var rebuildWork: DispatchWorkItem?
    private var previousApp: NSRunningApplication?
    private let updater = Updater()
    private var canvas: Canvas?                    // nil when Canvas.html isn't there
    private var canvasItem: NSStatusItem?          // the canvas's own menu-bar icon
    private var canvasWindow: CanvasWindow?
    private var canvasWindowWasOpen = false        // reopen it when the screen unblocks

    private var phase: Phase = .idle
    private var sessionEnd: Date?
    private var slots: [Mode: Int] = [.opened: Store.slot(for: .opened), .closed: Store.slot(for: .closed)]
    private var lastEscape: Date? = Store.lastEscape
    private var escapeLockedUntil: Date?
    private var puzzle: Puzzle?
    private var remindersDue: [Int] = []           // minute marks still to announce in this mode
    private var reminderText = ""
    private var firstConfirmation = true
    private var systemIsPoweringOff = false        // a logout / restart / shutdown is under way

    private var inSession: Bool {
        if case .idle = phase { return false }
        return true
    }
    private var isBlocked: Bool { !overlays.isEmpty }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)      // no Dock icon, menubar only
        if let dir = UserDefaults.standard.string(forKey: "preview"), !dir.isEmpty {
            runPreviews(into: URL(fileURLWithPath: dir))
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
                                                           weight: .regular)
        }
        menu.delegate = self
        menu.autoenablesItems = false              // honour the isEnabled flags set in menuNeedsUpdate
        statusItem.menu = menu
        updateStatusItem()
        installMainMenu()
        // Loaded now, so it's ready the first time Closed shows it.
        canvas = Canvas()
        if canvas != nil { addCanvasStatusItem() }

        updater.onChange = { [weak self] _ in self?.updateStatusItem() }
        updater.start()
        registerLoginItemOnce()

        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(screensChanged),
                           name: NSApplication.didChangeScreenParametersNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(appDidResignActive(_:)),
                           name: NSApplication.didResignActiveNotification,
                           object: nil)

        // After sleep/wake a deadline may already have passed; resync at once.
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(workspaceDidWake(_:)),
                                                          name: NSWorkspace.didWakeNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(workspaceWillPowerOff(_:)),
                                                          name: NSWorkspace.willPowerOffNotification,
                                                          object: nil)

        // §8: killed or restarted mid-session → the interrupted mode's confirmation, full slot.
        // A session whose time ran out while the app wasn't running just ends, quietly.
        if let end = Store.sessionEnd, let mode = Store.interruptedMode {
            if Date() >= end {
                Store.clearSession()
            } else {
                sessionEnd = end
                firstConfirmation = false
                startTicking()
                reachConfirmation(for: mode)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unblock()
    }

    // §4: the session cannot be ended by any other control, quitting included. A logout, restart
    // or shutdown still goes ahead (refusing it would stall the Mac); §8 reopens the session after.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        inSession && !systemIsPoweringOff ? .terminateCancel : .terminateNow
    }

    @objc private func workspaceWillPowerOff(_ note: Notification) {
        systemIsPoweringOff = true
        // If another app cancels the logout, quitting is refused again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.systemIsPoweringOff = false
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Never shown (the app has no menu bar of its own), but it's what makes Cmd-W close the
    /// canvas's window and Cmd-Z / X / C / V / A work on the canvas and in the puzzle's answer
    /// field. Deliberately no Quit; the overlay ignores Close.
    private func installMainMenu() {
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(windowItem)
        main.addItem(item)
        NSApp.mainMenu = main
    }

    // MARK: Previews

    /// `-preview DIR` draws the blocked screens, a pop-up, the menu's header and the menu-bar
    /// icons into PNGs in DIR, then quits. CI runs it, so every build leaves pictures of its UI.
    /// Nothing about a real session is touched: it plays muted and stores nothing it keeps.
    private func runPreviews(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "mute")
        func save(_ view: NSView?, _ name: String) {
            guard let view = view else { return }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        }
        var steps: [() -> Void] = [
            {
                self.sessionEnd = Date().addingTimeInterval(Config.seconds(minutes: 90))
                self.firstConfirmation = false
                self.reachConfirmation(for: .closed)
            },
            { save(self.overlays.first?.contentView, "1-confirmation") },
            {
                Store.closedRounds = 2
                self.begin(.closed)
                self.remind(.closed, minutes: 2)
                self.render()
            },
            {
                save(self.overlays.first?.contentView, "2-closed")
                Popup.shared.show("02:00", "left in Closed. Then the screen opens again.",
                                  symbol: "bell.fill", tint: Theme.closed)
            },
            {
                save(NSApp.windows.first { $0 is PopupPanel }?.contentView, "3-popup")
                self.puzzle = Puzzle(question: "23 × 7 = ?", answer: 161)
                self.render()
            },
            { save(self.overlays.first?.contentView, "4-puzzle") },
            {
                self.overlayAnswered("150")
            },
            {
                save(self.overlays.first?.contentView, "5-puzzle-wrong")
                self.puzzle = nil
                self.canvas = Canvas()
                self.buildOverlays()
                self.render()
            },
            {
                save(self.overlays.first?.contentView, "8-closed-with-canvas")
                for (name, appearance) in [("6-menu-dark", NSAppearance.Name.darkAqua), ("6-menu-light", .aqua)] {
                    self.menuHeader.appearance = NSAppearance(named: appearance)
                    self.refreshMenuHeader()
                    let backdrop = NSView(frame: self.menuHeader.frame)
                    backdrop.appearance = NSAppearance(named: appearance)
                    backdrop.wantsLayer = true
                    backdrop.layer?.backgroundColor = (appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1)
                                                                               : NSColor(white: 0.96, alpha: 1)).cgColor
                    backdrop.addSubview(self.menuHeader)
                    save(backdrop, name)
                    self.menuHeader.removeFromSuperview()
                }
                let kinds: [StatusIcon.Kind] = [.idle, .ready, .left(48), .left(36), .left(24), .left(12), .left(3), .paused]
                let strip = NSView(frame: NSRect(x: 0, y: 0, width: kinds.count * 40 + 8, height: 40))
                strip.wantsLayer = true
                strip.layer?.backgroundColor = NSColor.white.cgColor
                for (i, kind) in kinds.enumerated() {
                    let image = StatusIcon.image(kind).copy() as! NSImage
                    image.isTemplate = false
                    let view = NSImageView(frame: NSRect(x: 8 + i * 40, y: 4, width: 32, height: 32))
                    view.image = image
                    view.imageScaling = .scaleProportionallyUpOrDown
                    strip.addSubview(view)
                }
                save(strip, "7-menu-bar-icons")
                Store.clearSession()
                UserDefaults.standard.removeObject(forKey: "mute")
                exit(0)
            },
        ]
        func next() {
            guard !steps.isEmpty else { return }
            steps.removeFirst()()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { next() }
        }
        next()
    }

    // MARK: Open at Login

    /// §8 can only reopen a session after a restart if the app opens at login, so an installed
    /// copy asks for that once, the first time it runs. The menu turns it off again.
    private func registerLoginItemOnce() {
        guard #available(macOS 13.0, *), Updater.isInstalledApp,
              !UserDefaults.standard.bool(forKey: "loginItem.offered") else { return }
        UserDefaults.standard.set(true, forKey: "loginItem.offered")
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("login item: %@", error.localizedDescription)
        }
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try service.register()
            }
        } catch {
            NSLog("login item: %@", error.localizedDescription)
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: Canvas window (§10)

    private func addCanvasStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Canvas") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "✦"                 // fallback if SF Symbols are unavailable
            }
            button.toolTip = "Canvas — your surfaces, any time"
            button.target = self
            button.action = #selector(toggleCanvas)
        }
        canvasItem = item
    }

    /// Opens the canvas's window, or closes it when it's already in front. While the screen is
    /// blocked the overlay shows the canvas instead, and nothing closes it.
    @objc private func toggleCanvas() {
        guard !isBlocked, let canvas = canvas else { return }
        if let window = canvasWindow, window.isVisible, window.isKeyWindow, NSApp.isActive {
            window.performClose(nil)
            return
        }
        showCanvasWindow(canvas)
    }

    @objc private func openCanvas() {
        guard !isBlocked, let canvas = canvas else { return }
        showCanvasWindow(canvas)
    }

    private func showCanvasWindow(_ canvas: Canvas) {
        let window = canvasWindow ?? CanvasWindow(canvas: canvas)
        canvasWindow = window
        window.attach()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas.webView)
    }

    // MARK: Menubar

    /// The icon's pie is the time left in the mode; the digits beside it say how much.
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let kind: StatusIcon.Kind
        var title = ""
        var tip: String
        switch phase {
        case .idle:
            kind = .idle
            tip = "No session running — click to start one"
        case let .confirming(mode):
            kind = .ready
            tip = "Waiting for Start (\(mode.title))"
        case let .running(mode, deadline):
            let left = deadline.timeIntervalSinceNow
            kind = StatusIcon.kind(left: left / Config.seconds(minutes: slots[mode]!))
            title = Config.clock(left)
            tip = "\(mode.title) — \(title) left"
        case let .paused(until):
            let left = until.timeIntervalSinceNow
            kind = .paused
            title = Config.clock(left)
            tip = "Paused — \(title) until Closed restarts"
        }
        let image = StatusIcon.image(kind)
        if button.image !== image { button.image = image }
        if button.title != title { button.title = title }
        if case .available = updater.state { tip += " · An update is ready in the menu" }
        if button.toolTip != tip {
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
        }
        if menuIsOpen { refreshMenuHeader() }
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    /// "Session ends after 3:42 PM · 1 h 12 min to go · 2 Closed rounds so far".
    private func sessionLine() -> String {
        guard let end = sessionEnd else { return "" }
        let left = end.timeIntervalSinceNow
        var line = left > 0
            ? "Session ends after \(Config.wallTime(in: left)) · \(Config.duration(left)) to go"
            : "Session ends at the next confirmation"
        let rounds = Store.closedRounds
        if rounds > 0 { line += "\n\(rounds) Closed \(rounds == 1 ? "round" : "rounds") so far, \(Store.closedMinutes) min in all" }
        return line
    }

    private func refreshMenuHeader() {
        switch phase {
        case .idle:
            menuHeader.update(pill: "No session", tint: Theme.muted, time: "Ready when you are",
                              fraction: nil,
                              detail: "Opened \(slots[.opened]!) min ⇄ Closed \(slots[.closed]!) min. Pick a length below to begin.")
        case let .confirming(mode):
            menuHeader.update(pill: "Next · \(mode.title)", tint: Theme.tint(mode), time: "Waiting",
                              fraction: nil, detail: "Press Start on the screen to begin \(mode.title).")
        case let .running(mode, deadline):
            let left = deadline.timeIntervalSinceNow
            menuHeader.update(pill: mode.title, tint: Theme.tint(mode), time: Config.clock(left),
                              fraction: left / Config.seconds(minutes: slots[mode]!), detail: sessionLine())
        case let .paused(until):
            let left = until.timeIntervalSinceNow
            menuHeader.update(pill: "Paused", tint: Theme.muted, time: Config.clock(left),
                              fraction: left / Config.seconds(minutes: Config.pauseMinutes),
                              detail: "Then Closed starts over with its full \(slots[.closed]!) minutes.")
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let head = NSMenuItem()
        head.view = menuHeader
        menu.addItem(head)
        refreshMenuHeader()
        menu.addItem(.separator())

        // Not while an update installs: it ends in a restart, which a session would refuse.
        let canStart = !inSession && !updater.isInstalling
        let start = menu.addItem(withTitle: inSession ? "Session Running" : "Start Session",
                                 action: nil, keyEquivalent: "")
        start.image = symbol("play.circle")
        start.isEnabled = canStart
        let lengths = NSMenu()
        lengths.autoenablesItems = false
        for minutes in Config.sessionMinutes {
            let title = minutes < 60 ? "\(Config.sessionTitle(minutes: minutes)) — try it out"
                                     : Config.sessionTitle(minutes: minutes)
            let item = lengths.addItem(withTitle: title, action: #selector(startSession(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            item.isEnabled = canStart
            if minutes < 60 {
                item.toolTip = "With 4-minute slots: Opened, Closed, and Opened again"
                lengths.addItem(.separator())
            }
        }
        start.submenu = lengths

        if canvas != nil {
            let open = menu.addItem(withTitle: "Open Canvas", action: #selector(openCanvas), keyEquivalent: "")
            open.image = symbol("square.and.pencil")
            open.target = self
            open.isEnabled = !isBlocked
        }

        menu.addItem(.separator())
        addSoundItems(to: menu)
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            let login = menu.addItem(withTitle: status == .requiresApproval ? "Open at Login (Approve in Settings…)"
                                                                            : "Open at Login",
                                     action: #selector(toggleLoginItem), keyEquivalent: "")
            login.image = symbol("power")
            login.target = self
            login.state = status == .enabled ? .on : .off
            login.toolTip = "So a session survives a restart: the app reopens right where it was."
        }

        menu.addItem(.separator())
        addUpdateItems(to: menu)

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: inSession ? "Quit (after the session)" : "Quit CountdownOverlay",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        quit.isEnabled = !inSession
    }

    // MARK: Sound

    private func addSoundItems(to menu: NSMenu) {
        let sound = menu.addItem(withTitle: "Sound", action: nil, keyEquivalent: "")
        sound.image = symbol(Config.muted ? "speaker.slash" : "speaker.wave.2")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let on = sub.addItem(withTitle: "Play Sounds", action: #selector(toggleSound), keyEquivalent: "")
        on.target = self
        on.state = Config.muted ? .off : .on
        sub.addItem(.separator())
        let heading = sub.addItem(withTitle: "Loudness", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        let boost = Config.soundBoost
        // The nearest choice wins the check mark, so a hand-set value still shows one.
        let nearest = Config.loudness.indices.min { abs(Config.loudness[$0].boost - boost) < abs(Config.loudness[$1].boost - boost) }
        for (i, level) in Config.loudness.enumerated() {
            let item = sub.addItem(withTitle: level.title, action: #selector(setLoudness(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.indentationLevel = 1
            item.state = i == nearest ? .on : .off
            item.isEnabled = !Config.muted
        }
        sub.addItem(.separator())
        let sample = sub.addItem(withTitle: "Play a Sample", action: #selector(playSample), keyEquivalent: "")
        sample.target = self
        sample.isEnabled = !Config.muted
        sound.submenu = sub
    }

    @objc private func toggleSound() {
        UserDefaults.standard.set(!Config.muted, forKey: "mute")
        if !Config.muted { Sound.reminder.play() }
    }

    @objc private func setLoudness(_ sender: NSMenuItem) {
        guard Config.loudness.indices.contains(sender.tag) else { return }
        UserDefaults.standard.set(Config.loudness[sender.tag].boost, forKey: "soundBoost")
        SoundPlayer.shared.updateBoost()
        Sound.reminder.play()                      // hear what you picked
    }

    @objc private func playSample() { Sound.reminder.play() }

    // MARK: Updates

    private func addUpdateItems(to menu: NSMenu) {
        let version = menu.addItem(withTitle: Updater.versionLine, action: nil, keyEquivalent: "")
        version.isEnabled = false
        guard Updater.isInstalledApp else { return }

        @discardableResult
        func item(_ title: String, _ action: Selector?, enabled: Bool = true, image: String? = nil) -> NSMenuItem {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            i.target = self
            i.isEnabled = enabled
            if let image = image { i.image = symbol(image) }
            return i
        }

        switch updater.state {
        case .idle, .upToDate:
            item("Check for Updates…", #selector(checkForUpdates), image: "arrow.triangle.2.circlepath")
        case .checking:
            item("Checking for Updates…", nil, enabled: false, image: "arrow.triangle.2.circlepath")
        case .available(let plan):
            let title: String
            switch plan {
            case let .prebuilt(commit, release): title = "Update to \(release.tag) — \(commit.title)"
            case let .buildHere(commit): title = "Update (build here) — \(commit.short): \(commit.title)"
            case .upToDate: title = "Check for Updates…"
            }
            // Updating restarts the app, which a session refuses: offer it only in between.
            let update = item(inSession ? "\(title) (after the session)" : title, #selector(installUpdate),
                              enabled: !inSession, image: "arrow.down.circle.fill")
            update.toolTip = "Downloads the new version (or builds it on this Mac when GitHub hasn't), then restarts."
        case .installing(let step):
            item(step, nil, enabled: false, image: "arrow.down.circle")
        case .failed(let message):
            item(message, nil, enabled: false, image: "exclamationmark.triangle")
            item("Copy Update Details", #selector(copyUpdateDetails))
            item("Check for Updates…", #selector(checkForUpdates), image: "arrow.triangle.2.circlepath")
        }
    }

    @objc private func checkForUpdates() { updater.check(userInitiated: true) }

    @objc private func installUpdate() {
        guard !inSession else { return }
        updater.install()
    }

    @objc private func copyUpdateDetails() {
        guard case .failed(let message) = updater.state else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Updater.report(message), forType: .string)
    }

    // MARK: Session (§4)

    @objc private func startSession(_ sender: NSMenuItem) {
        guard !inSession, !updater.isInstalling, Config.sessionMinutes.contains(sender.tag) else { return }
        Store.clearSession()
        sessionEnd = Date().addingTimeInterval(Config.seconds(minutes: sender.tag))
        Store.sessionEnd = sessionEnd
        firstConfirmation = true
        startTicking()
        reachConfirmation(for: .opened)
    }

    /// Every mode change passes through here (§3). The session ends at the first confirmation
    /// reached after its length has elapsed (§4).
    private func reachConfirmation(for mode: Mode) {
        if let end = sessionEnd, Date() >= end {
            endSession()
            return
        }
        phase = .confirming(mode)
        Store.interruptedMode = mode
        puzzle = nil
        reminderText = ""
        block()
        render()
        updateStatusItem()
        Sound.confirmation.play()
    }

    private func endSession() {
        let rounds = Store.closedRounds, minutes = Store.closedMinutes
        phase = .idle
        sessionEnd = nil
        Store.clearSession()
        puzzle = nil
        stopTicking()
        unblock()
        updateStatusItem()
        Sound.sessionOver.play()
        let tally = rounds == 0 ? "That's the whole session."
            : "\(rounds) Closed \(rounds == 1 ? "round" : "rounds") · \(minutes) minutes with the screen closed."
        Popup.shared.show("Session over", tally, symbol: "checkmark.seal.fill", tint: Theme.opened, for: 10)
    }

    private func begin(_ mode: Mode) {
        let slot = slots[mode]!
        phase = .running(mode, deadline: Date().addingTimeInterval(Config.seconds(minutes: slot)))
        Store.interruptedMode = mode
        remindersDue = Config.reminders(forSlot: slot)
        reminderText = ""
        puzzle = nil
        firstConfirmation = false
        switch mode {
        case .opened:
            unblock()
            Sound.opened.play()
            Popup.shared.show("Opened", "The screen is yours for \(slot) minutes, until \(Config.wallTime(in: Config.seconds(minutes: slot))).",
                              symbol: "lock.open.fill", tint: Theme.opened)
        case .closed:
            block()
            render()
            Sound.closed.play()
        }
        updateStatusItem()
    }

    private func startPause() {
        phase = .paused(until: Date().addingTimeInterval(Config.seconds(minutes: Config.pauseMinutes)))
        Store.interruptedMode = .closed            // §7: a pause always leads to Closed
        puzzle = nil
        unblock()
        Sound.escaped.play()
        Popup.shared.show("Paused", "Everything stops for \(Config.pauseMinutes) minutes, until \(Config.wallTime(in: Config.seconds(minutes: Config.pauseMinutes))). Then Closed starts over.",
                          symbol: "pause.circle.fill", tint: Theme.muted)
        updateStatusItem()
    }

    // MARK: Ticking

    private func startTicking() {
        guard timer == nil else { return }
        // Tick often and derive everything from deadlines, so nothing drifts and the state
        // recovers correctly after the machine sleeps. Common modes: it keeps ticking while a
        // menu is open.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        switch phase {
        case .idle:
            break
        case .confirming:
            render()                               // frozen; only the "until" times move on
            return
        case let .running(mode, deadline):
            let left = deadline.timeIntervalSinceNow
            if left <= 0 {
                if mode == .closed {
                    Store.closedRounds += 1
                    Store.closedMinutes += slots[.closed]!
                }
                reachConfirmation(for: mode.other)
                return
            }
            // After a sleep several marks may have passed at once: announce only the latest.
            var passed: Int?
            while let mark = remindersDue.first, left <= Config.seconds(minutes: mark) {
                remindersDue.removeFirst()
                passed = mark
            }
            if let mark = passed { remind(mode, minutes: mark) }
            if mode == .closed {
                // Three wrong answers lock the button for a while; it comes back on its own.
                if let until = escapeLockedUntil, Date() >= until { escapeLockedUntil = nil }
                render()
            }
        case let .paused(until):
            if Date() >= until {
                Sound.pauseOver.play()
                reachConfirmation(for: .closed)
                return
            }
        }
        updateStatusItem()
    }

    /// §5: a pop-up in the middle of the screen, in both modes; Closed also keeps it on the
    /// blocked screen. Informational only.
    private func remind(_ mode: Mode, minutes: Int) {
        let left = Config.clock(minutes: minutes)
        Sound.reminder.play()
        let next = mode == .opened ? "Closed comes next." : "Then the screen opens again."
        Popup.shared.show(left, "left in \(mode.title). \(next)", symbol: "bell.fill", tint: Theme.tint(mode))
        if mode == .closed { reminderText = "\(left) left" }
    }

    // MARK: Escape puzzle (§6)

    private var escapeState: EscapeState {
        let now = Date()
        if let last = lastEscape, now < last.addingTimeInterval(Config.seconds(minutes: Config.cooldownMinutes)) {
            return .hidden
        }
        if let until = escapeLockedUntil, now < until { return .disabled }
        return .available
    }

    func overlayPressedEscape() {
        guard case .running(.closed, _) = phase, puzzle == nil, escapeState == .available else { return }
        puzzle = Puzzle.random()
        render()
    }

    func overlayAnswered(_ text: String) {
        guard case .running(.closed, _) = phase, var p = puzzle else { return }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }       // Return on an empty field isn't an attempt
        if Int(typed) == p.answer {
            lastEscape = Date()
            Store.lastEscape = lastEscape
            startPause()
            return
        }
        p.attemptsLeft -= 1
        Sound.wrong.play()
        if p.attemptsLeft <= 0 {
            puzzle = nil
            escapeLockedUntil = Date().addingTimeInterval(Config.seconds(minutes: Config.lockoutMinutes))
            render()
        } else {
            puzzle = p
            render()
            DispatchQueue.main.async { [weak self] in self?.overlays.forEach { $0.shakeAnswer() } }
        }
    }

    func overlayDismissedPuzzle() {
        guard puzzle != nil else { return }
        puzzle = nil
        render()
    }

    // MARK: Confirmation (§3)

    func overlayChoseSlot(_ minutes: Int) {
        guard case let .confirming(mode) = phase, Config.slots.contains(minutes) else { return }
        slots[mode] = minutes
        Store.setSlot(minutes, for: mode)
        render()
    }

    func overlayPressedStart() {
        guard case let .confirming(mode) = phase else { return }
        begin(mode)
    }

    // MARK: Blocked screen

    /// What a confirmation says about the session: how long it has left, or that this is the
    /// last round.
    private func sessionNote(after length: TimeInterval) -> String {
        guard let end = sessionEnd else { return "" }
        let left = end.timeIntervalSinceNow
        if left <= length { return "Last round: the session ends at the confirmation after it." }
        return "Session ends after \(Config.wallTime(in: left)) · \(Config.duration(left)) to go."
    }

    /// What the overlays should show for the current phase, and the live clock and lines of text.
    private func render() {
        guard isBlocked else { return }
        let content: OverlayContent
        var clock = ""
        var status = ""
        var note = ""
        var fraction = 1.0
        switch phase {
        case let .confirming(mode):
            let slot = slots[mode]!
            let length = Config.seconds(minutes: slot)
            let heading = firstConfirmation ? "Ready to start?" : "Ready to switch to \(mode.title)?"
            content = .confirmation(heading: heading, mode: mode)
            let until = Config.wallTime(in: length)
            note = mode == .closed
                ? "Every screen closes for \(slot) minutes, until \(until). Your canvas comes along."
                : "The screen is yours for \(slot) minutes, until \(until)."
            status = sessionNote(after: length)
        case let .running(.closed, deadline):
            let left = deadline.timeIntervalSinceNow
            clock = Config.clock(left)
            fraction = left / Config.seconds(minutes: slots[.closed]!)
            if let p = puzzle {
                content = .puzzle(question: p.question, attemptsLeft: p.attemptsLeft)
                status = p.attemptsLeft == Config.puzzleAttempts ? ""
                    : "Not quite. \(p.attemptsLeft) \(p.attemptsLeft == 1 ? "attempt" : "attempts") left."
            } else {
                content = .closed(escape: escapeState)
                if let until = escapeLockedUntil, Date() < until {
                    status = "Three wrong answers. I need out is back in \(Config.clock(until.timeIntervalSinceNow))."
                } else if !reminderText.isEmpty {
                    status = reminderText
                } else {
                    status = "The screen opens again at \(Config.wallTime(in: left))."
                }
            }
        default:
            return
        }
        let focusAnswer = overlays.first?.content != content && puzzle != nil
        for overlay in overlays {
            overlay.show(content)
            overlay.setClock(clock)
            overlay.setStatus(status)
            overlay.setNote(note)
            overlay.setProgress(fraction)
            if case let .confirming(mode) = phase { overlay.setSlot(slots[mode]!) }
        }
        if focusAnswer { overlays.first?.focusAnswer() }
    }

    private func block() {
        guard !isBlocked else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        // The canvas's window steps aside: the overlay takes the canvas, and nothing closes it there.
        canvasWindowWasOpen = canvasWindow?.isVisible ?? false
        canvasWindow?.orderOut(nil)
        buildOverlays(fadeIn: true)
        regainFocus()
        // Keys for anything but our own windows go nowhere; the overlay windows decide the rest.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            event.window is OverlayWindow ? event : nil
        }
    }

    /// Removes all overlays and gives focus back. Safe to call repeatedly.
    private func unblock() {
        rebuildWork?.cancel()
        rebuildWork = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        guard isBlocked else { return }
        closeOverlays()
        // The canvas goes back to its window (open, or minimized in the Dock), which reappears if it
        // was open before, under whatever app was in front.
        if let window = canvasWindow {
            window.attach()
            if canvasWindowWasOpen { window.orderFront(nil) }
        }
        canvasWindowWasOpen = false
        if let app = previousApp, !app.isTerminated, app != NSRunningApplication.current {
            app.activate(options: [])
        }
        previousApp = nil
    }

    private func closeOverlays() {
        if let canvas = canvas, canvas.webView.window is OverlayWindow {
            canvas.commitEdits()
            canvas.webView.removeFromSuperview()
        }
        overlays.forEach { $0.close() }
        overlays.removeAll()
    }

    /// One overlay per screen. Blocking fades them in (a quarter of a second, already opaque
    /// enough to cover at once); a rebuild after a display change swaps them in place.
    private func buildOverlays(fadeIn: Bool = false) {
        closeOverlays()
        overlays = NSScreen.screens.map { screen in
            let w = OverlayWindow(screen: screen)
            w.actions = self
            if fadeIn { w.alphaValue = 0 }
            w.orderFrontRegardless()
            return w
        }
        // §10: the main screen (the first one, with the menu bar) holds the canvas.
        if let canvas = canvas {
            overlays.first?.attachCanvas(canvas.webView)
            overlays.dropFirst().forEach { $0.canvasElsewhere = true }
        }
        if fadeIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                overlays.forEach { $0.animator().alphaValue = 1 }
            }
        }
    }

    /// Keeps an overlay key and the app active for as long as the screen is blocked, so key
    /// events keep landing in our windows.
    private func regainFocus() {
        guard isBlocked else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isBlocked else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.overlays.forEach { $0.orderFrontRegardless() }
            self.overlays.first?.makeKey()
            if self.puzzle != nil { self.overlays.first?.focusAnswer() }
        }
    }

    @objc private func workspaceDidWake(_ note: Notification) {
        tick()                                     // move on at once if a deadline passed
        regainFocus()
    }
    @objc private func appDidResignActive(_ note: Notification) { regainFocus() }

    // Rebuild if a display is plugged/unplugged or resized while blocked. These
    // notifications arrive in bursts, so coalesce them.
    @objc private func screensChanged() {
        guard isBlocked else { return }
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isBlocked else { return }
            self.buildOverlays()
            self.render()
            self.regainFocus()
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

// MARK: - Entry point

let args = CommandLine.arguments.dropFirst()
if args.contains("-h") || args.contains("--help") {
    print(Config.usage)
    exit(0)
}
if args.contains("--version") {
    print(Updater.versionLine)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
