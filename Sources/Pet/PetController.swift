import AppKit
import QuartzCore
import UniformTypeIdentifiers
import ServiceManagement

enum ScreenEdge: String { case bottom, top, left, right, free }

enum Mood: String, CaseIterable {
    case shy, normal, chatty
    var title: String {
        switch self {
        case .shy: return "Shy (mostly hidden)"
        case .normal: return "Normal"
        case .chatty: return "Chatty"
        }
    }
}

/// Owns the pet window, runs the animation loop, and decides what Pet feels like doing.
final class PetController: NSObject, NSMenuDelegate {
    enum State { case idle, wandering, napping, poked, dragging, landing, shrinking, strolling, growing }
    enum DiveReason { case menu, drag, idle, typing, autopilot, shh, app }

    let window = PetWindow()
    let view = PetView(frame: CGRect(origin: .zero, size: PetGeometry.viewSize))
    let launchPanel = RingPanel()
    let stashPanel = StashPanel()
    let bedPanel = DogBedPanel()
    let store = ShortcutStore.shared
    let music = MusicWatcher()
    private var homeWindow: PetHomeWindowController?
    private var musicNoteIn: TimeInterval = 20

    private var pose = PetPose()
    private var state: State = .idle
    private var stateTime: TimeInterval = 0
    private var time: TimeInterval = 0
    private var lastTick = CACurrentMediaTime()
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var screenAsleep = false
    private var sleepingInBed = false

    private(set) var edge: ScreenEdge = .bottom
    private(set) var hugEdges = true
    private var hideFromSharing = false
    private var mood: Mood = .normal
    private var quietHours = false
    private(set) var petScale: CGFloat = 1
    private var shhUntil: TimeInterval = 0
    private var diveApps: Set<String> = []
    private var followingCursor = false
    private var followSpeed: CGFloat = 0
    private var followWalkDirection: CGFloat = 1
    private var followSideX: CGFloat = -1
    private var followSideY: CGFloat = -1
    private var testMouse: CGPoint?

    // idle brain
    private var nextDecisionIn: TimeInterval = 8
    private var lastNapEnded: TimeInterval = 0
    private var napDuration: TimeInterval = 0
    private var afkNap = false
    /// Set to true to make it lie down after `afkSleepAfter` seconds without mouse or keyboard.
    private let afkSleepEnabled = false
    private let afkSleepAfter: TimeInterval = 10
    private var wanderTarget: CGFloat = 0
    private var wanderDeadline: TimeInterval = 0
    private var blinkIn: TimeInterval = 3
    private var blinkT: TimeInterval = -1
    private var trackingPointer = false
    private var thoughtIn: TimeInterval = 20
    private var thoughtUntil: TimeInterval = 0
    private var finFlickUntil: TimeInterval = 0
    private var oppositeSideFor: TimeInterval = 0
    private var tailTwitchIn: TimeInterval = 5
    private var tailTwitchUntil: TimeInterval = 0

    // curious
    private var curiousT: TimeInterval = -1
    private var curiousAnchor = CGPoint.zero
    private var curiousBuild: TimeInterval = 0
    private var lastCurious: TimeInterval = -100
    private var curiousTilt: CGFloat = 0

    // pointer / hover / typing
    private var hoverDwell: TimeInterval = 0
    private var hoverGrace: TimeInterval = 0
    private var panelCooldownUntil: TimeInterval = 0
    private var lastMouse = NSEvent.mouseLocation
    private var mouseStillFor: TimeInterval = 0
    private var cursorSpeed: CGFloat = 0
    private var welcomeUntil: TimeInterval = 0
    private var lastIgnoresMouse = true
    private var keyIdle: TimeInterval = 999
    private var typingFor: TimeInterval = 0
    private var typingDiveAfter: TimeInterval = 75
    private var resurfaceAfter: TimeInterval = 22
    private var dropHovering = false
    private var gulpT: TimeInterval = -1

    // drag
    private var pressed = false
    private var pressStart = CGPoint.zero
    private var pressOrigin = CGPoint.zero
    private var lastDragX: CGFloat = 0
    private var dragVelocity: CGFloat = 0
    private var tilt: CGFloat = 0
    private var releasedAt: TimeInterval = -1000

    // landing / pulses
    private var landFrom = CGPoint.zero
    private var landTo = CGPoint.zero
    private var landDuration: TimeInterval = 0.4
    private var pulseT: TimeInterval = -1
    private var pulseDuration: TimeInterval = 0.3
    private var pulseAmount: CGFloat = 0
    private var turnT: TimeInterval = -1
    private var spinT: TimeInterval = -1

    // poke / double-click
    private var pokeCount = 0
    private var lastPoke: TimeInterval = -10
    private var lastClickAt: TimeInterval = -10

    // side-edge peeking (0 = tucked away, 1 = fully out)
    private var peek: CGFloat = 1
    private var peekTarget: CGFloat = 1
    private var peekChangeIn: TimeInterval = 4

    // stroll: 0 = full size, 1 = compact (75% of idle size)
    private var mini: CGFloat = 0
    private var diveReason: DiveReason = .idle
    private var cruiseUntil: TimeInterval = 0
    private var cruiseDir: CGFloat = 1
    private var cruiseSpeed: CGFloat = 0
    private var targetSpeed: CGFloat = 0
    private var legUntil: TimeInterval = 0
    private var pauseUntil: TimeInterval = 0
    private var turnUntil: TimeInterval = 0
    private var hitWall = false
    private var lastSelfSurface: TimeInterval = -1000
    private var surfaceFrom: CGFloat = 0
    private var surfaceDuration: TimeInterval = 0.6
    private var surfaceOpenPanel = false
    private var pendingComeHere: CGPoint? = nil

    // apps
    private var recentApps: [URL] = []
    private var appRingMode: AppRingMode = .pinned
    private var frontSince: TimeInterval = 0
    private var frontBundle: String?
    private var switchTimes: [TimeInterval] = []
    private var lastAutopilot: TimeInterval = -1000

    private enum Keys {
        static let x = "pet.origin.x", y = "pet.origin.y", edge = "pet.edge", hugEdges = "pet.hugEdges", coat = "pet.coat"
        static let sharing = "pet.hideFromSharing", mood = "pet.mood", quiet = "pet.quietHours", underwater = "pet.underwater"
        static let diveApps = "pet.diveApps", firstRun = "pet.firstRunDone", pillHint = "pet.pillHintShown", size = "pet.displayScale"
        static let followCursor = "pet.followCursor"
        static let sleepingInBed = "pet.sleepingInBed"
        static let appRingMode = "pet.appRingMode", recentApps = "pet.recentApps"
    }
    private var saidBrb = false
    private var selfTesting = false
    private var pendingThoughts: [(TimeInterval, String, TimeInterval)] = []

