import Combine
import Foundation

enum SettingsSection: String, CaseIterable, Identifiable {
    case devices = "Devices"
    case shortcuts = "Shortcuts"
    case appearance = "Appearance"
    case controls = "Controls"
    case about = "About"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .devices: "tv"
        case .shortcuts: "square.grid.2x2"
        case .appearance: "paintbrush"
        case .controls: "keyboard"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsSection? = .devices
    @Published private(set) var shortcutRequest = false

    func openShortcutEditor() {
        selection = .shortcuts
        shortcutRequest = true
    }

    func consumeShortcutRequest() {
        shortcutRequest = false
    }
}

enum RokuConnectionStatus: Equatable {
    case idle, connecting, connected, standby, disconnected(String)

    var settingsTitle: String {
        switch self {
        case .idle: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .standby: "Standby"
        case .disconnected: "Connection failed"
        }
    }

    var settingsMessage: String? {
        switch self {
        case .standby: "Press Power on the visor to wake your Roku."
        case .disconnected: "Check that the Roku is awake and on the same network, then try reconnecting."
        default: nil
        }
    }
}

enum SettingsPresentation {
    static func discoveryEmpty(savedDevice: RokuDevice?) -> String {
        if savedDevice != nil {
            return "No devices appeared in this scan. You can still reconnect using your saved address."
        }
        return "Wake your Roku and check that it’s on the same network, or enter its IP address below."
    }

    static func channels(_ channels: [RokuChannel], matching search: String) -> [RokuChannel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? channels : channels.filter { $0.name.localizedStandardContains(query) }
    }
}

struct SettingsMetadata {
    let info: [String: Any]

    var name: String { text("CFBundleDisplayName") ?? text("CFBundleName") ?? "Ukor Visor" }
    var developer: String? { text("RokuVisorDeveloper") }
    var copyright: String? { text("NSHumanReadableCopyright") }
    var versionLabel: String? {
        switch (text("CFBundleShortVersionString"), text("CFBundleVersion")) {
        case let (.some(version), .some(build)): "Version \(version) (Build \(build))"
        case let (.some(version), nil): "Version \(version)"
        case let (nil, .some(build)): "Build \(build)"
        case (nil, nil): nil
        }
    }

    var supportURL: URL? { webURL("RokuVisorSupportURL") }
    var websiteURL: URL? { webURL("RokuVisorWebsiteURL") }

    private func text(_ key: String) -> String? {
        guard let value = info[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    private func webURL(_ key: String) -> URL? {
        guard let value = text(key), let url = URL(string: value), url.host != nil,
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

enum SettingsPalette {
    static let background: UInt32 = 0x191224
    static let sidebar: UInt32 = 0x241A35
    static let card: UInt32 = 0x2D233D
    static let selection: UInt32 = 0x51346F
    static let button: UInt32 = 0x49315E
    static let border: UInt32 = 0x493759
    static let accent: UInt32 = 0xA65CFA
    static let primaryText: UInt32 = 0xF5F0FA
    static let secondaryText: UInt32 = 0xBEB1CE
    static let mutedText: UInt32 = 0xA79AB7

    static func rgb(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255)
    }
}
