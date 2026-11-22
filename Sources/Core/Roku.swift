import Darwin
import Foundation

enum RokuKey: String, CaseIterable {
    case up = "Up", down = "Down", left = "Left", right = "Right", ok = "Select"
    case home = "Home", back = "Back", play = "Play", options = "Info"
    case rewind = "Rev", fastForward = "Fwd"
    case quieter = "VolumeDown", louder = "VolumeUp", power = "PowerOff", stop = "Stop"

    var repeats: Bool { [.up, .down, .left, .right].contains(self) }

    func command(for device: RokuDevice) throws -> String {
        switch self {
        case .stop:
            throw RokuError.unsupported
        case .power where !device.isTV, .quieter where !device.isTV, .louder where !device.isTV:
            throw RokuError.unsupported
        default:
            return rawValue
        }
    }
}

enum RokuKeyboardInput: Sendable {
    case text(String)
    case backspace
    case select

    static func macKey(code: UInt16, characters: String?, isRepeat: Bool) -> Self? {
        switch code {
        case 36, 76: return isRepeat ? nil : .select
        case 51, 117: return .backspace
        default:
            guard let characters, !characters.isEmpty,
                  !characters.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) })
            else { return nil }
            return .text(characters)
        }
    }

    func commands() throws -> [String] {
        switch self {
        case .backspace: return ["Backspace"]
        case .select: return [RokuKey.ok.rawValue]
        case .text(let text):
            guard !text.isEmpty, text.unicodeScalars.allSatisfy({ scalar in
                switch scalar.properties.generalCategory {
                case .control, .lineSeparator, .paragraphSeparator: return false
                default: return true
                }
            }) else { throw RokuError.invalidKeyboardText }
            return text.unicodeScalars.map { "Lit_\($0)" }
        }
    }
}

enum RokuPowerMode: String, Codable, Sendable {
    case on, standby

    init?(reportedValue: String?) {
        switch reportedValue?.lowercased() {
        case "poweron": self = .on
        case "poweroff", "displayoff", "ready", "standby": self = .standby
        default: return nil
        }
    }

    var command: String {
        switch self {
        case .on: return "PowerOn"
        case .standby: return "PowerOff"
        }
    }
}

struct RokuDevice: Codable, Hashable, Identifiable, Sendable {
    let address: String
    let name: String
    let serial: String?
    let isTV: Bool
    var powerMode: RokuPowerMode? = nil

    var id: String { serial ?? address }
}

struct DevicePreferences {
    let defaults: UserDefaults
    private let key = "selectedRoku"

    var selected: RokuDevice? {
        get {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(RokuDevice.self, from: data)
        }
        nonmutating set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
        }
    }
}

enum RokuError: LocalizedError, Equatable {
    case address, unsupported, invalidResponse, timedOut, accessDenied, unreachable, http(Int), discovery(Int32)
    case invalidKeyboardText

    var errorDescription: String? {
        switch self {
        case .address: return "Enter the Roku’s local IPv4 address, such as 192.168.1.25."
        case .unsupported: return "This command is unavailable for this Roku."
        case .invalidResponse: return "The address did not return valid Roku device information."
        case .timedOut: return "The Roku did not respond in time. Check that it is awake and on the same network."
        case .accessDenied: return "Check Roku’s Control by mobile apps setting and allow Ukor Visor in macOS Local Network privacy settings."
        case .unreachable: return "Roku is unreachable. Check its address, network, and macOS Local Network permission."
        case .http(let code): return "Roku rejected the request (HTTP \(code))."
        case .invalidKeyboardText: return "Enter a single line of text."
        case .discovery(let code): return "Discovery was unavailable (socket error \(code)). Check Local Network access or enter the IP address."
        }
    }
}

enum RokuAddress {
    static func ipv4(_ input: String) -> String? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes = in_addr()
        guard !address.utf8.contains(0), inet_pton(AF_INET, address, &bytes) == 1 else { return nil }
        let ip = UInt32(bigEndian: bytes.s_addr)
        switch ip >> 24 {
        case 0, 127, 224...255: return nil
        default: return address
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct RokuClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport
    private static let commandCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    init(transport: @escaping Transport) { self.transport = transport }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 3
        config.waitsForConnectivity = false
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        self.init { try await session.data(for: $0) }
    }

