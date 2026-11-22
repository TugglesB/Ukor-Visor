#if EXPERIMENTAL_LISTENING
import AVFoundation
import Darwin
import Combine

enum ListeningError: Error, LocalizedError {
    case disabled, invalidPacket, unsupportedFormat, decodingFailed, outputUnavailable, outputChanged, playbackTimeout

    var errorDescription: String? {
        switch self {
        case .disabled: "The experimental listening diagnostic is disabled."
        case .invalidPacket: "Invalid or unexpected RTP packet."
        case .unsupportedFormat: "The system Opus decoder or audio format is unavailable."
        case .decodingFailed: "The Opus packet could not be decoded."
        case .outputUnavailable: "The current Mac audio output is unavailable."
        case .outputChanged: "The Mac audio output changed. Run the diagnostic again."
        case .playbackTimeout: "Mac audio playback timed out."
        }
    }
}

enum ListeningExperiment {
    static let experimentalPrivateListeningEnabled = "experimentalPrivateListeningEnabled"
    static let command = "--experimental-listening-tone"

    static func enabled(environment: [String: String]) -> Bool {
        environment[experimentalPrivateListeningEnabled] == "1"
    }
}

// Standard RTP v2 framing (RFC 3550). This type makes no Roku handshake assumptions.
struct ListeningRTPPacket {
    let payloadType: UInt8
    let sequence: UInt16
    let timestamp: UInt32
    let source: UInt32
    let payload: Data

    init(datagram: Data, expectedType: UInt8, expectedSource: UInt32? = nil) throws {
        let bytes = datagram
        func byte(_ offset: Int) -> UInt8 { bytes[bytes.startIndex + offset] }
        guard (12...2048).contains(bytes.count), byte(0) >> 6 == 2,
              byte(1) & 0x7f == expectedType else { throw ListeningError.invalidPacket }
        func word(_ offset: Int) -> UInt32 {
            bytes[(bytes.startIndex + offset)..<(bytes.startIndex + offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let source = word(8)
        guard expectedSource == nil || expectedSource == source else { throw ListeningError.invalidPacket }
        var start = 12 + Int(byte(0) & 0x0f) * 4
        guard start <= bytes.count else { throw ListeningError.invalidPacket }
        if byte(0) & 0x10 != 0 {
            guard start + 4 <= bytes.count else { throw ListeningError.invalidPacket }
            let words = Int(byte(start + 2)) * 256 + Int(byte(start + 3))
            start += 4 + words * 4
        }
        var end = bytes.count
        if byte(0) & 0x20 != 0 {
            guard let count = bytes.last, count > 0 else { throw ListeningError.invalidPacket }
            end -= Int(count)
        }
        guard start < end else { throw ListeningError.invalidPacket }
        payloadType = byte(1) & 127
        sequence = (UInt16(byte(2)) << 8) | UInt16(byte(3))
        timestamp = word(4)
        self.source = source
        payload = bytes[(bytes.startIndex + start)..<(bytes.startIndex + end)]
    }
}

// A bounded sequence window for one source. A future playout clock decides when to skip a loss.
struct ListeningPacketWindow {
    private(set) var next: UInt16
    private var packets: [UInt16: ListeningRTPPacket] = [:]
    private let capacity: UInt16
    var count: Int { packets.count }

    init(firstSequence: UInt16, capacity: UInt16 = 24) {
        next = firstSequence
        self.capacity = min(256, max(1, capacity))
    }

    enum Insertion { case accepted, duplicate, outsideWindow }

    @discardableResult mutating func insert(_ packet: ListeningRTPPacket) -> Insertion {
        if packets[packet.sequence] != nil { return .duplicate }
        guard packet.sequence &- next < capacity else { return .outsideWindow }
        packets[packet.sequence] = packet
        return .accepted
    }

    mutating func pop() -> ListeningRTPPacket? {
        guard let packet = packets.removeValue(forKey: next) else { return nil }
        next &+= 1
        return packet
    }

    mutating func skipMissingPacket() {
        if packets[next] == nil { next &+= 1 }
    }
}

final class ListeningOpusDecoder {
    private let decoder: OpaquePointer
    let pcmFormat: AVAudioFormat

    init(sampleRate: Int32 = 48_000, channels: AVAudioChannelCount = 2) throws {
        guard [8_000, 12_000, 16_000, 24_000, 48_000].contains(sampleRate),
              channels == 1 || channels == 2,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: channels) else {
            throw ListeningError.unsupportedFormat
        }
        var status: Int32 = 0
        guard let decoder = opus_decoder_create(sampleRate, Int32(channels), &status) else {
            throw ListeningError.unsupportedFormat
        }
        self.decoder = decoder
        pcmFormat = format
    }

    deinit { opus_decoder_destroy(decoder) }

    func decode(_ packet: Data) throws -> AVAudioPCMBuffer {
        guard (1...2048).contains(packet.count) else { throw ListeningError.decodingFailed }
        return try packet.withUnsafeBytes { bytes in
            try decode(bytes.bindMemory(to: UInt8.self), frameCapacity: Int(pcmFormat.sampleRate) * 120 / 1000)
        }
    }

    func concealLoss(frames: Int) throws -> AVAudioPCMBuffer {
        let step = Int(pcmFormat.sampleRate) / 400
        guard (step...step * 48).contains(frames), frames.isMultiple(of: step) else {
            throw ListeningError.decodingFailed
        }
        return try decode(UnsafeBufferPointer(start: nil, count: 0), frameCapacity: frames)
    }

    private func decode(_ bytes: UnsafeBufferPointer<UInt8>, frameCapacity: Int) throws -> AVAudioPCMBuffer {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCapacity)),
              let channels = pcm.floatChannelData else { throw ListeningError.decodingFailed }
        let count = Int(pcmFormat.channelCount)
        var interleaved = [Float](repeating: 0, count: frameCapacity * count)
        let frames = interleaved.withUnsafeMutableBufferPointer { samples -> Int32 in
            guard let output = samples.baseAddress else { return -1 }
            return opus_decode_float(decoder, bytes.baseAddress, Int32(bytes.count), output, Int32(frameCapacity), 0)
        }
        guard frames > 0 else { throw ListeningError.decodingFailed }
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<count {
            for frame in 0..<Int(frames) {
                channels[channel][frame] = interleaved[frame * count + channel]
            }
        }
        return pcm
    }
}

enum ListeningRTPProfile {
    case fixture, tcl

    var payloadType: UInt8 { self == .fixture ? 96 : 97 }
    var timestampRate: Int { self == .fixture ? 48_000 : 1000 }
    var nominalFrames: Int { self == .fixture ? 960 : 480 }
    var nominalMilliseconds: Int { nominalFrames / 48 }
    var fixturePackets: [Data] { self == .fixture ? ListeningToneFixture.packets : ListeningToneFixture.tclPackets }
}