    var currentCoat: Coat { pose.coat }
    var currentAppRingMode: AppRingMode { appRingMode }
    var ringAppURLs: [URL] { launchPanel.displayedAppURLs }
    var currentMood: Mood { mood }
    var quietHoursEnabled: Bool { quietHours }
    var hidesFromSharing: Bool { hideFromSharing }
    var opensAtLogin: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") && SMAppService.mainApp.status == .enabled
    }

    override init() {
        super.init()
        view.controller = self
        window.contentView = view
        let d = UserDefaults.standard
        hugEdges = d.object(forKey: Keys.hugEdges) as? Bool ?? true
        pose.coat = Coat(rawValue: d.string(forKey: Keys.coat) ?? "") ?? .sand
        sleepingInBed = d.object(forKey: Keys.sleepingInBed) == nil
            ? d.bool(forKey: "pet.sleepingInHouse") : d.bool(forKey: Keys.sleepingInBed)
        bedPanel.coat = pose.coat
        bedPanel.occupied = sleepingInBed
        bedPanel.onWake = { [weak self] in self?.wakeFromBed() }
        hideFromSharing = d.bool(forKey: Keys.sharing)
        mood = Mood(rawValue: d.string(forKey: Keys.mood) ?? "") ?? .normal
        quietHours = d.bool(forKey: Keys.quiet)
        followingCursor = d.bool(forKey: Keys.followCursor)
        appRingMode = AppRingMode(rawValue: d.string(forKey: Keys.appRingMode) ?? "") ?? .pinned
        var seenApps = Set<String>()
        recentApps = Array((d.stringArray(forKey: Keys.recentApps) ?? [])
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path)
                && $0.path != Bundle.main.bundleURL.path
                && seenApps.insert($0.path).inserted }
            .prefix(RingPanel.recentLimit + 1))
        launchPanel.appMode = appRingMode
        launchPanel.recents = switchBackApps
        launchPanel.reload()
        let savedScale = CGFloat((d.object(forKey: Keys.size) as? NSNumber)?.doubleValue ?? 1)
        petScale = (0.85...1.15).contains(savedScale) ? savedScale : 1
        pose.displayScale = petScale
        diveApps = Set(d.stringArray(forKey: Keys.diveApps) ?? [])
        applySharing()
        launchPanel.onLaunch = { [weak self] url in self?.launch(url) }
        launchPanel.onAdd = { [weak self] in self?.addShortcut() }
        launchPanel.onStash = { [weak self] in self?.openStash() }
        launchPanel.onPlayPause = { [weak self] in
            self?.music.playPause()
            self?.launchPanel.hide()
        }
        music.onChange = { [weak self] in
            guard let self else { return }
            self.launchPanel.nowPlaying = self.music.track
            self.launchPanel.reload()
            if self.music.isPlaying, self.state == .idle { self.think("♪", for: 2) }
        }
        launchPanel.onRemove = { [weak self] url in
            self?.store.remove(url)
            self?.launchPanel.reload()
        }
        launchPanel.onPin = { [weak self] url in
            self?.store.add(url)
            self?.launchPanel.reload()
            self?.spawnParticles("♥", count: 1)
        }
    }

    func start() {
        placeInitially()
        bedPanel.place(in: currentScreen.visibleFrame)
        bedPanel.orderFrontRegardless()
        if sleepingInBed { window.orderOut(nil) }
        else { window.orderFrontRegardless() }
        restartTimer(interval: 1.0 / 30.0)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(activeSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        // debug: `Pet --snapshot` (from a second process) asks the running app to dump what it draws + its state
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(debugSnapshot),
                                                            name: Notification.Name("in.vellabs.pet.snapshot"), object: nil)
        if let front = NSWorkspace.shared.frontmostApplication {
            frontBundle = front.bundleIdentifier
            if front.bundleIdentifier != Bundle.main.bundleIdentifier,
               front.activationPolicy == .regular, let url = front.bundleURL { recordRecentApp(url) }
        }
        enterIdle()
        let d = UserDefaults.standard
        if !d.bool(forKey: Keys.firstRun) {
            d.set(true, forKey: Keys.firstRun)
            thinkLater("hi! ◠‿◠", after: 1, for: 2.6)
            thinkLater("rest your mouse on me", after: 4, for: 4)
            thinkLater("drop files on me too", after: 8.5, for: 3.5)
        }
    }

    // MARK: - Timer

    private func restartTimer(interval: TimeInterval) {
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timerInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Faster frames during movement or pointer interaction; slower ticks while Pet rests.
    private func desiredInterval(mouse: CGPoint) -> TimeInterval {
        if screenAsleep { return 2.0 }
        if launchPanel.isShown || hitRectOnScreen.insetBy(dx: -48, dy: -48).contains(mouse) {
            return 1.0 / 60.0
        }
        if followingCursor { return followSpeed > 20 ? 1.0 / 60.0 : 1.0 / 30.0 }
        switch state {
        case .landing, .dragging, .wandering, .poked, .shrinking, .growing: return 1.0 / 60.0
        case .strolling: return cruiseSpeed > 1 ? 1.0 / 30.0 : 1.0 / 15.0
        default: break
        }
        if launchPanel.isShown || pressed || pulseT >= 0 || turnT >= 0 || spinT >= 0 || gulpT >= 0
            || !pose.particles.isEmpty || pose.thoughtAlpha > 0.01 || curiousT >= 0 {
            return 1.0 / 30.0
        }
        let c = refPoint
        if hypot(mouse.x - c.x, mouse.y - c.y) < 500 { return 1.0 / 30.0 }
        return state == .napping ? 1.0 / 10.0 : 1.0 / 15.0
    }

    @objc private func screensSlept() { screenAsleep = true }
    @objc private func screensWoke() {
        screenAsleep = false
        lastTick = CACurrentMediaTime()
        bedPanel.orderFrontRegardless()
        if !sleepingInBed { window.orderFrontRegardless() }
        if launchPanel.isShown { launchPanel.orderFrontRegardless() }
        if stashPanel.isShown { stashPanel.orderFrontRegardless() }
    }

    /// Full-screen apps live in their own Spaces. Reassert the panel after a Space swipe so
    /// the pet remains present everywhere, including full-screen app Spaces.
    @objc private func activeSpaceChanged() {
        guard !screenAsleep else { return }
        bedPanel.orderFrontRegardless()
        if !sleepingInBed { window.orderFrontRegardless() }
        if launchPanel.isShown { launchPanel.orderFrontRegardless() }
        if stashPanel.isShown { stashPanel.orderFrontRegardless() }
        lastTick = CACurrentMediaTime()
    }

    private func applySharing() {
        window.sharingType = hideFromSharing ? .none : .readOnly
        launchPanel.sharingType = hideFromSharing ? .none : .readOnly
        stashPanel.sharingType = hideFromSharing ? .none : .readOnly
        bedPanel.sharingType = hideFromSharing ? .none : .readOnly
    }

    // MARK: - Apps you use

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        if app.bundleIdentifier != frontBundle {
            frontBundle = app.bundleIdentifier
            frontSince = time
            switchTimes.append(time)
            switchTimes.removeAll { time - $0 > 60 }
        }
        guard let url = app.bundleURL, app.activationPolicy == .regular else { return }
        recordRecentApp(url)
    }

    private func recordRecentApp(_ url: URL) {
        let app = url.standardizedFileURL
        recentApps.removeAll { $0.path == app.path }
        recentApps.insert(app, at: 0)
        if recentApps.count > RingPanel.recentLimit + 1 { recentApps.removeLast() }
        if !selfTesting { UserDefaults.standard.set(recentApps.map(\.path), forKey: Keys.recentApps) }
        if appRingMode == .recent {
            launchPanel.recents = switchBackApps
            launchPanel.reload()
        }
        if appRingMode == .recent, homeWindow?.window?.isVisible == true { homeWindow?.refreshApps() }
    }

    private var switchBackApps: [URL] {
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL
        return recentApps.filter { $0.path != front?.path }
    }

    // MARK: - Geometry

    private var origin: CGPoint { window.frame.origin }
    private func setOrigin(_ p: CGPoint) { window.setFrameOrigin(CGPoint(x: (p.x * 2).rounded() / 2, y: (p.y * 2).rounded() / 2)) }

    var bodyCenterOnScreen: CGPoint {
        let y = PetGeometry.bodyBottom + (PetGeometry.bodyCenter.y - PetGeometry.bodyBottom) * petScale
        return CGPoint(x: origin.x + PetGeometry.bodyCenter.x, y: origin.y + y)
    }
    private var refPoint: CGPoint { bodyCenterOnScreen }
    private var typing: Bool { keyIdle < 3 }

    private var lastKnownScreen: NSScreen?
    private var currentScreen: NSScreen {
        let c = bodyCenterOnScreen
        let s = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(c) }
            ?? NSScreen.main ?? NSScreen.screens.first ?? lastKnownScreen
        lastKnownScreen = s
        return s ?? NSScreen()
    }

    private func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) } ?? currentScreen
    }

    /// True when a screen point is on the pet's visible silhouette.
    func petContains(_ point: CGPoint) -> Bool {
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard scaledHitPath().contains(local) else { return false }
        return currentScreen.visibleFrame.insetBy(dx: -2, dy: -2).contains(point)
    }

    var hitRectOnScreen: CGRect {
        let full = scaledHitPath()
            .boundingBox.offsetBy(dx: origin.x, dy: origin.y)
        let visible = full.intersection(currentScreen.visibleFrame.insetBy(dx: -2, dy: -2))
        return visible.isNull ? full : visible
    }

    private func scaledHitPath() -> CGPath {
        let napping = SpriteAtlas.image != nil && pose.napping
        let path = PetGeometry.hitPath(bob: pose.bob, facing: pose.facing,
                                       squashX: napping ? 1 : pose.squashX,
                                       squashY: napping ? 1 : pose.squashY, napping: napping)
        var transform = CGAffineTransform(translationX: PetGeometry.bodyCenter.x, y: PetGeometry.bodyBottom)
            .scaledBy(x: petScale, y: petScale)
            .translatedBy(x: -PetGeometry.bodyCenter.x, y: -PetGeometry.bodyBottom)
        return path.copy(using: &transform) ?? path
    }

    private func edgeTarget(for edge: ScreenEdge, in f: CGRect, from o: CGPoint) -> CGPoint {
        let g = PetGeometry.self
        let scaledHalfWidth = g.bodyHalfWidth * petScale
        let scaledTop = g.bodyBottom + (g.earTop - g.bodyBottom) * petScale
        let minX = f.minX - g.bodyCenter.x + scaledHalfWidth + 4
        let maxX = f.maxX - g.bodyCenter.x - scaledHalfWidth - 4
        let minY = f.minY - g.bodyBottom + 6      // feet 6pt above the edge: legs never crop
        let maxY = f.maxY - scaledTop - 2
        func cx(_ x: CGFloat) -> CGFloat { min(max(x, minX), maxX) }
        func cy(_ y: CGFloat) -> CGFloat { min(max(y, minY), maxY) }
        switch edge {
        case .bottom: return CGPoint(x: cx(o.x), y: minY)
        case .top:    return CGPoint(x: cx(o.x), y: maxY)
        case .left:   return CGPoint(x: minX + 8 - (scaledHalfWidth * 2 - 16) * (1 - peek), y: cy(o.y))
        case .right:  return CGPoint(x: maxX - 8 + (scaledHalfWidth * 2 - 16) * (1 - peek), y: cy(o.y))
        case .free:   return CGPoint(x: cx(o.x), y: cy(o.y))
        }
    }

    private func isSeam(_ probe: CGPoint, of f: CGRect) -> Bool {
        NSScreen.screens.contains { !$0.visibleFrame.equalTo(f) && $0.frame.contains(probe) }
    }

    private func nearestEdge(in f: CGRect, at c: CGPoint? = nil) -> ScreenEdge {
        let c = c ?? bodyCenterOnScreen
        var options: [(ScreenEdge, CGFloat)] = []
        if !isSeam(CGPoint(x: c.x, y: f.minY - 3), of: f) { options.append((.bottom, (c.y - f.minY) * 0.8)) }
        if !isSeam(CGPoint(x: c.x, y: f.maxY + 3), of: f) { options.append((.top, f.maxY - c.y)) }
        if !isSeam(CGPoint(x: f.minX - 3, y: c.y), of: f) { options.append((.left, c.x - f.minX)) }
        if !isSeam(CGPoint(x: f.maxX + 3, y: c.y), of: f) { options.append((.right, f.maxX - c.x)) }
        return options.min { $0.1 < $1.1 }?.0 ?? .bottom
    }

    private func placeInitially() {
        let d = UserDefaults.standard
        if let e = ScreenEdge(rawValue: d.string(forKey: Keys.edge) ?? "") { edge = e }
        if !hugEdges { edge = .free }
        if followingCursor { edge = .free; peek = 1; mini = 0 }
        var o = CGPoint(x: d.double(forKey: Keys.x), y: d.double(forKey: Keys.y))
        let saved = d.object(forKey: Keys.x) != nil
        let center = CGPoint(x: o.x + PetGeometry.bodyCenter.x, y: o.y + PetGeometry.bodyCenter.y)
        let onSomeScreen = NSScreen.screens.contains { $0.frame.insetBy(dx: -40, dy: -110).contains(center) }
        if !saved || !onSomeScreen {
            let f = (NSScreen.main ?? NSScreen.screens.first ?? currentScreen).visibleFrame
            o = CGPoint(x: f.midX + 140 - PetGeometry.bodyCenter.x, y: f.minY - PetGeometry.bodyBottom)
            edge = hugEdges ? .bottom : .free
        }
        setOrigin(o)
        setOrigin(edgeTarget(for: edge, in: currentScreen.visibleFrame, from: o))
        if edge == .right { pose.facing = -1 }
    }

    func savePosition() {
        let d = UserDefaults.standard
        let standingY = edge == .bottom ? currentScreen.visibleFrame.minY - PetGeometry.bodyBottom : origin.y
        d.set(Double(origin.x), forKey: Keys.x)
        d.set(Double(standingY), forKey: Keys.y)
        d.set(edge.rawValue, forKey: Keys.edge)
    }

    @objc private func screensChanged() {
        bedPanel.place(in: currentScreen.visibleFrame)
        if sleepingInBed { return }
        if followingCursor { return } // the next pointer tick chooses the new display
        guard state != .dragging, !isMini else { return }
        let target = edgeTarget(for: edge, in: currentScreen.visibleFrame, from: origin)
        if hypot(target.x - origin.x, target.y - origin.y) < 2 { return }
        landFrom = origin; landTo = target; landDuration = 0.4
        peek = 1
        state = .landing; stateTime = 0
    }

    // MARK: - Mood

    private var isQuietTime: Bool {
        if time < shhUntil { return true }
        guard quietHours else { return false }
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 22 || h < 8
    }
    private var moodNow: Mood { isQuietTime ? .shy : mood }
    private var thoughtInterval: ClosedRange<Double> {
        switch moodNow { case .shy: return 60...120; case .normal: return 25...70; case .chatty: return 18...40 }
    }
    private var periscopeCheckIn: ClosedRange<Double>? {
        switch moodNow { case .shy: return nil; case .normal: return 40...120; case .chatty: return 30...60 }
    }
    private var curiousCooldown: TimeInterval {
        switch moodNow { case .shy: return 40; case .normal: return 20; case .chatty: return 12 }
    }
    private var selfSurfaceGap: TimeInterval {
        switch moodNow { case .shy: return 600; case .normal: return 300; case .chatty: return 240 }
    }
    private var idleDiveChance: Double {
        switch moodNow { case .shy: return 0.85; case .normal: return 0.7; case .chatty: return 0.5 }
    }

    // MARK: - Animation loop

    private func tick() {
        let now = CACurrentMediaTime()
        let wallDt = max(0, now - lastTick)
        let dt = min(wallDt, 0.1)          // animation step
        lastTick = now
        time += wallDt                      // clocks (naps, cruises, shh) follow the wall clock
        stateTime += dt
        if sleepingInBed {
            bedPanel.tick(time: time)
            restartTimer(interval: 1.0 / 8.0)
            return
        }

        // Keep headless verification deterministic: the real pointer must not hover the test pet
        // and interrupt a stroll by asking it to grow.
        let mouse = selfTesting ? (testMouse ?? CGPoint(x: -10_000, y: -10_000)) : NSEvent.mouseLocation
        let moved = hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y)
        cursorSpeed = approach(cursorSpeed, moved / CGFloat(max(dt, 0.001)), rate: 12, dt: CGFloat(dt))
        if moved > 0.5 {
            if mouseStillFor > 150 { welcomeBack() }
            mouseStillFor = 0
        } else { mouseStillFor += wallDt }
        lastMouse = mouse

        // typing, without any permission: how long since the last key press anywhere
        keyIdle = selfTesting ? 999 : CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if keyIdle < 3 { typingFor += dt } else if keyIdle > 8 { typingFor = 0 }

        updateHover(mouse: mouse, dt: dt)
        updateState(dt: dt, mouse: mouse)
        updateAnimation(dt: dt, mouse: mouse)
        launchPanel.tick(dt: CGFloat(dt))
        view.pose = pose
        applyScreenClip()
        restartTimer(interval: desiredInterval(mouse: mouse))
    }

    private func welcomeBack() {
        guard !isMini else { return }
        if state == .napping { wake() }
        welcomeUntil = time + 1.6
        pulse(amount: 0.12, duration: 0.4)
        spawnBubbles(1)
        think("hi again", for: 1.8)
    }

    private func updateHover(mouse: CGPoint, dt: TimeInterval) {
        let f = currentScreen.visibleFrame
        let petRect = hitRectOnScreen
        let overPet = mouse.y >= f.minY - 2 && petContains(mouse)
        // A passive halo makes the ring easier to find without taking clicks
        // away from the app underneath. Only the actual dog receives mouse events.
        let halo = petRect.insetBy(dx: -18 * petScale, dy: -18 * petScale)
        let nearPet = f.insetBy(dx: -2, dy: -2).contains(mouse) && halo.contains(mouse)
        let overPanel = launchPanel.keepsOpen(for: mouse)

        if state != .dragging && !pressed {
            let ignore = !overPet
            if ignore != lastIgnoresMouse { window.ignoresMouseEvents = ignore; lastIgnoresMouse = ignore }
        }

        if nearPet || overPanel {
            hoverGrace = 0
            if nearPet { hoverDwell += dt } else { hoverDwell = 0 }
            if time < panelCooldownUntil { hoverDwell = 0 }
            let ready = overPet || (nearPet && hoverDwell >= 0.07)
            if !launchPanel.isShown, ready, time >= panelCooldownUntil, !pressed,
               (selfTesting || NSEvent.pressedMouseButtons == 0), !dropHovering, state != .dragging {
                switch state {
                case .strolling, .shrinking:
                    grow(fast: true, openPanel: false)
                default:
                    if state == .napping { wake() }
                    if state == .wandering { enterIdle() }
                }
                launchPanel.show(near: petRect, edge: edge, screen: f, centreX: bodyCenterOnScreen.x)
                if !UserDefaults.standard.bool(forKey: Keys.pillHint) {
                    UserDefaults.standard.set(true, forKey: Keys.pillHint)
                    launchPanel.flash("click an app · + adds one · drop files on me", for: 6)
                }
            }
        } else {
            hoverDwell = 0
            hoverGrace += dt
            if launchPanel.isShown && hoverGrace > 0.45 { launchPanel.hide() }
        }
    }

    private func updateState(dt: TimeInterval, mouse: CGPoint) {
        if followingCursor {
            if state == .poked && stateTime > 0.5 { enterIdle() }
            updateFollow(dt: dt, mouse: mouse)
            return
        }
        switch state {
        case .idle:
            if afkSleepEnabled && mouseStillFor > afkSleepAfter && keyIdle > afkSleepAfter && !launchPanel.isShown && !pressed && !dropHovering && !selfTesting {
                afkNap = true
                startNap()
            }
            if !launchPanel.isShown && !pressed && !typing {
                nextDecisionIn -= dt
                if nextDecisionIn <= 0 { decideNext() }
            }
            updatePeek(dt: dt)
            updateCurious(dt: dt, mouse: mouse)
            // typing focus: after a long steady stretch of typing, get out of the way
            if edge == .bottom && hugEdges && typingFor > typingDiveAfter && !launchPanel.isShown && !pressed {
                startStroll(.typing)
            }
            // deep-work autopilot: 15 min in one app, hands on the mouse
            if edge == .bottom && hugEdges && time - frontSince > 900 && keyIdle > 30
                && time - lastAutopilot > 600 && !launchPanel.isShown && !pressed && mouseStillFor < 30 {
                lastAutopilot = time
                startStroll(.autopilot)
            }
            if let front = frontBundle, diveApps.contains(front), edge == .bottom, hugEdges, !launchPanel.isShown, !pressed {
                startStroll(.app)
            }
        case .wandering:
            if launchPanel.isShown { enterIdle() } else { updateWander(dt: dt) }
        case .napping:
            if afkNap {
                if mouseStillFor < 0.5 || keyIdle < 1 { wake() }
            } else if stateTime > napDuration { wake() }
        case .poked:
            if stateTime > 0.5 { enterIdle() }
        case .dragging:
            break
        case .shrinking:
            updateShrink(dt: dt)
        case .strolling:
            updateStroll(dt: dt, mouse: mouse)
        case .growing:
            updateGrow(dt: dt, mouse: mouse)
        case .landing:
            let p = min(1, stateTime / landDuration)
            let e = 1 - pow(1 - p, 3)
            setOrigin(CGPoint(x: landFrom.x + (landTo.x - landFrom.x) * e,
                              y: landFrom.y + (landTo.y - landFrom.y) * e))
            if p >= 1 {
                setOrigin(landTo)
                enterIdle()
                pulse(amount: edge == .bottom ? -0.16 : 0.08, duration: 0.3)
                savePosition()
            }
        }
    }

    /// Keep Pet near the pointer without covering it. Hovering Pet pauses the chase so
    /// a double-click or drag remains possible.
    private func updateFollow(dt: TimeInterval, mouse: CGPoint) {
        guard !pressed, !petContains(mouse), !launchPanel.isShown else { followSpeed = 0; return }
        let destinationScreen = screen(containing: mouse)
        let bodyY = PetGeometry.bodyBottom + (PetGeometry.bodyCenter.y - PetGeometry.bodyBottom) * petScale
        let visible = destinationScreen.visibleFrame
        // Enter and leave the edge zone at different distances. Choosing the
        // nearest side every frame made Pet flip back and forth at the boundary.
        let leftDistance = mouse.x - visible.minX
        let bottomDistance = mouse.y - visible.minY
        let sideX: CGFloat = leftDistance < (followSideX < 0 ? 165 : 260) * petScale ? 1 : -1
        let sideY: CGFloat = bottomDistance < (followSideY < 0 ? 135 : 230) * petScale ? 1 : -1
        let changedSide = sideX != followSideX || sideY != followSideY
        followSideX = sideX; followSideY = sideY
        let desired = CGPoint(x: mouse.x + sideX * 125 * petScale - PetGeometry.bodyCenter.x,
                              y: mouse.y + sideY * 90 * petScale - bodyY)
        let target = edgeTarget(for: .free, in: visible, from: desired)
        let start = origin
        let dx = target.x - start.x, dy = target.y - start.y
        let distance = hypot(dx, dy)
        if changedSide || destinationScreen.frame != currentScreen.frame {
            setOrigin(target)
        } else if distance > 0.5 {
            let eased = distance * (1 - exp(-6 * CGFloat(dt)))
            let move = min(eased, 700 * CGFloat(dt))
            setOrigin(CGPoint(x: start.x + dx / distance * move,
                              y: start.y + dy / distance * move))
        }
        followSpeed = changedSide ? 0 : hypot(origin.x - start.x, origin.y - start.y) / max(CGFloat(dt), 0.001)
        if abs(origin.x - start.x) > 0.5 { followWalkDirection = origin.x > start.x ? 1 : -1 }
        pose.facing = mouse.x < bodyCenterOnScreen.x ? -1 : 1
    }

    /// On a side edge the shark hides behind the screen edge and peeks out now and then.
    private var peekUntil: TimeInterval = 0
    private func updatePeek(dt: TimeInterval) {
        guard edge == .left || edge == .right else { peek = 1; return }
        let mouse = NSEvent.mouseLocation
        let f = currentScreen.visibleFrame
        let wallX = edge == .left ? f.minX : f.maxX
        let near = abs(mouse.x - wallX) < 240 && abs(mouse.y - bodyCenterOnScreen.y) < 200 && mouseStillFor < 1.5
        // a brief peek now and then (never while typing, never in shy/quiet mode)
        if time > peekUntil {
            peekChangeIn -= dt
            if peekChangeIn <= 0 {
                if periscopeCheckIn != nil, !typing, mouseStillFor < 60 {
                    peekUntil = time + Double.random(in: 1.2...2.5)
                    peekTarget = 0.55
                    blinkT = 0
                }
                peekChangeIn = Double.random(in: 25...70)
            }
        }
        var target: CGFloat
        if near || launchPanel.isShown || pressed || dropHovering { target = 1 }
        else if time < peekUntil { target = peekTarget }
        else if typing { target = 0.02 }
        else { target = 0.14 }
        let old = peek
        peek = approach(peek, target, rate: target > peek ? 3.2 : 1.8, dt: CGFloat(dt))
        if abs(peek - old) > 0.0005 {
            setOrigin(edgeTarget(for: edge, in: f, from: origin))
        }
    }

    /// Nothing outside the usable screen is ever drawn (so a tucked pet never shows over the Dock or a second monitor).
    private func applyScreenClip() {
        guard let view = window.contentView else { return }
        if !view.wantsLayer { view.wantsLayer = true }
        let allowed: CGRect
        if state == .dragging || edge == .free || !hugEdges {
            allowed = currentScreen.frame
        } else {
            allowed = currentScreen.visibleFrame
        }
        let local = CGRect(x: allowed.minX - origin.x, y: allowed.minY - origin.y, width: allowed.width, height: allowed.height)
        let mask = (view.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = view.bounds
        let path = CGPath(rect: local.intersection(view.bounds).isNull ? .zero : local.intersection(view.bounds), transform: nil)
        if mask.path == nil || !(mask.path!.boundingBox.equalTo(path.boundingBox)) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            mask.path = path
            view.layer?.mask = mask
            CATransaction.commit()
        }
    }

    /// A cursor that pauses nearby earns a little head tilt.
    private func updateCurious(dt: TimeInterval, mouse: CGPoint) {
        if curiousT >= 0 {
            curiousT += dt
            if hypot(mouse.x - curiousAnchor.x, mouse.y - curiousAnchor.y) > 40 || curiousT > 5 { curiousT = -1 }
            return
        }
        let c = bodyCenterOnScreen
        let dist = hypot(mouse.x - c.x, mouse.y - c.y)
        if dist > 60, dist < 220, !petContains(mouse), cursorSpeed < 30, !typing, time - lastCurious > curiousCooldown {
            curiousBuild += dt
            if curiousBuild > 0.8 {
                curiousBuild = 0
                curiousT = 0
                curiousAnchor = mouse
                lastCurious = time
            }
        } else { curiousBuild = 0 }
    }

    // MARK: - Stroll (idle "hide": shrink to compact size and walk along the edge)

    private var isMini: Bool { state == .shrinking || state == .strolling || state == .growing }
    private var miniScale: CGFloat { 1 - 0.25 * mini }

    private func startStroll(_ reason: DiveReason) {
        guard edge == .bottom || edge == .top || edge == .free, hugEdges || edge == .free, !isMini, state != .dragging else { return }
        diveReason = reason
        if !saidBrb, reason == .idle || reason == .typing || reason == .autopilot || reason == .app {
            saidBrb = true
            think("brb ~", for: 1.2)
        }
        if launchPanel.isShown { launchPanel.hide() }
        panelCooldownUntil = time + 0.1
        curiousT = -1
        state = .shrinking
        stateTime = 0
    }

    /// Shrink smoothly to the small size, then start walking.
    private func updateShrink(dt: TimeInterval) {
        let q = CGFloat(min(1, stateTime / 0.6))
        mini = q < 0.5 ? 2 * q * q : 1 - pow(-2 * q + 2, 2) / 2      // ease in-out
        if stateTime >= 0.6 { mini = 1; beginStroll() }
    }

    private func beginStroll() {
        cruiseUntil = time + Double.random(in: 40...120)
        resurfaceAfter = Double.random(in: 20...25)
        state = .strolling
        stateTime = 0
        cruiseDir = pose.facing
        cruiseSpeed = 0
        hitWall = false
        startLeg()
        savePosition()
    }

    private func startLeg() {
        legUntil = time + Double.random(in: 4...10)
        targetSpeed = 30
        pauseUntil = 0
    }

    private func updateStroll(dt: TimeInterval, mouse: CGPoint) {
        let f = currentScreen.visibleFrame
        let g = PetGeometry.self
        let dtf = CGFloat(dt)
        let half = g.bodyHalfWidth * miniScale
        let minX = f.minX - g.bodyCenter.x + half + 4
        let maxX = f.maxX - g.bodyCenter.x - half - 4

        if time < pauseUntil {
            targetSpeed = 0
        } else if pauseUntil > 0 {
            pauseUntil = 0
            if !hitWall && Double.random(in: 0..<1) < 0.6 { cruiseDir = -cruiseDir }
            hitWall = false
            startLeg()
        } else if time > legUntil {
            pauseUntil = time + Double.random(in: 1.5...4)
        }
        cruiseSpeed = approach(cruiseSpeed, targetSpeed, rate: 6, dt: dtf)
        var o = origin
        o.x += cruiseDir * cruiseSpeed * dtf
        if o.x <= minX { o.x = minX; cruiseDir = 1; pauseUntil = time + 1; hitWall = true }
        else if o.x >= maxX { o.x = maxX; cruiseDir = -1; pauseUntil = time + 1; hitWall = true }
        setOrigin(o)
        if cruiseSpeed > 0.5 && cruiseDir != pose.facing { pose.facing = cruiseDir }

        let c = bodyCenterOnScreen
        let near = hypot(mouse.x - c.x, mouse.y - c.y) < 200 && mouseStillFor < 1.5
        if near && !typing { grow(fast: true, openPanel: false); return }

        let shh = time < shhUntil
        switchTimes.removeAll { time - $0 > 60 }
        switch diveReason {
        case .typing:
            if keyIdle > resurfaceAfter && mouseStillFor < 10 && !shh { grow(fast: false, openPanel: false); return }
            if switchTimes.count >= 3 && !shh { grow(fast: false, openPanel: false); return }
        case .autopilot:
            if switchTimes.count >= 3 && !shh { grow(fast: false, openPanel: false); return }
        case .app:
            if let front = frontBundle, !diveApps.contains(front), !shh { grow(fast: false, openPanel: false); return }
        default:
            break
        }
        if time > cruiseUntil && mouseStillFor < 3 && time - lastSelfSurface > selfSurfaceGap && !typing && !shh {
            grow(fast: false, openPanel: false)
        }
    }

    private func grow(fast: Bool, openPanel: Bool) {
        guard isMini, state != .growing else { return }
        surfaceFrom = mini
        surfaceOpenPanel = openPanel
        surfaceDuration = fast ? 0.45 : 0.8
        if !fast { lastSelfSurface = time }
        cruiseSpeed = 0
        state = .growing
        stateTime = 0
    }

    private func updateGrow(dt: TimeInterval, mouse: CGPoint) {
        let p = CGFloat(min(1, stateTime / surfaceDuration))
        let e = 1 - pow(1 - p, 3)
        mini = surfaceFrom * (1 - e)
        if p >= 1 {
            mini = 0
            enterIdle()
            pulse(amount: 0.08, duration: 0.3)
            savePosition()
            typingFor = 0
            typingDiveAfter = Double.random(in: 60...90)
            if surfaceOpenPanel && petContains(mouse) { hoverDwell = 0.3; panelCooldownUntil = 0 }
            if let target = pendingComeHere { pendingComeHere = nil; glide(to: target) }
        }
    }

    // MARK: - Animation

    private func think(_ glyph: String, for seconds: TimeInterval = 2.4) {
        pose.thought = glyph
        thoughtUntil = time + seconds
    }

    private func thinkLater(_ glyph: String, after delay: TimeInterval, for seconds: TimeInterval) {
        pendingThoughts.append((time + delay, glyph, seconds))
    }

    private func updateAnimation(dt: TimeInterval, mouse: CGPoint) {
        let t = CGFloat(time)
        let dtf = CGFloat(dt)
        let napping = state == .napping
        pose.napping = napping
        pose.held = state == .dragging
        let yawning = napping && stateTime < 0.9
        let happy = state == .poked || launchPanel.isShown || dropHovering || time < welcomeUntil

        // little passing thoughts while idle (never while typing)
        if state == .idle && !followingCursor && !launchPanel.isShown && !typing && !isQuietTime {
            thoughtIn -= dt
            if thoughtIn <= 0 {
                thoughtIn = Double.random(in: thoughtInterval)
                think(["hm", "…", "?", "♪", "◠‿◠", "ok"].randomElement() ?? "…")
            }
        }
        if let next = pendingThoughts.first, time >= next.0 {
            pendingThoughts.removeFirst()
            think(next.1, for: next.2)
        }
        pose.thoughtAlpha = approach(pose.thoughtAlpha, time < thoughtUntil ? 1 : 0, rate: 6, dt: dtf)

        // music: the disc keeps turning while something plays; a note now and then
        let playing = music.isPlaying
        pose.music = approach(pose.music, playing ? 1 : 0, rate: 3, dt: dtf)
        if playing {
            pose.discAngle += dtf * 3.2
            musicNoteIn -= dt
            if musicNoteIn <= 0 && state == .idle && !followingCursor && !typing { musicNoteIn = Double.random(in: 40...90); think("♪", for: 1.6) }
        }

        // blinking
        if napping {
            blinkT = -1
        } else if blinkT >= 0 {
            blinkT += dt
            if blinkT > 0.18 { blinkT = -1; blinkIn = Double.random(in: 2.5...6.5) }
        } else {
            blinkIn -= dt
            if blinkIn <= 0 { blinkT = 0 }
        }
        let blinkOpen: CGFloat = blinkT < 0 ? 1 : CGFloat(abs(cos(Double.pi * blinkT / 0.18)))

        // where to look
        let c = bodyCenterOnScreen
        let dx = mouse.x - c.x, dy = mouse.y - (c.y + 8)
        let dist = hypot(dx, dy)
        let proximity: CGFloat = max(0, 1 - dist / 380)
        var lookTarget = CGPoint.zero
        if napping {
            lookTarget = .zero
        } else if state == .dragging {
            lookTarget = CGPoint(x: 0, y: 0.3)
        } else {
            // A distant pointer must not trigger a random whole-body gaze pose.
            // Use a wide enter/leave gap so tracking does not chatter
            // when the pointer sits near the edge of Pet's attention area.
            if followingCursor || dist < 350 { trackingPointer = true }
            else if dist > 430 { trackingPointer = false }
        }
        if !napping && state != .dragging && trackingPointer && dist > 0.5 {
            let k = min(1, dist / 140) * (0.45 + 0.55 * max(0, 1 - dist / 1600))
            lookTarget = CGPoint(x: dx / dist * k, y: dy / dist * k)
            if state == .idle, edge == .bottom || edge == .top || edge == .free, abs(dx) > 60, !typing {
                let want: CGFloat = dx > 0 ? 1 : -1
                if want != pose.facing {
                    oppositeSideFor += dt
                    if oppositeSideFor > 0.8 { pose.facing = want; turnT = 0; oppositeSideFor = 0 }
                } else { oppositeSideFor = 0 }
            }
        }
        pose.look.x = approach(pose.look.x, lookTarget.x, rate: 9, dt: dtf)
        pose.look.y = approach(pose.look.y, lookTarget.y, rate: 9, dt: dtf)

        // eyes
        let eyeTarget: CGFloat = yawning ? 0.3 : (napping ? 0 : (state == .dragging ? 1.15 : blinkOpen * (launchPanel.isShown ? 1.08 : 1)))
        pose.eyeOpen = approach(pose.eyeOpen, eyeTarget, rate: napping ? 3 : 30, dt: dtf)
        if state == .poked || dropHovering { pose.eyeStyle = .happy }
        else if napping && pose.eyeOpen < 0.12 { pose.eyeStyle = .closed }
        else { pose.eyeStyle = .open }

        // fin, flippers, mouth, blush, tail
        let curious = curiousT >= 0
        var earTarget: CGFloat = 0.35 + 0.65 * proximity
        if napping { earTarget = 0.05 }
        else if happy || time < finFlickUntil { earTarget = 1 }
        else if state == .dragging { earTarget = 0.2 }
        else if curious { earTarget = 0.8 }
        pose.earPerk = approach(pose.earPerk, earTarget, rate: 6, dt: dtf)

        // chomp: poke, launch, drop, yawn
        var chompTarget: CGFloat = 0
        var mouth: Mouth = .neutral
        if state == .poked {
            let p = CGFloat(stateTime / 0.5)
            chompTarget = p < 0.18 ? p / 0.18 : max(0, 1 - (p - 0.18) / 0.14)
            mouth = .chomp
        } else if dropHovering {
            chompTarget = 1; mouth = .chomp
        } else if yawning {
            chompTarget = sin(CGFloat(stateTime / 0.9) * .pi) * 0.8; mouth = .chomp
        } else if happy { mouth = .happy }
        else if state == .dragging { mouth = .surprised }
        else if napping { mouth = .sleepy }
        pose.chomp = approach(pose.chomp, chompTarget, rate: mouth == .chomp && chompTarget > pose.chomp ? 40 : 18, dt: dtf)
        pose.mouth = mouth
        pose.smile = approach(pose.smile, happy ? 1 : 0, rate: 10, dt: dtf)
        pose.blush = approach(pose.blush, happy ? 1 : 0.55, rate: 4, dt: dtf)

        pose.tailPhase += dtf * (happy ? 6 : (napping ? 0.7 : (state == .wandering ? 3 : 1.7)))
        let swayTarget: CGFloat = curious ? 4 * (dx > 0 ? 1 : -1) * pose.facing : 0
        pose.finSway = approach(pose.finSway, swayTarget, rate: 5, dt: dtf)
        // napping tail twitch
        if napping && !yawning {
            tailTwitchIn -= dt
            if tailTwitchIn <= 0 { tailTwitchIn = Double.random(in: 4...7); tailTwitchUntil = time + 0.3 }
        }
        pose.tailWag = approach(pose.tailWag, time < tailTwitchUntil ? 2.5 : (napping ? 0.35 : 1), rate: 6, dt: dtf)

        // lying flat while napping
        pose.flop = approach(pose.flop, (napping && !yawning) ? 1 : 0, rate: napping ? 2 : 6, dt: dtf)

        // bob + squash
        var bob: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1
        let onFloor = edge == .bottom
        switch state {
        case .idle:
            if onFloor { sy = 1 + 0.018 * sin(t * 1.9); sx = 1 - 0.01 * sin(t * 1.9) }
            else { bob = 2.4 * sin(t * 1.6) }
        case .wandering:
            if onFloor { bob = abs(sin(t * 9)) * 3.2; sy = 1 + 0.03 * sin(t * 18) }
            else { bob = 2.4 * sin(t * 1.6) + 1.2 * sin(t * 7) }
        case .napping:
            sy = 1 + 0.035 * sin(t * 1.1); sx = 1 - 0.02 * sin(t * 1.1)
            bob = onFloor ? 0 : 1.5 * sin(t)
        case .poked:
            let p = CGFloat(stateTime / 0.5)
            if p > 0.32 && p < 0.44 { sy = 0.86; sx = 1.08 }
            bob = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : max(0, sin(p * .pi)) * 3
        case .dragging:
            let wriggle = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : sin(t * 21)
            sy = 1.07 + 0.018 * wriggle
            sx = 0.95 - 0.018 * wriggle
            bob = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1.3 * sin(t * 17)
        case .shrinking, .strolling, .growing, .landing:
            bob = 0
        }
        // small while strolling (anchored at the feet); the nap pose is drawn lying down by the view
        sx *= miniScale
        sy *= miniScale
        let settleTime = time - releasedAt
        if settleTime >= 0 && settleTime < 0.42 && state != .dragging
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CGFloat(pow(1 - settleTime / 0.42, 2))
            let settle = fade * sin(CGFloat(settleTime) * 31)
            sy *= 1 - 0.055 * settle
            sx *= 1 + 0.035 * settle
            bob += 2 * fade * abs(sin(CGFloat(settleTime) * 23))
        }
        if pulseT >= 0 {
            pulseT += dt
            let q = CGFloat(pulseT / pulseDuration)
            if q >= 1 { pulseT = -1 } else { let s = sin(q * .pi) * pulseAmount; sy *= 1 + s; sx *= 1 - s * 0.6 }
        }
        if turnT >= 0 {
            turnT += dt
            let q = CGFloat(turnT / 0.22)
            if q >= 1 { turnT = -1 } else { sx *= 1 - 0.18 * sin(q * .pi) }
        }
        if spinT >= 0 {
            spinT += dt
            let q = CGFloat(spinT / 0.45)
            if q >= 1 { spinT = -1 } else { sx *= cos(2 * .pi * q) }
        }
        if gulpT >= 0 {
            gulpT += dt
            let q = CGFloat(gulpT / 0.7)
            if q >= 1 { gulpT = -1 } else {
                let s: CGFloat = q < 0.35 ? 0.18 * sin(q / 0.35 * .pi) : -0.15 * sin((q - 0.35) / 0.65 * .pi)
                sy *= 1 + s; sx *= 1 - s * 0.7
            }
        }
        pose.bob = bob; pose.squashX = sx; pose.squashY = sy

        // tilt: dangling while dragged, nose-down when diving, lean while cruising, head tilt when curious
        if state == .dragging {
            let vx = (origin.x - lastDragX) / max(dtf, 0.001)
            lastDragX = origin.x
            dragVelocity = approach(dragVelocity, vx, rate: 10, dt: dtf)
            let wriggle: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0 : 0.10 * sin(t * 21) + 0.035 * sin(t * 34)
            let target = max(-0.20, min(0.20, -dragVelocity * 0.00035 + wriggle))
            tilt = approach(tilt, target, rate: 14, dt: dtf)
        } else {
            tilt = approach(tilt, 0, rate: 8, dt: dtf)
        }
        curiousTilt = approach(curiousTilt, curious ? -0.14 * (dx > 0 ? 1 : -1) : 0, rate: 6, dt: dtf)
        pose.tilt = tilt * pose.facing + curiousTilt
        if settleTime >= 0 && settleTime < 0.42 && state != .dragging
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CGFloat(pow(1 - settleTime / 0.42, 2))
            pose.tilt += 0.075 * fade * sin(CGFloat(settleTime) * 31)
        }

        // shadow, water, sleep bubbles, particles
        var shadowTarget: CGFloat = 0
        if onFloor {
            if state == .landing { shadowTarget = CGFloat(min(1, stateTime / landDuration)) }
            else if state != .dragging { shadowTarget = 1 }
        }
        pose.shadow = approach(pose.shadow, shadowTarget, rate: 6, dt: dtf)
        pose.submerged = 0
        pose.walk = (state == .strolling && cruiseSpeed > 0.5) ? cruiseDir
            : (followingCursor && state != .poked && followSpeed > 25 ? followWalkDirection : 0)
        pose.waterline = currentScreen.visibleFrame.minY - origin.y
        pose.ceiling = currentScreen.visibleFrame.maxY - origin.y
        pose.zzz = approach(pose.zzz, (napping && !yawning) ? 1 : 0, rate: 2.5, dt: dtf)
        pose.particles = pose.particles.compactMap { particle in
            var q = particle
            q.life -= dtf
            guard q.life > 0 else { return nil }
            if q.glyph == "•" { q.velocity.dy -= 90 * dtf }
            q.position.x += q.velocity.dx * dtf
            q.position.y += q.velocity.dy * dtf
            q.velocity.dx *= 0.98
            return q
        }
        pose.time = t
    }

    // MARK: - Behaviours

    private func enterIdle() {
        state = .idle
        stateTime = 0
        nextDecisionIn = Double.random(in: 4...10)
    }

    private func decideNext() {
        let sinceNap = time - lastNapEnded
        let userAway = mouseStillFor > 150
        let userBusy = mouseStillFor < 6
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let r = Double.random(in: 0..<1)
        _ = sinceNap; _ = userAway            // random naps are off; "Nap now" still works
        if !userBusy && !reduceMotion {
            if (edge == .bottom || edge == .top || edge == .free) && r < idleDiveChance { startStroll(.idle); return }
            if hugEdges && edge != .free && r < idleDiveChance + 0.3 { startWander(); return }
        }
        if Bool.random() { pulse(amount: 0.08, duration: 0.35) } else { finFlickUntil = time + 0.35 }
        nextDecisionIn = Double.random(in: userBusy ? 8...18 : 5...12)
    }

    private func startWander() {
        let f = currentScreen.visibleFrame
        let g = PetGeometry.self
        let o = origin
        let horizontal = (edge == .bottom || edge == .top)
        let lo: CGFloat, hi: CGFloat, cur: CGFloat
        if horizontal {
            lo = f.minX - g.bodyCenter.x + g.bodyHalfWidth + 4
            hi = f.maxX - g.bodyCenter.x - g.bodyHalfWidth - 4
            cur = o.x
        } else {
            lo = f.minY - g.bodyBottom + 10
            hi = f.maxY - g.earTop - 10
            cur = o.y
        }
        guard hi > lo + 60 else { enterIdle(); return }
        var delta = CGFloat.random(in: 110...300) * (Bool.random() ? 1 : -1)
        var target = min(max(cur + delta, lo), hi)
        if abs(target - cur) < 50 { delta = -delta; target = min(max(cur + delta, lo), hi) }
        wanderTarget = target
        wanderDeadline = time + 14
        if horizontal {
            let newFacing: CGFloat = target < cur ? -1 : 1
            if newFacing != pose.facing { pose.facing = newFacing; turnT = 0 }
        }
        state = .wandering
        stateTime = 0
    }

    private func updateWander(dt: TimeInterval) {
        let horizontal = (edge == .bottom || edge == .top)
        let speed: CGFloat = edge == .bottom ? 46 : 32
        var o = origin
        let cur = horizontal ? o.x : o.y
        let d = wanderTarget - cur
        let step = min(abs(d), speed * CGFloat(dt)) * (d < 0 ? -1 : 1)
        if horizontal { o.x += step } else { o.y += step }
        setOrigin(o)
        if abs(d) < 1.5 || time > wanderDeadline || typing {
            enterIdle()
            savePosition()
        }
    }

    private func startNap() {
        napDuration = Double.random(in: 25...60)
        state = .napping
        stateTime = 0
        tailTwitchIn = Double.random(in: 4...7)
        curiousT = -1
        if launchPanel.isShown { launchPanel.hide() }
    }

    private func wake() {
        afkNap = false
        lastNapEnded = time
        enterIdle()
        pulse(amount: 0.14, duration: 0.4)
        spawnDroplets(3)
    }

    private func pulse(amount: CGFloat, duration: TimeInterval) {
        pulseAmount = amount
        pulseDuration = duration
        pulseT = 0
    }

    private func poke() {
        if time - lastPoke < 1.6 { pokeCount += 1 } else { pokeCount = 1 }
        lastPoke = time
        if state == .napping { lastNapEnded = time }
        state = .poked
        stateTime = 0
        curiousT = -1
        if pokeCount >= 2 && pokeCount < 4 { spawnParticles("♥", count: pokeCount - 1) }
        if pokeCount == 1 && Bool.random() { think(["!", "hi", "♥", "?"].randomElement() ?? "!", for: 1.4) }
        if pokeCount >= 4 { spinT = 0; think("@_@", for: 2) }
    }

    private func release() {
        let f = currentScreen.visibleFrame
        releasedAt = time
        pose.held = false
        view.pose = pose
        mini = 0
        // stay wherever it was dropped unless it's close to an edge; then tuck into that edge
        let c = bodyCenterOnScreen
        let edgeDistance = min(c.y - f.minY, f.maxY - c.y, c.x - f.minX, f.maxX - c.x)
        edge = (hugEdges && edgeDistance < 150) ? nearestEdge(in: f) : .free
        var from = origin
        if edge == .bottom || edge == .top || edge == .free {
            let toss = max(-250, min(250, dragVelocity * 0.25))
            from.x += toss
            if abs(toss) > 40 { pose.facing = toss > 0 ? 1 : -1 }
        }
        landTo = edgeTarget(for: edge, in: f, from: from)
        landFrom = origin
        if edge == .left { pose.facing = 1 } else if edge == .right { pose.facing = -1 }
        peek = 1; peekTarget = 1; peekChangeIn = Double.random(in: 25...70); peekUntil = time + 3
        let dist = hypot(landTo.x - landFrom.x, landTo.y - landFrom.y)
        if dist < 1 {
            enterIdle()
            pulse(amount: -0.12, duration: 0.25)
            savePosition()
            return
        }
        landDuration = min(max(Double(dist) / 1500, 0.22), 0.65)
        state = .landing
        stateTime = 0
    }

    private func enterBed() {
        launchPanel.hide()
        pose.held = false
        bedPanel.dropHighlighted = false
        bedPanel.place(in: currentScreen.visibleFrame)
        bedPanel.occupied = true
        bedPanel.orderFrontRegardless()
        sleepingInBed = true
        state = .napping
        stateTime = 0
        afkNap = false
        mini = 0
        if !selfTesting { UserDefaults.standard.set(true, forKey: Keys.sleepingInBed) }
        if !selfTesting { savePosition() }
        window.orderOut(nil)
    }

    private func wakeFromBed() {
        guard sleepingInBed else { return }
        sleepingInBed = false
        bedPanel.occupied = false
        if !selfTesting { UserDefaults.standard.set(false, forKey: Keys.sleepingInBed) }
        let f = currentScreen.visibleFrame
        edge = hugEdges ? .bottom : .free
        peek = 1; peekTarget = 1; mini = 0
        pose.napping = false; pose.flop = 0; pose.eyeOpen = 1; pose.eyeStyle = .open
        pose.held = false
        view.pose = pose
        let besideBed = CGPoint(x: bedPanel.frame.minX - 64 - PetGeometry.bodyCenter.x,
                                y: f.minY - PetGeometry.bodyBottom + 6)
        setOrigin(edgeTarget(for: edge, in: f, from: besideBed))
        enterIdle()
        panelCooldownUntil = time + 0.7
        window.orderFrontRegardless()
        if !selfTesting { savePosition() }
    }

    private func spawnParticles(_ glyph: String, count: Int) {
        let c = PetGeometry.bodyCenter
        for _ in 0..<count {
            let life = CGFloat.random(in: 0.9...1.3)
            pose.particles.append(Particle(
                position: CGPoint(x: c.x + CGFloat.random(in: -20...20), y: pose.bodyTopNow + CGFloat.random(in: 0...10)),
                velocity: CGVector(dx: CGFloat.random(in: -18...18), dy: CGFloat.random(in: 28...48)),
                life: life, maxLife: life, glyph: glyph))
        }
    }

    private func spawnBubbles(_ count: Int) {}   // no water effects for the dog

    private func spawnDroplets(_ count: Int) {}   // no water effects for the dog

    private func launch(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.think("?", for: 2)
                self.turnT = 0
                if !FileManager.default.fileExists(atPath: url.path) {
                    self.store.remove(url)
                    self.launchPanel.reload()
                }
                self.think("can't open it", for: 2.5)
            }
        }
        launchPanel.hide()
        panelCooldownUntil = time + 0.8
        state = .poked
        stateTime = 0
        pokeCount = 0
        spawnBubbles(3)
    }

    // MARK: - Drops and Stash

    func dragHover(_ inside: Bool) {
        dropHovering = inside
        if inside {
            if state == .napping { wake() }
            if isMini { grow(fast: true, openPanel: false) }
            think("give?", for: 3)
        } else {
            thoughtUntil = 0
        }
    }

    func acceptDrop(_ pb: NSPasteboard) -> Bool {
        let store = StashStore.shared
        if store.hasFiles(pb) {
            // big files are copied off the main thread so the shark never freezes
            let urls = store.fileURLs(pb)
            think("…", for: 30)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = store.saveFiles(urls)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let what = result { self.gulp(what) } else { self.think("?", for: 1.5) }
                }
            }
            return true
        }
        guard let what = store.save(from: pb) else { think("?", for: 1.5); return false }
        gulp(what)
        return true
    }

    private func gulp(_ what: String) {
        gulpT = 0
        think("kept \(what) ✓", for: 2.5)
        spawnBubbles(3)
        if stashPanel.isShown { stashPanel.reload() }
    }

    // MARK: - Mouse (from PetView)

    func petMouseDown(at p: CGPoint) {
        pressed = true
        pressStart = p
        pressOrigin = origin
        lastDragX = origin.x
        dragVelocity = 0
        if state == .strolling { grow(fast: true, openPanel: false) }
    }

    func petMouseDragged(to p: CGPoint) {
        guard pressed else { return }
        if state != .dragging {
            if hypot(p.x - pressStart.x, p.y - pressStart.y) < 4 { return }
            if followingCursor { setFollowingCursor(false, saveOnStop: false) }
            if state == .napping { lastNapEnded = time }
            mini = 0
            state = .dragging
            stateTime = 0
            curiousT = -1
            curiousTilt = 0
            if launchPanel.isShown { launchPanel.hide() }
            panelCooldownUntil = time + 0.6
        }
        setOrigin(CGPoint(x: pressOrigin.x + (p.x - pressStart.x), y: pressOrigin.y + (p.y - pressStart.y)))
        bedPanel.place(in: currentScreen.visibleFrame)
        bedPanel.dropHighlighted = bedPanel.acceptsDrop(at: p, dogRect: hitRectOnScreen)
    }

    func petMouseUp(at p: CGPoint) {
        guard pressed else { return }
        pressed = false
        if state == .dragging {
            if bedPanel.acceptsDrop(at: p, dogRect: hitRectOnScreen) { enterBed() }
            else { bedPanel.dropHighlighted = false; release() }
        }
        else if state == .growing || state == .shrinking { return }
        else {
            let isDouble = time - lastClickAt < 0.35
            lastClickAt = time
            if isDouble {
                if followingCursor { setFollowingCursor(false) }
                else { switchToPreviousApp() }
            } else { poke() }
        }
    }

    /// Double-click: bring back the app you were using before the current one.
    private func switchToPreviousApp() {
        guard let url = switchBackApps.first else { think("no other app yet", for: 1.6); return }
        let name = url.deletingPathExtension().lastPathComponent
        think("→ \(name)", for: 1.4)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        state = .poked; stateTime = 0
        pokeCount = 0
    }

    // MARK: - Menu

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        populate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.addItem(withTitle: "Open Pet home…", action: #selector(openHome), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Open Stash", action: #selector(openStash), keyEquivalent: "").target = self
        let follow = menu.addItem(withTitle: followingCursor ? "Stop following" : "Follow cursor",
                                  action: #selector(toggleFollowingCursor), keyEquivalent: "")
        follow.target = self
        follow.state = followingCursor ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pet", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func setFollowingCursor(_ enabled: Bool, saveOnStop: Bool = true) {
        guard enabled != followingCursor else { return }
        followingCursor = enabled
        if !selfTesting { UserDefaults.standard.set(enabled, forKey: Keys.followCursor) }
        followSpeed = 0
        followWalkDirection = 1
        followSideX = -1; followSideY = -1
        mini = 0
        edge = .free
        peek = 1; peekTarget = 1
        hoverDwell = 0
        panelCooldownUntil = time + 0.1
        lastClickAt = -10
        if launchPanel.isShown { launchPanel.hide() }
        if state == .napping { lastNapEnded = time }
        enterIdle()
        if !enabled && saveOnStop && !selfTesting { savePosition() }
    }

    @objc private func toggleFollowingCursor() { setFollowingCursor(!followingCursor) }

    @objc private func openHome() { showHome() }
    @objc private func openStash() {
        if launchPanel.isShown { launchPanel.hide() }
        stashPanel.show(near: hitRectOnScreen, screen: currentScreen.visibleFrame)
        panelCooldownUntil = time + 0.8
    }

    func addShortcut() {
        launchPanel.hide()
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Pick apps for Pet's ring"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] response in
            if let previous, previous.bundleIdentifier != Bundle.main.bundleIdentifier {
                if #available(macOS 14.0, *) { NSApp.yieldActivation(to: previous) }
                previous.activate(options: [])
            }
            guard let self, response == .OK else { return }
            for url in panel.urls { self.store.add(url) }
            self.launchPanel.reload()
            self.spawnParticles("♥", count: 2)
        }
    }

    private func shhHour() {
        if time < shhUntil {
            shhUntil = 0
            if isMini { grow(fast: false, openPanel: false) }
            return
        }
        shhUntil = time + 3600
        if launchPanel.isShown { launchPanel.hide() }
        if edge == .bottom && hugEdges { startStroll(.shh) } else if state == .idle { startNap() }
    }

    private func comeHere() {
        let mouse = NSEvent.mouseLocation
        if isMini {
            pendingComeHere = mouse
            grow(fast: true, openPanel: false)
            return
        }
        glide(to: mouse)
    }

    private func glide(to mouse: CGPoint) {
        let f = screen(containing: mouse).visibleFrame
        landFrom = origin
        mini = 0
        edge = hugEdges ? nearestEdge(in: f, at: mouse) : .free
        if edge == .left { pose.facing = 1 } else if edge == .right { pose.facing = -1 }
        peek = 1
        let want = CGPoint(x: mouse.x - PetGeometry.bodyCenter.x, y: mouse.y - PetGeometry.bodyCenter.y)
        landTo = edgeTarget(for: edge, in: f, from: want)
        let dist = hypot(landTo.x - landFrom.x, landTo.y - landFrom.y)
        landDuration = min(max(Double(dist) / 1800, 0.3), 0.8)
        if launchPanel.isShown { launchPanel.hide() }
        state = .landing
        stateTime = 0
    }

    @objc private func quit() {
        savePosition()
        NSApp.terminate(nil)
    }

    // MARK: - Pet home

    func showHome() {
        if homeWindow == nil { homeWindow = PetHomeWindowController(controller: self) }
        homeWindow?.show()
    }

    func showManageApps(onChange: (() -> Void)? = nil) {
        launchPanel.hide()
        let manager = ManageAppsWindowController.shared
        manager.onChange = { [weak self] in
            self?.launchPanel.reload()
            onChange?()
        }
        manager.show()
    }

    func showStash() { openStash() }

    func setAppRingMode(_ mode: AppRingMode) {
        guard mode != appRingMode else { return }
        appRingMode = mode
        if !selfTesting { UserDefaults.standard.set(mode.rawValue, forKey: Keys.appRingMode) }
        launchPanel.hide()
        launchPanel.appMode = mode
        launchPanel.recents = switchBackApps
        launchPanel.reload()
        homeWindow?.refreshApps()
    }

    func setCoat(_ coat: Coat) {
        guard coat != pose.coat else { return }
        pose.coat = coat
        bedPanel.coat = coat
        UserDefaults.standard.set(coat.rawValue, forKey: Keys.coat)
        pulse(amount: 0.12, duration: 0.35)
        spawnBubbles(2)
    }

    func setPetScale(_ value: CGFloat) {
        let clamped = min(1.15, max(0.85, value))
        guard abs(clamped - petScale) > 0.0001 else { return }
        petScale = clamped
        pose.displayScale = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Keys.size)
        let target = edgeTarget(for: edge, in: currentScreen.visibleFrame, from: origin)
        setOrigin(target)
        applyScreenClip()
        view.pose = pose
    }

    func setMood(_ value: Mood) {
        guard value != mood else { return }
        mood = value
        UserDefaults.standard.set(value.rawValue, forKey: Keys.mood)
        think(value == .chatty ? "yay" : (value == .shy ? "…" : "ok"), for: 1.5)
    }

    func setQuietHours(_ enabled: Bool) {
        quietHours = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.quiet)
    }

    var compactAppIdentifiers: [String] { diveApps.sorted() }

    func setCompactForApp(_ id: String, enabled: Bool) {
        if enabled { diveApps.insert(id) } else { diveApps.remove(id) }
        UserDefaults.standard.set(Array(diveApps), forKey: Keys.diveApps)
    }

    func setHugEdges(_ enabled: Bool) {
        guard enabled != hugEdges else { return }
        hugEdges = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.hugEdges)
        if enabled {
            release()
        } else {
            if isMini { grow(fast: true, openPanel: false) }
            edge = .free
            savePosition()
        }
    }

    func setHideFromSharing(_ enabled: Bool) {
        hideFromSharing = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.sharing)
        applySharing()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .notRegistered { try service.register() }
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            think("hm? couldn't", for: 2.5)
        }
    }

    // MARK: - Debug snapshot

    @objc private func debugSnapshot() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pet-debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        lines.append("state=\(state) edge=\(edge) mini=\(mini) peek=\(peek) followingCursor=\(followingCursor) followSpeed=\(followSpeed) origin=\(origin) screenVisible=\(currentScreen.visibleFrame)")
        lines.append("windowVisible=\(window.isVisible) alpha=\(window.alphaValue) onActiveSpace=\(window.isOnActiveSpace) ringVisible=\(launchPanel.isShown) ringOnActiveSpace=\(launchPanel.isOnActiveSpace) stashVisible=\(stashPanel.isShown) bedSleeping=\(sleepingInBed) bedVisible=\(bedPanel.isVisible)")
        lines.append("atlas=\(SpriteAtlas.image != nil) coat=\(pose.coat) walk=\(pose.walk) squash=\(pose.squashX),\(pose.squashY) flop=\(pose.flop)")
        if let mask = window.contentView?.layer?.mask as? CAShapeLayer { lines.append("mask=\(mask.path?.boundingBox ?? .zero)") } else { lines.append("mask=none") }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
        guard let view = window.contentView, let layer = view.layer else { return }
        let b = view.bounds
        guard let ctx = CGContext(data: nil, width: Int(b.width * 2), height: Int(b.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor); ctx.fill(b)
        view.displayIfNeeded()
        layer.render(in: ctx)
        if let img = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("view.png"))
        }
    }

    // MARK: - Headless self-test (run with `Pet --selftest`)

    func selfTest() -> Bool {
        var failures: [String] = []
        func step(_ seconds: Double) {
            for _ in 0..<Int(seconds * 60) {
                lastTick = CACurrentMediaTime() - 1.0 / 60
                tick()
            }
        }
        func expect(_ cond: @autoclosure () -> Bool, _ msg: String) {
            if !cond() { failures.append("\(msg) (state=\(state), mini=\(mini), origin=\(origin))") }
        }
        let f = currentScreen.visibleFrame
        selfTesting = true
        if sleepingInBed {
            sleepingInBed = false
            bedPanel.occupied = false
            window.orderFrontRegardless()
        }
        followingCursor = false; followSpeed = 0; followSideX = -1; followSideY = -1; testMouse = nil
        hugEdges = true; edge = .bottom; mini = 0
        pendingThoughts.removeAll()
        setOrigin(edgeTarget(for: .bottom, in: f, from: CGPoint(x: f.midX, y: 0)))
        enterIdle()
        print("selftest: screen", f)
        expect(launchPanel.collectionBehavior.contains(.canJoinAllApplications),
               "app ring joins other apps' full-screen Spaces")
        let menuTitles = makeMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
        expect(menuTitles == ["Open Pet home…", "Open Stash", "Follow cursor", "Quit Pet"], "essential menu and follow control")
        let savedRingMode = appRingMode
        let savedRecentApps = recentApps
        recentApps.removeAll()
        setAppRingMode(.recent)
        for index in 0..<8 { recordRecentApp(URL(fileURLWithPath: "/Applications/PetRecentTest\(index).app")) }
        expect(recentApps.count == 7 && recentApps.first?.lastPathComponent == "PetRecentTest7.app",
               "recent history keeps the latest seven so six previous apps are available")
        recordRecentApp(URL(fileURLWithPath: "/Applications/PetRecentTest4.app"))
        expect(recentApps.count == 7 && recentApps.first?.lastPathComponent == "PetRecentTest4.app",
               "revisiting an app moves it to the front without duplicating it")
        launchPanel.recents = Array(recentApps.dropFirst()) // pretend the newest app is foreground
        launchPanel.reload()
        expect(ringAppURLs == Array(recentApps.dropFirst()) && ringAppURLs.count == 6,
               "recent ring shows exactly six previous apps, without pinned extras")
        setAppRingMode(.pinned)
        expect(ringAppURLs == store.apps, "pinned mode restores the chosen app list")
        recentApps = savedRecentApps
        setAppRingMode(savedRingMode)
        launchPanel.recents = switchBackApps
        launchPanel.reload()
        expect(SpriteAtlas.lookView(dx: 0, dyUp: 1).frame == SpriteFrame(row: 6, col: 2), "cursor above shows raised face")
        expect(SpriteAtlas.lookView(dx: 1, dyUp: 0) == SpriteLook(frame: SpriteFrame(row: 9, col: 2), mirrored: true), "cursor right turns face right")
        expect(SpriteAtlas.lookView(dx: 0, dyUp: -1).frame == SpriteFrame(row: 9, col: 0), "cursor below shows front face")
        expect(SpriteAtlas.lookView(dx: -1, dyUp: 0) == SpriteLook(frame: SpriteFrame(row: 9, col: 2)), "cursor left turns face left")
        for i in 0..<16 {
            let a = CGFloat(i) * .pi / 8
            let look = SpriteAtlas.lookView(dx: sin(a), dyUp: cos(a))
            expect((look.frame.row == 6 && (2...3).contains(look.frame.col))
                || (look.frame.row == 9 && (0...2).contains(look.frame.col)),
                "all pointer directions keep the face visible")
        }

        testMouse = CGPoint(x: -10_000, y: -10_000)
        lastMouse = testMouse!
        mouseStillFor = 70
        pose.look = CGPoint(x: 0.7, y: 0.5)
        trackingPointer = false
        step(0.3)
        expect(hypot(pose.look.x, pose.look.y) < 0.05, "distant still pointer returns to neutral gaze")
        let nearby = bodyCenterOnScreen
        testMouse = CGPoint(x: nearby.x + 120, y: nearby.y + 140)
        step(0.3)
        expect(trackingPointer && pose.look.x > 0.4 && pose.look.y > 0.4, "nearby pointer gets directional gaze")
        testMouse = nil
        trackingPointer = false
        mouseStillFor = 0

        startStroll(.menu); step(3)
        expect(state == .strolling, "stroll should end small and walking")
        expect(abs(mini - 1) < 0.05, "small while strolling")
        step(6)
        expect(state == .strolling || state == .growing || state == .idle, "strolling keeps a sane state")
        grow(fast: true, openPanel: false); step(2)
        expect(state == .idle && mini == 0, "grow ends idle at full size")

        startNap(); step(0.1)
        expect(state == .napping && pose.napping, "nap pose starts immediately")
        step(1.9); expect(state == .napping, "napping")
        expect(pose.flop > 0.5, "flopped while napping")
        wake(); step(1); expect(state == .idle && !pose.napping && pose.flop < 0.2, "wake returns idle and un-flops")

        poke(); step(1); expect(state == .idle, "poke ends idle")
        for _ in 0..<4 { poke() }; step(1); expect(state == .idle, "dizzy pokes end idle")

        let c = bodyCenterOnScreen
        petMouseDown(at: c); petMouseDragged(to: CGPoint(x: c.x + 60, y: c.y + 30)); step(0.2)
        expect(state == .dragging && pose.held, "dragging uses the held-dog pose")
        petMouseUp(at: CGPoint(x: c.x + 60, y: c.y + 30)); step(0.05)
        expect(!pose.held && state != .dragging, "dropping releases the collar pose")
        step(2)
        expect(state == .idle && edge == .bottom, "drop near the bottom stays on the bottom edge")

        startStroll(.menu); step(2)
        comeHere(); step(4)
        expect(state == .idle && mini == 0, "come here while small ends idle at full size")

        // drag to the left edge and back to the bottom
        petMouseDown(at: bodyCenterOnScreen)
        petMouseDragged(to: CGPoint(x: f.minX + 40, y: f.midY)); step(0.2)
        petMouseUp(at: CGPoint(x: f.minX + 40, y: f.midY)); step(2)
        expect(state == .idle && edge == .left, "released near the left edge → left edge")
        step(20)
        expect(origin.x < f.minX - 20, "tucked behind the left edge")
        petMouseDown(at: bodyCenterOnScreen)
        let dropY = f.minY + (PetGeometry.bodyCenter.y - PetGeometry.bodyBottom) + 24
        petMouseDragged(to: CGPoint(x: f.midX, y: dropY)); step(0.2)
        petMouseUp(at: CGPoint(x: f.midX, y: dropY)); step(2)
        expect(state == .idle && edge == .bottom, "released near the bottom → bottom edge")

        startWander(); step(0.5); expect(state == .wandering, "wander starts")
        step(15); expect(state != .wandering || stateTime < 14, "a wander never outlives its deadline")

        // a long unattended stretch: random decisions, no crash, ends in a sane state
        var seen: Set<String> = []
        for _ in 0..<60 { step(10); seen.insert("\(state)") }
        expect([State.idle, .napping, .strolling, .wandering, .shrinking, .growing].contains(state), "sane state after 10 min")
        print("selftest: states seen in 10 min:", seen.sorted())
        setHugEdges(false); step(2); setHugEdges(true); step(3)
        expect(state != .dragging, "hug toggle round trip")
        if isMini { grow(fast: true, openPanel: false); step(1) }
        edge = .bottom; mini = 0
        setOrigin(edgeTarget(for: .bottom, in: f, from: CGPoint(x: f.midX, y: 0))); enterIdle(); step(0.5)
        shhHour(); step(4); expect(isMini, "shh strolls small"); shhHour(); step(3); expect(!isMini, "shh off grows back")

        // Isolate the hover assertion from random state left by the long run
        // and from the owner's actual mouse buttons while the self-test runs.
        launchPanel.hide()
        pressed = false
        dropHovering = false
        startStroll(.menu); step(0.3)
        panelCooldownUntil = 0
        testMouse = bodyCenterOnScreen
        step(1.0 / 60.0)
        expect(launchPanel.readyForSelection && state == .growing, "compact Pet opens a clickable ring before growing finishes")

        setFollowingCursor(true)
        testMouse = CGPoint(x: f.midX, y: f.midY)
        step(2)
        let firstFollowPosition = bodyCenterOnScreen
        expect(followingCursor && edge == .free && mini == 0, "follow mode stays full-size and free")
        expect(hypot(firstFollowPosition.x - (f.midX - 125 * petScale),
                     firstFollowPosition.y - (f.midY - 90 * petScale)) < 30, "Pet trails the cursor")
        testMouse = CGPoint(x: f.midX + 240, y: f.midY + 80)
        step(1)
        expect(bodyCenterOnScreen.x > firstFollowPosition.x + 100, "Pet follows a moved cursor")
        testMouse = CGPoint(x: f.minX + 12, y: f.minY + 12)
        step(2)
        expect(f.insetBy(dx: -2, dy: -2).contains(bodyCenterOnScreen), "following stays on screen near edges")
        expect(!petContains(testMouse!), "following keeps the pointer clear near edges")
        testMouse = CGPoint(x: f.minX + 200 * petScale, y: f.midY)
        step(2)
        expect(followSideX == 1, "follow keeps its side inside the edge band")
        let stableFollowOrigin = origin
        step(3)
        expect(followSideX == 1 && hypot(origin.x - stableFollowOrigin.x, origin.y - stableFollowOrigin.y) < 2,
               "stationary pointer does not repeat side switches")
        testMouse = CGPoint(x: f.minX + 290 * petScale, y: f.midY + 250)
        step(1)
        expect(followSideX == -1, "follow leaves the edge band once")
        testMouse = CGPoint(x: f.minX + 245 * petScale, y: f.midY + 250)
        step(1)
        expect(followSideX == -1, "follow does not immediately switch back")
        testMouse = bodyCenterOnScreen
        let pausedOrigin = origin
        step(0.3)
        expect(hypot(origin.x - pausedOrigin.x, origin.y - pausedOrigin.y) < 1, "hovering pauses follow for clicks")
        expect(launchPanel.readyForSelection, "follow mode opens a clickable app ring when hovered")
        let followMenuTitles = makeMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
        expect(followMenuTitles.contains("Stop following"), "follow menu shows stop action")
        petMouseDown(at: bodyCenterOnScreen); petMouseUp(at: bodyCenterOnScreen)
        step(0.08)
        petMouseDown(at: bodyCenterOnScreen); petMouseUp(at: bodyCenterOnScreen)
        expect(!followingCursor && edge == .free, "double-click stops following in place")
        setFollowingCursor(true)
        petMouseDown(at: bodyCenterOnScreen)
        petMouseDragged(to: CGPoint(x: bodyCenterOnScreen.x + 50, y: bodyCenterOnScreen.y + 20))
        expect(!followingCursor && state == .dragging, "dragging stops following")
        petMouseUp(at: bodyCenterOnScreen)
        testMouse = CGPoint(x: -10_000, y: -10_000)
        step(1)
        panelCooldownUntil = 0
        testMouse = bodyCenterOnScreen
        step(1.0 / 60.0)
        expect(launchPanel.readyForSelection, "touching Pet opens a clickable ring on the next tick")
        launchPanel.hide()
        hoverDwell = 0
        let r = hitRectOnScreen
        testMouse = CGPoint(x: r.maxX + 10 * petScale, y: r.midY)
        step(0.12)
        expect(launchPanel.isShown, "passive hover halo opens the ring")
        expect(window.ignoresMouseEvents, "hover halo leaves the underlying app clickable")
        testMouse = nil

        let bedPoint = CGPoint(x: bedPanel.frame.midX, y: bedPanel.frame.midY)
        expect(bedPanel.frame.size == DogBedPanel.emptySize
               && bedPanel.frame.maxX >= f.maxX - 2
               && bedPanel.frame.minY <= f.minY,
               "empty bed is tiny and hugs the lower-right edge")
        expect(!bedPanel.acceptsDrop(at: CGPoint(x: f.midX, y: f.midY), dogRect: .zero),
               "bed does not capture ordinary drops")
        petMouseDown(at: bodyCenterOnScreen)
        petMouseDragged(to: bedPoint)
        expect(bedPanel.dropHighlighted, "bed lights up while Pet is dragged over it")
        petMouseUp(at: bedPoint)
        expect(sleepingInBed && bedPanel.occupied && !window.isVisible,
               "dropping Pet on the bed puts him to sleep and hides the standing dog")
        expect(bedPanel.frame.size == DogBedPanel.occupiedSize,
               "occupied bed grows to the half-size sleeping dog")
        step(120)
        expect(sleepingInBed, "bed sleep lasts until clicked")
        wakeFromBed()
        expect(!sleepingInBed && !bedPanel.occupied && window.isVisible && state == .idle,
               "clicking the bed brings Pet back awake")
        expect(bedPanel.frame.size == DogBedPanel.emptySize,
               "bed shrinks again when Pet wakes")

        if failures.isEmpty { print("selftest: OK") } else { print("selftest: FAILED\n - " + failures.joined(separator: "\n - ")) }
        return failures.isEmpty
    }
}
