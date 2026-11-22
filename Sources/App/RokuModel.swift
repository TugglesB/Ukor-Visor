import AppKit
import CryptoKit
import ServiceManagement
import SwiftUI

@MainActor
final class RokuModel: ObservableObject {
    typealias Status = RokuConnectionStatus

    @Published private(set) var selected: RokuDevice? {
        didSet {
            guard selected?.id != oldValue?.id else { return }
            catalogTask?.cancel()
            catalogTask = nil
            loadingChannels = false
            installedChannels = nil
            catalogError = nil
            shortcutLaunchError = nil
            unavailableChannels.removeAll()
            replacingShortcut = nil
            channelSearch = ""
        }
    }
    @Published private(set) var favorites: [RokuChannel] = []
    @Published private(set) var installedChannels: [RokuChannel]?
    @Published private(set) var catalogError: String?
    @Published private(set) var loadingChannels = false
    @Published private(set) var launchingChannel: String?
    @Published private(set) var shortcutLaunchError: String?
    @Published private(set) var channelIcons: [String: NSImage] = [:]
    @Published private(set) var unavailableChannels: Set<String> = []
    @Published var channelSearch = ""
    @Published var replacingShortcut: String?
    @Published private(set) var devices: [RokuDevice] = []
    @Published private(set) var status: Status = .idle
    @Published private var changingPower = false
    @Published private(set) var discoveryMessage = ""
    @Published private(set) var scanning = false
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginMessage = ""
    @Published var manualAddress = ""
    @Published var animations: Bool {
        didSet { defaults.set(animations, forKey: "animationsEnabled") }
    }

    private let defaults: UserDefaults
    private let preferences: DevicePreferences
    private let shortcutStore: QuickLaunchFavorites
    private var catalogTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var iconRequests = Set<String>()
    private let client = RokuClient()
    private var connection: Task<Void, Never>?
    private var scan: Task<Void, Never>?
    private var transmission: Task<Void, Never>?
    private var periodic: Task<Void, Never>?
    private var targetAddress: String?
    private var nextCommand = ContinuousClock.now
    private struct PendingCommand {
        let name: String
        let fromKeyboard: Bool
    }