// Standard RTP/Opus buffer for one externally negotiated source. The caller owns
// the playout clock and explicitly declares when a missing packet is due.
struct ListeningDatagramPipeline {
    private let profile: ListeningRTPProfile
    private let source: UInt32
    private let decoder: ListeningOpusDecoder
    private var window: ListeningPacketWindow
    private var previousFrames: Int?
    private var expectedTimestamp: UInt32?
    private var lastTCLTimestamp: UInt32?
    private(set) var gaps = 0
    var pendingCount: Int { window.count }

    init(firstSequence: UInt16, profile: ListeningRTPProfile = .fixture, source: UInt32, decoder: ListeningOpusDecoder) {
        self.profile = profile
        self.source = source
        self.decoder = decoder
        window = ListeningPacketWindow(firstSequence: firstSequence)
    }

    @discardableResult mutating func receive(_ data: Data) throws -> ListeningPacketWindow.Insertion {
        try receive(ListeningRTPPacket(datagram: data, expectedType: profile.payloadType, expectedSource: source))
    }

    @discardableResult mutating func receive(_ packet: ListeningRTPPacket) throws -> ListeningPacketWindow.Insertion {
        guard packet.payloadType == profile.payloadType, packet.source == source else { throw ListeningError.invalidPacket }
        return window.insert(packet)
    }

    mutating func next(concealExpiredGap: Bool = false) throws -> AVAudioPCMBuffer? {
        if let packet = window.pop() {
            if let expectedTimestamp {
                let delta = packet.timestamp &- expectedTimestamp
                guard delta <= 48_000, delta.isMultiple(of: 120) else {
                    throw ListeningError.invalidPacket
                }
            }
            if let lastTCLTimestamp {
                let step = packet.timestamp &- lastTCLTimestamp
                guard (1...UInt32(profile.timestampRate)).contains(step) else {
                    throw ListeningError.invalidPacket
                }
            }
            expectedTimestamp = nil
            let pcm = try decoder.decode(packet.payload)
            previousFrames = Int(pcm.frameLength)
            if profile == .fixture {
                expectedTimestamp = packet.timestamp &+ ticks(for: Int(pcm.frameLength))
            } else {
                lastTCLTimestamp = packet.timestamp
            }
            return pcm
        }
        guard concealExpiredGap, window.count > 0, let previousFrames else { return nil }
        let pcm = try decoder.concealLoss(frames: previousFrames)
        window.skipMissingPacket()
        gaps += 1
        if let stamp = expectedTimestamp { expectedTimestamp = stamp &+ ticks(for: previousFrames) }
        return pcm
    }

    private func ticks(for frames: Int) -> UInt32 {
        UInt32(frames * profile.timestampRate / Int(decoder.pcmFormat.sampleRate))
    }
}

struct ListeningVolume {
    static let key = "experimentalListeningVolume"
    var defaults: UserDefaults = .standard

    var percent: Int {
        get { defaults.object(forKey: Self.key) == nil ? 70 : min(100, max(0, defaults.integer(forKey: Self.key))) }
        nonmutating set { defaults.set(min(100, max(0, newValue)), forKey: Self.key) }
    }
}

// Each stream owns its tracker so callbacks from a stopped player cannot affect a restart.
final class ListeningPlaybackCounts: @unchecked Sendable {
    struct Snapshot {
        var frames = 0
        var scheduled = 0
        var completed = 0
        var pending: Int { scheduled - completed }
    }

    private let lock = NSLock()
    private var counts = Snapshot()

    func submit(frames: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard counts.pending < 8 else { return false }
        counts.frames += frames
        counts.scheduled += 1
        return true
    }

    func complete() {
        lock.lock()
        defer { lock.unlock() }
        if counts.pending > 0 { counts.completed += 1 }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }
}

@MainActor
final class ListeningAudioOutput {
    enum State: Equatable { case stopped, starting, playing, failed }

    private(set) var state: State = .stopped
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let format: AVAudioFormat

    init(format: AVAudioFormat) {
        self.format = format
    }

    // The diagnostic plays one short clip and bounds its wait and queued audio.
    func play(_ clip: AVAudioPCMBuffer, volume: Int) throws -> AVAudioFramePosition {
        guard state == .stopped || state == .failed else { throw ListeningError.outputUnavailable }
        state = .starting
        do {
            try render(clip, volume: volume)
            stop()
            return AVAudioFramePosition(clip.frameLength)
        } catch {
            stop()
            state = .failed
            throw error
        }
    }

    func stop() {
        player?.stop()
        engine?.stop()
        if let player { engine?.detach(player) }
        player = nil
        engine = nil
        state = .stopped
    }

    private var playback = ListeningPlaybackCounts()
    var counts: ListeningPlaybackCounts.Snapshot { playback.snapshot() }
    var engineRunning: Bool { engine?.isRunning == true }
    var playerPlaying: Bool { player?.isPlaying == true }

    func startStream(volume: Int) throws {
        guard state == .stopped else { throw ListeningError.outputUnavailable }
        state = .starting
        playback = ListeningPlaybackCounts()
        do {
            _ = try prepare(volume: volume)
        } catch {
            stop()
            state = .failed
            throw error
        }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) throws -> Bool {
        guard let player, engine?.isRunning == true, buffer.format == format,
              buffer.frameLength > 0 else { throw ListeningError.outputChanged }
        let tracker = playback
        guard tracker.submit(frames: Int(buffer.frameLength)) else { return false }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { completion in
            if completion == .dataPlayedBack { tracker.complete() }
        }
        if !player.isPlaying, tracker.snapshot().pending >= 4 { startQueuedPlayback() }
        return true
    }

    private func startQueuedPlayback() {
        player?.play()
        state = .playing
    }

