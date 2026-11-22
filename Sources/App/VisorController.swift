import AppKit
import Combine
import SwiftUI

private final class VisorPanel: NSPanel {
    var allowsKeyboard = false
    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class VisorController {
    private struct ControlPanel {
        let control: VisorControl
        let button: RokuButton
        let panel: VisorPanel
    }

    private let model: RokuModel
    private let presentation = VisorPresentation()
    private let surface = VisorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: true)
    private let shortcuts = VisorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: true)
    private var controls: [ControlPanel] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var modelObservation: AnyCancellable?
    private var transition: Task<Void, Never>?
    private var shortcutMotion = false
    private var geometry: VisorGeometry?
    private var activationDown: NotchClick?
    #if EXPERIMENTAL_LISTENING
    private let clickLogging = CommandLine.arguments.contains("--notch-click-log")
    #endif
    private var visibility: VisorVisibility = .collapsed

    var open: Bool { visibility.isOpen }

    init(model: RokuModel, openSettings: @escaping () -> Void, editShortcuts: @escaping (String?) -> Void) {
        self.model = model
        Self.configure(surface, acceptsMouse: false)
        surface.contentView = NSHostingView(rootView: VisorSurface(presentation: presentation))

        Self.configure(shortcuts, acceptsMouse: false)
        let shortcutView = NSHostingView(rootView: QuickLaunchView(model: model, presentation: presentation,
                                                                   edit: editShortcuts,
                                                                   toggle: { [weak self] in self?.toggleShortcuts() }))
        shortcutView.sizingOptions = []
        shortcuts.contentView = shortcutView
        shortcuts.acceptsMouseMovedEvents = true

        // The artwork never receives input. Each input panel is confined to the button it draws.
        controls = (VisorControl.all + [.settings]).map { control in
            let panel = VisorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
            Self.configure(panel, acceptsMouse: true)
            let button = RokuButton(key: control.key, symbol: control.symbol, label: control.label)
            button.send = { [weak model] key, isRepeat in model?.send(key, isRepeat: isRepeat) }
            if control.key == nil { button.performLocalAction = openSettings }
            panel.contentView = button
            panel.setAccessibilityLabel(control.label)
            return ControlPanel(control: control, button: button, panel: panel)
        }
        modelObservation = model.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                self?.syncControls()
            }
        }
        layout()
        startMonitoring()
    }

    private static func configure(_ panel: VisorPanel, acceptsMouse: Bool) {
        panel.level = NotchDisplay.overlayLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.allowsKeyboard = acceptsMouse
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    }

    func layout() {
        if visibility.showsSurface { dismiss(immediate: true) }
        activationDown = nil
        let displays = NSScreen.screens.map(NotchDisplay.init(screen:))
        let display = NotchDisplay.preferred(from: displays, mouse: NSEvent.mouseLocation)
        geometry = display?.geometry
    #if EXPERIMENTAL_LISTENING
        if clickLogging, let display {
            display.diagnosticLines().forEach(logClick)
        }
    #endif
    }

    func toggle() {
        if open { dismiss() } else { show() }
    }

    func dismiss(immediate: Bool = false) {
        guard visibility.showsSurface else { return }
        if visibility == .closing, !immediate { return }
        visibility = .closing
        shortcuts.ignoresMouseEvents = true
        model.discardQueuedKeyboardInput()
        transition?.cancel()
        syncControls()
        let duration = immediate ? 0 : motion
        guard duration > 0 else { hide(); return }

        fadeButtons(to: 0, duration: 0.08)
        transition = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(55)) } catch { return }
            guard let self else { return }
            withAnimation(.spring(duration: duration - 0.055, bounce: 0)) {
                self.presentation.wings = 0
            }
            do { try await Task.sleep(for: .milliseconds(36)) } catch { return }
            withAnimation(.spring(duration: duration - 0.091, bounce: 0)) {
                self.presentation.drop = 0
            }
            do { try await Task.sleep(for: .seconds(duration - 0.091)) } catch { return }
            self.hide()
        }
    }

    private var motion: TimeInterval {
        MotionPreference(animationsEnabled: model.animations,
                         reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion).duration
    }

    private func show() {
        guard !NSApp.currentSystemPresentationOptions.contains(.fullScreen) else { return }
        if visibility == .closing || geometry?.hasNotch != true { layout() }
        guard let geometry, geometry.scale > 0 else { return }
        transition?.cancel()
        visibility = .opening
        presentation.topExtension = geometry.topExtension / geometry.scale
        let level = geometry.hasNotch ? NotchDisplay.notchOverlayLevel : NotchDisplay.overlayLevel
        surface.level = level
        surface.setFrame(geometry.surfaceFrame, display: false)
        surface.orderFrontRegardless()
        shortcuts.level = level
        shortcuts.alphaValue = 0
        presentation.shortcutsExpanded = false
        presentation.shortcutScale = geometry.scale
        let layout = QuickLaunchLayout(rise: presentation.topExtension)
        shortcuts.setFrame(layout.screenFrame(in: geometry), display: false)
        shortcuts.order(.below, relativeTo: surface.windowNumber)
        for item in controls {
            item.panel.level = level
            let rise = item.control.isDirectionPad ? 0 : presentation.topExtension
            let artworkFrame = item.control.frame.offsetBy(dx: 0, dy: -rise)
            item.panel.setFrame(geometry.screenFrame(for: artworkFrame), display: false)
            item.panel.alphaValue = 0
            item.panel.orderFrontRegardless()
        }
        syncControls()

        guard motion > 0 else {
            presentation.settle(at: 1)
            fadeButtons(to: 1, duration: 0)
            finishOpening()
            return
        }

        transition = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(15)) } catch { return }
            guard let self else { return }
            withAnimation(.spring(duration: 0.26, bounce: 0.10)) {
                self.presentation.wings = 1
            }
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            withAnimation(.spring(duration: 0.26, bounce: 0.08)) { self.presentation.drop = 1 }
            do { try await Task.sleep(for: .milliseconds(92)) } catch { return }
            self.fadeButtons(to: 1, duration: 0.16)
            do { try await Task.sleep(for: .milliseconds(168)) } catch { return }
            self.finishOpening()
        }
    }

    private func finishOpening() {
        visibility = .expanded
        syncControls()
        syncShortcutMouse(at: NSEvent.mouseLocation)
        let item = controls.first { $0.control.key == .ok && $0.button.isEnabled } ?? controls.first
        item?.panel.makeKeyAndOrderFront(nil)
        if let item, item.button.isEnabled { item.panel.makeFirstResponder(item.button) }
    }

    private func syncControls() {
        for item in controls {
            item.button.isEnabled = visibility.isOpen && (item.control.key.map(model.supports) ?? true)
            item.panel.ignoresMouseEvents = !visibility.acceptsControlClicks
            if !visibility.acceptsControlClicks { item.panel.makeFirstResponder(nil) }
        }
    }

    private func fadeButtons(to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            shortcuts.animator().alphaValue = alpha
            for item in controls { item.panel.animator().alphaValue = alpha }
        }
    }

    private func hide() {
        visibility = .collapsed
        surface.orderOut(nil)
        shortcuts.orderOut(nil)
        presentation.shortcutsExpanded = false
        shortcutMotion = false
        for item in controls { item.panel.orderOut(nil) }
        presentation.settle(at: 0)
    }

    private func startMonitoring() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks.union(.mouseMoved)) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .mouseMoved { self?.syncShortcutMouse(at: NSEvent.mouseLocation) }
                else { self?.observeMouse(event, source: "global") }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union([.keyDown, .mouseMoved])) { [weak self] event in
            guard let self else { return event }
            let isControl = self.controls.contains { $0.panel === event.window }
            let isShortcut = event.window === self.shortcuts
            if event.type == .mouseMoved {
                self.syncShortcutMouse(at: NSEvent.mouseLocation)
            } else if event.type == .keyDown {
                if isControl, event.window?.isKeyWindow == true, self.visibility == .expanded {
                    return self.routeKeyboard(event)
                }
            } else if isShortcut, !self.hitsShortcuts(event) {
                self.observeMouse(event, source: "local")
            } else if isControl || isShortcut {
                if event.type == .leftMouseDown { self.activationDown = nil }
            } else {
                self.observeMouse(event, source: "local")
            }
            return event
        }
    }

    private func toggleShortcuts() {
        guard visibility == .expanded, !shortcutMotion else { return }
        let duration = motion
        guard duration > 0 else {
            presentation.shortcutsExpanded.toggle()
            syncShortcutMouse(at: NSEvent.mouseLocation)
            return
        }
        shortcutMotion = true
        shortcuts.ignoresMouseEvents = true
        withAnimation(.easeInOut(duration: duration)) {
            presentation.shortcutsExpanded.toggle()
        } completion: { [weak self] in
            guard let self else { return }
            self.shortcutMotion = false
            self.syncShortcutMouse(at: NSEvent.mouseLocation)
        }
    }

    private func syncShortcutMouse(at point: CGPoint) {
        guard visibility == .expanded, !shortcutMotion,
              shortcuts.frame.contains(point) else {
            shortcuts.ignoresMouseEvents = true
            return
        }
        shortcuts.ignoresMouseEvents = !hitsShortcuts(shortcuts.convertPoint(fromScreen: point))
    }

    private func hitsShortcuts(_ event: NSEvent) -> Bool {
        hitsShortcuts(event.locationInWindow)
    }

    private func hitsShortcuts(_ location: CGPoint) -> Bool {
        let size = shortcuts.frame.size
        let point = CGPoint(x: location.x, y: size.height - location.y)
        let shape = QuickLaunchShape(progress: presentation.shortcutsExpanded ? 1 : 0,
                                     rise: presentation.topExtension)
        return shape.path(in: CGRect(origin: .zero, size: size)).contains(point)
    }

    private func routeKeyboard(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags
        if modifiers.intersection([.command, .control]).isEmpty {
            if event.keyCode == 53 { dismiss(); return nil }
            if event.keyCode == 48 {
                cycleButtons(backward: modifiers.contains(.shift))
                return nil
            }
            if [36, 49, 76].contains(event.keyCode),
               controls.contains(where: { $0.control.key == nil && $0.panel.isKeyWindow && $0.panel.firstResponder === $0.button }) {
                return event
            }
            if event.isARepeat, event.keyCode == 36 || event.keyCode == 76 { return nil }
            if let input = RokuKeyboardInput.macKey(code: event.keyCode, characters: event.characters,
                                                    isRepeat: event.isARepeat),
               model.sendKeyboard(input) { return nil }
        } else if modifiers.intersection([.command, .control, .shift, .option]) == .command,
                  event.charactersIgnoringModifiers == "v", !event.isARepeat,
                  model.status == .connected, let text = NSPasteboard.general.string(forType: .string),
                  model.sendKeyboard(.text(text)) {
            return nil
        }
        return event
    }

    private func observeMouse(_ event: NSEvent, source: String) {
        let point = event.cgEvent?.unflippedLocation
            ?? event.window?.convertPoint(toScreen: event.locationInWindow)
            ?? event.locationInWindow
        let hit = geometry?.hit(at: point)
        let allowedHit = NSApp.currentSystemPresentationOptions.contains(.fullScreen) ? nil : hit
        #if EXPERIMENTAL_LISTENING
        if clickLogging, let geometry, hit != nil || geometry.cameraHousing?.contains(point) == true
            || geometry.phase11Activation.contains(point) {
            logClick("\(source) \(event.type) at \(NSStringFromPoint(point)); "
                     + "region=\(hit?.rawValue ?? "outside"); eligible=\(allowedHit != nil); "
                     + "frontmost hit-test window=\(NotchDisplay.hitTestWindow(at: point))")
        }
        #endif

        switch event.type {
        case .leftMouseDown:
            activationDown = allowedHit.map { NotchClick(point: point, hit: $0) }
            if allowedHit == nil { dismiss() }
        case .leftMouseUp:
            defer { activationDown = nil }
            guard let down = activationDown, down.completes(at: point, in: allowedHit) else { return }
    #if EXPERIMENTAL_LISTENING
            if clickLogging { logClick("Toggle accepted from \(down.hit.rawValue)") }
    #endif
            toggle()
        default:
            activationDown = nil
            dismiss()
        }
    }

    #if EXPERIMENTAL_LISTENING
    private func logClick(_ line: String) {
        FileHandle.standardError.write(Data("[Ukor Visor] \(line)\n".utf8))
    }
    #endif

    private func cycleButtons(backward: Bool) {
        let items = controls.filter { $0.button.isEnabled }
        guard !items.isEmpty else { return }
        let focused = items.firstIndex { $0.panel.isKeyWindow && $0.panel.firstResponder === $0.button }
        let index = focused.map { ($0 + (backward ? -1 : 1) + items.count) % items.count }
            ?? (backward ? items.count - 1 : 0)
        let item = items[index]
        item.panel.makeKey()
        item.panel.makeFirstResponder(item.button)
    }
}
