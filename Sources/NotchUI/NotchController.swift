import AppKit
import Carbon.HIToolbox
import NotchCore
import Observation
import QuartzCore
import SwiftUI
import os

/// Settings owned by NotchUI.
public enum NotchSettings {
    /// Hovering the notch opens the panel (otherwise hover only swells it and a click opens).
    public static let openOnHover = SettingsKey("notch.openOnHover", default: false)
    /// ⌃⌥N toggles the panel.
    public static let hotkeyEnabled = SettingsKey("notch.hotkeyEnabled", default: true)
}

/// Owns the notch window: placement, click-through, hover/drag/drop detection, the hotkey and the expanded panel.
@MainActor
public final class NotchController: NotchControlling {
    private let allModules: [any NotchModule]
    private let services: AppServices
    private let settings: SettingsStore
    private let directories: AppDirectories
    private let debug: DebugOptions
    private let log = Log.logger("notch")

    let model: NotchViewModel
    private var machine = NotchStateMachine()
    private var metrics: ScreenMetrics = NotchController.placeholderMetrics
    private var running = false
    /// `--force-state` / `--demo`: user input does not change the state.
    private let pinned: Bool

    private var panel: NotchPanel?
    private var container: NotchContainerView?
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timerTasks: [NotchTimer: Task<Void, Never>] = [:]
    /// Bumped whenever a timer is (re)scheduled or cancelled; a firing task whose token is stale does nothing.
    private var timerGenerations: [NotchTimer: Int] = [:]
    private let clock = ContinuousClock()
    private var expiryTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var toggleKey: HotKey?
    private var frameMonitor: FrameRateMonitor?
    private var fullscreen = false
    /// What the current activity's text asks of the wings (`WingText.request(for:)`), before clamping.
    private var wingRequest = WingRequest.none
    /// Room before the nearest menu-bar status item right of the notch, re-measured on activity, app, Space and
    /// screen changes and every few seconds (status items come and go).
    private var statusRoom: CGFloat?
    private var statusTask: Task<Void, Never>?
    private var moduleSignature: [ModuleSignature] = []
    private var drag = DragTracking()

    private struct ModuleSignature: Equatable { var id: ModuleID; var placement: PanelPlacement }

    private struct DragTracking {
        /// Drag pasteboard change count while the mouse was last up.
        var baseline = 0
        var baselineTakenAt = ContinuousClock.now
        /// The mouse went down in our own panel (e.g. dragging a shelf item out): not a drop candidate.
        var internalSource = false
        var active = false
        var preview: [DropItem]?
        var previewChangeCount = -1
        var optionKey = false
        var accepted = false
        var poll: Task<Void, Never>?
    }

    public init(
        modules: [any NotchModule], services: AppServices, settings: SettingsStore, directories: AppDirectories,
        debug: DebugOptions = DebugOptions()
    ) {
        self.allModules = modules
        self.services = services
        self.settings = settings
        self.directories = directories
        self.debug = debug
        self.pinned = debug.demo || debug.forceState.flatMap(NotchState.init(rawValue:)) != nil
        self.model = NotchViewModel(layout: NotchGeometry.layout(metrics: Self.placeholderMetrics, state: .closed))
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        if services.notch == nil { services.notch = self }
        machine.openOnHover = settings.get(NotchSettings.openOnHover)
        model.onSelectPage = { [weak self] page in self?.send(.selectPage(page)) }
        model.onOpenSettings = { [weak self] in
            guard let self else { return }
            self.services.openSettings?(nil)
            self.send(.collapse)
        }

        let panel = NotchPanel()
        let container = NotchContainerView(frame: .zero)
        container.dropHandler = self
        let hosting = NotchHostingView(rootView: NotchRootView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        self.panel = panel
        self.container = container

        rebuildScreen()
        refreshModules()
        observeSettings()
        installMonitors()
        installObservers()
        refreshDragBaseline()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.running else { return }
                self.measureStatusItems()
            }
        }