    func drainStream() throws {
        guard counts.pending > 0 else { return }
        guard engineRunning else { throw ListeningError.outputChanged }
        if !playerPlaying { startQueuedPlayback() }
        let deadline = ContinuousClock.now + .seconds(2)
        while counts.pending > 0, ContinuousClock.now < deadline {
            guard engineRunning, playerPlaying else { throw ListeningError.outputChanged }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        guard counts.pending == 0 else { throw ListeningError.playbackTimeout }
    }

    private func prepare(volume: Int) throws -> AVAudioPlayerNode {
        let engine = AVAudioEngine()
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.channelCount > 0, output.sampleRate > 0 else { throw ListeningError.outputUnavailable }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        self.engine = engine
        self.player = player
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.volume = Float(min(100, max(0, volume))) / 100
        try engine.start()
        return player
    }

    private func render(_ clip: AVAudioPCMBuffer, volume: Int) throws {
        guard clip.format == format, clip.frameLength > 0, Double(clip.frameLength) <= format.sampleRate else {
            throw ListeningError.outputUnavailable
        }
        let player = try prepare(volume: volume)
        guard let engine else { throw ListeningError.outputUnavailable }
        let finished = DispatchSemaphore(value: 0)
        player.scheduleBuffer(clip, completionCallbackType: .dataPlayedBack) { _ in finished.signal() }
        player.play()
        state = .playing
        guard finished.wait(timeout: .now() + 2) == .success else {
            throw engine.isRunning ? ListeningError.playbackTimeout : ListeningError.outputChanged
        }
        guard engine.isRunning, player.isPlaying else { throw ListeningError.outputChanged }
    }
}


// Original 440 Hz sine generated for this diagnostic. Opus packets are embedded as
// test data so neither the application nor its tests depend on an external encoder.
enum ListeningToneFixture {
    private static let encoded = [
        "fIf8tLVje4P1sAApqjAi3UJ2LY/myfY1BvC6MSf4F4wf/JBPv4Bwp0cJY0npPpExO5eoKZHO1hDdlO3CovCOJsGZiKsRnkznjtN4k9DzRnK0Zg7Q",
        "fIf/Mr8VQtZQ77c7bCaDDNPlgIDfz8MBNfejfld+FTxB0N90N7L+QZvYJHk5yvJ/LMp6tWq750TZqkkdvYpmotskTaIxLT3i4zspnSR+RQ==",
        "fIgCYfsHeGXshwU1KP/nohLcA15rbLZnSLCnZBTAuh1KTN9EdfB43DJ7YKKZvUiJmbFNZuNv+mW/QgPFWgvdBjoYTwya",
        "fIgCYfsHeGXsgtf69YZZYIwLqv+fL92BWjyWM0ttt1zSDCWzsahxzVKgT9pPsDXFi8CAGMci6yRc0GgO2g8QJt8Ysc0v",
        "fIgCYfsHdnkYFpfjW2kEpmy5DMrWLbbV3m2jYQSiiItrzWuzmZ2A3ZyRXe1KZCt+bXQo0OIZbD4JbZK8acya",
        "fIgCYfsHeGI2Ha262CWtH8fsxULdo0L0HTH9ug1hmgbm9d2hEAHxnnBS1DrMwDN0XdFHgsCGZ1Kxv3QsHnICTiORhhfQHZo4QS8=",
        "fIgCYfsHdnkYGX73A0sB4MnpMBCJq/WSNYPEcm5lBCSwTP2AcX+ZTetC91NPDACbNZJsyPmQLmQxotmVpBEIDEMdJHspjJ8=",
        "fIgCYfsHdnkYGwc3LfQSX+YW3OSPg9kZ3DmGNf1GbHvgPc/6aI3sxzat+Uqay+xYyq1Yni4PwG7e+HDCeaDHTJo=",
        "fIgCYfsHdnkYFta8cTDBTO1JkKcDCc8AiFa+/skIN9d6rYV78XVcYabIB2gREf2H1xdY4qZW7PjmQPWYsebfAJ8=",
        "TIgCYZvuNnkYGVAH5ravJjp/R000KVJ2e9eSjq/6FImyU9CQM4VymTQerXIWs3BmcxBw",
        "TIgCYTzU+GXshxsCtHcXy5BNwBIpUJAYHL0O3pao7P+Pe8OAoIkDiTc9EvByWsz0XIk0Oxae",
        "TIgCYTzU9nVhrUk3a+fqZuFHBmRwoiLBpw2n4pZGhI7N6BluzST63paQUHCZcRK3Kg6KSA==",
        "TIgCYTzU9nkYGwc3ZEg94uNfGEKx77yFrdSuoyFhCvt3iBEx3Tpuucc9gYVQ9JHr+7kbRBsL",
        "TIgCYTzU9nkYGX4dz8khWZNg58E1syJMJtNbDT6QnDpHX6xSsqBiwHMJ9HS7iiniOkyS",
        "TIgCYTzU9nkYFr+yQP5VhT5+6fVJIy7DaX0VjKOm9247273nt7UQQmGttJYDd0IwEWw=",
        "TIgCYTzU+GXshwaACyfzL/wkizUxGfyFFfze2sOdbt0d0hb5V+ndkDisYZv5R8A=",
        "TIgCYTzU+GXsgti8NKncEg39ylvt7OcNvPaZKHEh0kGgeXWlB/A=",
        "TIgCYa8PjettdbXFXdaltbAvH9h8jidDjpDlIWLah2Hh7L0Zf4XsScGJ1RyY6o4wkIRazkh5yMOxHaFgftAkB5zubtEhn0su57d+6zkBzeIZLGaGXP0SPsljdyPinOP+mg02PYYwwD8=",
    ]

    static var packets: [Data] { encoded.compactMap { Data(base64Encoded: $0) } }

