import AppKit
import Combine

/// Owns the floating window and the buddy's behavior. Each tick it picks a target pose for the
/// current behavior, springs the displayed pose toward it, and updates particle effects.
@MainActor
final class BuddyController: NSObject {
    private enum Mode {
        case idle(until: Date)
        case walking(to: CGFloat)
        case reminding(UUID)
        case celebrating(started: Date)
        case dragging
        case falling
    }

    var openSettings: (() -> Void)?
    private(set) var isVisible = true

    private let state = AppState.shared
    private let brain = BuddyBrain.shared
    private let panel: NSPanel
    private let view = BuddyView()
    private let chatBox = ChatBox()
    private var puppet: Puppet
    private var animator = PoseAnimator()
    private var particles: [Particle] = []
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    private var mode: Mode = .idle(until: Date().addingTimeInterval(3))
    private var x: CGFloat = 0           // center of the character, screen coords
    private var y: CGFloat = 0           // feet, screen coords
    private var vy: CGFloat = 0
    private var dragOffset = CGPoint.zero
    private var dragSwing: CGFloat = 0
    private var lastDragX: CGFloat = 0
    private var time: Double = 0
    private var walkPhase: Double = 0
    private var lastTick = CACurrentMediaTime()
    private var lastReminderCheck: Double = 0
    private var nextEffect: Double = 0
    private var alerted = Set<UUID>()
    private var transient: (bubble: Bubble, until: Double)?
    private var nag: (id: UUID, line: String, since: Date)?
    private var nextChatter = Date().addingTimeInterval(.random(in: 240...480))
    private var isThinking = false
    private var celebrateStage = 0
    private var frameCount = 0

    override init() {
        puppet = CharacterLibrary.puppet(AppState.shared.selectedCharacter)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.contentView = view
        view.puppet = puppet

        view.onClick = { [weak self] in self?.handleClick() }
        view.onDoubleClick = { [weak self] in self?.openChat() }
        view.onDragStart = { [weak self] in self?.beginDrag() }
        view.onDrag = { [weak self] p in self?.drag(to: p) }
        view.onDragEnd = { [weak self] in self?.mode = .falling }
        view.onContextMenu = { [weak self] e in self?.showContextMenu(e) }
        chatBox.onSubmit = { [weak self] text in self?.send(text) }

        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        x = screen.midX
        y = screen.minY
        layout()
        panel.orderFrontRegardless()

        if state.isFirstLaunch {
            say("Hi! I'm \(brain.buddyName) 👋", "double-click to chat · right-click for more", seconds: 8)
        }

        state.$selectedCharacter.dropFirst().sink { [weak self] name in
            guard let self else { return }
            puppet = CharacterLibrary.puppet(name)
            view.puppet = puppet
            DispatchQueue.main.async {
                self.layout()
                self.celebrate()
                self.say("Hi, I'm \(self.brain.buddyName)! ✨", seconds: 3)
                self.brain.refreshIfNeeded()
            }
        }.store(in: &cancellables)
        state.$buddyHeight.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }.store(in: &cancellables)
        // New reminders / personality → fresh lines (debounced so typing doesn't spam the API).
        state.$reminders.map { _ in () }.merge(with: state.$personality.map { _ in () })
            .debounce(for: .seconds(4), scheduler: RunLoop.main)
            .sink { [weak self] in self?.brain.refreshIfNeeded() }
            .store(in: &cancellables)
        brain.refreshIfNeeded()

        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Public

