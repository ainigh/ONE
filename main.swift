import Cocoa

// MARK: - Configuration

/// Resolves the countdown length. Precedence: `-duration N` launch argument
/// (read via UserDefaults' argument domain, so it can also be persisted with
/// `defaults write <bundle id> duration -int 10`), then `COUNTDOWN_SECONDS`
/// env var, then the built-in default. Out-of-range values fall back to the
/// default so a typo can never lock the screen for hours.
enum Config {
    static let defaultDuration = 5
    static let minDuration = 1
    static let maxDuration = 3600

    static var duration: Int {
        var value = defaultDuration
        if let env = ProcessInfo.processInfo.environment["COUNTDOWN_SECONDS"],
           let parsed = Int(env.trimmingCharacters(in: .whitespaces)) {
            value = parsed
        }
        if UserDefaults.standard.object(forKey: "duration") != nil {
            value = UserDefaults.standard.integer(forKey: "duration")
        }
        return (minDuration...maxDuration).contains(value) ? value : defaultDuration
    }

    static let usage = """
    CountdownOverlay — menubar countdown that covers every screen.

    usage: CountdownOverlay [-duration SECONDS]

      -duration N   countdown length, \(minDuration)...\(maxDuration) (default \(defaultDuration))
      -h, --help    show this help
      --version     print the version and commit this copy was built from

    COUNTDOWN_SECONDS=N in the environment is used when -duration is absent.
    """
}

// MARK: - Overlay window (one per screen)

final class OverlayWindow: NSWindow {
    private let label = NSTextField(labelWithString: "")

    init(screen: NSScreen) {
        // Use the global-coordinate initializer: the `screen:` variant interprets
        // contentRect relative to that screen, which misplaces secondary displays.
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        setFrame(screen.frame, display: false)

        level = .screenSaver                       // above everything, incl. full-screen apps
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.85)
        hasShadow = false
        ignoresMouseEvents = false                 // swallow clicks so they don't fall through
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none                  // appear instantly, no fade
        isMovable = false

        // Scale the digits with the screen so they fit on small displays
        // and stay legible on large ones.
        let shortSide = min(screen.frame.width, screen.frame.height)
        let fontSize = min(max(shortSide * 0.28, 72), 320)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityLabel("Countdown")

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        contentView = content
    }

    func setRemaining(_ seconds: Int) {
        let text = "\(seconds)"
        if label.stringValue != text {
            label.stringValue = text
        }
    }

    // Allow the window to take focus so it captures key presses.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Swallow Esc, Cmd-W, Cmd-Q, arrow keys, etc.
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    override func cancelOperation(_ sender: Any?) {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }

    // Swallow mouse interaction on the overlay itself.
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlays: [OverlayWindow] = []
    private var timer: Timer?
    private var deadline: Date?
    private var keyMonitor: Any?
    private var rebuildWork: DispatchWorkItem?
    private var previousApp: NSRunningApplication?
    private var lastShown = -1
    private let duration = Config.duration
    private let updater = Updater()

    private var isRunning: Bool { deadline != nil }

    /// Whole seconds left, rounded up so "5" shows for the first full second.
    private var remainingSeconds: Int {
        guard let deadline = deadline else { return 0 }
        return max(0, Int(ceil(deadline.timeIntervalSinceNow)))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)      // no Dock icon, menubar only

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Countdown") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "⏱"                 // fallback if SF Symbols are unavailable
            }
            button.toolTip = "Countdown Overlay (\(duration)s) — click to start, right-click for menu"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updater.onChange = { [weak self] state in
            guard let button = self?.statusItem?.button else { return }
            if case .available = state {
                button.toolTip = "Update available — right-click for menu"
            }
        }
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

        // After sleep/wake the deadline may already have passed; resync at once.
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(workspaceDidWake(_:)),
                                                          name: NSWorkspace.didWakeNotification,
                                                          object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardown()
    }

    // Refuse to quit while the countdown is running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isRunning ? .terminateCancel : .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Menubar interaction

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            startCountdown()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false              // honour the isEnabled flags below

        let title = menu.addItem(withTitle: isRunning
                                    ? "Counting down… \(remainingSeconds)s"
                                    : "Countdown length: \(duration)s",
                                 action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(.separator())

        let start = menu.addItem(withTitle: "Start Countdown",
                                 action: #selector(startCountdown), keyEquivalent: "")
        start.target = self
        start.isEnabled = !isRunning

        menu.addItem(.separator())
        addUpdateItems(to: menu)

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        quit.isEnabled = !isRunning

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil                      // restore click-to-start behaviour
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
            // Updating restarts the app, which the countdown refuses: offer it only in between.
            let update = item(title, #selector(installUpdate), enabled: !isRunning)
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
        guard !isRunning else { return }
        updater.install()
    }

    @objc private func copyUpdateDetails() {
        guard case .failed(let message) = updater.state else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Updater.report(message), forType: .string)
    }

    // MARK: Countdown

    @objc private func startCountdown() {
        guard !isRunning else { return }           // ignore clicks mid-countdown

        previousApp = NSWorkspace.shared.frontmostApplication
        deadline = Date().addingTimeInterval(TimeInterval(duration))
        lastShown = -1
        statusItem.button?.appearsDisabled = true
        NSCursor.hide()

        buildOverlays()
        updateLabels()
        regainFocus()

        // Swallow every key event delivered to this process, regardless of
        // which window is key, so Cmd-Q etc. never reach the responder chain.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { _ in nil }

        // Tick often and derive the display from the deadline, so the count
        // never drifts and recovers correctly after the machine sleeps.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func workspaceDidWake(_ note: Notification) {
        tick()                                     // finish at once if the deadline passed
        if isRunning { regainFocus() }
    }
    @objc private func appDidResignActive(_ note: Notification) { regainFocus() }

    private func tick() {
        guard isRunning else { return }
        if remainingSeconds <= 0 {
            finish()
        } else {
            updateLabels()
        }
    }

    private func finish() {
        teardown()

        // Give focus back to whatever the user was using before we took over.
        if let app = previousApp, !app.isTerminated, app != NSRunningApplication.current {
            app.activate(options: [])
        }
        previousApp = nil
    }

    /// Stops the timer and removes all overlays. Safe to call repeatedly.
    private func teardown() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        rebuildWork?.cancel()
        rebuildWork = nil
        NSCursor.unhide()                          // never leave the cursor hidden
        statusItem?.button?.appearsDisabled = false
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        closeOverlays()
    }

    private func closeOverlays() {
        overlays.forEach { $0.close() }
        overlays.removeAll()
    }

    private func buildOverlays() {
        closeOverlays()
        overlays = NSScreen.screens.map { screen in
            let w = OverlayWindow(screen: screen)
            w.orderFrontRegardless()
            return w
        }
    }

    private func updateLabels() {
        let value = remainingSeconds
        guard value != lastShown else { return }
        lastShown = value
        overlays.forEach { $0.setRemaining(value) }
    }

    /// Keeps the overlay key and the app active for as long as the countdown
    /// runs, so key events keep landing in our swallowing handlers.
    private func regainFocus() {
        guard isRunning else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.overlays.forEach { $0.orderFrontRegardless() }
            self.overlays.first?.makeKey()
        }
    }

    // Rebuild if a display is plugged/unplugged or resized mid-countdown. These
    // notifications arrive in bursts, so coalesce them.
    @objc private func screensChanged() {
        guard isRunning else { return }
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.lastShown = -1
            self.buildOverlays()
            self.updateLabels()
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