    // Original 440 Hz sine encoded with libopus using 10 ms stereo frames.
    static let tclPackets: [Data] = [
        "9HT6jwQUhsSIK5uYX2lXmIp/3C5SdaSqWOye7h2lgAAZlyOFJpAnlWO1Qoe7ejVt0HzCCxWW2H9+fIm0Q59D1evO66BzktB7s3T1G/JueGItF5DOHCHsxYix3b88gDTV/EY4W6LYwmz/YFXw/8PPXw==",
        "9K1Wyl2XFYIfeppfSukK0Z3uD9bmXzouc/KOgOatD5f0zTTwivyQv5tW4p8PD3XmY0W2gi9438EC+uV38Af/gqySJe4=",
        "9LEpema7dkvz4K9cj2FymHC5hs4oa7NZUIF+1oAXT/Bo0JteatIgJakj2TK5E+NyymHrobdm3/gFU3+T7g==",
        "9K0l4N63E6Ydu/Bg56JY7ExO/n1/wezEvJklmVUge3Gyx0c+5A1iaWV9AflTklmRqVQcOCMOJaR1AbY2fSiZYherVs0DeH4YftITMgBn7g==",
        "9K13KGSrxfK1L6shabA9bAmY96d3svUMEh4szqzl5WkbIZj41pxWQusWGG7GoNlYoDKF+NIJWxj/WZriWdkDn56m08kGfgCVtuwiI+4=",
        "9K13KYQcbKQm71mL/+aeZp8PnIvuv2/Wgy5dxfefrBd1U13Lk8YRf16gU/UnVXdPojbL5/mnrTxPjEhMeFoXpKQBG4EO0TF4gf4Bh/s3dmYj7g==",
        "9K0ldjVk+pQWvZwnLLE2+aZKCpypL3h75cfwROc7NLRu7Yfi/vLXs62WUwMtGvFGgu8ciMje7yyDaPU0TPRbz8fYh9G88BJgg35/mH/gfu/c7+4=",
        "9K0le9ktyAwFlj37ibGvmfJDJdy7LGjd317vW0A3n3zzeDCuL3BH6wFMpCex6kuBf+fwnV5tXlZZ4/oiCilXcWMQtTyjMOd8g3n+efpSNzLu7+4=",
        "9K0l4N7FB5/Q7qE7GRtOkOVPUPjkUqb0MeTsog7uaKEqStz7NJ8ZiL9q2/XQZdRhAfcyQmTZO3bjwhA2FSe4vIHj0Gr/344tA3h+Yf7SEzIAZ+4=",
        "9K13KGSrxfK1L8vJUNLzV+Sc0C98fJvILOj3RdXJrazS+G+zLWXXXuaWv77MNARu2zEy797/RtDfHKfm0XM97AQECBLRxjrFk8l4Z+BSVsm6IiPu",
        "9K13KYSNd6GCNShICwFnN7Hep5DDfAOkXChjUu/qDlZ8lNYnhMKa6/cWFmXNl0BOehaGg9YwpHtC8YirFTN1r4EpAEbgQ7ZHXiHn+AH/7M12ZiPu",
        "9K0ldjVk+pQWvaBm8to5C/bh53oQVU4pjdAluie4F8M6aT4i65yyCMLKoHXWOg5P2+EqnCmUX/I2Mrny/wGI2fYh3bkJiQiDeH+Yf+B+zdzN7g==",
        "9K0le9k4h1w2u60fqQbtbMdZmp4HAFyzDt2O/+7BYiCUm8BEJpI4f8OgPUR0YYl5B9a/6VL1SwFAdD9LuilXcWMQtTyjMOd8g3n+fnpSNzLu7+4=",
        "9K0l4N63D4n9B5VfSfJjQcQOkPu6TFoG6AGf9x8xYc+EunzvNPsDqslKahUgQx/tHbcSH+5qzsgrOK8eFSe4vIHj0Gr/344tA3h+YH7SEzIAZ+4=",
        "9K13KGSrxfK1L8vJUNLzV+Sc0C98s9rFZD3AoRZojt2/ncTslIW/831y8AWewQ2L7m/y/AQ5iSQ89HxRT/WRqAgQJalyed08kGfgUlbJuiIB7g==",
        "9K13KYSHmJWEjwfMP1ZsSrVc8N5F/4tmEYGdXrdbwQT6MFgHeDyGg+mp5gcz32YdSl2tcnsWGUt1VHzciVoXpKQBG4EO0TF4gf4B//s3dmYj7g==",
        "9K0ldjVk+pQWvaBm8to5C/bh53oQVU4hxsAluie4F8M4U2xfO04CEsTPjK1jtTKfbQo8tCY6Gk+xiqFny/wGI2fYh9G88Basg35/mH/gfs3c7+4=",
        "9K0le9ktyAwFonN76yj+X8sE69sGc929MzWFCzqjPnYXmkx3FPrLi4UL+TsjVmlC6uI+Y68azeBtIP6IgopbHrYxC1PKMw6eiDeZ/nn6Ujcy7u/u",
        "9K0l4N7FB5/Q7bATdZAFDhMr7XFGG5fWvrF705I5CPNBAq3ijsOAtbQZpTsCJCnB017BzekdeecAhRIGwqT3F5A8ehUx/fji0Df4fmH+0hMyAGfu",
        "tK13KGSrxfK2qfx1Whfs/1Te4qmUzIDuhQRLV3uSSgVTA0srKb1Dr7zA2Rnno/0jfp83p17hgSE+8zYufJUszajC7izMfK5TyRn+BSV3M7oiAe4=",
        "tK13KYSNd6A8xNmQrD3dl4zw2HH3IDVtD34TgXqNvghSHWu0EgF5j0DB1Z1X/3lU9K+LgcJBdvdGwd4ke5cVdkQPL2KddeIf6gH/7M12ZiPu",
        "tK0lBn4dMXwwxBSbm3yrFqCar+D5jJFSrExlSdqjM0YC+PhgEOGB+S51nNsuw8ZBvkcARKWt7SJEr1hQky3vY/ox8QG2hIN5/mH/tgDN3O/u",
        "tHx1lPZTnLHJMNDK7DYFvDAqhtF/UV6ijGEGgLI7LHIAChVSMF84EgoNvWNx0TBgydh7OUL4Xyh1AyJ/PMtfKzQfw3yQC7RuURS7dIhRcuUu7jvG5wWMM6aGgtnFDgyERy4fQz8m2gS8BVpQzveRaw==",
    ].compactMap { Data(base64Encoded: $0) }

    static func datagram(sequence: UInt16, timestamp: UInt32, payload: Data,
                         profile: ListeningRTPProfile = .fixture) -> Data {
        Data([0x80, profile.payloadType, UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence),
              UInt8(truncatingIfNeeded: timestamp >> 24), UInt8(truncatingIfNeeded: timestamp >> 16),
              UInt8(truncatingIfNeeded: timestamp >> 8), UInt8(truncatingIfNeeded: timestamp),
              0, 0, 0, 1]) + payload
    }

    static func decode(using decoder: ListeningOpusDecoder) throws -> AVAudioPCMBuffer {
        guard let clip = AVAudioPCMBuffer(pcmFormat: decoder.pcmFormat, frameCapacity: 48_000),
              let destination = clip.floatChannelData else { throw ListeningError.unsupportedFormat }
        var pipeline = ListeningDatagramPipeline(firstSequence: 0, source: 1, decoder: decoder)
        for (index, packet) in packets.enumerated() {
            try pipeline.receive(datagram(sequence: UInt16(index), timestamp: UInt32(index * 960), payload: packet))
            guard let decoded = try pipeline.next() else { throw ListeningError.invalidPacket }
            guard decoded.frameLength <= clip.frameCapacity - clip.frameLength,
                  let source = decoded.floatChannelData else { throw ListeningError.decodingFailed }
            for channel in 0..<Int(clip.format.channelCount) {
                destination[channel].advanced(by: Int(clip.frameLength))
                    .update(from: source[channel], count: Int(decoded.frameLength))
            }
            clip.frameLength += decoded.frameLength
        }
        return clip
    }
}

// No reuse flags: an existing application on the port wins. Bind only to loopback.
final class ListeningUDPSocket {
    private var descriptor: Int32 = -1
    private(set) var port: UInt16?

    func start(port: UInt16 = 6970, localIP: String = "127.0.0.1") throws {
        guard descriptor == -1 else { throw Failure(operation: "already started", code: EALREADY) }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure(operation: "socket", code: errno) }
        do {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Failure(operation: "fcntl", code: errno) }
            var address = try Self.endpoint(localIP, port)
            guard Self.withAddress(&address, { Darwin.bind(fd, $0, $1) }) == 0 else {
                throw Failure(operation: "bind UDP \(localIP):\(port)", code: errno)
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let status = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard status == 0 else { throw Failure(operation: "getsockname", code: errno) }
            descriptor = fd
            self.port = UInt16(bigEndian: address.sin_port)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func stop() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
        port = nil
    }

    deinit { stop() }