    private var pendingCommands: [PendingCommand] = []
    private var discovered = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = DevicePreferences(defaults: defaults)
        shortcutStore = QuickLaunchFavorites(defaults: defaults)
        let saved = preferences.selected
        selected = saved
        if let saved { favorites = shortcutStore.channels(for: saved.id) }
        targetAddress = saved?.address
        manualAddress = saved?.address ?? ""
        animations = defaults.object(forKey: "animationsEnabled") as? Bool ?? true
        reloadLogin()
    }

    func start() {
        reconnect()
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.retryIfNeeded()
            }
        }
    }

    func stop() {
        periodic?.cancel()
        scan?.cancel()
        connection?.cancel()
        transmission?.cancel()
        catalogTask?.cancel()
        launchTask?.cancel()
        pendingCommands.removeAll()
    }

    func startDiscoveryIfNeeded() {
        guard !discovered else { return }
        discovered = true
        refresh()
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        discoveryMessage = "Looking for Roku devices…"
        scan = Task { [weak self, client] in
            do {
                let addresses = try await Discovery.find()
                let devices = await withTaskGroup(of: RokuDevice?.self, returning: [RokuDevice].self) { group in
                    for address in addresses {
                        group.addTask { try? await client.identify(address) }
                    }
                    var found: [String: RokuDevice] = [:]
                    for await device in group {
                        if let device { found[device.id] = device }
                    }
                    return found.values.sorted { ($0.name, $0.address) < ($1.name, $1.address) }
                }
                guard let self, !Task.isCancelled else { return }
                self.devices = devices
                if let selected = self.selected, let moved = devices.first(where: { $0.id == selected.id }),
                   self.targetAddress == selected.address, moved.address != selected.address {
                    self.select(moved)
                }
                self.discoveryMessage = devices.isEmpty
                    ? "No devices found. Allow Local Network access, wake the Roku, or enter its IP address."
                    : ""
            } catch {
                self?.discoveryMessage = error.localizedDescription
            }
            self?.scanning = false
        }
    }

    func select(_ device: RokuDevice) {
        connect(address: device.address, expectedSerial: device.serial)
    }

    func useManualAddress(_ value: String) {
        guard let address = RokuAddress.ipv4(value) else {
            discoveryMessage = RokuError.address.localizedDescription
            return
        }
        discoveryMessage = ""
        connect(address: address)
    }

    var canReconnect: Bool { targetAddress != nil }

    func reconnect() {
        guard let targetAddress else { return }
        let expected = selected?.address == targetAddress ? selected?.serial : nil
        connect(address: targetAddress, expectedSerial: expected)
    }

    private func retryIfNeeded() {
        guard selected != nil, transmission == nil else { return }
        switch status {
        case .standby:
            reconnect()
        case .disconnected:
            reconnect()
            if !scanning { refresh() }
        default:
            break
        }
    }

    private func connect(address: String, expectedSerial: String? = nil) {
        connection?.cancel()
        if address != targetAddress || (expectedSerial != nil && expectedSerial != selected?.serial) {
            launchTask?.cancel()
            launchTask = nil
            launchingChannel = nil
            catalogTask?.cancel()
            catalogTask = nil
            loadingChannels = false
        }
        transmission?.cancel()
        transmission = nil
        pendingCommands.removeAll()
        let wasInStandby = status == .standby && selected?.address == address
        targetAddress = address
        status = .connecting
        connection = Task { [weak self, client] in
            do {
                let device = try await client.identify(address)
                guard expectedSerial == nil || device.serial == expectedSerial else { throw RokuError.invalidResponse }
                guard let self, !Task.isCancelled else { return }
                self.selected = device
                self.favorites = self.shortcutStore.channels(for: device.id)
                self.manualAddress = device.address
                self.preferences.selected = device
                self.status = device.powerMode == .standby || (device.powerMode == nil && wasInStandby)
                    ? .standby : .connected
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = .disconnected(error.localizedDescription)
            }
        }
    }

    func supports(_ key: RokuKey) -> Bool {
        guard let selected else { return false }
        if key == .power {
            return selected.isTV && targetAddress == selected.address && status != .connecting && !changingPower
        }
        return status == .connected && (try? key.command(for: selected)) != nil
    }

    func send(_ key: RokuKey, isRepeat: Bool) {
        guard let device = selected, supports(key), let name = try? key.command(for: device) else { return }
        if key == .power {
            guard !pendingCommands.contains(where: { $0.name == name }) else { return }
        } else if isRepeat {
            guard transmission == nil, ContinuousClock.now >= nextCommand else { return }
        } else {
            guard pendingCommands.count(where: { !$0.fromKeyboard }) < 3 else { return }
        }
        pendingCommands.append(PendingCommand(name: name, fromKeyboard: false))
        startTransmission(to: device)
    }

    @discardableResult
    func sendKeyboard(_ input: RokuKeyboardInput) -> Bool {
        guard let device = selected, status == .connected, let names = try? input.commands() else { return false }
        pendingCommands.append(contentsOf: names.map { PendingCommand(name: $0, fromKeyboard: true) })
        startTransmission(to: device)
        return true
    }

    func discardQueuedKeyboardInput() {
        pendingCommands.removeAll(where: \.fromKeyboard)
    }

    private func startTransmission(to device: RokuDevice) {
        guard transmission == nil else { return }
        transmission = Task { [weak self] in
            await self?.transmit(to: device)
        }
    }

    private func transmit(to device: RokuDevice) async {
        do {
            while !pendingCommands.isEmpty {
                try await Task.sleep(until: nextCommand)
                try Task.checkCancellation()
                guard !pendingCommands.isEmpty else { break }

                let command = pendingCommands.removeFirst()
                nextCommand = ContinuousClock.now + .milliseconds(command.fromKeyboard ? 40 : 90)
                if command.name == RokuKey.power.rawValue {
                    await changePower(on: device)
                    break
                }
                try await client.send(command: command.name, to: device)
                try Task.checkCancellation()
            }
        } catch {
            guard !Task.isCancelled else { return }
            status = .disconnected(error.localizedDescription)
        }
        guard !Task.isCancelled else { return }
        pendingCommands.removeAll()
        transmission = nil
    }

    private func changePower(on device: RokuDevice) async {
        changingPower = true
        defer { changingPower = false }

        do {
            let target = try await client.togglePower(on: device, assumeOn: status == .connected)
            try Task.checkCancellation()
            if target == .standby {
                status = .standby
            } else {
                status = .connecting
                try await Task.sleep(for: .seconds(1))
                reconnect()
            }
        } catch {
            guard !Task.isCancelled else { return }
            if let error = error as? RokuError, error == .timedOut || error == .unreachable {
                status = .disconnected("Couldn’t reach the TV. Enable Fast TV Start on the TV to keep it reachable in standby.")
            } else {
                status = .disconnected(error.localizedDescription)
            }
        }
    }

    func refreshChannels() {
        guard let device = selected, targetAddress == device.address, status != .connecting,
              catalogTask == nil else { return }
        loadingChannels = true
        catalogError = nil
        catalogTask = Task { [weak self, client] in
            do {
                let channels = try await client.installedChannels(on: device)
                guard let self, !Task.isCancelled, self.selected?.id == device.id else { return }
                self.installedChannels = channels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.unavailableChannels.removeAll()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.catalogError = self.channelError(error, forLaunch: false)
            }
            self?.loadingChannels = false
            self?.catalogTask = nil
        }
    }

    func chooseShortcut(_ channel: RokuChannel) {
        guard let device = selected else { return }
        shortcutStore.choose(channel, on: device.id, replacing: replacingShortcut)
        favorites = shortcutStore.channels(for: device.id)
        replacingShortcut = nil
    }

    func removeShortcut(_ id: String) {
        guard let device = selected else { return }
        shortcutStore.remove(id, on: device.id)
        favorites = shortcutStore.channels(for: device.id)
        if replacingShortcut == id { replacingShortcut = nil }
    }

    func moveShortcut(_ id: String, by offset: Int) {
        guard let device = selected else { return }
        shortcutStore.move(id, by: offset, on: device.id)
        favorites = shortcutStore.channels(for: device.id)
    }

    func isUnavailable(_ id: String) -> Bool {
        RokuChannel.isUnavailable(id, installed: installedChannels, rejected: unavailableChannels)
    }

    func launchShortcut(_ channel: RokuChannel) {
        guard let device = selected, targetAddress == device.address, status != .connecting else {
            shortcutLaunchError = "Connect to a Roku to launch a shortcut."
            return
        }
        guard launchTask == nil else { return }
        guard !isUnavailable(channel.id) else {
            shortcutLaunchError = "\(channel.name) is unavailable. Replace it or refresh installed channels."
            return
        }
        shortcutLaunchError = nil
        launchingChannel = channel.id
        launchTask = Task { [weak self, client] in
            do {
                try await client.launchChannel(channel.id, on: device)
            } catch {
                guard let self, !Task.isCancelled else { return }
                if (error as? RokuError) == .http(404) { self.unavailableChannels.insert(channel.id) }
                self.shortcutLaunchError = self.channelError(error, forLaunch: true)
            }
            guard !Task.isCancelled else { return }
            self?.launchingChannel = nil
            self?.launchTask = nil
        }
    }

    func iconKey(for channel: RokuChannel) -> String { "\(selected?.id ?? "")/\(channel.id)" }

    func loadIcon(for channel: RokuChannel) async {
        guard let device = selected, targetAddress == device.address else { return }
        let key = iconKey(for: channel)
        guard iconRequests.insert(key).inserted else { return }
        let filename = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RokuVisor/ChannelIcons", isDirectory: true)
        let path = directory?.appendingPathComponent(filename)
        if let path, let image = NSImage(contentsOf: path) {
            channelIcons[key] = image
            return
        }
        do {
            let data = try await client.channelIcon(channel.id, on: device)
            guard let image = NSImage(data: data) else { return }
            channelIcons[key] = image
            if let directory, let path {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: path, options: .atomic)
            }
        } catch is CancellationError {
            iconRequests.remove(key)
        } catch {
            // Keep the placeholder for the rest of this session.
        }
    }

    private func channelError(_ error: Error, forLaunch: Bool) -> String {
        switch error as? RokuError {
        case .accessDenied:
            return "Roku blocked channel access. Check Control by mobile apps and this Roku’s ECP support."
        case .http(404) where forLaunch:
            return "Channel unavailable on this Roku. The shortcut was kept."
        case .http(404), .http(405):
            return "This Roku did not expose its installed channel list."
        default: return error.localizedDescription
        }
    }

    func reloadLogin() {
        let state = SMAppService.mainApp.status
        loginEnabled = state == .enabled || state == .requiresApproval
        if state == .requiresApproval { loginMessage = "Allow Ukor Visor in System Settings → Login Items." }
        else { loginMessage = "" }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            reloadLogin()
        } catch {
            reloadLogin()
            loginMessage = error.localizedDescription
        }
    }
}