        panel.orderFrontRegardless()
        applyDebugOptions()
        prewarm()
        log.notice("started; notch \(self.model.layout.notchRect.debugDescription, privacy: .public)")
    }

    public func stop() {
        guard running else { return }
        running = false
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        for task in timerTasks.values { task.cancel() }
        timerTasks.removeAll()
        expiryTask?.cancel()
        demoTask?.cancel()
        statusTask?.cancel()
        drag.poll?.cancel()
        drag = DragTracking()
        toggleKey?.unregister(); toggleKey = nil
        frameMonitor?.stop(); frameMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        container = nil
        if services.notch === self { services.notch = nil }
        machine = NotchStateMachine(openOnHover: machine.openOnHover)
    }

    private func prewarm() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.running else { return }
            self.model.warming = true
            try? await Task.sleep(for: .milliseconds(250))
            self.model.warming = false
        }
    }

    // MARK: - NotchControlling

    public func expand(page: ModuleID?) { send(.expand(page: page)) }
    public func collapse() { send(.collapse) }
    public func toggle() { send(.toggle) }

    // MARK: - State

    private func send(_ event: NotchEvent) {
        let before = machine
        let effects = machine.send(event, now: clock.now)
        perform(effects)
        if before.visual != machine.visual { render(from: before) }
    }

    private func perform(_ effects: [NotchEffect]) {
        for effect in effects {
            switch effect {
            case .schedule(let timer, let instant):
                timerTasks[timer]?.cancel()
                let generation = timerGenerations[timer, default: 0] &+ 1
                timerGenerations[timer] = generation
                timerTasks[timer] = Task { [weak self] in
                    try? await Task.sleep(until: instant, clock: .continuous)
                    guard !Task.isCancelled, let self, self.timerGenerations[timer] == generation else { return }
                    self.timerTasks[timer] = nil
                    self.send(.timer(timer))
                }
            case .cancel(let timer):
                timerGenerations[timer, default: 0] &+= 1
                timerTasks.removeValue(forKey: timer)?.cancel()
            case .hapticTick:
                Haptics.tick()
            }
        }
    }

    private func render(from before: NotchStateMachine) {
        let layout = currentLayout()
        let animation = Self.animation(from: before.state, to: machine.state)
        let machine = machine
        Motion.animate(animation) {
            model.state = machine.state
            model.page = machine.page
            model.dropTargeted = machine.dropTargeted
            model.hintVisible = HoverHint.isVisible(state: machine.state, openOnHover: machine.openOnHover)
            model.layout = layout
        }
        if before.state == .expanded, machine.state != .expanded { relinquishKeyFocus() }
        updatePointer(NSEvent.mouseLocation)
    }

    private func currentLayout() -> NotchLayout {
        NotchGeometry.layout(
            metrics: metrics, state: machine.state, hasActivity: machine.hasActivity, wings: wingRequest,
            statusRoom: statusRoom, hoverHint: !machine.openOnHover, simulatedNotch: debug.simulateNotch
        )
    }

    static func animation(from: NotchState, to: NotchState) -> Animation {
        switch to {
        case .expanded, .drop: from.isOpen ? Motion.morph : Motion.open
        case .hover: Motion.open
        case .activity: from == .closed ? Motion.open : Motion.close
        case .closed: Motion.close
        }
    }

    // MARK: - Pointer, clicks, keys

    private func installMonitors() {
        let global: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: global, handler: { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handleGlobal(type, at: location) }
        }) { monitors.append(m) }

        let local: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .keyDown]
        if let m = NSEvent.addLocalMonitorForEvents(matching: local, handler: { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            let inPanel = event.window != nil && event.window === self?.panel
            let keyCode = type == .keyDown ? Int(event.keyCode) : nil
            let consume = MainActor.assumeIsolated {
                self?.handleLocal(type, at: location, inPanel: inPanel, keyCode: keyCode) ?? false
            }
            return consume ? nil : event
        }) { monitors.append(m) }
    }

    private func handleGlobal(_ type: NSEvent.EventType, at location: CGPoint) {
        switch type {
        case .mouseMoved:
            refreshDragBaselineIfIdle()
            updatePointer(location)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if type == .leftMouseDown { beginMouseDown(fromPanel: false) }
            if !pinned, machine.state == .expanded, !model.layout.hits(location) { send(.clickOutside) }
        case .leftMouseDragged:
            updatePointer(location)
            checkForDrag(at: location)
        default: break
        }
    }

    private func handleLocal(_ type: NSEvent.EventType, at location: CGPoint, inPanel: Bool, keyCode: Int?) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged:
            if type == .mouseMoved { refreshDragBaselineIfIdle() }
            updatePointer(location)
        case .leftMouseDown, .rightMouseDown:
            if type == .leftMouseDown { beginMouseDown(fromPanel: inPanel) }
            guard !pinned else { break }
            if inPanel, model.layout.hits(location) {
                if type == .leftMouseDown { send(.click) }
            } else if machine.state == .expanded {
                // A click in another window of this app (e.g. Settings).
                send(.clickOutside)
            }
        case .keyDown:
            // Only when the panel itself is key (a module text field took focus): Esc is never taken from other apps.
            if keyCode == kVK_Escape, inPanel, machine.state == .expanded, !pinned {
                send(.escape)
                return true
            }
        default: break
        }
        return false
    }

    /// Makes the panel take mouse events exactly while the pointer is inside the interactive rect, and reports
    /// enter/exit to the state machine.
    private func updatePointer(_ location: CGPoint) {
        guard let panel else { return }
        let inside = model.layout.hits(location)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if !pinned, inside != machine.pointerInside { send(inside ? .pointerEntered : .pointerExited) }
    }

    /// A module text field may have made the panel key. Hand key focus back to the frontmost app's window
    /// (we never activated the app, so ordering the panel out and in again is enough).
    private func relinquishKeyFocus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    // MARK: - Drag tracking

    /// A drag is in flight when the drag pasteboard changed since the mouse was last up. The baseline is taken at
    /// start, after each drag, and whenever the pointer moves with no button down (throttled), never from a
    /// mouse-down that might be handled after the drag already began.
    private func refreshDragBaseline() {
        drag.baseline = NSPasteboard(name: .drag).changeCount
        drag.baselineTakenAt = clock.now
    }

    private func refreshDragBaselineIfIdle() {
        guard !drag.active, clock.now - drag.baselineTakenAt > .milliseconds(250), NSEvent.pressedMouseButtons == 0 else { return }
        refreshDragBaseline()
    }

    private func beginMouseDown(fromPanel: Bool) {
        drag.internalSource = fromPanel
        guard fromPanel else { return }
        // A drag out of our own panel (a shelf item) rewrites the drag pasteboard; rebase once the button is up again.
        Task { [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.refreshDragBaseline()
        }
    }

    private func checkForDrag(at location: CGPoint) {
        guard !pinned, !drag.internalSource else { return }
        if !drag.active {
            guard NSPasteboard(name: .drag).changeCount != drag.baseline else { return }
            drag.active = true
            drag.preview = nil
            startDragPolling()
        }
        evaluateDrag(at: location)
    }

    /// Once a drag is known, poll the pointer and button: global drag events are not guaranteed for the whole session.
    private func startDragPolling() {
        drag.poll?.cancel()
        drag.poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.finishDrag()
                    return
                }
                self.evaluateDrag(at: NSEvent.mouseLocation)
            }
        }
    }

    private func evaluateDrag(at location: CGPoint) {
        guard drag.active else { return }
        updatePointer(location)
        let near = NotchGeometry.isNearForDrop(location, layout: model.layout)
        guard near else {
            if machine.state == .drop { send(.dragFar) }
            return
        }
        let accepted = dragAcceptance(NSPasteboard(name: .drag), option: NSEvent.modifierFlags.contains(.option))
        if accepted, machine.state != .drop {
            send(.dragNear)
        } else if !accepted, machine.state == .drop {
            send(.dragFar)
        }
    }

    /// Whether any enabled module would take the dragged content (cached per pasteboard generation and ⌥ state),
    /// updating the hint as a side effect.
    private func dragAcceptance(_ pasteboard: NSPasteboard, option: Bool) -> Bool {
        let count = pasteboard.changeCount
        if drag.preview != nil, drag.previewChangeCount == count, drag.optionKey == option { return drag.accepted }
        let preview = drag.previewChangeCount == count ? (drag.preview ?? DragPasteboard.preview(pasteboard)) : DragPasteboard.preview(pasteboard)
        let modules = enabledModules
        drag.preview = preview
        drag.previewChangeCount = count
        drag.optionKey = option
        drag.accepted = DropDecision.accepts(preview, optionKey: option, among: modules)
        if drag.accepted {
            let hint = DropRouter.hint(for: DropPayload(items: preview, optionKey: option), among: modules) ?? .fallback
            if hint != model.hint { Motion.animate(Motion.quick) { model.hint = hint } }
        }
        return drag.accepted
    }

    private func finishDrag() {
        drag.active = false
        drag.poll = nil
        drag.preview = nil
        refreshDragBaseline()
        send(.dragEnded)
    }

    /// Recomputed on every use: modules can be enabled or disabled at any time.
    private var enabledModules: [any NotchModule] {
        PanelContent.enabled(allModules, disabled: settings.get(CoreSettings.disabledModules))
    }

    // MARK: - Modules and activities

    private func refreshModules() {
        let modules = enabledModules
        let signature = modules.map { ModuleSignature(id: $0.id, placement: $0.placement) }
        if signature != moduleSignature {
            moduleSignature = signature
            model.modules = modules
            // The open page's module was disabled or stopped being a page: fall back to Home.
            if machine.page != nil, PanelContent.pageModule(machine.page, in: modules) == nil { send(.selectPage(nil)) }
        }
        refreshActivity()
        withObservationTracking {
            for module in allModules {
                _ = module.liveActivity
                _ = module.placement
            }
            _ = settings.get(CoreSettings.disabledModules)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.refreshModules()
            }
        }
    }

    private func refreshActivity() {
        let now = Date()
        let candidates = enabledModules.compactMap(\.liveActivity)
        let chosen = ActivityArbiter.select(candidates, now: now, fullscreen: fullscreen)
        let request = chosen.map(WingText.request(for:)) ?? .none
        if chosen != model.activity || request != wingRequest {
            let textChanged = request != wingRequest
            wingRequest = request
            if textChanged { measureStatusItems(animate: false) }
            let layout = currentLayout()
            // Next track: each wing resizes on its own and the text cross-fades in one morph; glyphs ride the edges.
            Motion.animate(Motion.morph) {
                model.activity = chosen
                model.layout = layout
            }
        }
        if !pinned { send(.activityChanged(chosen != nil)) }

        expiryTask?.cancel()
        if let next = candidates.compactMap(\.expiresAt).filter({ $0 > now }).min() {
            expiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.01))
                guard !Task.isCancelled else { return }
                self?.refreshActivity()
            }
        }
    }

    /// Re-reads the status items right of the notch. Only matters while some wing text is asking for room.
    private func measureStatusItems(animate: Bool = true) {
        guard wingRequest.trailingTextWidth > 0 else { return }
        let room = StatusItems.trailingRoom(screen: metrics, notch: model.layout.notchRect)
        guard room != statusRoom else { return }
        statusRoom = room
        guard animate else { return }
        let layout = currentLayout()
        Motion.animate(Motion.morph) { model.layout = layout }
    }

    private func refreshFullscreen() {
        let value = FullscreenDetector.current(screen: metrics)
        guard value != fullscreen else { return }
        fullscreen = value
        refreshActivity()
    }

    // MARK: - Settings

    private func observeSettings() {
        let openOnHover = settings.get(NotchSettings.openOnHover)
        let hotkeyEnabled = settings.get(NotchSettings.hotkeyEnabled)
        if openOnHover != machine.openOnHover { send(.setOpenOnHover(openOnHover)) }
        if hotkeyEnabled, toggleKey == nil {
            toggleKey = HotKey(keyCode: kVK_ANSI_N, modifiers: HotKey.controlOption) { [weak self] in self?.send(.hotkey) }
            if toggleKey == nil { log.error("could not register ⌃⌥N") }
        } else if !hotkeyEnabled, let key = toggleKey {
            key.unregister()
            toggleKey = nil
        }
        withObservationTracking {
            _ = settings.get(NotchSettings.openOnHover)
            _ = settings.get(NotchSettings.hotkeyEnabled)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.observeSettings()
            }
        }
    }

    // MARK: - Screens

    private func installObservers() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ c: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (NotchController) -> Void) {
            let token = c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
            observers.append((c, token))
        }
        observe(center, NSApplication.didChangeScreenParametersNotification) { $0.rebuildScreen() }
        observe(workspace, NSWorkspace.didWakeNotification) { controller in
            Task { @MainActor [weak controller] in
                try? await Task.sleep(for: .milliseconds(600))
                controller?.rebuildScreen()
            }
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { controller in
            controller.refreshFullscreen()
            controller.measureStatusItems()
            // The menu bar settles after the space animation; look again once it has.
            Task { @MainActor [weak controller] in
                try? await Task.sleep(for: .milliseconds(800))
                controller?.refreshFullscreen()
                controller?.measureStatusItems()
            }
        }
        // "Hide Others" can hide an accessory app; the notch must never disappear with it.
        observe(center, NSApplication.didHideNotification) { _ in NSApp.unhideWithoutActivation() }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { controller in
            controller.refreshFullscreen()
            controller.measureStatusItems()
        }
    }

    /// The built-in notched display, else the primary display (with a virtual notch).
    private static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { ScreenMetrics(screen: $0).hasNotch } ?? NSScreen.screens.first
    }

    private func rebuildScreen() {
        guard running, let screen = Self.notchScreen() else { return }
        metrics = ScreenMetrics(screen: screen)
        let layout = currentLayout()
        panel?.setFrame(layout.windowFrame, display: true)
        container?.frame = CGRect(origin: .zero, size: layout.windowFrame.size)
        model.layout = layout
        refreshFullscreen()
        measureStatusItems()
        updatePointer(NSEvent.mouseLocation)
    }

    private static let placeholderMetrics = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
        safeTop: 0, auxLeft: nil, auxRight: nil
    )

    // MARK: - Debug options

    private func applyDebugOptions() {
        if debug.dumpMetrics { dumpMetrics() }
        if debug.fps, let container {
            let monitor = FrameRateMonitor(
                context: { [weak self] in self.map { "\($0.model.state.rawValue)\($0.model.page.map { " " + $0.rawValue } ?? "")" } ?? "" },
                report: { [weak self] text in self?.model.fpsText = text }
            )
            monitor.start(on: container)
            frameMonitor = monitor
        }
        if debug.demo {
            startDemo()
        } else if let forced = debug.forceState.flatMap(NotchState.init(rawValue:)) {
            force(forced, page: debug.page, targeted: false)
        } else if let name = debug.forceState {
            log.error("unknown --force-state \(name, privacy: .public)")
        }
    }

    private func force(_ state: NotchState, page: ModuleID?, targeted: Bool) {
        let before = machine
        if state == .drop {
            let sample = DropPayload(items: [.file(URL(fileURLWithPath: "/tmp/Sample.png"))])
            model.hint = DropRouter.hint(for: sample, among: enabledModules) ?? .fallback
        }
        machine = NotchStateMachine(
            state: state, page: page, hasActivity: model.activity != nil, openOnHover: machine.openOnHover, dropTargeted: targeted
        )
        render(from: before)
    }

    private func startDemo() {
        let firstPage = PanelContent.pages(enabledModules).first?.id
        let steps: [(NotchState, ModuleID?, Bool)] = [
            (.closed, nil, false), (.activity, nil, false), (.hover, nil, false), (.drop, nil, false), (.drop, nil, true),
            (.activity, nil, false), (.expanded, nil, false), (.expanded, firstPage, false), (.expanded, nil, false),
            (.activity, nil, false),
        ]
        demoTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                guard let self else { return }
                let (state, page, targeted) = steps[index % steps.count]
                self.force(state, page: page, targeted: targeted)
                index += 1
                try? await Task.sleep(for: .seconds(1.6))
            }
        }
    }

    private func dumpMetrics() {
        func r(_ rect: CGRect) -> String {
            "(\(rect.minX), \(rect.minY), \(rect.width)×\(rect.height))"
        }
        var lines = ["metrics frame=\(r(metrics.frame)) visible=\(r(metrics.visibleFrame)) safeTop=\(metrics.safeTop) "
            + "hasNotch=\(metrics.hasNotch) menuBar=\(metrics.menuBarHeight) scale=\(metrics.scale) fps=\(metrics.maximumFramesPerSecond)"]
        let notch = metrics.effectiveNotchRect(simulated: debug.simulateNotch)
        lines.append("notch \(r(notch))\(debug.simulateNotch != nil || !metrics.hasNotch ? " (virtual)" : "")")
        for state in NotchState.allCases {
            let l = NotchGeometry.layout(metrics: metrics, state: state, hasActivity: true, simulatedNotch: debug.simulateNotch)
            lines.append("\(state.rawValue): window=\(r(l.windowFrame)) shape=\(r(l.shapeRect)) visible=\(r(l.visibleRect)) hit=\(l.hitRect.isNull ? "none" : r(l.hitRect)) radii=\(l.topRadius)/\(l.bottomRadius)")
        }
        print(lines.joined(separator: "\n"))
    }
}