    static func request(address: String, command: String? = nil) throws -> URLRequest {
        guard let address = RokuAddress.ipv4(address) else { throw RokuError.address }
        var url = URLComponents()
        url.scheme = "http"
        url.host = address
        url.port = 8060
        if let command {
            guard let encoded = command.addingPercentEncoding(withAllowedCharacters: commandCharacters) else {
                throw RokuError.invalidKeyboardText
            }
            url.percentEncodedPath = "/keypress/\(encoded)"
        } else {
            url.path = "/query/device-info"
        }
        guard let endpoint = url.url else { throw RokuError.address }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2.5)
        request.httpMethod = command == nil ? "GET" : "POST"
        if command != nil { request.httpBody = Data() }
        return request
    }

    func identify(_ address: String) async throws -> RokuDevice {
        guard let address = RokuAddress.ipv4(address) else { throw RokuError.address }
        let data = try await perform(Self.request(address: address))
        return try DeviceInfo.parse(data, address: address)
    }

    func send(command: String, to device: RokuDevice) async throws {
        _ = try await perform(Self.request(address: device.address, command: command))
    }

    func togglePower(on device: RokuDevice, assumeOn: Bool) async throws -> RokuPowerMode {
        guard device.isTV else { throw RokuError.unsupported }
        let current: RokuPowerMode
        do {
            let live = try await identify(device.address)
            guard live.isTV, device.serial == nil || device.serial == live.serial else {
                throw RokuError.invalidResponse
            }
            current = live.powerMode ?? (assumeOn ? .on : .standby)
        } catch let error as RokuError where error == .unreachable || error == .timedOut {
            // A sleeping Roku can refuse device-info. Try the explicit wake command only.
            current = .standby
        }
        try Task.checkCancellation()
        let target: RokuPowerMode = current == .on ? .standby : .on
        try await send(command: target.command, to: device)
        return target
    }

    static func channelRequest(address: String, operation: ChannelOperation) throws -> URLRequest {
        var request = try Self.request(address: address)
        guard let base = request.url, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw RokuError.address
        }
        switch operation {
        case .installed: components.path = "/query/apps"
        case .icon(let id), .launch(let id):
            guard RokuChannel.validID(id) else { throw RokuError.invalidResponse }
            if case .launch = operation {
                components.path = "/launch/\(id)"
                request.httpMethod = "POST"
                request.httpBody = Data()
            } else {
                components.path = "/query/icon/\(id)"
            }
        }
        request.url = components.url
        return request
    }

    enum ChannelOperation {
        case installed, icon(String), launch(String)
    }

    func installedChannels(on device: RokuDevice) async throws -> [RokuChannel] {
        let data = try await perform(Self.channelRequest(address: device.address, operation: .installed))
        return try RokuChannel.installed(from: data)
    }

    func channelIcon(_ id: String, on device: RokuDevice) async throws -> Data {
        try await perform(Self.channelRequest(address: device.address, operation: .icon(id)))
    }

    func launchChannel(_ id: String, on device: RokuDevice) async throws {
        _ = try await perform(Self.channelRequest(address: device.address, operation: .launch(id)))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await transport(request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw RokuError.timedOut
            case .noPermissionsToReadFile, .userAuthenticationRequired, .appTransportSecurityRequiresSecureConnection: throw RokuError.accessDenied
            default: throw RokuError.unreachable
            }
        }
        guard let response = result.1 as? HTTPURLResponse else { throw RokuError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return result.0
        case 401, 403: throw RokuError.accessDenied
        default: throw RokuError.http(response.statusCode)
        }
    }
}

enum DeviceInfo {
    static func parse(_ data: Data, address: String) throws -> RokuDevice {
        let xml: XMLDocument
        do { xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) }
        catch { throw RokuError.invalidResponse }
        guard let root = xml.rootElement(), root.name == "device-info" else { throw RokuError.invalidResponse }
        func field(_ key: String) -> String? {
            guard let value = root.elements(forName: key).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        return RokuDevice(address: address, name: field("user-device-name") ?? field("friendly-device-name")
                          ?? field("model-name") ?? "Roku", serial: field("serial-number"),
                          isTV: field("is-tv")?.lowercased() == "true",
                          powerMode: RokuPowerMode(reportedValue: field("power-mode")))
    }
}
