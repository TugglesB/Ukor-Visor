import Foundation

struct RokuChannel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let type: String?

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    static func isUnavailable(_ id: String, installed: [Self]?, rejected: Set<String>) -> Bool {
        rejected.contains(id) || installed.map { !$0.contains { $0.id == id } } == true
    }

    static func installed(from data: Data) throws -> [Self] {
        guard let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let root = document.rootElement(), root.name == "apps" else { throw RokuError.invalidResponse }
        var seen = Set<String>()
        return root.elements(forName: "app").compactMap { item in
            guard let id = item.attribute(forName: "id")?.stringValue, validID(id),
                  let name = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, seen.insert(id).inserted else { return nil }
            return RokuChannel(id: id, name: name, type: item.attribute(forName: "type")?.stringValue)
        }
    }
}

struct QuickLaunchFavorites {
    static let limit = 4
    private let defaults: UserDefaults
    private let key = "quickLaunchFavorites"

    init(defaults: UserDefaults) { self.defaults = defaults }

    private var devices: [String: [RokuChannel]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: [RokuChannel]].self, from: data)) ?? [:]
    }

    func channels(for device: String) -> [RokuChannel] {
        var seen = Set<String>()
        return Array((devices[device] ?? []).filter { RokuChannel.validID($0.id) && seen.insert($0.id).inserted }.prefix(Self.limit))
    }

    func choose(_ channel: RokuChannel, on device: String, replacing id: String? = nil) {
        var favorites = channels(for: device)
        guard RokuChannel.validID(channel.id), !favorites.contains(where: { $0.id == channel.id }) else { return }
        if let id {
            guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
            favorites[index] = channel
        } else {
            guard favorites.count < Self.limit else { return }
            favorites.append(channel)
        }
        save(favorites, for: device)
    }

    func remove(_ id: String, on device: String) {
        save(channels(for: device).filter { $0.id != id }, for: device)
    }

    func move(_ id: String, by offset: Int, on device: String) {
        var favorites = channels(for: device)
        guard let index = favorites.firstIndex(where: { $0.id == id }),
              favorites.indices.contains(index + offset) else { return }
        let channel = favorites.remove(at: index)
        favorites.insert(channel, at: index + offset)
        save(favorites, for: device)
    }

    private func save(_ favorites: [RokuChannel], for device: String) {
        var all = devices
        all[device] = favorites
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }
}

struct QuickLaunchLayout {
    static let height: CGFloat = 40
    static let width: CGFloat = 164
    static let peekTravel: CGFloat = 94
    static let tileWidth: CGFloat = 23
    static let tileHeight: CGFloat = 21
    static let spacing: CGFloat = 3
    static let rowInset: CGFloat = 13
    static let rowTop: CGFloat = 16

    let rise: CGFloat

    var artworkFrame: CGRect {
        CGRect(x: VisorGeometry.anchor - VisorGeometry.leftSpan + 20,
               y: VisorGeometry.wingHeight - rise - 11,
               width: Self.width, height: Self.height)
    }

    func screenFrame(in visor: VisorGeometry) -> CGRect {
        visor.screenFrame(for: artworkFrame)
    }

    static func leadingEdge(progress: CGFloat) -> CGFloat {
        peekTravel * (1 - progress)
    }

    static func rowWidth(count: Int) -> CGFloat {
        CGFloat(count) * tileWidth + CGFloat(max(0, count - 1)) * spacing
    }
}
