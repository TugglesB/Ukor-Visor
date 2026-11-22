#if EXPERIMENTAL_LISTENING
import AVFoundation
#endif
import AppKit
import XCTest

final class RokuVisorTests: XCTestCase {
    private let tv = RokuDevice(address: "192.168.1.25", name: "Living Room", serial: "R001", isTV: true)
    private let player = RokuDevice(address: "10.0.0.9", name: "Stick", serial: nil, isTV: false)

    func testCommandMap() throws {
        let expected: [RokuKey: String] = [
            .up: "Up", .down: "Down", .left: "Left", .right: "Right", .ok: "Select", .home: "Home",
            .back: "Back", .play: "Play", .options: "Info", .quieter: "VolumeDown",
            .louder: "VolumeUp", .power: "PowerOff", .rewind: "Rev", .fastForward: "Fwd"
        ]
        XCTAssertEqual(Set(expected.keys).union([.stop]), Set(RokuKey.allCases))
        for (key, name) in expected { XCTAssertEqual(try key.command(for: tv), name) }
        XCTAssertEqual(try RokuKey.home.command(for: player), "Home")
    }

    func testUnsupportedKeysNeverReachTransport() async {
        let client = RokuClient { _ in XCTFail("Unsupported keys must not make requests"); throw RokuError.invalidResponse }
        for (key, device) in [(RokuKey.stop, tv), (.stop, player), (.power, player), (.louder, player), (.quieter, player)] {
            do {
                try await client.send(command: key.command(for: device), to: device)
                XCTFail("Expected unsupported")
            } catch {
                XCTAssertEqual(error as? RokuError, .unsupported)
            }
        }
    }

    func testRequestConstruction() throws {
        let query = try RokuClient.request(address: " 192.168.1.25 ")
        XCTAssertEqual(query.url?.absoluteString, "http://192.168.1.25:8060/query/device-info")
        XCTAssertEqual(query.httpMethod, "GET")
        let key = try RokuClient.request(address: tv.address, command: "Info")
        XCTAssertEqual(key.url?.absoluteString, "http://192.168.1.25:8060/keypress/Info")
        XCTAssertEqual(key.httpMethod, "POST")
        XCTAssertEqual(key.timeoutInterval, 2.5)
        XCTAssertThrowsError(try RokuClient.request(address: "192.168.1.25:8060/evil"))
        XCTAssertThrowsError(try RokuClient.request(address: "192.168.1.25\0suffix"))
    }

    func testRokuKeyboardSendsLiteralTextAndEditingCommandsInOrder() async throws {
        let recorder = RequestLog()
        let client = RokuClient { request in
            await recorder.record(request)
            return (Data(), Self.response(request, 200))
        }

        for input in [RokuKeyboardInput.text("a /?%é"), .backspace, .select] {
            for command in try input.commands() {
                try await client.send(command: command, to: tv)
            }
        }

        let requests = await recorder.requests
        XCTAssertEqual(requests.compactMap { $0.url?.absoluteString }, [
            "Lit_a", "Lit_%20", "Lit_%2F", "Lit_%3F", "Lit_%25", "Lit_%C3%A9", "Backspace", "Select"
        ].map { "http://192.168.1.25:8060/keypress/\($0)" })
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" })
    }

    func testInvalidRokuTextDoesNotProduceCommands() {
        for text in ["", "first\nsecond", "a\tb"] {
            XCTAssertThrowsError(try RokuKeyboardInput.text(text).commands()) { error in
                XCTAssertEqual(error as? RokuError, .invalidKeyboardText)
            }
        }
    }

    func testMacReturnAndEnterMatchTheRokuOKButton() throws {
        for code: UInt16 in [36, 76] {
            let input = try XCTUnwrap(RokuKeyboardInput.macKey(code: code, characters: "\r", isRepeat: false))
            XCTAssertEqual(try input.commands(), [try RokuKey.ok.command(for: tv)])
            XCTAssertNil(RokuKeyboardInput.macKey(code: code, characters: "\r", isRepeat: true))
        }
    }

    func testMacDeleteKeysBackspaceAndPrintableKeysTypeDirectly() throws {
        for code: UInt16 in [51, 117] {
            let input = try XCTUnwrap(RokuKeyboardInput.macKey(code: code, characters: nil, isRepeat: true))
            XCTAssertEqual(try input.commands(), ["Backspace"])
        }
        let a = try XCTUnwrap(RokuKeyboardInput.macKey(code: 0, characters: "A", isRepeat: false))
        XCTAssertEqual(try a.commands(), ["Lit_A"])
        let space = try XCTUnwrap(RokuKeyboardInput.macKey(code: 49, characters: " ", isRepeat: false))
        XCTAssertEqual(try space.commands(), ["Lit_ "])
        XCTAssertNil(RokuKeyboardInput.macKey(code: 123, characters: "\u{F702}", isRepeat: false))
    }

    func testDiscoveryParsing() {
        let response = "HTTP/1.1 200 OK\r\nST: roku:ecp\r\nLocation: http://192.168.1.25:8060/\r\n\r\n"
        XCTAssertEqual(Discovery.address(from: response), tv.address)
        XCTAssertNil(Discovery.address(from: response.replacingOccurrences(of: "roku:ecp", with: "other")))
        XCTAssertNil(Discovery.address(from: response.replacingOccurrences(of: "8060", with: "80")))
        XCTAssertNil(Discovery.address(from: response.replacingOccurrences(of: "192.168.1.25", with: "127.0.0.1")))
        XCTAssertNil(Discovery.address(from: "NOTIFY * HTTP/1.1\r\n" + response))
    }

    func testIdentifyFromMockXML() async throws {
        let client = RokuClient { request in
            XCTAssertEqual(request.url?.path, "/query/device-info")
            let xml = "<device-info><user-device-name>Living Room</user-device-name><serial-number>R001</serial-number><is-tv>true</is-tv></device-info>"
            return (Data(xml.utf8), Self.response(request, 200))
        }
        let device = try await client.identify(tv.address)
        XCTAssertEqual(device, tv)
        XCTAssertThrowsError(try DeviceInfo.parse(Data("<html/>".utf8), address: tv.address))
    }

    func testPowerButtonUsesLivePowerModeForOnAndOff() async throws {
        for (reported, expected, path) in [
            ("PowerOn", RokuPowerMode.standby, "/keypress/PowerOff"),
            ("Ready", .on, "/keypress/PowerOn"),
            ("DisplayOff", .on, "/keypress/PowerOn")
        ] {
            let recorder = RequestLog()
            let client = RokuClient { request in
                await recorder.record(request)
                let body = "<device-info><serial-number>R001</serial-number><is-tv>true</is-tv><power-mode>\(reported)</power-mode></device-info>"
                return (Data(body.utf8), Self.response(request, 200))
            }
            let target = try await client.togglePower(on: tv, assumeOn: true)
            XCTAssertEqual(target, expected)
            let requests = await recorder.requests
            XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/query/device-info", path])
            XCTAssertEqual(requests.last?.httpMethod, "POST")
        }
    }

    func testPowerButtonAttemptsWakeWhenStandbyProbeTimesOut() async throws {
        let recorder = RequestLog()
        let client = RokuClient { request in
            await recorder.record(request)
            if request.url?.path == "/query/device-info" { throw URLError(.timedOut) }
            return (Data(), Self.response(request, 200))
        }
        let target = try await client.togglePower(on: tv, assumeOn: true)
        XCTAssertEqual(target, .on)
        let requests = await recorder.requests
        XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/query/device-info", "/keypress/PowerOn"])
    }