// MARK: - Drops

extension NotchController: NotchDropHandling {
    func dragUpdated(at screenPoint: CGPoint, pasteboard: NSPasteboard) -> NSDragOperation {
        guard machine.state == .drop else { return [] }
        let accepted = dragAcceptance(pasteboard, option: NSEvent.modifierFlags.contains(.option))
        let inside = accepted && model.layout.hits(screenPoint)
        send(inside ? .dropTargetEntered : .dropTargetExited)
        return inside ? .copy : []
    }

    func dragExited() { send(.dropTargetExited) }

    /// Also true just after a highlighted target gave up waiting, so a late drop still lands.
    func canAcceptDrop() -> Bool { machine.acceptsDrop(now: clock.now) }

    /// Returns false (so the source keeps its content) unless some module actually takes something.
    func performDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard machine.acceptsDrop(now: clock.now) else { return false }
        let option = NSEvent.modifierFlags.contains(.option)
        let contents = DragPasteboard.read(pasteboard)
        let modules = enabledModules
        if contents.promises.isEmpty {
            let items = DropItems.resolve(fileURLs: contents.fileURLs, imageData: contents.imageData, text: contents.text)
            guard DropDecision.accepts(items, optionKey: option, among: modules) else { return false }
            deliver(items, option: option, to: modules)
        } else {
            // Receive only promises whose types some module accepts, so nothing unwanted is written to Downloads.
            let wanted = DropDecision.acceptedPromises(contents.promises.map(\.fileTypes), optionKey: option, among: modules)
            guard !wanted.isEmpty else { return false }
            let receivers = wanted.map { contents.promises[$0] }
            let downloads = directories.downloads
            Task { [weak self] in
                let urls = await FilePromises.receive(receivers, into: downloads)
                self?.deliver(DropItems.resolve(fileURLs: urls, imageData: nil, text: nil), option: option, to: modules)
            }
        }
        drag.active = false
        drag.poll?.cancel()
        drag.poll = nil
        drag.preview = nil
        refreshDragBaseline()
        send(.dropped)
        return true
    }

    private func deliver(_ items: [DropItem], option: Bool, to modules: [any NotchModule]) {
        guard !items.isEmpty else { log.notice("drop had no readable items"); return }
        let routes = DropRouter.route(DropPayload(items: items, optionKey: option), among: modules)
        if routes.isEmpty { log.notice("no module accepted \(items.count) dropped item(s)") }
        for route in routes {
            guard let module = modules.first(where: { $0.id == route.module }) else { continue }
            Task { await module.handleDrop(route.payload) }
        }
    }
}