    func receive(from peer: String? = nil) throws -> Data? {
        guard descriptor >= 0 else { throw Failure(operation: "receive before start", code: EBADF) }
        // One extra byte distinguishes oversize input from valid maximum-size packets.
        var bytes = [UInt8](repeating: 0, count: 2049)
        var source = Self.loopback(0)
        let count = Self.withMutableAddress(&source) { pointer, length in
            bytes.withUnsafeMutableBytes { Darwin.recvfrom(descriptor, $0.baseAddress, $0.count, 0, pointer, length) }
        }
        if count >= 0 {
            if let peer, try Self.endpoint(peer, 0).sin_addr.s_addr != source.sin_addr.s_addr { return nil }
            return Data(bytes.prefix(count))
        }
        let code = errno
        if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { return nil }
        throw Failure(operation: "receive", code: code)
    }

    func send(_ data: Data, to ip: String, port: UInt16) throws {
        var address = try Self.endpoint(ip, port)
        let sent = Self.withAddress(&address) { endpoint, length in
            data.withUnsafeBytes { Darwin.sendto(descriptor, $0.baseAddress, $0.count, 0, endpoint, length) }
        }
        guard sent == data.count else { throw Failure(operation: "send UDP", code: errno) }
    }

    private static func endpoint(_ ip: String, _ port: UInt16) throws -> sockaddr_in {
        var address = loopback(port)
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else {
            throw Failure(operation: "invalid IPv4 endpoint", code: EINVAL)
        }
        return address
    }

    private static func withMutableAddress<T>(
        _ address: inout sockaddr_in, _ body: (UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> T
    ) -> T {
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        return withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, &length) }
        }
    }

    // Only the generated fixture uses this sender. No remote addresses are accepted.
    static func sendFixture(_ data: Data, port: UInt16) throws {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure(operation: "sender socket", code: errno) }
        defer { Darwin.close(fd) }
        var address = loopback(port)
        let sent = withAddress(&address) { endpoint, length in
            data.withUnsafeBytes { Darwin.sendto(fd, $0.baseAddress, $0.count, 0, endpoint, length) }
        }
        guard sent == data.count else { throw Failure(operation: "send loopback fixture", code: errno) }
    }

    private static func loopback(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        return address
    }

    private static func withAddress<T>(_ address: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    struct Failure: LocalizedError {
        let operation: String
        let code: Int32
        var errorDescription: String? { "\(operation): \(String(cString: strerror(code))) (\(code))" }
    }
}

// RFC 3550 compound RTCP for the synthetic transport fixture. No Roku APP messages.
enum ListeningFixtureRTCP {
    enum Kind: Equatable { case report, goodbye }

    static func packet(source: UInt32, goodbye: Bool = false) -> Data {
        let identifier = withUnsafeBytes(of: source.bigEndian) { Array($0) }
        let name = Array("roku-visor-fixture".utf8)
        var chunk = identifier + [1, UInt8(name.count)] + name + [0]
        while !chunk.count.isMultiple(of: 4) { chunk.append(0) }
        let words = UInt16(chunk.count / 4)
        var bytes: [UInt8] = [0x80, 201, 0, 1] + identifier
        bytes += [0x81, 202, UInt8(words >> 8), UInt8(truncatingIfNeeded: words)] + chunk
        if goodbye { bytes += [0x81, 203, 0, 1] + identifier }
        return Data(bytes)
    }

    // Validate this fixture's strict RR/SDES[/BYE] contract, not arbitrary peer RTCP.
    static func validate(_ data: Data, source: UInt32) throws -> Kind {
        if data == packet(source: source) { return .report }
        if data == packet(source: source, goodbye: true) { return .goodbye }
        throw ListeningError.invalidPacket
    }
}

@MainActor
enum ListeningUDPDiagnostic {
    static let receiver = "--experimental-listening-udp"
    static let fixture = "--experimental-listening-udp-fixture"
    static let tclFixture = "--experimental-listening-udp-tcl-fixture"
    static let mediaFixture = "--experimental-listening-media-fixture"

    static func profile(for command: String) -> ListeningRTPProfile? {
        switch command {
        case receiver, fixture: .fixture
        case tclFixture, mediaFixture: .tcl
        default: nil
        }
    }