    func toggleVisible() {
        isVisible.toggle()
        if isVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil); chatBox.orderOut(nil) }
    }

    /// "Done" from the menu bar: completes the active reminder, or the first one.
    func completeNow() {
        if case .reminding(let id) = mode { complete(id); return }
        if let r = state.reminders.first(where: { $0.enabled }) { complete(r.id) }
    }

    func openChat() {
        guard isVisible else { return }
        let anchor = panel.convertToScreen(view.spriteRect)
        chatBox.show(above: anchor, placeholder: "Talk to \(brain.buddyName)…  (esc to close)")
    }

    // MARK: - Layout

    private var screen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: x, y: y + 1)) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var windowWidth: CGFloat { max(340, view.spriteSize.height * 1.7) }

    private func layout() {
        let h = CGFloat(state.buddyHeight)
        view.spriteSize = CGSize(width: (h * puppet.aspect).rounded(), height: h)
        panel.setContentSize(NSSize(width: windowWidth, height: h * 1.12 + 170))
        view.frame = panel.contentView?.bounds ?? .zero
        position()
    }

    private func position() {
        panel.setFrameOrigin(NSPoint(x: (x - windowWidth / 2).rounded(), y: (y - 6).rounded()))
    }

    // MARK: - Tick

    private func step(toward target: CGFloat, speed: CGFloat, dt: CGFloat) -> Bool {
        let dir: CGFloat = target >= x ? 1 : -1
        view.facingRight = dir > 0
        let delta = dir * speed * dt
        x += delta
        walkPhase += Double(abs(delta)) / Double(max(40, view.spriteSize.height)) * 7.5
        if (dir > 0 && x >= target) || (dir < 0 && x <= target) { x = target; return true }
        return false
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 0.1))
        lastTick = now
        time += Double(dt)

        if now - lastReminderCheck > 2 {
            lastReminderCheck = now
            checkReminders()
        }

        let vis = screen.visibleFrame
        let half = view.spriteSize.width / 2
        let speed = CGFloat(state.walkSpeed) * max(1, CGFloat(state.buddyHeight) / 120)
        var target = PoseLibrary.idle(time)
        var anim = Anim.idle
        var animTime = time
        var bubble: Bubble?

        switch mode {
        case .idle(let until):
            if state.isSuppressed {
                target = PoseLibrary.sleep(time)
                anim = .sleep
                emit(every: 1.6) { self.spawn("💤", at: CGPoint(x: 40, y: 230), vy: 30, vx: 12, life: 2.4, size: 26) }
            } else {
                if Date() >= nextChatter {
                    nextChatter = Date().addingTimeInterval(.random(in: 420...900))
                    if transient == nil, let line = brain.idleLine() { say(line, seconds: 5) }
                }
                if Date() >= until {
                    mode = .walking(to: .random(in: (vis.minX + half + 20)...(vis.maxX - half - 20)))
                }
            }

        case .walking(let goal):
            target = PoseLibrary.walk(phase: walkPhase, time)
            anim = .walk
            animTime = walkPhase / 7.5
            if step(toward: goal, speed: speed, dt: dt) {
                mode = .idle(until: Date().addingTimeInterval(.random(in: 5...14)))
            }

        case .reminding(let id):
            guard let r = state.reminder(id) else { mode = .idle(until: Date()); break }
            // Pick a fresh line now and then so a long-ignored reminder doesn't repeat itself.
            if nag?.id != id || Date().timeIntervalSince(nag!.since) > 75 {
                nag = (id, brain.nagLine(r), Date())
            }
            bubble = Bubble(title: nag!.line, subtitle: "click me when done")
            // Follow the cursor along the dock until noticed, then hop and wave.
            let mouseX = min(max(NSEvent.mouseLocation.x, vis.minX + half), vis.maxX - half)
            if abs(mouseX - x) > 160 {
                target = PoseLibrary.walk(phase: walkPhase, time)
                anim = .walk
                animTime = walkPhase / 7.5
                _ = step(toward: mouseX, speed: speed * 1.8, dt: dt)
            } else {
                target = PoseLibrary.remind(time)
                emit(every: 1.2) { self.spawn("💧", at: CGPoint(x: 70, y: 200), vy: 60, vx: 30, life: 1.2, size: 22, gravity: -160) }
            }

        case .celebrating(let started):
            let t = Date().timeIntervalSince(started)
            if t < PoseLibrary.drinkDuration {
                target = PoseLibrary.drink(t, time)
                anim = .drink
                animTime = t
                if celebrateStage == 0 && t > 0.6 { celebrateStage = 1 }
            } else if t < PoseLibrary.drinkDuration + PoseLibrary.cheerDuration {
                let c = t - PoseLibrary.drinkDuration
                target = PoseLibrary.cheer(c, time)
                anim = .cheer
                animTime = c
                if celebrateStage == 1 && c > 0.25 {
                    celebrateStage = 2
                    for i in 0..<9 {
                        let a = Double(i) / 9 * .pi + 0.2
                        spawn(["✨", "⭐️", "💖", "💧"][i % 4], at: CGPoint(x: 0, y: 160),
                              vy: CGFloat(sin(a)) * 260, vx: CGFloat(cos(a)) * 220, life: 1.3, size: 24, gravity: -380)
                    }
                }
            } else {
                mode = .idle(until: Date().addingTimeInterval(5))
            }

        case .dragging:
            let vx = (x - lastDragX) / max(dt, 0.001)
            lastDragX = x
            dragSwing += (max(-0.7, min(0.7, -vx / 900)) - dragSwing) * min(1, dt * 8)
            target = PoseLibrary.dangle(time, swing: dragSwing)

        case .falling:
            vy -= 2400 * dt
            y += vy * dt
            target = PoseLibrary.falling(time)
            if y <= vis.minY {
                y = vis.minY
                vy = 0
                animator.kick(\.squash, -5.5)   // squishy landing
                mode = .idle(until: Date().addingTimeInterval(2))
            }
        }

        // Eyes follow the cursor.
        let mouse = NSEvent.mouseLocation
        let headY = y + view.spriteSize.height * 0.78
        let facing: CGFloat = view.facingRight ? 1 : -1
        if target.eyesOpen > 0.5 {
            target.lookX = max(-1, min(1, (mouse.x - x) / 350)) * facing
            target.lookY = max(-1, min(1, (mouse.y - headY) / 350))
        }

        if isThinking && bubble == nil {
            bubble = Bubble(title: String(repeating: "•", count: 1 + Int(time * 3) % 3), subtitle: nil)
        } else if bubble == nil, let t = transient {
            if now < t.until { bubble = t.bubble } else { transient = nil }
        }

        x = min(max(x, vis.minX + half), vis.maxX - half)
        switch mode {
        case .dragging, .falling: break
        default: y = vis.minY
        }

        animator.update(toward: target, dt: dt)
        updateParticles(dt)

        position()
        updateMousePassthrough()

        // Full 60 fps only while moving; calm states redraw less often to save battery.
        frameCount += 1
        let divisor: Int
        switch mode {
        case .idle: divisor = state.isSuppressed ? 6 : 3
        case .reminding: divisor = 2
        default: divisor = 1
        }
        guard frameCount % divisor == 0 || bubble != view.bubble else { return }
        view.pose = animator.pose
        if case .frames(let set) = puppet { view.image = set.frame(anim, at: animTime) }
        view.particles = particles
        view.bubble = bubble
        view.needsDisplay = true
    }

    private func updateMousePassthrough() {
        if case .dragging = mode { panel.ignoresMouseEvents = false; return }
        let hit = panel.convertToScreen(view.hitRect.insetBy(dx: -4, dy: -4))
        let inside = hit.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    // MARK: - Effects

    private func emit(every interval: Double, _ make: () -> Void) {
        if time >= nextEffect {
            nextEffect = time + interval
            make()
        }
    }

    private func spawn(_ text: String, at p: CGPoint, vy: CGFloat, vx: CGFloat = 0, life: CGFloat, size: CGFloat, gravity: CGFloat = 0) {
        particles.append(Particle(text: text, x: p.x, y: p.y, vx: vx, vy: vy, life: life, maxLife: life, size: size, gravity: gravity))
    }

    private func updateParticles(_ dt: CGFloat) {
        for i in particles.indices {
            particles[i].vy += particles[i].gravity * dt
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt
            particles[i].life -= dt
        }
        particles.removeAll { $0.life <= 0 }
    }

    // MARK: - Reminders

    private func checkReminders() {
        if case .reminding = mode {
            if state.isSuppressed { mode = .idle(until: Date().addingTimeInterval(3)) }
            return
        }
        switch mode {
        case .dragging, .falling, .celebrating: return
        default: break
        }
        if state.isSuppressed, case .idle = mode, transient == nil, Int.random(in: 0..<300) == 0 {
            say(brain.sleepyLine(), seconds: 4)
        }
        guard isVisible, let due = state.dueReminder() else { return }
        mode = .reminding(due.id)
        animator.kick(\.squash, 3)
        if !alerted.contains(due.id) {
            alerted.insert(due.id)
            if state.soundEnabled { NSSound(named: "Glass")?.play() }
        }
    }

    private func celebrate() {
        celebrateStage = 0
        mode = .celebrating(started: Date())
    }

    private func complete(_ id: UUID) {
        guard let r = state.reminder(id) else { return }
        state.markDone(id)
        alerted.remove(id)
        nag = nil
        celebrate()
        say(brain.praiseLine(r), "\(r.emoji) \(state.count(for: id)) today", seconds: 4)
    }

    private func say(_ title: String, _ subtitle: String? = nil, seconds: Double) {
        transient = (Bubble(title: title, subtitle: subtitle), CACurrentMediaTime() + seconds)
    }

    // MARK: - Chat

    private func send(_ text: String) {
        isThinking = true
        Task {
            let reply = await brain.chat(text)
            isThinking = false
            animator.kick(\.squash, 2.5)
            say(reply, seconds: min(12, 3 + Double(reply.count) / 14))
        }
    }

    // MARK: - Interaction

    private func handleClick() {
        if case .reminding(let id) = mode { complete(id); return }
        if case .falling = mode { return }
        // Little hop, and say when the next reminder is.
        mode = .falling
        vy = 560
        animator.kick(\.squash, 4)
        spawn("💖", at: CGPoint(x: 30, y: 250), vy: 70, vx: 20, life: 1.1, size: 22)
        if let next = state.nextUpcoming() {
            let mins = max(0, Int(ceil(next.nextDue.timeIntervalSinceNow / 60)))
            say("\(next.emoji) \(next.title) in \(mins) min", "\(state.count(for: next.id)) today · double-click to chat", seconds: 2.5)
        } else {
            say("Hi there! 👋", seconds: 2)
        }
    }

    private func beginDrag() {
        let p = NSEvent.mouseLocation
        dragOffset = CGPoint(x: p.x - x, y: p.y - y)
        lastDragX = x
        dragSwing = 0
        mode = .dragging
        say("Wheee!", seconds: 1.2)
    }

    private func drag(to p: NSPoint) {
        x = p.x - dragOffset.x
        y = p.y - dragOffset.y
    }

    private func showContextMenu(_ event: NSEvent) {
        let menu = NSMenu()
        if case .reminding(let id) = mode, let r = state.reminder(id) {
            menu.addItem(item("Done ✓  \(r.emoji) \(r.title)", #selector(menuDone)))
            menu.addItem(item("Snooze 10 min", #selector(menuSnooze)))
            menu.addItem(item("Skip this one", #selector(menuSkip)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Talk to \(brain.buddyName)…", #selector(menuChat)))
        menu.addItem(item("Hide buddy", #selector(menuHide)))
        menu.addItem(item("Settings…", #selector(menuSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit SipBuddy", #selector(menuQuit)))
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func menuDone() { if case .reminding(let id) = mode { complete(id) } }

    @objc private func menuSnooze() {
        guard case .reminding(let id) = mode else { return }
        state.snooze(id, minutes: 10)
        alerted.remove(id)
        nag = nil
        mode = .idle(until: Date().addingTimeInterval(3))
        say("Okay, 10 more minutes 😴", seconds: 2)
    }

    @objc private func menuSkip() {
        guard case .reminding(let id) = mode else { return }
        state.skip(id)
        alerted.remove(id)
        nag = nil
        mode = .idle(until: Date().addingTimeInterval(3))
        say("Fine… 😒", seconds: 2)
    }

    @objc private func menuChat() { openChat() }
    @objc private func menuHide() { toggleVisible() }
    @objc private func menuSettings() { openSettings?() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}