// MARK: - Frame-time overlay

/// Display-link driven frame pacing monitor for `--fps`. Shows the last half second on screen and prints every
/// half second that dropped frames (plus a heartbeat every 2 s) with the state that was showing.
@MainActor
final class FrameRateMonitor: NSObject {
    private var link: CADisplayLink?
    private var stats = FrameStats()
    private var windowStart: Double?
    private var windowFrames = 0
    private var droppedAtWindowStart = 0
    private var lastPrint: Double = 0
    private let context: () -> String
    private let report: (String) -> Void

    init(context: @escaping () -> String, report: @escaping (String) -> Void) {
        self.context = context
        self.report = report
    }

    func start(on view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        stats.record(timestamp: link.timestamp, frameInterval: link.targetTimestamp - link.timestamp)
        windowFrames += 1
        guard let start = windowStart else { windowStart = link.timestamp; return }
        let elapsed = link.timestamp - start
        guard elapsed >= 0.5 else { return }
        let fps = Double(windowFrames - 1) / elapsed
        let dropped = stats.dropped - droppedAtWindowStart
        let text = String(format: "%.0f fps · worst %.1f ms · dropped %d (total %d)", fps, stats.worst * 1000, dropped, stats.dropped)
        report(text)
        if dropped > 0 || link.timestamp - lastPrint >= 2 {
            print("fps [\(context())] \(text)")
            lastPrint = link.timestamp
        }
        stats.resetWorst()
        droppedAtWindowStart = stats.dropped
        windowStart = link.timestamp
        windowFrames = 1
    }
}
