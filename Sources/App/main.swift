import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = RokuModel()
    private var visor: VisorController?
    private var statusItem: NSStatusItem?
    private var settings: NSWindow?
    private let settingsNavigation = SettingsNavigation()
    #if EXPERIMENTAL_LISTENING
    private let privateListening = RokuPrivateListening()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard privateListening.active else { return .terminateNow }
        privateListening.stop()
        Task {
            await privateListening.waitUntilStopped()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func stopListeningForSleep() { privateListening.stop() }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        visor = VisorController(model: model, openSettings: { [weak self] in self?.showSettings() }) { [weak self] replacement in
            guard let self else { return }
            self.model.replacingShortcut = replacement
            self.model.channelSearch = ""
            self.settingsNavigation.openShortcutEditor()
            self.showSettings()
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "tv", accessibilityDescription: "Ukor Visor")
        item.button?.toolTip = "Ukor Visor"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        #if EXPERIMENTAL_LISTENING
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(stopListeningForSleep),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
        #endif
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        visor?.dismiss(immediate: true)
        model.stop()
    }

    @objc private func screenChanged() { visor?.layout() }

    @objc private func spaceChanged() { visor?.dismiss(immediate: true) }

    @objc private func wake() {
        visor?.layout()
        model.reconnect()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(visor?.open == true ? "Close Ukor Visor" : "Open Ukor Visor", action: #selector(toggle), to: menu)
        let devices = NSMenuItem(title: "Roku Devices", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if model.devices.isEmpty {
            add("Find Devices…", action: #selector(showSettings), to: submenu)
        } else {
            for device in model.devices {
                let item = add("\(device.name) (\(device.address))", action: #selector(selectDevice(_:)), to: submenu)
                item.representedObject = device
                item.state = device.id == model.selected?.id ? .on : .off
            }
            submenu.addItem(.separator())
            add("Refresh Devices…", action: #selector(showSettings), to: submenu)
        }
        devices.submenu = submenu
        menu.addItem(devices)
        add("Settings…", action: #selector(showSettings), key: ",", to: menu)
        menu.addItem(.separator())
        add("Quit Ukor Visor", action: #selector(quit), key: "q", to: menu)
    }

    @discardableResult
    private func add(_ title: String, action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggle() { visor?.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func selectDevice(_ item: NSMenuItem) {
        if let device = item.representedObject as? RokuDevice { model.select(device) }
    }

    @objc private func showSettings() {
        visor?.dismiss()
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Ukor Visor"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(SettingsTheme.background)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            #if EXPERIMENTAL_LISTENING
            let view = NSHostingView(rootView: VisorSettings(model: model, navigation: settingsNavigation,
                                                            quit: { [weak self] in self?.quit() },
                                                            privateListening: privateListening))
            #else
            let view = NSHostingView(rootView: VisorSettings(model: model, navigation: settingsNavigation,
                                                            quit: { [weak self] in self?.quit() }))
            #endif
            view.sizingOptions = []
            window.contentView = view
            window.contentMinSize = NSSize(width: 630, height: 410)
            if !window.setFrameUsingName("RokuVisorSettings") { window.center() }
            window.setFrameAutosaveName("RokuVisorSettings")
            settings = window
        }
        model.reloadLogin()
        model.startDiscoveryIfNeeded()
        if settingsNavigation.selection == .shortcuts { model.refreshChannels() }
        NSApp.activate()
        guard let settings else { return }
        if settings.isMiniaturized { settings.deminiaturize(nil) }
        if let screen = settings.screen ?? NSScreen.main {
            var frame = settings.frame
            let visible = screen.visibleFrame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            let constrained = settings.constrainFrameRect(frame, to: screen)
            if settings.frame != constrained { settings.setFrame(constrained, display: false) }
        }
        settings.makeKeyAndOrderFront(nil)
    }
}

#if EXPERIMENTAL_LISTENING
if let probe = CommandLine.arguments.dropFirst().first,
   probe == ListeningSessionProbe.command || probe == ListeningSessionProbe.authCommand {
    guard ListeningExperiment.enabled(environment: ProcessInfo.processInfo.environment),
          CommandLine.arguments.count == 3, let address = ListeningSessionProbe.localAddress(CommandLine.arguments[2]) else {
        FileHandle.standardError.write(Data("Enable experimentalPrivateListeningEnabled=1 and supply one local Roku IPv4 address.\n".utf8))
        exit(2)
    }
    if probe == ListeningSessionProbe.authCommand {
        ListeningSessionProbe.runAuthProbe(address: address)
    } else {
        ListeningSessionProbe.run(address: address)
    }
    exit(0)
}
if let command = CommandLine.arguments.dropFirst().first,
   let profile = ListeningUDPDiagnostic.profile(for: command) {
    do {
        guard ListeningExperiment.enabled(environment: ProcessInfo.processInfo.environment) else {
            throw ListeningError.disabled
        }
        let args = CommandLine.arguments.dropFirst(2)
        guard args.count <= 2, let port = UInt16(args.first ?? "6970"),
              let seconds = Int(args.dropFirst().first ?? "5"), (1...60).contains(seconds) else {
            FileHandle.standardError.write(Data("Usage: \(command) [port 0–65535] [duration 1–60 seconds]\n".utf8))
            exit(2)
        }
        try ListeningUDPDiagnostic.run(port: port, seconds: seconds,
                                       generate: command != ListeningUDPDiagnostic.receiver,
                                       volume: ListeningVolume().percent, profile: profile,
                                       includeControl: command == ListeningUDPDiagnostic.mediaFixture)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("UDP diagnostic failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
if CommandLine.arguments.dropFirst().first == ListeningExperiment.command {
    do {
        guard ListeningExperiment.enabled(environment: ProcessInfo.processInfo.environment) else {
            throw ListeningError.disabled
        }
        let volume = ListeningVolume()
        if let argument = CommandLine.arguments.dropFirst(2).first {
            guard let percent = Int(argument), (0...100).contains(percent) else {
                FileHandle.standardError.write(Data("Volume must be a whole number from 0 to 100.\n".utf8))
                exit(2)
            }
            volume.percent = percent
        }
        let decoder = try ListeningOpusDecoder()
        let clip = try ListeningToneFixture.decode(using: decoder)
        let output = ListeningAudioOutput(format: decoder.pcmFormat)
        print("Playing synthetic Opus test tone at \(volume.percent)%. No Roku connection is used.")
        let frames = try output.play(clip, volume: volume.percent)
        print("Finished playing \(frames) frames through Mac audio output.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Experimental playback failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
#endif

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