    static func run(port: UInt16, seconds: Int, generate: Bool, volume: Int, profile: ListeningRTPProfile, includeControl: Bool = false) throws {
        let socket = ListeningUDPSocket()
        try socket.start(port: port)
        defer { socket.stop() }
        guard let boundPort = socket.port else { throw ListeningError.invalidPacket }
        let control = includeControl ? ListeningUDPSocket() : nil
        try control?.start(port: 0)
        defer { control?.stop() }
        let decoder = try ListeningOpusDecoder()
        let output = ListeningAudioOutput(format: decoder.pcmFormat)
        defer { output.stop() }
        let clock = ContinuousClock()
        let interrupted = DispatchSemaphore(value: 0)
        let oldHandler = signal(SIGINT, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interruptSource.setEventHandler { interrupted.signal() }
        interruptSource.resume()
        defer {
            interruptSource.cancel()
            _ = signal(SIGINT, oldHandler)
        }
        let start = clock.now
        let deadline = start + .seconds(seconds)
        print("Listening on 127.0.0.1:\(boundPort); loopback RTP only (PT \(profile.payloadType), clock \(profile.timestampRate) Hz).")
        var nextSend = start
        var nextReport = start + .seconds(1)
        var controlReports = 0
        let feedbackSource: UInt32 = 2
        var nextFrame = start + .milliseconds(80)
        let packets = profile.fixturePackets
        var sequence: UInt16 = 0
        var timestamp: UInt32 = 0
        var pipeline: ListeningDatagramPipeline?
        var received = 0, accepted = 0, duplicates = 0, rejected = 0
        var frames = 0, underruns = 0, outputDrops = 0
        var lastArrival: (ContinuousClock.Instant, UInt32)?
        var jitterMilliseconds = 0.0
        var terminalError: Error?
        do {
            while clock.now < deadline, interrupted.wait(timeout: .now()) == .timedOut {
                let now = clock.now
                if generate, now >= nextSend {
                    let packet = packets[Int(sequence) % packets.count]
                    try ListeningUDPSocket.sendFixture(
                        ListeningToneFixture.datagram(sequence: sequence, timestamp: timestamp, payload: packet, profile: profile), port: boundPort)
                    sequence &+= 1
                    timestamp &+= UInt32(profile.nominalMilliseconds * profile.timestampRate / 1000)
                    nextSend = max(now, nextSend + .milliseconds(profile.nominalMilliseconds))
                }
                if let control, let controlPort = control.port, now >= nextReport {
                    try ListeningUDPSocket.sendFixture(ListeningFixtureRTCP.packet(source: feedbackSource), port: controlPort)
                    nextReport = now + .seconds(1)
                }
                for _ in 0..<8 {
                    guard let feedback = try control?.receive() else { break }
                    if try ListeningFixtureRTCP.validate(feedback, source: feedbackSource) == .report {
                        controlReports += 1
                    }
                }
                for _ in 0..<32 {
                    guard let data = try socket.receive() else { break }
                    received += 1
                    do {
                        let packet = try ListeningRTPPacket(datagram: data, expectedType: profile.payloadType,
                                                            expectedSource: profile == .fixture ? 1 : nil)
                        if pipeline == nil {
                            pipeline = ListeningDatagramPipeline(firstSequence: packet.sequence, profile: profile,
                                                                source: packet.source, decoder: decoder)
                            nextFrame = now + .milliseconds(80)
                        }
                        switch try pipeline?.receive(packet) {
                        case .accepted:
                            accepted += 1
                            let arrival = clock.now
                            if let (priorTime, priorStamp) = lastArrival {
                                let step = packet.timestamp &- priorStamp
                                if step > 0, step <= UInt32(profile.timestampRate) {
                                    let elapsed = priorTime.duration(to: arrival).components
                                    let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                                    jitterMilliseconds += (abs(milliseconds - Double(step) * 1000 / Double(profile.timestampRate)) - jitterMilliseconds) / 16
                                    lastArrival = (arrival, packet.timestamp)
                                }
                            } else {
                                lastArrival = (arrival, packet.timestamp)
                            }
                        case .duplicate: duplicates += 1
                        case .outsideWindow, nil: rejected += 1
                        }
                    } catch { rejected += 1 }
                }
                if pipeline != nil, now >= nextFrame {
                    var pcm: AVAudioPCMBuffer?
                    do { pcm = try pipeline?.next(concealExpiredGap: true) }
                    catch { rejected += 1 }
                    if let pcm {
                        if output.state == .stopped { try output.startStream(volume: volume) }
                        frames += Int(pcm.frameLength)
                        if try !output.enqueue(pcm) { outputDrops += 1 }
                    } else if output.state == .playing { underruns += 1 }
                    let ticks = Int64(pcm?.frameLength ?? AVAudioFrameCount(profile.nominalFrames))
                    nextFrame += .nanoseconds(ticks * 1_000_000_000 / 48_000)
                    if nextFrame < now - .milliseconds(80) { nextFrame = now }
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
            }
        } catch { terminalError = error }
        let elapsed = start.duration(to: clock.now).components
        let beforeDrain = output.counts.pending
        if terminalError == nil {
            do { try output.drainStream() } catch { terminalError = error }
        }
        if let control, let controlPort = control.port, terminalError == nil {
            do {
                try ListeningUDPSocket.sendFixture(ListeningFixtureRTCP.packet(source: feedbackSource, goodbye: true), port: controlPort)
                var sawGoodbye = false
                let limit = clock.now + .milliseconds(100)
                while clock.now < limit && !sawGoodbye {
                    if let feedback = try control.receive() {
                        switch try ListeningFixtureRTCP.validate(feedback, source: feedbackSource) {
                        case .report: controlReports += 1
                        case .goodbye: sawGoodbye = true
                        }
                    } else {
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
                    }
                }
                guard sawGoodbye else { throw ListeningError.playbackTimeout }
                print("Loopback RTCP: \(controlReports) receiver reports and one goodbye validated.")
            } catch { terminalError = error }
        }
        let playback = output.counts
        print("Audio: decoded \(frames) PCM frames; submitted \(playback.frames), scheduled \(playback.scheduled) buffers, playback callbacks \(playback.completed), pending at shutdown \(beforeDrain) → \(playback.pending), engine running \(output.engineRunning), player playing \(output.playerPlaying), volume \(volume)%, error \(terminalError?.localizedDescription ?? "none").")
        let secondsElapsed = max(0.001, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        print("Stopped. UDP \(received) (\(String(format: "%.1f", Double(received) / secondsElapsed))/s), accepted \(accepted), rejected \(rejected), duplicates \(duplicates), concealed gaps \(pipeline?.gaps ?? 0), estimated jitter \(String(format: "%.2f", jitterMilliseconds)) ms, PCM frames \(frames), underrun ticks \(underruns), output queue drops \(outputDrops).")
        if let terminalError { throw terminalError }
    }
}
#endif

#if EXPERIMENTAL_LISTENING
// These probes use fresh, cookie-free sessions and send no WebSocket application frames.
final class ListeningSessionProbe: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Subprotocol: Equatable {
        case ecp2, absent, unexpected

        init(_ value: String?) {
            switch value {
            case "ecp-2": self = .ecp2
            case nil: self = .absent
            default: self = .unexpected
            }
        }
    }

    enum Challenge: Equatable {
        case present, malformed, unexpected

        static func classify(_ message: URLSessionWebSocketTask.Message) -> Self {
            guard case .string(let text) = message else { return .unexpected }
            let data = Data(text.utf8)
            guard data.count <= 4096,
                  let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .malformed
            }
            guard fields["notify"] as? String == "authenticate" else { return .unexpected }
            guard let challenge = fields["param-challenge"] as? String, !challenge.isEmpty,
                  let decoded = Data(base64Encoded: challenge), !decoded.isEmpty else { return .malformed }
            return .present
        }

        var description: String {
            switch self {
            case .present: "authentication challenge observed (value redacted)"
            case .malformed: "malformed first WebSocket message or challenge"
            case .unexpected: "first WebSocket message was not an authentication challenge"
            }
        }
    }

    enum Outcome: Equatable {
        case http(Int, Data)
        case upgraded(selected: Subprotocol)
        case challenge(Challenge)
        case closed(Int)
        case failure(Int)
        case timeout

        var description: String {
            switch self {
            case .http(let code, _): "HTTP \(code)"
            case .upgraded(.ecp2): "upgrade accepted; ECP-2 selected"
            case .upgraded(.absent): "upgrade accepted; no subprotocol selected"
            case .upgraded(.unexpected): "upgrade accepted; unexpected subprotocol selected"
            case .challenge(let result): "ECP-2 selected; \(result.description)"
            case .closed(let code): "WebSocket closed (\(code))"
            case .failure(let code): "URLSession error \(code)"
            case .timeout: "timed out"
            }
        }
    }

    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var outcome: Outcome?
    private let observeChallenge: Bool

    init(observeChallenge: Bool = false) {
        self.observeChallenge = observeChallenge
    }

    func finish(_ result: Outcome) {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == nil else { return }
        outcome = result
        completed.signal()
    }

    func wait(timeout: DispatchTime, cleanup: () -> Void) -> Outcome {
        defer { cleanup() }
        if completed.wait(timeout: timeout) == .timedOut { finish(.timeout) }
        lock.lock()
        defer { lock.unlock() }
        return outcome ?? .timeout
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let response = challenge.failureResponse as? HTTPURLResponse {
            finish(.http(response.statusCode, Data()))
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol selectedProtocol: String?) {
        let selected = Subprotocol(selectedProtocol)
        guard observeChallenge, selected == .ecp2 else {
            finish(.upgraded(selected: selected))
            return
        }
        webSocketTask.receive { [self] result in
            switch result {
            case .success(let message):
                finish(.challenge(Challenge.classify(message)))
            case .failure(let error as URLError):
                finish(error.code == .timedOut ? .timeout : .failure(error.errorCode))
            case .failure(let error):
                finish(.failure((error as NSError).code))
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(.closed(closeCode.rawValue))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task is URLSessionWebSocketTask else { return }
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            finish(.http(response.statusCode, Data()))
        } else if let error = error as? URLError {
            finish(error.code == .timedOut ? .timeout : .failure(error.errorCode))
        } else {
            finish(.closed((task as? URLSessionWebSocketTask)?.closeCode.rawValue ?? 0))
        }
    }

    static let command = "--experimental-listening-session-probe"
    static let authCommand = "--experimental-listening-auth-probe"

    static func localAddress(_ input: String) -> String? {
        guard let address = RokuAddress.ipv4(input) else { return nil }
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        switch (octets[0], octets[1]) {
        case (10, _), (172, 16...31), (192, 168), (169, 254): return address
        default: return nil
        }
    }

    static func request(address: String, path: String, websocket: Bool = false, observeChallenge: Bool = false) -> Outcome {
        let probe = ListeningSessionProbe(observeChallenge: observeChallenge)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config, delegate: probe, delegateQueue: nil)
        var url = URLComponents()
        url.scheme = websocket ? "ws" : "http"
        url.host = address
        url.port = 8060
        url.path = path
        guard let endpoint = url.url else {
            session.invalidateAndCancel()
            return .failure(URLError.badURL.rawValue)
        }
        let task: URLSessionTask
        if websocket {
            let socket = session.webSocketTask(with: endpoint, protocols: ["ecp-2"])
            if observeChallenge { socket.maximumMessageSize = 4096 }
            task = socket
        } else {
            task = session.dataTask(with: endpoint) { data, response, error in
                if let response = response as? HTTPURLResponse {
                    probe.finish(.http(response.statusCode, data ?? Data()))
                } else if let error = error as? URLError {
                    probe.finish(error.code == .timedOut ? .timeout : .failure(error.errorCode))
                } else {
                    probe.finish(.failure(URLError.badServerResponse.rawValue))
                }
            }
        }
        task.resume()
        return probe.wait(timeout: .now() + 3) {
            if let socket = task as? URLSessionWebSocketTask, probe.finalResultIsUpgrade {
                socket.cancel(with: .normalClosure, reason: nil)
                session.finishTasksAndInvalidate()
            } else {
                session.invalidateAndCancel()
            }
        }
    }

    private var finalResultIsUpgrade: Bool {
        lock.lock()
        defer { lock.unlock() }
        switch outcome {
        case .upgraded, .challenge: return true
        default: return false
        }
    }

    static func runAuthProbe(address: String) {
        let result = request(address: address, path: "/ecp-session", websocket: true, observeChallenge: true)
        print("ECP-2 challenge probe: \(result.description).")
        print("Authentication: no response sent. A verified authorization method for independent clients is missing.")
        print("Shutdown: closed locally; no audio session requested.")
    }

    static func run(address: String) {
        let device = request(address: address, path: "/query/device-info")
        print("ECP: \(device.description)")
        let information: RokuDevice?
        if case .http(200, let data) = device, data.count <= 262_144 {
            information = try? DeviceInfo.parse(data, address: address)
        } else {
            information = nil
        }
        if let info = information {
            print("Device capabilities: Roku device-info validated; \(info.isTV ? "TV" : "streaming device").")
        } else {
            print("Device capabilities: Roku device-info could not be validated.")
        }
        if information != nil {
            let audio = request(address: address, path: "/query/audio-device")
            if case .http(200, let data) = audio, data.count <= 262_144,
               let xml = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
               let root = xml.rootElement() {
                let advertised = (try? root.nodes(forXPath: ".//all-destinations")) ?? []
                print("Audio capability: HTTP 200; datagram destination \(advertised.contains { ($0.stringValue ?? "").lowercased().contains("datagram") } ? "advertised" : "not identified").")
            } else {
                print("Audio capability: \(audio.description); no capability established.")
            }
            let upgrade = request(address: address, path: "/ecp-session", websocket: true)
            print("WebSocket (offered ecp-2): \(upgrade.description).")
        } else {
            print("Audio capability and WebSocket: skipped because Roku device-info could not be validated.")
        }
        print("Authentication: not attempted; no independently verified authorization flow.")
        print("Listening session: not established. RTP packets received: 0. Audio playback: inactive.")
        print("Shutdown: probe cancelled locally; no TV audio settings changed. Peer closure not verified.")
    }
}

// Wire format reference: Roam audio-protocol.md, Scott Driggers.
// Independently implemented. See Docs/Third-Party-Notices.md for the project-specific grant.
enum RokuListeningControl {
    case delay, version, report, goodbye

    var data: Data {
        switch self {
        case .delay: Data([128, 204, 0, 3, 0, 0, 0, 0, 86, 68, 76, 89, 0, 9, 39, 192])
        case .version: Data([128, 204, 0, 3, 0, 0, 0, 0, 67, 86, 69, 82, 0, 0, 0, 2])
        case .report: Data([128, 201, 0, 1, 0, 0, 0, 0])
        case .goodbye: Data([129, 203, 0, 1, 0, 0, 0, 0])
        }
    }

    func acknowledges(_ datagram: Data) -> Bool {
        let expected: [UInt8]
        switch self {
        case .delay: expected = [88, 68, 76, 89, 0, 9, 39, 192]
        case .version: expected = [78, 67, 76, 73]
        default: return false
        }
        let bytes = Array(datagram)
        var offset = 0
        var matched = false
        while offset + 4 <= bytes.count {
            let length = (1 + Int(bytes[offset + 2]) * 256 + Int(bytes[offset + 3])) * 4
            guard bytes[offset] >> 6 == 2, offset + length <= bytes.count else { return false }
            if bytes[offset] == 128, bytes[offset + 1] == 204, length == 8 + expected.count,
               bytes[(offset + 4)..<(offset + 8)].allSatisfy({ $0 == 0 }),
               bytes[(offset + 8)..<(offset + length)].elementsEqual(expected) { matched = true }
            offset += length
        }
        return offset == bytes.count && matched
    }
}

enum RokuListeningRouting {
    static func start(id: String, address: String, port: UInt16) -> [String: String] {
        ["request": "set-audio-output", "request-id": id, "param-audio-output": "datagram",
         "param-devname": "\(address):\(port):97:960"]
    }

    static func accepted(_ response: [String: String], request: [String: String]) -> Bool {
        response["response"] == request["request"] &&
        response["response-id"] == request["request-id"] && response["status"] == "200"
    }
}

@MainActor
protocol RokuListeningConnection: AnyObject {
    // The provider supplies the route selected by its connected ECP socket.
    var localIPv4: String { get }
    var remoteRTCPPort: UInt16 { get }
    // Return only after the peer confirms authentication. Operations must be bounded
    // and honor cancellation. Requests return the correlated ECP response envelope.
    func authenticate() async throws
    func request(_ fields: [String: String]) async throws -> [String: String]
    // Restore the previously selected output using the provider's verified protocol.
    // Return true only on a confirmed acknowledgment.
    func restoreAudio() async throws -> Bool
    func close()
}

@MainActor
protocol RokuListeningAuthenticationProvider {
    func connect(address: String) async throws -> any RokuListeningConnection
}

@MainActor
final class RokuPrivateListening: ObservableObject {
    enum State: Equatable {
        case off, connecting, authenticating, negotiating, listening, stopping, failed(String)

        var label: String {
            switch self {
            case .off: "Off"
            case .connecting: "Connecting"
            case .authenticating: "Authenticating"
            case .negotiating: "Negotiating audio"
            case .listening: "Listening"
            case .stopping: "Stopping"
            case .failed(let message): message
            }
        }
    }

    @Published private(set) var state = State.off
    private let provider: (any RokuListeningAuthenticationProvider)?
    private var task: Task<Void, Never>?
    private var stopRequested = false

    private let rtpPort: UInt16
    private let rtcpPort: UInt16

    init(provider: (any RokuListeningAuthenticationProvider)? = nil, rtpPort: UInt16 = 6970, rtcpPort: UInt16 = 6971) {
        self.provider = provider
        self.rtpPort = rtpPort
        self.rtcpPort = rtcpPort
    }

    var active: Bool { task != nil }

    func start(address: String) {
        guard task == nil else { return }
        guard let provider else {
            state = .failed("Live audio requires an authorized authentication provider.")
            return
        }
        stopRequested = false
        state = .connecting
        task = Task { await run(address: address, provider: provider) }
    }

    func stop() {
        guard task != nil else { return }
        stopRequested = true
        state = .stopping
    }

    func waitUntilStopped() async {
        await task?.value
    }

    private func checkStop() throws {
        if stopRequested { throw CancellationError() }
    }

    private func run(address: String, provider: any RokuListeningAuthenticationProvider) async {
        var connection: (any RokuListeningConnection)?
        var routingAttempted = false
        var negotiated = false
        var failure: String?
        let rtp = ListeningUDPSocket()
        let rtcp = ListeningUDPSocket()
        let feedback = ListeningUDPSocket()
        var output: ListeningAudioOutput?
        do {
            try checkStop()
            let channel = try await provider.connect(address: address)
            connection = channel
            try checkStop()
            state = .authenticating
            try await channel.authenticate()
            try checkStop()
            state = .negotiating
            let decoder = try ListeningOpusDecoder()
            let audio = ListeningAudioOutput(format: decoder.pcmFormat)
            output = audio
            try rtp.start(port: rtpPort, localIP: channel.localIPv4)
            try rtcp.start(port: rtcpPort, localIP: channel.localIPv4)
            try feedback.start(port: 0, localIP: channel.localIPv4)
            guard let boundRTPPort = rtp.port else { throw ListeningError.invalidPacket }
            let request = RokuListeningRouting.start(id: UUID().uuidString, address: channel.localIPv4, port: boundRTPPort)
            routingAttempted = true
            let response = try await channel.request(request)
            if response["response"] == request["request"], response["response-id"] == request["request-id"],
               let status = response["status"], status != "200" {
                routingAttempted = false
            }
            guard RokuListeningRouting.accepted(response, request: request) else { throw Failure.routing }
            try await negotiate(.delay, receive: rtcp, send: feedback, address: address, port: channel.remoteRTCPPort)
            try await negotiate(.version, receive: rtcp, send: feedback, address: address, port: channel.remoteRTCPPort)
            negotiated = true
            try await play(receive: rtp, send: feedback, address: address, port: channel.remoteRTCPPort,
                           decoder: decoder, output: audio)
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
        output?.stop()
        if let connection, routingAttempted {
            if negotiated { try? feedback.send(RokuListeningControl.goodbye.data, to: address, port: connection.remoteRTCPPort) }
            if (try? await connection.restoreAudio()) != true {
                failure = [failure, "TV audio restoration was not confirmed."].compactMap { $0 }.joined(separator: " ")
            }
        }
        rtp.stop()
        rtcp.stop()
        feedback.stop()
        connection?.close()
        state = failure.map(State.failed) ?? .off
        task = nil
    }

    private func negotiate(_ control: RokuListeningControl, receive: ListeningUDPSocket, send: ListeningUDPSocket,
                           address: String, port: UInt16) async throws {
        for _ in 0..<3 {
            try checkStop()
            try send.send(control.data, to: address, port: port)
            let deadline = ContinuousClock.now + .seconds(1)
            while ContinuousClock.now < deadline {
                try checkStop()
                if let data = try receive.receive(from: address), control.acknowledges(data) { return }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        throw Failure.negotiation
    }

    private func play(receive: ListeningUDPSocket, send: ListeningUDPSocket, address: String, port: UInt16,
                      decoder: ListeningOpusDecoder, output: ListeningAudioOutput) async throws {
        var pipeline: ListeningDatagramPipeline?
        var lastPacket = ContinuousClock.now
        var nextFrame = lastPacket
        var nextReport = lastPacket
        while true {
            try checkStop()
            let now = ContinuousClock.now
            if now >= nextReport {
                try send.send(RokuListeningControl.report.data, to: address, port: port)
                nextReport = now + .seconds(1)
            }
            for _ in 0..<32 {
                guard let data = try receive.receive(from: address) else { break }
                guard let packet = try? ListeningRTPPacket(datagram: data, expectedType: 97, expectedSource: nil) else { continue }
                if pipeline == nil {
                    pipeline = ListeningDatagramPipeline(firstSequence: packet.sequence, profile: .tcl,
                                                        source: packet.source, decoder: decoder)
                    nextFrame = now + .milliseconds(80)
                }
                if (try? pipeline?.receive(packet)) == .accepted { lastPacket = now }
            }
            if now - lastPacket > .seconds(4) { throw Failure.interrupted }
            if now >= nextFrame, pipeline != nil {
                let buffer = try pipeline?.next(concealExpiredGap: true)
                if let buffer {
                    if output.state == .stopped { try output.startStream(volume: ListeningVolume().percent) }
                    _ = try output.enqueue(buffer)
                    if output.counts.completed > 0 { state = .listening }
                }
                let frames = Int64(buffer?.frameLength ?? 480)
                nextFrame = max(nextFrame + .nanoseconds(frames * 1_000_000_000 / 48_000), now)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private enum Failure: LocalizedError {
        case routing, negotiation, interrupted
        var errorDescription: String? {
            switch self {
            case .routing: "The TV did not acknowledge the audio route."
            case .negotiation: "The TV did not acknowledge RTCP negotiation."
            case .interrupted: "The TV audio stream timed out."
            }
        }
    }
}
#endif
