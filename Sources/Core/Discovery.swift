import Darwin
import Foundation

enum Discovery {
    static func address(from response: String) -> String? {
        let lines = response.components(separatedBy: "\r\n")
        guard lines.first?.lowercased().hasPrefix("http/1.1 200 ") == true else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2 {
                headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard headers["st"]?.lowercased() == "roku:ecp", let location = headers["location"],
              let url = URLComponents(string: location), url.scheme?.lowercased() == "http",
              url.port == 8060, url.user == nil, url.password == nil, let host = url.host else { return nil }
        return RokuAddress.ipv4(host)
    }

    static func find() async throws -> [String] {
        let worker = Task.detached(priority: .utility) { try scan() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func scan() throws -> [String] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw RokuError.discovery(errno) }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw RokuError.discovery(errno)
        }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &target.sin_addr)
        let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nST: roku:ecp\r\nMX: 1\r\n\r\n"
        let payload = Array(request.utf8)
        let count = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(descriptor, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard count == payload.count else { throw RokuError.discovery(errno) }

        let deadline = ContinuousClock.now + .milliseconds(1800)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var addresses = Set<String>()
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while ContinuousClock.now < deadline, addresses.count < 16 {
            try Task.checkCancellation()
            let ready = poll(&event, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw RokuError.discovery(errno) }
            guard event.revents & Int16(POLLIN) != 0 else { throw RokuError.discovery(EIO) }
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let size = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length)
                }
            }
            if size <= 0 { continue }
            guard let source = inet_ntoa(peer.sin_addr), let advertised = address(from: String(decoding: buffer.prefix(size), as: UTF8.self)),
                  advertised == String(cString: source) else { continue }
            addresses.insert(advertised)
        }
        return addresses.sorted()
    }
}
