import Cocoa
import UserNotifications

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
    /// Session lengths offered at activation, in hours (§4).
    static let sessionHours = [1, 2, 4, 8]
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

    static func seconds(minutes: Int) -> TimeInterval { Double(minutes) * secondsPerMinute }

    /// `mm:ss` of a real interval, in the app's minutes, rounded up so a full minute reads 01:00.
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(ceil(interval / secondsPerMinute * 60 - 0.0001)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// `mm:ss` of a whole number of minutes.
    static func clock(minutes: Int) -> String { String(format: "%02d:%02d", minutes, 0) }

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

    usage: CountdownOverlay [-minute SECONDS] [-mute YES]

      -minute N     real seconds per app minute, 1...60 (default 60), to try the cycle quickly
      -mute YES     no sounds at transitions
      -h, --help    show this help
      --version     print the version and commit this copy was built from
    """
}

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

    func play() {
        guard !Config.muted else { return }
        // `NSSound(named:)` hands back a shared instance that ignores play() while it is already
        // playing; a copy plays every time.
        guard let sound = NSSound(named: NSSound.Name(rawValue))?.copy() as? NSSound else { return }
        sound.play()
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
/// confirmation for the interrupted mode, plus the slots and the escape cooldown.
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
    }
}

/// Notifications for Opened-mode reminders (§5) and other things that happen while the screen
/// isn't blocked. Only an app bundle can post them; a bare binary logs instead.
enum Notifier {
    static var available: Bool { Updater.isInstalledApp }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        guard available else {
            NSLog("%@: %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Overlay window (one per screen)

/// What the blocked screen can show. The clock and status line underneath are set separately,
/// every tick, without rebuilding the views.
enum OverlayContent: Equatable {
    case confirmation(heading: String, mode: Mode, slot: Int)
    case closed(escape: EscapeState)
    case puzzle(question: String, note: String)
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

    private let clockLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private var answerField: NSTextField?
    private let headingSize: CGFloat
    private let textSize: CGFloat

    init(screen: NSScreen) {
        // Use the global-coordinate initializer: the `screen:` variant interprets
        // contentRect relative to that screen, which misplaces secondary displays.
        let shortSide = min(screen.frame.width, screen.frame.height)
        headingSize = min(max(shortSide * 0.06, 28), 64)
        textSize = min(max(shortSide * 0.028, 18), 34)
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        setFrame(screen.frame, display: false)

        level = .screenSaver                       // above everything, incl. full-screen apps
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.88)
        hasShadow = false
        ignoresMouseEvents = false                 // swallow clicks so they don't fall through
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none                  // appear instantly, no fade
        isMovable = false

        // Scale the digits with the screen so they fit on small displays
        // and stay legible on large ones.
        let clockSize = min(max(shortSide * 0.22, 64), 260)
        clockLabel.font = NSFont.monospacedDigitSystemFont(ofSize: clockSize, weight: .bold)
        clockLabel.textColor = .white
        clockLabel.alignment = .center
        clockLabel.setAccessibilityLabel("Time left")

        statusLabel.font = NSFont.systemFont(ofSize: textSize, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = textSize
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.8),
        ])
        contentView = content
    }

    // MARK: Content

    /// Rebuilds the controls for `content`, unless it is already showing.
    func show(_ new: OverlayContent) {
        guard new != content else { return }
        content = new
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        answerField = nil

        switch new {
        case let .confirmation(heading, _, slot):
            stack.addArrangedSubview(label(heading, size: headingSize, weight: .bold))
            let picker = NSSegmentedControl(labels: Config.slots.map(String.init),
                                            trackingMode: .selectOne,
                                            target: self, action: #selector(slotChanged(_:)))
            picker.font = NSFont.systemFont(ofSize: textSize)
            picker.controlSize = .large
            picker.selectedSegment = Config.slots.firstIndex(of: slot) ?? -1
            picker.setAccessibilityLabel("Minutes")
            stack.addArrangedSubview(picker)
            stack.addArrangedSubview(label("minutes", size: textSize * 0.8, weight: .regular))
            stack.addArrangedSubview(button("Start", key: "\r", action: #selector(startPressed)))

        case let .closed(escape):
            stack.addArrangedSubview(clockLabel)
            stack.addArrangedSubview(statusLabel)
            if escape != .hidden {
                let out = button("I need out", key: "", action: #selector(escapePressed))
                out.isEnabled = escape == .available
                stack.addArrangedSubview(out)
            }

        case let .puzzle(question, note):
            stack.addArrangedSubview(clockLabel)
            stack.addArrangedSubview(label(question, size: headingSize, weight: .bold))
            let field = NSTextField(string: "")
            field.font = NSFont.monospacedDigitSystemFont(ofSize: headingSize * 0.8, weight: .regular)
            field.alignment = .center
            field.placeholderString = "?"
            field.setAccessibilityLabel("Answer")
            field.widthAnchor.constraint(equalToConstant: headingSize * 5).isActive = true
            stack.addArrangedSubview(field)
            answerField = field
            let row = NSStackView(views: [
                button("Never mind", key: "", action: #selector(dismissPuzzlePressed)),
                button("Answer", key: "\r", action: #selector(answerPressed)),
            ])
            row.orientation = .horizontal
            row.spacing = textSize
            stack.addArrangedSubview(row)
            statusLabel.stringValue = note
            stack.addArrangedSubview(statusLabel)
        }
        stack.layoutSubtreeIfNeeded()
    }

    func setClock(_ text: String) {
        if clockLabel.stringValue != text { clockLabel.stringValue = text }
    }

    func setStatus(_ text: String) {
        if statusLabel.stringValue != text { statusLabel.stringValue = text }
    }

    /// Puts the cursor in the answer field, when the puzzle is showing.
    func focusAnswer() {
        if let field = answerField { makeFirstResponder(field) }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = .white
        l.alignment = .center
        return l
    }

    private func button(_ title: String, key: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.font = NSFont.systemFont(ofSize: textSize)
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

    // Keys that no control claims go nowhere: the window itself swallows them.
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    override func cancelOperation(_ sender: Any?) {}

    /// Return still reaches the Start / Answer buttons; any Cmd-combination nobody claims
    /// (Cmd-W, Cmd-Q, Cmd-H…) stops here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
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
    static let repo = "ainigh/ONE-FILE-SWIFT"
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


// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, OverlayActions,
                         UNUserNotificationCenterDelegate {
    /// Where the session is (§1, §3, §7). Everything else derives from it.
    enum Phase {
        case idle
        case confirming(Mode)                      // blocked, timer frozen
        case running(Mode, deadline: Date)
        case paused(until: Date)                   // unblocked, timers frozen
    }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var overlays: [OverlayWindow] = []
    private var timer: Timer?
    private var keyMonitor: Any?
    private var rebuildWork: DispatchWorkItem?
    private var previousApp: NSRunningApplication?
    private let updater = Updater()

    private var phase: Phase = .idle
    private var sessionEnd: Date?
    private var slots: [Mode: Int] = [.opened: Store.slot(for: .opened), .closed: Store.slot(for: .closed)]
    private var lastEscape: Date? = Store.lastEscape
    private var escapeLockedUntil: Date?
    private var puzzle: Puzzle?
    private var remindersDue: [Int] = []           // minute marks still to announce in this mode
    private var reminderText = ""
    private var firstConfirmation = true

    private var inSession: Bool {
        if case .idle = phase { return false }
        return true
    }
    private var isBlocked: Bool { !overlays.isEmpty }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)      // no Dock icon, menubar only

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Session timer") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeading
            } else {
                button.title = "⏱"                 // fallback if SF Symbols are unavailable
            }
        }
        menu.delegate = self
        menu.autoenablesItems = false              // honour the isEnabled flags set in menuNeedsUpdate
        statusItem.menu = menu
        updateStatusItem()

        if Notifier.available {
            UNUserNotificationCenter.current().delegate = self
        }

        updater.onChange = { [weak self] _ in self?.updateStatusItem() }
        updater.start()

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

        // §8: killed or restarted mid-session → the interrupted mode's confirmation, full slot.
        if let end = Store.sessionEnd, let mode = Store.interruptedMode {
            sessionEnd = end
            firstConfirmation = false
            startTicking()
            reachConfirmation(for: mode)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unblock()
    }

    // §4: the session cannot be ended by any other control, quitting included.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        inSession ? .terminateCancel : .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // Show reminders even while this app is the active one.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    // MARK: Menubar

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let title: String
        switch phase {
        case .idle: title = ""
        case .confirming: title = "Ready?"
        case let .running(mode, deadline): title = "\(mode.title) \(Config.clock(deadline.timeIntervalSinceNow))"
        case let .paused(until): title = "Paused \(Config.clock(until.timeIntervalSinceNow))"
        }
        if button.title != title { button.title = title }
        if case .available = updater.state {
            button.toolTip = "Update available — see the menu"
        } else {
            button.toolTip = inSession ? "Session running" : "Click to start a session"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        switch phase {
        case .idle: status = "No session"
        case let .confirming(mode): status = "Waiting for Start (\(mode.title), \(slots[mode]!) min)"
        case let .running(mode, deadline): status = "\(mode.title): \(Config.clock(deadline.timeIntervalSinceNow)) left"
        case let .paused(until): status = "Paused: \(Config.clock(until.timeIntervalSinceNow)) left"
        }
        let title = menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        title.isEnabled = false
        if let end = sessionEnd {
            let ends = menu.addItem(withTitle: "Session ends after \(Config.clock(end.timeIntervalSinceNow))",
                                    action: nil, keyEquivalent: "")
            ends.isEnabled = false
        }
        menu.addItem(.separator())

        let start = menu.addItem(withTitle: "Start Session", action: nil, keyEquivalent: "")
        start.isEnabled = !inSession
        let lengths = NSMenu()
        lengths.autoenablesItems = false
        for hours in Config.sessionHours {
            let item = lengths.addItem(withTitle: hours == 1 ? "1 hour" : "\(hours) hours",
                                       action: #selector(startSession(_:)), keyEquivalent: "")
            item.target = self
            item.tag = hours
            item.isEnabled = !inSession
        }
        start.submenu = lengths

        menu.addItem(.separator())
        addUpdateItems(to: menu)

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        quit.isEnabled = !inSession
    }

    // MARK: Updates

    private func addUpdateItems(to menu: NSMenu) {
        let version = menu.addItem(withTitle: Updater.versionLine, action: nil, keyEquivalent: "")
        version.isEnabled = false
        guard Updater.isInstalledApp else { return }

        @discardableResult
        func item(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            i.target = self
            i.isEnabled = enabled
            return i
        }

        switch updater.state {
        case .idle, .upToDate:
            item("Check for Updates…", #selector(checkForUpdates))
        case .checking:
            item("Checking for Updates…", nil, enabled: false)
        case .available(let plan):
            let title: String
            switch plan {
            case let .prebuilt(commit, release): title = "Update to \(release.tag) — \(commit.title)"
            case let .buildHere(commit): title = "Update (build here) — \(commit.short): \(commit.title)"
            case .upToDate: title = "Check for Updates…"
            }
            // Updating restarts the app, which a session refuses: offer it only in between.
            let update = item(title, #selector(installUpdate), enabled: !inSession)
            update.toolTip = "Downloads the new version (or builds it on this Mac when GitHub hasn't), then restarts."
        case .installing(let step):
            item(step, nil, enabled: false)
        case .failed(let message):
            item(message, nil, enabled: false)
            item("Copy Update Details", #selector(copyUpdateDetails))
            item("Check for Updates…", #selector(checkForUpdates))
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
        guard !inSession, Config.sessionHours.contains(sender.tag) else { return }
        Notifier.requestPermission()
        sessionEnd = Date().addingTimeInterval(Config.seconds(minutes: sender.tag * 60))
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
        Sound.confirmation.play()
    }

    private func endSession() {
        phase = .idle
        sessionEnd = nil
        Store.clearSession()
        puzzle = nil
        stopTicking()
        unblock()
        updateStatusItem()
        Sound.sessionOver.play()
        Notifier.post("Session over", "The session length has elapsed.")
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
            Notifier.post("Opened", "\(Config.clock(minutes: slot)) until Closed.")
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
        Notifier.post("Paused", "\(Config.clock(minutes: Config.pauseMinutes)) until Closed restarts.")
        updateStatusItem()
    }

    // MARK: Ticking

    private func startTicking() {
        guard timer == nil else { return }
        // Tick often and derive everything from deadlines, so nothing drifts and the state
        // recovers correctly after the machine sleeps.
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
        case .idle, .confirming:
            break                                  // frozen
        case let .running(mode, deadline):
            let left = deadline.timeIntervalSinceNow
            if left <= 0 {
                reachConfirmation(for: mode.other)
                return
            }
            if let mark = remindersDue.first, left <= Config.seconds(minutes: mark) {
                remindersDue.removeFirst()
                remind(mode, minutes: mark)
            }
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

    /// §5: Opened → a notification; Closed → text on the blocked screen. Informational only.
    private func remind(_ mode: Mode, minutes: Int) {
        let left = Config.clock(minutes: minutes)
        Sound.reminder.play()
        switch mode {
        case .opened: Notifier.post("Opened", "\(left) left.")
        case .closed: reminderText = "\(left) left"
        }
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
        let answer = Int(text.trimmingCharacters(in: .whitespaces))
        if answer == p.answer {
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
        } else {
            puzzle = p
        }
        render()
    }

    func overlayDismissedPuzzle() {
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

    /// What the overlays should show for the current phase, and the live clock and status line.
    private func render() {
        guard isBlocked else { return }
        let content: OverlayContent
        var clock = ""
        var status = ""
        switch phase {
        case let .confirming(mode):
            let heading = firstConfirmation ? "Ready to start?" : "Ready to switch to \(mode.title)?"
            content = .confirmation(heading: heading, mode: mode, slot: slots[mode]!)
        case let .running(.closed, deadline):
            clock = Config.clock(deadline.timeIntervalSinceNow)
            if let p = puzzle {
                let attempts = p.attemptsLeft == Config.puzzleAttempts ? ""
                    : "Not quite. \(p.attemptsLeft) \(p.attemptsLeft == 1 ? "attempt" : "attempts") left."
                content = .puzzle(question: p.question, note: attempts)
                status = attempts
            } else {
                content = .closed(escape: escapeState)
                if let until = escapeLockedUntil, Date() < until {
                    status = "Three wrong answers. I need out is back in \(Config.clock(until.timeIntervalSinceNow))."
                } else {
                    status = reminderText
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
        }
        if focusAnswer { overlays.first?.focusAnswer() }
    }

    private func block() {
        guard !isBlocked else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        buildOverlays()
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
        if let app = previousApp, !app.isTerminated, app != NSRunningApplication.current {
            app.activate(options: [])
        }
        previousApp = nil
    }

    private func closeOverlays() {
        overlays.forEach { $0.close() }
        overlays.removeAll()
    }

    private func buildOverlays() {
        closeOverlays()
        overlays = NSScreen.screens.map { screen in
            let w = OverlayWindow(screen: screen)
            w.actions = self
            w.orderFrontRegardless()
            return w
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