    func testPowerButtonDoesNotToggleATVWithDifferentSerialNumber() async throws {
        let recorder = RequestLog()
        let client = RokuClient { request in
            await recorder.record(request)
            let body = "<device-info><serial-number>R002</serial-number><is-tv>true</is-tv></device-info>"
            return (Data(body.utf8), Self.response(request, 200))
        }
        do {
            _ = try await client.togglePower(on: tv, assumeOn: true)
            XCTFail("Expected an identity mismatch")
        } catch {
            XCTAssertEqual(error as? RokuError, .invalidResponse)
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/query/device-info"])
    }

    func testConnectionAndPermissionFailures() async {
        await assertError(.unreachable, transport: { _ in throw URLError(.cannotConnectToHost) })
        await assertError(.accessDenied, transport: { (Data(), Self.response($0, 403)) })
        await assertError(.http(503), transport: { (Data(), Self.response($0, 503)) })
        await assertError(.http(302), transport: { (Data(), Self.response($0, 302)) })
    }

    func testCommandTimeout() async {
        await assertError(.timedOut, transport: { request in
            XCTAssertEqual(request.url?.path, "/keypress/Home")
            throw URLError(.timedOut)
        })
    }

    func testPreferencePersistence() throws {
        let suite = "RokuVisor-Tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DevicePreferences(defaults: defaults)
        XCTAssertNil(preferences.selected)
        preferences.selected = tv
        XCTAssertEqual(DevicePreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).selected, tv)
        preferences.selected = nil
        XCTAssertNil(preferences.selected)
    }

    @MainActor
    func testDirectionalRepeatStartsAndStops() async throws {
        let repeater = DirectionRepeat(initial: .milliseconds(15), cadence: .milliseconds(10))
        var keys: [RokuKey] = []
        let firstRepeat = expectation(description: "direction repeats")
        repeater.start(.right) { key, isRepeat in
            keys.append(key)
            XCTAssertEqual(isRepeat, keys.count > 1)
            if keys.count == 2 {
                repeater.stop()
                firstRepeat.fulfill()
            }
        }
        XCTAssertEqual(keys, [.right])
        await fulfillment(of: [firstRepeat], timeout: 1)
        try await Task.sleep(for: .milliseconds(45))
        XCTAssertEqual(keys, [.right, .right])
        repeater.start(.left) { key, _ in keys.append(key) }
        repeater.stop()
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(keys, [.right, .right, .left])
        repeater.start(.ok) { _, _ in XCTFail("OK does not repeat") }
    }

    func testPositionForScaledAndOffsetScreen() {
        let geometry = VisorGeometry(screen: CGRect(x: -1512, y: 150, width: 1512, height: 982),
                                     visibleTop: 1098, notch: -838 ... -660, safeTop: 37,
                                     physicalMM: CGSize(width: 300, height: 195))
        XCTAssertEqual(geometry.requestedActivationSize.width, 192.024, accuracy: 0.01)
        XCTAssertEqual(geometry.requestedActivationSize.height, 31.98, accuracy: 0.01)
        XCTAssertEqual(geometry.cameraHousing, CGRect(x: -838, y: 1095, width: 178, height: 37))
        XCTAssertEqual(geometry.physicalActivation, geometry.cameraHousing)
        XCTAssertEqual(geometry.physicalActivation?.midX, -749)
        XCTAssertEqual(geometry.phase11Activation.maxY, 1095)
        XCTAssertEqual(geometry.wingTop, geometry.physicalActivation?.minY)
        XCTAssertEqual(geometry.surfaceFrame.maxY, 1132, accuracy: 0.001)
        XCTAssertEqual(geometry.fallbackActivation?.maxY, 1095)
        XCTAssertEqual(geometry.fallbackActivation?.height, 6)
    }

    func testPositionForPhysicalSizeAndMissingEDID() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let sized = VisorGeometry(screen: frame, visibleTop: 576, notch: nil, safeTop: 0,
                                  physicalMM: CGSize(width: 300, height: 150))
        XCTAssertEqual(sized.requestedActivationSize.width, 127, accuracy: 0.01)
        XCTAssertEqual(sized.requestedActivationSize.height, 25.4, accuracy: 0.01)
        XCTAssertEqual(sized.anchorX, 500)
        let missingSize = VisorGeometry(screen: frame, visibleTop: 576, notch: nil, safeTop: 0, physicalMM: .zero)
        XCTAssertEqual(missingSize.requestedActivationSize, CGSize(width: 108, height: 18))
        XCTAssertEqual(missingSize.wingTop, 576)
        XCTAssertNil(missingSize.physicalActivation)
        XCTAssertNil(missingSize.fallbackActivation)
    }

    func testReducedMotionAndAnimationPreference() {
        XCTAssertEqual(MotionPreference(animationsEnabled: true, reduceMotion: false).duration, 0.31)
        XCTAssertEqual(MotionPreference(animationsEnabled: true, reduceMotion: true).duration, 0)
        XCTAssertEqual(MotionPreference(animationsEnabled: false, reduceMotion: false).duration, 0)
    }

    func testCollapsedVisorHasNoArtworkOrClickableControls() {
        let canvas = CGRect(origin: .zero, size: VisorGeometry.artworkSize)
        XCTAssertTrue(VisorOutline(wings: 0, drop: 0).path(in: canvas).isEmpty)
        XCTAssertFalse(VisorVisibility.collapsed.showsSurface)
        XCTAssertFalse(VisorVisibility.collapsed.acceptsControlClicks)
        XCTAssertFalse(VisorVisibility.opening.acceptsControlClicks)
        XCTAssertFalse(VisorVisibility.closing.acceptsControlClicks)
        XCTAssertTrue(VisorVisibility.expanded.acceptsControlClicks)
    }

    func testExpandedVisorIsOneCompactOutlineContainingAllControls() {
        let canvas = CGRect(origin: .zero, size: VisorGeometry.artworkSize)
        let outline = VisorOutline(wings: 1, drop: 1).path(in: canvas)
        var subpaths = 0
        var closures = 0
        outline.cgPath.applyWithBlock {
            if $0.pointee.type == .moveToPoint { subpaths += 1 }
            if $0.pointee.type == .closeSubpath { closures += 1 }
        }
        XCTAssertEqual(subpaths, 1)
        XCTAssertEqual(closures, 1)
        XCTAssertEqual(outline.boundingRect.height, VisorGeometry.depth, accuracy: 0.01)
        XCTAssertGreaterThan(outline.boundingRect.width / outline.boundingRect.height, 5)
        XCTAssertFalse(outline.contains(CGPoint(x: canvas.minX, y: canvas.maxY)))
        XCTAssertFalse(outline.contains(CGPoint(x: VisorGeometry.anchor + 160, y: 85)))
        XCTAssertEqual(Set(VisorControl.all.compactMap(\.key)), Set(RokuKey.allCases))
        for control in VisorControl.all {
            for x in [control.frame.minX, control.frame.maxX] {
                for y in [control.frame.minY, control.frame.maxY] {
                    XCTAssertTrue(outline.contains(CGPoint(x: x, y: y)), "\(control.key) must stay inside the silhouette")
                }
            }
        }
    }

    func testNarrowOffsetDisplayKeepsArtworkInsideAndAlignsToNotchPixels() {
        let screen = CGRect(x: 1600, y: -240, width: 590, height: 450)
        let geometry = VisorGeometry(screen: screen, visibleTop: 176.7, notch: 1792.4 ... 1982.2,
                                     safeTop: 33, physicalMM: .zero, backingScale: 2)
        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.anchorX, 1887.5)
        XCTAssertEqual(geometry.wingTop, 176.5)
        XCTAssertLessThan(geometry.scale, 1)
        XCTAssertGreaterThanOrEqual(geometry.surfaceFrame.minX, screen.minX - 0.001)
        XCTAssertLessThanOrEqual(geometry.surfaceFrame.maxX, screen.maxX + 0.001)
        let select = VisorControl.all.first { $0.key == .ok }!
        let button = geometry.screenFrame(for: select.frame)
        XCTAssertEqual(button.midX, geometry.anchorX, accuracy: 0.001)
        XCTAssertEqual(button.midY, geometry.wingTop - select.frame.midY * geometry.scale, accuracy: 0.001)
    }

    @MainActor
    func testDirectionVectorsAndHomeSymbol() throws {
        let directions: [(RokuKey, String, CGVector)] = [
            (.up, "Up", CGVector(dx: 0, dy: 1)), (.down, "Down", CGVector(dx: 0, dy: -1)),
            (.left, "Left", CGVector(dx: -1, dy: 0)), (.right, "Right", CGVector(dx: 1, dy: 0))
        ]
        for (key, command, vector) in directions {
            XCTAssertEqual(DirectionGlyph.tipVector(for: key, flipped: false), vector)
            XCTAssertEqual(DirectionGlyph.tipVector(for: key, flipped: true), CGVector(dx: vector.dx, dy: -vector.dy))
            XCTAssertEqual(try key.command(for: tv), command)
        }
        let home = try XCTUnwrap(VisorControl.all.first { $0.key == .home })
        XCTAssertEqual(home.symbol, "house")
        XCTAssertNotNil(NSImage(systemSymbolName: home.symbol, accessibilityDescription: nil))
    }

    func testNotchHitCoversUpperMiddleLowerAndExcludesMenuBar() throws {
        let screen = CGRect(x: 200, y: 100, width: 1440, height: 932)
        let geometry = VisorGeometry(screen: screen, visibleTop: 1000, notch: 816...1024, safeTop: 32,
                                     physicalMM: CGSize(width: 300, height: 188), backingScale: 2)
        let region = try XCTUnwrap(geometry.physicalActivation)
        XCTAssertEqual(region.midX, 920)
        XCTAssertEqual(region.width, 182.88, accuracy: 0.01)
        for y in [region.maxY, region.minY + 2, region.midY, region.maxY - 2] {
            XCTAssertEqual(geometry.hit(at: CGPoint(x: 920, y: y)), .physical)
        }
        XCTAssertNil(geometry.hit(at: CGPoint(x: 800, y: region.midY)))
        XCTAssertNil(geometry.hit(at: CGPoint(x: 1040, y: region.midY)))
        XCTAssertNil(geometry.hit(at: CGPoint(x: 920, y: region.maxY + 1)))
    }

    func testFallbackStaysBelowTheVisibleFrameDuringMenuBarChanges() throws {
        let screen = CGRect(x: -1000, y: 50, width: 1000, height: 650)
        let geometry = VisorGeometry(screen: screen, visibleTop: 654.7, notch: -576 ... -424,
                                     safeTop: 36, physicalMM: .zero, backingScale: 2)
        let primary = try XCTUnwrap(geometry.physicalActivation)
        let fallback = try XCTUnwrap(geometry.fallbackActivation)
        XCTAssertEqual(primary.minY, 664)
        XCTAssertEqual(fallback.maxY, 654.5)
        XCTAssertEqual(fallback.height, 6)
        XCTAssertEqual(fallback.midX, primary.midX)
        XCTAssertFalse(fallback.intersects(primary))
        XCTAssertEqual(geometry.hit(at: CGPoint(x: fallback.midX, y: fallback.midY)), .fallback)
        XCTAssertNil(geometry.hit(at: CGPoint(x: fallback.midX, y: 658)))
        XCTAssertNil(geometry.hit(at: CGPoint(x: fallback.midX, y: fallback.minY - 1)))
    }

    func testClickCompletesOnlyInItsOriginalRegionWithMinimalMovement() {
        let start = CGPoint(x: 100, y: 200)
        let click = NotchClick(point: start, hit: .physical)
        XCTAssertTrue(click.completes(at: CGPoint(x: 102, y: 197), in: .physical))
        XCTAssertFalse(click.completes(at: start, in: .fallback))
        XCTAssertFalse(click.completes(at: start, in: nil))
        XCTAssertFalse(click.completes(at: CGPoint(x: 106, y: 200), in: .physical))
    }

    func testBackplatesAreCenteredAroundTheirButtons() throws {
        let groups: [[RokuKey]] = [
            [.power, .options],
            [.up, .left, .ok, .right, .down],
            [.home, .back, .play, .stop, .quieter, .louder],
            [.rewind, .fastForward]
        ]
        let plates = VisorControl.backplates
        XCTAssertEqual(plates.count, groups.count)
        for (keys, plate) in zip(groups, plates) {
            let controls = VisorControl.all.filter { $0.key.map(keys.contains) == true }
            XCTAssertEqual(controls.count, keys.count)
            let buttons = controls.reduce(CGRect.null) { $0.union($1.frame) }
            XCTAssertEqual(plate.midX, buttons.midX, accuracy: 0.001)
            XCTAssertEqual(plate.midY, buttons.midY, accuracy: 0.001)
            XCTAssertEqual(buttons.minX - plate.minX, 7, accuracy: 0.001)
            XCTAssertTrue(plate.contains(buttons))
        }
        let left = try XCTUnwrap(plates.first)
        let right = plates[2]
        XCTAssertEqual(left.minY, right.minY)
        XCTAssertEqual(left.maxY, right.maxY)
        XCTAssertLessThan(left.maxX, plates[1].minX)
        XCTAssertLessThan(plates[1].maxX, right.minX)
        XCTAssertLessThan(right.maxY, plates[3].minY)
    }

    @MainActor
    func testSeekButtonsSitBeneathPlaybackControls() throws {
        let pairs: [(RokuKey, RokuKey, String)] = [
            (.rewind, .play, "Rev"),
            (.fastForward, .stop, "Fwd")
        ]
        for (lower, upper, command) in pairs {
            let seek = try XCTUnwrap(VisorControl.all.first { $0.key == lower })
            let playback = try XCTUnwrap(VisorControl.all.first { $0.key == upper })
            XCTAssertEqual(seek.frame.midX, playback.frame.midX, accuracy: 0.001)
            XCTAssertGreaterThan(seek.frame.minY, playback.frame.maxY)
            XCTAssertNotNil(NSImage(systemSymbolName: seek.symbol, accessibilityDescription: nil))
            XCTAssertEqual(try XCTUnwrap(seek.key).command(for: player), command)
        }
    }

    func testNotchedVisorReachesTopWithControlsBelowCamera() {
        let rise: CGFloat = 32
        let canvas = CGRect(origin: .zero, size: VisorGeometry.artworkSize)
        let outline = VisorOutline(wings: 1, drop: 1, topExtension: rise)
            .path(in: canvas)
        let x = VisorGeometry.anchor
        XCTAssertTrue(outline.contains(CGPoint(x: x, y: 1)))
        XCTAssertTrue(outline.contains(CGPoint(x: x, y: rise + 1)))
        XCTAssertTrue(outline.contains(CGPoint(x: x - 116, y: 1)))
        XCTAssertTrue(outline.contains(CGPoint(x: x + 116, y: 1)))
        for control in VisorControl.all {
            let frame = control.frame.offsetBy(dx: 0, dy: control.isDirectionPad ? rise : 0)
            for px in [frame.minX, frame.maxX] {
                for py in [frame.minY, frame.maxY] {
                    XCTAssertTrue(outline.contains(CGPoint(x: px, y: py)), "\(control.key) must fit the tightened outline")
                }
            }
        }
        XCTAssertFalse(outline.contains(CGPoint(x: x - 180, y: 70)))
    }

    func testFlatTopClearsControlsOnDisplayWithoutNotch() {
        let canvas = CGRect(origin: .zero, size: VisorGeometry.artworkSize)
        let profile = VisorOutline(wings: 1, drop: 1).path(in: canvas)
        XCTAssertTrue(profile.contains(CGPoint(x: VisorGeometry.anchor, y: 1)))
        XCTAssertTrue(profile.contains(CGPoint(x: VisorGeometry.anchor, y: 14)))
        XCTAssertTrue(profile.contains(CGPoint(x: VisorGeometry.anchor + 135, y: 6)))
        for control in VisorControl.all {
            for x in [control.frame.minX, control.frame.maxX] {
                for y in [control.frame.minY, control.frame.maxY] {
                    XCTAssertTrue(profile.contains(CGPoint(x: x, y: y)), "\(control.key) overlaps the outline")
                }
            }
        }
    }

    func testSilhouetteKeepsCenterVisibleWhileWingsRetract() {
        let canvas = CGRect(origin: .zero, size: VisorGeometry.artworkSize)
        let wings = VisorOutline(wings: 1, drop: 0).path(in: canvas)
        let center = VisorOutline(wings: 0, drop: 1).path(in: canvas)
        XCTAssertEqual(wings.boundingRect.height, VisorGeometry.wingHeight, accuracy: 0.01)
        XCTAssertEqual(center.boundingRect.height, VisorGeometry.depth, accuracy: 0.01)
        XCTAssertEqual(center.boundingRect.midX, VisorGeometry.anchor, accuracy: 0.01)
        XCTAssertLessThan(center.boundingRect.width, wings.boundingRect.width)
        for extensionAmount: CGFloat in [0.05, 0.2, 0.55, 1] {
            let outline = VisorOutline(wings: extensionAmount, drop: 1).path(in: canvas)
            XCTAssertEqual(outline.boundingRect.maxX,
                           VisorGeometry.anchor + 107 + (VisorGeometry.rightSpan - 107) * extensionAmount,
                           accuracy: 0.01)
        }
    }

    func testInstalledChannelsParseFromMockRoku() async throws {
        let client = RokuClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/query/apps")
            let xml = """
                <apps><app id="42" type="appl">Cats &amp; Dogs</app>
                <app id="42">Duplicate</app><app id="tvinput.hdmi1">HDMI 1</app>
                <app id="../test">Invalid ID</app><app>Missing ID</app></apps>
                """
            return (Data(xml.utf8), Self.response(request, 200))
        }
        let channels = try await client.installedChannels(on: tv)
        XCTAssertEqual(channels, [
            RokuChannel(id: "42", name: "Cats & Dogs", type: "appl"),
            RokuChannel(id: "tvinput.hdmi1", name: "HDMI 1", type: nil)
        ])
        XCTAssertThrowsError(try RokuChannel.installed(from: Data("<html/>".utf8)))
    }

    func testChannelIconAndLaunchRequestConstruction() async throws {
        let recorder = RequestLog()
        let client = RokuClient { request in
            await recorder.record(request)
            return (Data([42]), Self.response(request, 200))
        }
        let bytes = try await client.channelIcon("42", on: tv)
        XCTAssertEqual(bytes, Data([42]))
        try await client.launchChannel("42", on: tv)
        let requests = await recorder.requests
        XCTAssertEqual(requests.compactMap { $0.url?.absoluteString }, [
            "http://192.168.1.25:8060/query/icon/42", "http://192.168.1.25:8060/launch/42"
        ])
        XCTAssertEqual(requests.compactMap(\.httpMethod), ["GET", "POST"])
        XCTAssertThrowsError(try RokuClient.channelRequest(address: tv.address, operation: .launch("../x")))
    }

    func testFavoritesAreLimitedUniqueOrderedAndSavedPerRoku() throws {
        let suite = "RokuVisor-QuickLaunch-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuickLaunchFavorites(defaults: defaults)
        let channels = (1...6).map { RokuChannel(id: "\($0)", name: "Channel \($0)", type: nil) }
        XCTAssertTrue(store.channels(for: tv.id).isEmpty)
        store.choose(channels[0], on: tv.id)
        store.choose(channels[0], on: tv.id)
        for channel in channels.dropFirst() { store.choose(channel, on: tv.id) }
        store.choose(channels[5], on: player.id)
        XCTAssertEqual(store.channels(for: tv.id).map(\.id), ["1", "2", "3", "4"])
        store.move("4", by: -1, on: tv.id)
        store.move("1", by: -1, on: tv.id)
        store.remove("2", on: tv.id)
        store.choose(channels[4], on: tv.id, replacing: "4")
        store.choose(channels[0], on: tv.id, replacing: "5")
        let reloaded = QuickLaunchFavorites(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reloaded.channels(for: tv.id).map(\.id), ["1", "5", "3"])
        XCTAssertEqual(reloaded.channels(for: player.id).map(\.id), ["6"])
    }

    func testUnavailableAndFailedChannelCommands() async throws {
        XCTAssertFalse(RokuChannel.isUnavailable("42", installed: nil, rejected: []))
        XCTAssertTrue(RokuChannel.isUnavailable("42", installed: [], rejected: []))
        XCTAssertTrue(RokuChannel.isUnavailable("42", installed: nil, rejected: ["42"]))
        let client = RokuClient { request in
            if request.url?.path == "/query/apps" { throw URLError(.timedOut) }
            return (Data(), Self.response(request, request.url?.path == "/launch/42" ? 404 : 403))
        }
        do {
            _ = try await client.installedChannels(on: tv)
            XCTFail("Expected catalog timeout")
        } catch { XCTAssertEqual(error as? RokuError, .timedOut) }
        do {
            try await client.launchChannel("42", on: tv)
            XCTFail("Expected unavailable channel")
        } catch { XCTAssertEqual(error as? RokuError, .http(404)) }
        do {
            _ = try await client.channelIcon("42", on: tv)
            XCTFail("Expected denied icon request")
        } catch { XCTAssertEqual(error as? RokuError, .accessDenied) }
    }

    func testQuickLaunchCornerMatchesTheVisorAndFlattensIntoItsBottomEdge() {
        let rect = CGRect(origin: .zero, size: CGSize(width: QuickLaunchLayout.width,
                                                      height: QuickLaunchLayout.height))
        let panel = QuickLaunchShape(progress: 1, rise: 0).path(in: rect)
        let visor = VisorOutline(wings: 1, drop: 1)
            .path(in: CGRect(origin: .zero, size: VisorGeometry.artworkSize))

        // Compare both silhouettes in coordinates relative to their lower left corners.
        for x in 1...35 {
            for depth in 1...26 {
                let point = CGPoint(x: CGFloat(x) + 0.13, y: rect.maxY - CGFloat(depth) - 0.17)
                let visorPoint = point.applying(CGAffineTransform(
                    translationX: VisorGeometry.glowMargin,
                    y: VisorGeometry.wingHeight - rect.height
                ))
                XCTAssertEqual(panel.contains(point), visor.contains(visorPoint), "At \(point)")
            }
        }
        for x in stride(from: 27, through: 130, by: 5) {
            XCTAssertTrue(panel.contains(CGPoint(x: CGFloat(x), y: rect.maxY - 0.25)))
            XCTAssertFalse(panel.contains(CGPoint(x: CGFloat(x), y: rect.maxY + 0.25)))
        }
    }

    func testQuickLaunchMovesOnlyHorizontallyBehindTheVisor() {
        let screen = CGRect(x: -900, y: 12, width: 1800, height: 900)
        for safeTop: CGFloat in [0, 32] {
            let geometry = VisorGeometry(screen: screen, visibleTop: screen.maxY - max(25, safeTop),
                                         notch: safeTop == 0 ? nil : -82...82,
                                         safeTop: safeTop, physicalMM: .zero)
            let rise = geometry.topExtension / geometry.scale
            let layout = QuickLaunchLayout(rise: rise)
            let frame = layout.screenFrame(in: geometry)
            let rect = CGRect(origin: .zero, size: layout.artworkFrame.size)
            let expanded = QuickLaunchShape(progress: 1, rise: rise).path(in: rect)
            let halfway = QuickLaunchShape(progress: 0.5, rise: rise).path(in: rect)
            let closed = QuickLaunchShape(progress: 0, rise: rise).path(in: rect)

            XCTAssertTrue(screen.contains(frame))
            XCTAssertTrue(geometry.surfaceFrame.contains(frame))
            XCTAssertEqual(frame.height, 40 * geometry.scale, accuracy: 0.001)
            XCTAssertEqual(layout.artworkFrame.minX, VisorGeometry.anchor - VisorGeometry.leftSpan + 20)
            XCTAssertEqual(expanded.boundingRect.maxY, closed.boundingRect.maxY, accuracy: 0.01)
            XCTAssertEqual(halfway.boundingRect.maxY, expanded.boundingRect.maxY, accuracy: 0.01)
            XCTAssertEqual(frame.maxY, geometry.surfaceFrame.maxY - 54 * geometry.scale, accuracy: 0.001)
            XCTAssertEqual(QuickLaunchLayout.leadingEdge(progress: 0), 94)
            XCTAssertEqual(QuickLaunchLayout.leadingEdge(progress: 1), 0)
            XCTAssertEqual(halfway.boundingRect.minX - expanded.boundingRect.minX,
                           closed.boundingRect.minX - halfway.boundingRect.minX, accuracy: 0.2)
            XCTAssertFalse(closed.contains(CGPoint(x: 60, y: 24)))
            XCTAssertTrue(closed.contains(CGPoint(x: 115, y: 26)))
            XCTAssertFalse(expanded.contains(CGPoint(x: 40, y: 6)))
            XCTAssertFalse(expanded.contains(CGPoint(x: 160, y: 28)))

            for count in 1...QuickLaunchFavorites.limit {
                let left = QuickLaunchLayout.rowInset
                let right = left + QuickLaunchLayout.rowWidth(count: count)
                // Buttons themselves have rounded corners. Probe the visible tile interiors.
                for x in [left + 4, right - 4] {
                    for y in [QuickLaunchLayout.rowTop + 2, QuickLaunchLayout.rowTop + QuickLaunchLayout.tileHeight - 2] {
                        XCTAssertTrue(expanded.contains(CGPoint(x: x, y: y)), "Count \(count), point \(x), \(y)")
                    }
                }
            }
        }
    }

    func testDirectionalButtonsShareDimensionsAndAreCenteredAroundOK() throws {
        let select = try XCTUnwrap(VisorControl.all.first { $0.key == .ok }).frame
        let arrows = VisorControl.all.filter { $0.key?.repeats == true }
        XCTAssertEqual(arrows.count, 4)
        for arrow in arrows {
            XCTAssertEqual(arrow.frame.size, CGSize(width: 48, height: 23))
            if arrow.key == .up || arrow.key == .down {
                XCTAssertEqual(arrow.frame.midX, select.midX)
                XCTAssertEqual(abs(arrow.frame.midY - select.midY), 26)
            } else {
                XCTAssertEqual(arrow.frame.midY, select.midY)
                XCTAssertEqual(abs(arrow.frame.midX - select.midX), 61)
            }
        }
    }

    @MainActor
    func testSettingsNavigationRemembersSelectionAndOpensTheShortcutEditor() {
        let navigation = SettingsNavigation()
        XCTAssertEqual(SettingsSection.allCases, [.devices, .shortcuts, .appearance, .controls, .about])
        XCTAssertEqual(navigation.selection, .devices)
        navigation.selection = .controls
        XCTAssertEqual(navigation.selection, .controls)
        XCTAssertFalse(navigation.shortcutRequest)
        navigation.openShortcutEditor()
        XCTAssertEqual(navigation.selection, .shortcuts)
        XCTAssertTrue(navigation.shortcutRequest)
        navigation.consumeShortcutRequest()
        XCTAssertEqual(navigation.selection, .shortcuts)
        XCTAssertFalse(navigation.shortcutRequest)
    }

    func testSettingsConnectionStatusAndSavedDeviceDiscoveryAreSeparate() {
        let statuses: [RokuConnectionStatus] = [.idle, .connecting, .connected, .standby, .disconnected("HTTP 503")]
        XCTAssertEqual(statuses.map(\.settingsTitle),
                       ["Disconnected", "Connecting", "Connected", "Standby", "Connection failed"])
        XCTAssertNil(RokuConnectionStatus.connected.settingsMessage)
        XCTAssertFalse(RokuConnectionStatus.disconnected("HTTP 503").settingsMessage?.contains("503") ?? true)
        XCTAssertTrue(SettingsPresentation.discoveryEmpty(savedDevice: tv).contains("saved address"))
        XCTAssertTrue(SettingsPresentation.discoveryEmpty(savedDevice: nil).contains("enter its IP address"))
    }

    func testSettingsChannelSearchAndEmptyResults() {
        let catalog = [
            RokuChannel(id: "1", name: "Café Cinema", type: nil),
            RokuChannel(id: "2", name: "Cinema News", type: nil)
        ]
        XCTAssertEqual(SettingsPresentation.channels(catalog, matching: "  "), catalog)
        XCTAssertEqual(SettingsPresentation.channels(catalog, matching: " CAFE "), [catalog[0]])
        XCTAssertEqual(SettingsPresentation.channels(catalog, matching: "cinema"), catalog)
        XCTAssertTrue(SettingsPresentation.channels(catalog, matching: "Jazz").isEmpty)
        XCTAssertTrue(SettingsPresentation.channels([], matching: "").isEmpty)
    }

    func testSettingsMetadataReadsTheBundleValues() {
        let metadata = SettingsMetadata(info: [
            "CFBundleDisplayName": "Ukor Visor",
            "CFBundleShortVersionString": "4.2",
            "CFBundleVersion": "112",
            "RokuVisorDeveloper": "YOB Apps",
            "NSHumanReadableCopyright": "© YOB Apps",
            "RokuVisorSupportURL": "javascript:invalid",
            "RokuVisorWebsiteURL": "https://example.com"
        ])
        XCTAssertEqual(metadata.name, "Ukor Visor")
        XCTAssertEqual(metadata.versionLabel, "Version 4.2 (Build 112)")
        XCTAssertEqual(metadata.developer, "YOB Apps")
        XCTAssertEqual(metadata.copyright, "© YOB Apps")
        XCTAssertNil(metadata.supportURL)
        XCTAssertEqual(metadata.websiteURL?.host, "example.com")
        XCTAssertNil(SettingsMetadata(info: [:]).versionLabel)
    }

    func testSettingsPurplePaletteMaintainsTextContrast() {
        func luminance(_ value: UInt32) -> Double {
            let rgb = SettingsPalette.rgb(value)
            func linear(_ channel: Double) -> Double {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
        }

        let pairs: [(UInt32, UInt32)] = [
            (SettingsPalette.primaryText, SettingsPalette.background),
            (SettingsPalette.secondaryText, SettingsPalette.sidebar),
            (SettingsPalette.primaryText, SettingsPalette.selection),
            (SettingsPalette.primaryText, SettingsPalette.card),
            (SettingsPalette.secondaryText, SettingsPalette.card),
            (SettingsPalette.primaryText, SettingsPalette.button),
            (SettingsPalette.mutedText, SettingsPalette.background),
            (SettingsPalette.background, SettingsPalette.accent)
        ]
        for (foreground, background) in pairs {
            let ends = [luminance(foreground), luminance(background)].sorted()
            XCTAssertGreaterThanOrEqual((ends[1] + 0.05) / (ends[0] + 0.05), 4.5)
        }
        XCTAssertEqual(Set([SettingsPalette.background, SettingsPalette.sidebar, SettingsPalette.card,
                            SettingsPalette.selection, SettingsPalette.button]).count, 5)
    }

    #if EXPERIMENTAL_LISTENING
    func testLiveListeningRTCPFramingAndAcknowledgments() {
        let delay = RokuListeningControl.delay.data
        XCTAssertEqual(delay.prefix(4), Data([128, 204, 0, 3]))
        XCTAssertEqual(delay.suffix(8), Data([86, 68, 76, 89, 0, 9, 39, 192]))
        XCTAssertEqual(RokuListeningControl.version.data.suffix(4), Data([0, 0, 0, 2]))
        XCTAssertEqual(RokuListeningControl.report.data, Data([128, 201, 0, 1, 0, 0, 0, 0]))
        XCTAssertEqual(RokuListeningControl.goodbye.data, Data([129, 203, 0, 1, 0, 0, 0, 0]))
        var acknowledgment = delay
        acknowledgment.replaceSubrange(8..<12, with: "XDLY".utf8)
        XCTAssertTrue(RokuListeningControl.delay.acknowledges(RokuListeningControl.report.data + acknowledgment))
        XCTAssertFalse(RokuListeningControl.delay.acknowledges(acknowledgment.dropLast()))
        acknowledgment[15] = 0
        XCTAssertFalse(RokuListeningControl.delay.acknowledges(acknowledgment))
        XCTAssertTrue(RokuListeningControl.version.acknowledges(Data([128, 204, 0, 2, 0, 0, 0, 0, 78, 67, 76, 73])))
    }

    func testLiveListeningRoutingCorrelatesAcknowledgment() throws {
        let request = RokuListeningRouting.start(id: "7", address: "127.0.0.1", port: 6970)
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: encoded)["param-devname"], "127.0.0.1:6970:97:960")
        var reply = ["response": "set-audio-output", "response-id": "7", "status": "200"]
        XCTAssertTrue(RokuListeningRouting.accepted(reply, request: request))
        reply["response-id"] = "8"
        XCTAssertFalse(RokuListeningRouting.accepted(reply, request: request))
    }

    @MainActor
    func testLiveListeningWithoutProviderFailsBeforeConnection() {
        let controller = RokuPrivateListening()
        controller.start(address: "127.0.0.1")
        XCTAssertFalse(controller.active)
        XCTAssertEqual(controller.state, .failed("Live audio requires an authorized authentication provider."))
    }

    @MainActor
    func testLiveListeningAuthenticationFailureNeverRoutesAudio() async {
        let fake = ListeningConnectionFake()
        let controller = RokuPrivateListening(provider: fake)
        for _ in 0..<2 {
            controller.start(address: "127.0.0.1")
            XCTAssertEqual(controller.state, .connecting)
            await controller.waitUntilStopped()
            XCTAssertFalse(controller.active)
            guard case .failed = controller.state else { return XCTFail("Expected authentication failure") }
        }
        XCTAssertEqual(fake.events, ["connect", "authenticate", "close", "connect", "authenticate", "close"])
    }

    @MainActor
    func testLiveListeningCancellationDuringNegotiationRestoresAudioAndReleasesPorts() async throws {
        let fake = ListeningConnectionFake()
        fake.rejectAuthentication = false
        let peer = ListeningUDPSocket()
        try peer.start(port: 0)
        fake.remoteRTCPPort = try XCTUnwrap(peer.port)
        let (rtpPort, rtcpPort) = try availableListeningPorts()
        let controller = RokuPrivateListening(provider: fake, rtpPort: rtpPort, rtcpPort: rtcpPort)
        controller.start(address: "127.0.0.1")
        let deadline = ContinuousClock.now + .seconds(1)
        while !fake.events.contains("route"), controller.active, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.state, .negotiating)
        controller.stop()
        controller.stop()
        await controller.waitUntilStopped()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(fake.events, ["connect", "authenticate", "route", "restore", "close"])
        let socket = ListeningUDPSocket()
        try socket.start(port: rtpPort)
        socket.stop()
        try socket.start(port: rtcpPort)
    }

    @MainActor
    func testLiveListeningNegotiatesBeforeReportsAndSendsGoodbyeOnStop() async throws {
        let peer = ListeningUDPSocket()
        try peer.start(port: 0)
        let fake = ListeningConnectionFake()
        fake.rejectAuthentication = false
        fake.remoteRTCPPort = try XCTUnwrap(peer.port)
        let (rtpPort, rtcpPort) = try availableListeningPorts()
        let controller = RokuPrivateListening(provider: fake, rtpPort: rtpPort, rtcpPort: rtcpPort)
        controller.start(address: "127.0.0.1")
        defer { controller.stop() }

        func nextPacket() async throws -> Data {
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                if let packet = try peer.receive() { return packet }
                try await Task.sleep(for: .milliseconds(2))
            }
            throw ListeningError.playbackTimeout
        }

        let delay = try await nextPacket()
        XCTAssertEqual(delay, RokuListeningControl.delay.data)
        var delayReply = delay
        delayReply.replaceSubrange(8..<12, with: "XDLY".utf8)
        try peer.send(delayReply, to: "127.0.0.1", port: rtcpPort)
        let version = try await nextPacket()
        XCTAssertEqual(version, RokuListeningControl.version.data)
        try peer.send(Data([128, 204, 0, 2, 0, 0, 0, 0, 78, 67, 76, 73]), to: "127.0.0.1", port: rtcpPort)
        let report = try await nextPacket()
        XCTAssertEqual(report, RokuListeningControl.report.data)
        XCTAssertEqual(controller.state, .negotiating, "No audio reached the output.")
        controller.stop()
        await controller.waitUntilStopped()
        XCTAssertEqual(try peer.receive(), RokuListeningControl.goodbye.data)
        XCTAssertEqual(fake.events, ["connect", "authenticate", "route", "restore", "close"])
        XCTAssertEqual(controller.state, .off)
    }

    private func availableListeningPorts() throws -> (UInt16, UInt16) {
        let rtp = ListeningUDPSocket()
        let rtcp = ListeningUDPSocket()
        try rtp.start(port: 0)
        try rtcp.start(port: 0)
        return (try XCTUnwrap(rtp.port), try XCTUnwrap(rtcp.port))
    }

    func testListeningFlagAndVolumeDefaults() throws {
        XCTAssertFalse(ListeningExperiment.enabled(environment: [:]))
        XCTAssertFalse(ListeningExperiment.enabled(environment: [ListeningExperiment.experimentalPrivateListeningEnabled: "true"]))
        XCTAssertTrue(ListeningExperiment.enabled(environment: [ListeningExperiment.experimentalPrivateListeningEnabled: "1"]))
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let volume = ListeningVolume(defaults: defaults)
        XCTAssertEqual(volume.percent, 70)
        volume.percent = 42
        XCTAssertEqual(ListeningVolume(defaults: defaults).percent, 42)
        volume.percent = 150
        XCTAssertEqual(volume.percent, 100)
    }

    func testListeningRTPHeaderExtensionsPaddingAndWindowWrap() throws {
        let data = Data([0xB1, 97, 0, 0, 0, 0, 0, 42, 0, 0, 0, 9,
                         0, 0, 0, 3, 0xBE, 0xDE, 0, 1, 4, 3, 2, 1, 0xFC, 0, 2])
        let packet = try ListeningRTPPacket(datagram: data, expectedType: 97, expectedSource: 9)
        XCTAssertEqual(packet.sequence, 0)
        XCTAssertEqual(packet.timestamp, 42)
        XCTAssertEqual(packet.payload, Data([0xFC]))
        XCTAssertThrowsError(try ListeningRTPPacket(datagram: data, expectedType: 96))
        XCTAssertThrowsError(try ListeningRTPPacket(datagram: data, expectedType: 97, expectedSource: 1))
        XCTAssertThrowsError(try ListeningRTPPacket(datagram: data.prefix(22), expectedType: 97))
        XCTAssertThrowsError(try ListeningRTPPacket(datagram: Data(repeating: 1, count: 3000), expectedType: 97))
        var window = ListeningPacketWindow(firstSequence: .max, capacity: 2)
        window.insert(packet)
        window.insert(packet)
        XCTAssertEqual(window.count, 1)
        XCTAssertNil(window.pop())
        window.skipMissingPacket()
        XCTAssertEqual(window.pop()?.sequence, 0)
        window.insert(packet)
        XCTAssertEqual(window.count, 0)
    }

    func testSessionProbeUpgradeRejectionCloseTimeoutAndCleanup() {
        let outcomes: [ListeningSessionProbe.Outcome] = [.upgraded(selected: .ecp2), .upgraded(selected: .absent),
                                                          .http(400, Data()), .http(403, Data()), .closed(1008)]
        for result in outcomes {
            let probe = ListeningSessionProbe()
            probe.finish(result)
            probe.finish(.closed(1000))
            var cleaned = false
            XCTAssertEqual(probe.wait(timeout: .now()) { cleaned = true }, result)
            XCTAssertTrue(cleaned)
        }

        let stalled = ListeningSessionProbe()
        var cleanups = 0
        XCTAssertEqual(stalled.wait(timeout: .now()) { cleanups += 1 }, .timeout)
        stalled.finish(.upgraded(selected: .ecp2))
        XCTAssertEqual(cleanups, 1)
    }

    func testSessionProbeClassifiesNegotiatedSubprotocolWithoutEchoingUnexpectedValue() {
        XCTAssertEqual(ListeningSessionProbe.Subprotocol("ecp-2"), .ecp2)
        XCTAssertEqual(ListeningSessionProbe.Subprotocol(nil), .absent)
        let result = ListeningSessionProbe.Outcome.upgraded(selected: .init("unexpected-server-value"))
        XCTAssertEqual(result, .upgraded(selected: .unexpected))
        XCTAssertFalse(result.description.contains("unexpected-server-value"))
    }

    func testAuthenticationProbeClassifiesOneMessageWithoutLoggingItsValue() {
        typealias Challenge = ListeningSessionProbe.Challenge
        XCTAssertEqual(Challenge.classify(.string(#"{"notify":"authenticate","param-challenge":"YWJj"}"#)), .present)
        XCTAssertEqual(Challenge.classify(.string(#"{"notify":"authenticate","param-challenge":"?"}"#)), .malformed)
        XCTAssertEqual(Challenge.classify(.string(#"{"notify":"authenticate"}"#)), .malformed)
        XCTAssertEqual(Challenge.classify(.string("{")), .malformed)
        XCTAssertEqual(Challenge.classify(.string(#"{"notify":"status","request-id":"2"}"#)), .unexpected)
        XCTAssertEqual(Challenge.classify(.data(Data([1, 2]))), .unexpected)
        XCTAssertFalse(ListeningSessionProbe.Outcome.challenge(.present).description.contains("YWJj"))
    }

    func testSessionProbeOnlyAcceptsLocalIPv4() {
        XCTAssertEqual(ListeningSessionProbe.localAddress("192.168.250.44"), "192.168.250.44")
        XCTAssertNil(ListeningSessionProbe.localAddress("192.0.2.44"))
        XCTAssertEqual(ListeningSessionProbe.localAddress("172.16.0.2"), "172.16.0.2")
        XCTAssertNil(ListeningSessionProbe.localAddress("172.15.0.2"))
        XCTAssertNil(ListeningSessionProbe.localAddress("example.com"))
        XCTAssertNil(ListeningSessionProbe.localAddress("8.8.8.8"))
    }

    func testMediaFixtureRTCPCompoundPacketsAndLoopback() throws {
        let source: UInt32 = 0x12345678
        let report = ListeningFixtureRTCP.packet(source: source)
        XCTAssertEqual(Array(report.prefix(8)), [0x80, 201, 0, 1, 0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(report[9], 202)
        let goodbye = ListeningFixtureRTCP.packet(source: source, goodbye: true)
        XCTAssertEqual(Array(goodbye.suffix(8)), [0x81, 203, 0, 1, 0x12, 0x34, 0x56, 0x78])
        XCTAssertThrowsError(try ListeningFixtureRTCP.validate(goodbye.dropLast(), source: source))
        XCTAssertThrowsError(try ListeningFixtureRTCP.validate(report, source: 3))

        let control = ListeningUDPSocket()
        try control.start(port: 0)
        defer { control.stop() }
        let port = try XCTUnwrap(control.port)
        for (packet, kind) in [(report, ListeningFixtureRTCP.Kind.report), (goodbye, .goodbye)] {
            try ListeningUDPSocket.sendFixture(packet, port: port)
            let deadline = ContinuousClock.now + .seconds(1)
            var received = try control.receive()
            while received == nil && ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.001)
                received = try control.receive()
            }
            XCTAssertEqual(try ListeningFixtureRTCP.validate(XCTUnwrap(received), source: source), kind)
        }
        control.stop()
        XCTAssertThrowsError(try control.receive())
    }

    func testStreamPlaybackTracksBoundedSubmissionCompletionAndRestart() {
        let stoppedStream = ListeningPlaybackCounts()
        for _ in 0..<8 { XCTAssertTrue(stoppedStream.submit(frames: 960)) }
        XCTAssertFalse(stoppedStream.submit(frames: 960))
        XCTAssertEqual(stoppedStream.snapshot().frames, 7680)
        XCTAssertEqual(stoppedStream.snapshot().pending, 8)
        stoppedStream.complete()
        XCTAssertEqual(stoppedStream.snapshot().completed, 1)
        XCTAssertTrue(stoppedStream.submit(frames: 480))
        let restartedStream = ListeningPlaybackCounts()
        XCTAssertTrue(restartedStream.submit(frames: 960))
        for _ in 0..<10 { stoppedStream.complete() }
        XCTAssertEqual(stoppedStream.snapshot().pending, 0)
        XCTAssertEqual(restartedStream.snapshot().pending, 1)
        restartedStream.complete()
        XCTAssertEqual(restartedStream.snapshot().pending, 0)
    }

    @MainActor
    func testTCLProfileDecodesVariableSizeStereoAndConcealsLossAcrossWraparound() throws {
        XCTAssertEqual(ListeningUDPDiagnostic.profile(for: ListeningUDPDiagnostic.fixture), .fixture)
        XCTAssertEqual(ListeningUDPDiagnostic.profile(for: ListeningUDPDiagnostic.tclFixture), .tcl)
        XCTAssertNil(ListeningUDPDiagnostic.profile(for: "other"))
        XCTAssertEqual(ListeningRTPProfile.fixture.timestampRate, 48_000)
        XCTAssertEqual(ListeningRTPProfile.tcl.timestampRate, 1000)
        let decoder = try ListeningOpusDecoder()
        let packets = ListeningToneFixture.tclPackets
        XCTAssertGreaterThan(Set(packets.map(\.count)).count, 1)
        var pipeline = ListeningDatagramPipeline(firstSequence: .max, profile: .tcl, source: 1, decoder: decoder)
        func packet(_ sequence: UInt16, _ timestamp: UInt32, _ index: Int, profile: ListeningRTPProfile = .tcl) -> Data {
            ListeningToneFixture.datagram(sequence: sequence, timestamp: timestamp, payload: packets[index], profile: profile)
        }
        XCTAssertThrowsError(try pipeline.receive(packet(.max, .max - 5, 0, profile: .fixture)))
        XCTAssertThrowsError(try pipeline.receive(Data([0x80, 97])))
        XCTAssertEqual(try pipeline.receive(packet(0, 3, 1)), .accepted)
        XCTAssertEqual(try pipeline.receive(packet(0, 3, 1)), .duplicate)
        XCTAssertNil(try pipeline.next())
        try pipeline.receive(packet(.max, .max - 5, 0))
        let first = try XCTUnwrap(pipeline.next())
        XCTAssertEqual(first.frameLength, 480)
        XCTAssertEqual(first.format.channelCount, 2)
        XCTAssertEqual(first.format.sampleRate, 48_000)
        XCTAssertEqual(try pipeline.next()?.frameLength, 480)
        try pipeline.receive(packet(2, 24, 3))
        XCTAssertEqual(try pipeline.next(concealExpiredGap: true)?.frameLength, 480)
        XCTAssertEqual(pipeline.gaps, 1)
        XCTAssertEqual(try pipeline.next()?.frameLength, 480)
        try pipeline.receive(packet(3, 23, 4))
        XCTAssertThrowsError(try pipeline.next())
        for fixture in packets {
            XCTAssertEqual(try decoder.decode(fixture).frameLength, 480)
        }
    }

    func testListeningUDPLoopbackCollisionDecodeAndRestart() throws {
        let socket = ListeningUDPSocket()
        let other = ListeningUDPSocket()
        defer { socket.stop(); other.stop() }
        try socket.start(port: 0)
        let port = try XCTUnwrap(socket.port)
        XCTAssertThrowsError(try socket.start(port: port))
        XCTAssertThrowsError(try other.start(port: port))
        let decoder = try ListeningOpusDecoder()
        var pipeline = ListeningDatagramPipeline(firstSequence: 0, source: 1, decoder: decoder)
        let first = try XCTUnwrap(ListeningToneFixture.packets.first)
        try ListeningUDPSocket.sendFixture(ListeningToneFixture.datagram(sequence: 0, timestamp: 0, payload: first), port: port)
        let deadline = ContinuousClock.now + .seconds(1)
        var datagram: Data?
        while datagram == nil && ContinuousClock.now < deadline {
            datagram = try socket.receive()
            if datagram == nil { Thread.sleep(forTimeInterval: 0.001) }
        }
        try pipeline.receive(XCTUnwrap(datagram))
        XCTAssertEqual(try pipeline.next()?.frameLength, 960)
        try pipeline.receive(ListeningToneFixture.datagram(sequence: 1, timestamp: 5, payload: first))
        XCTAssertThrowsError(try pipeline.next())
        socket.stop()
        XCTAssertNil(socket.port)
        XCTAssertThrowsError(try socket.receive())
        try other.start(port: port)
        XCTAssertEqual(other.port, port)
        other.stop()
        try socket.start(port: port)
    }

    func testOpusDatagramPipelineOrdersAndConcealsExpiredLoss() throws {
        let decoder = try ListeningOpusDecoder(sampleRate: 24_000, channels: 1)
        var pipeline = ListeningDatagramPipeline(firstSequence: 0, source: 1, decoder: decoder)
        let packets = ListeningToneFixture.packets
        func datagram(_ sequence: UInt8, payload: Data) -> Data {
            ListeningToneFixture.datagram(sequence: UInt16(sequence), timestamp: UInt32(sequence) * 960, payload: payload)
        }

        try pipeline.receive(datagram(2, payload: packets[2]))
        XCTAssertNil(try pipeline.next(concealExpiredGap: true))
        try pipeline.receive(datagram(0, payload: packets[0]))
        try pipeline.receive(datagram(0, payload: packets[0]))
        XCTAssertEqual(pipeline.pendingCount, 2)
        let first = try XCTUnwrap(pipeline.next())
        XCTAssertEqual(first.format.channelCount, 1)
        XCTAssertEqual(first.format.sampleRate, 24_000)
        XCTAssertEqual(first.frameLength, 480)
        XCTAssertNil(try pipeline.next())
        let concealed = try XCTUnwrap(pipeline.next(concealExpiredGap: true))
        XCTAssertEqual(concealed.frameLength, first.frameLength)
        XCTAssertEqual(try pipeline.next()?.frameLength, first.frameLength)
        XCTAssertNil(try pipeline.next(concealExpiredGap: true))
        XCTAssertThrowsError(try pipeline.receive(Data([0x80])))
        XCTAssertThrowsError(try decoder.decode(Data([0x03])))
        XCTAssertThrowsError(try decoder.concealLoss(frames: 3))
        XCTAssertThrowsError(try ListeningOpusDecoder(sampleRate: 44_100, channels: 2))
    }

    @MainActor
    func testSyntheticOpusDecodesAndWritesPCMWithCleanup() throws {
        let decoder = try ListeningOpusDecoder()
        XCTAssertThrowsError(try decoder.decode(Data()))
        let clip = try ListeningToneFixture.decode(using: decoder)
        XCTAssertTrue((15_000...19_000).contains(clip.frameLength))
        let samples = try XCTUnwrap(clip.floatChannelData)[0]
        XCTAssertGreaterThan((0..<Int(clip.frameLength)).map { abs(samples[$0]) }.max() ?? 0, 0.01)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: clip.format.settings)
            try file.write(from: clip)
        }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, Int64(clip.frameLength))
        let output = ListeningAudioOutput(format: decoder.pcmFormat)
        XCTAssertEqual(output.state, .stopped)
        clip.frameLength = 0
        XCTAssertThrowsError(try output.play(clip, volume: 70))
        XCTAssertEqual(output.state, .failed)
        output.stop()
        XCTAssertEqual(output.state, .stopped)
    }
    #endif

    private func assertError(_ expected: RokuError, transport: @escaping RokuClient.Transport) async {
        do {
            try await RokuClient(transport: transport).send(command: RokuKey.home.rawValue, to: tv)
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? RokuError, expected)
        }
    }

    private static func response(_ request: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}


private actor RequestLog {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

#if EXPERIMENTAL_LISTENING
@MainActor
private final class ListeningConnectionFake: RokuListeningAuthenticationProvider, RokuListeningConnection {
    let localIPv4 = "127.0.0.1"
    var remoteRTCPPort: UInt16 = 5150
    var events: [String] = []
    var rejectAuthentication = true

    func connect(address: String) async throws -> any RokuListeningConnection {
        XCTAssertEqual(address, localIPv4)
        events.append("connect")
        return self
    }

    func authenticate() async throws {
        events.append("authenticate")
        if rejectAuthentication { throw NSError(domain: "Test authentication rejected", code: 401) }
    }

    func request(_ fields: [String: String]) async throws -> [String: String] {
        events.append("route")
        return ["response": "set-audio-output", "response-id": fields["request-id"] ?? "", "status": "200"]
    }

    func restoreAudio() async throws -> Bool {
        events.append("restore")
        return true
    }

    func close() { events.append("close") }
}
#endif

extension RokuVisorTests {
    func testSettingsGearFitsAbovePlaybackRow() {
        let gear = VisorControl.settings
        XCTAssertNil(gear.key)
        XCTAssertEqual(gear.label, "Settings")
        XCTAssertNotNil(NSImage(systemSymbolName: gear.symbol, accessibilityDescription: nil))
        XCTAssertTrue(VisorControl.all.allSatisfy { !$0.frame.intersects(gear.frame) })
        for rise: CGFloat in [0, 32] {
            let canvas = CGRect(origin: .zero, size: VisorGeometry.artworkSize)
            let shape = VisorOutline(wings: 1, drop: 1, topExtension: rise).path(in: canvas)
            let visibleGear = gear.frame.insetBy(dx: 1.5, dy: 1.5)
            for x in [visibleGear.minX, visibleGear.maxX] {
                for y in [visibleGear.minY, visibleGear.maxY] {
                    XCTAssertTrue(shape.contains(CGPoint(x: x, y: y)))
                }
            }
        }
    }
}
