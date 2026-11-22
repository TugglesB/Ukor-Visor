import AppKit

@MainActor
struct NotchDisplay {
    static let overlayLevel = NSWindow.Level.floating
    static let notchOverlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)

    let screen: NSScreen
    let geometry: VisorGeometry
    let displayID: CGDirectDisplayID?
    let millimeters: CGSize

    init(screen: NSScreen) {
        self.screen = screen
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let physicalSize = id.map(CGDisplayScreenSize) ?? .zero
        displayID = id
        millimeters = physicalSize
        let notch: ClosedRange<CGFloat>?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           left.maxX < right.minX {
            notch = left.maxX...right.minX
        } else {
            notch = nil
        }
        geometry = VisorGeometry(screen: screen.frame, visibleTop: screen.visibleFrame.maxY,
                                 notch: notch, safeTop: screen.safeAreaInsets.top,
                                 physicalMM: physicalSize, backingScale: screen.backingScaleFactor)
    }

    var builtIn: Bool { displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }

    static func preferred(from displays: [Self], mouse: CGPoint) -> Self? {
        displays.first { $0.builtIn && $0.geometry.hasNotch }
            ?? displays.first { $0.geometry.hasNotch }
            ?? displays.first { $0.screen.frame.contains(mouse) }
            ?? displays.first
    }

    func diagnosticLines() -> [String] {
        let mode = displayID.flatMap(CGDisplayCopyDisplayMode)
        let resolution = mode.map { "\($0.pixelWidth) × \($0.pixelHeight) pixels" } ?? "unavailable"
        let insets = screen.safeAreaInsets
        let target = geometry.requestedActivationSize
        var lines = [
            "Display: \(screen.localizedName) (built-in: \(builtIn), ID: \(displayID.map(String.init) ?? "unavailable"))",
            "Resolution (display-mode backing pixels): \(resolution); backing scale: \(screen.backingScaleFactor)",
            "Display frame: \(NSStringFromRect(screen.frame))",
            "Visible frame: \(NSStringFromRect(screen.visibleFrame))",
            "Safe-area insets (top/left/bottom/right): \(insets.top)/\(insets.left)/\(insets.bottom)/\(insets.right) pt",
            "Screen physical dimensions: \(millimeters.width) × \(millimeters.height) mm",
            "Estimated hardware notch: \(description(geometry.cameraHousing))",
            "Calculated notch center: \(geometry.cameraHousing.map { NSStringFromPoint(CGPoint(x: $0.midX, y: $0.midY)) } ?? "none")",
            "Requested activation dimensions: \(target.width) × \(target.height) pt (1.5 × 0.25 in when physical data is available)",
            "Primary activation region and dimensions: \(description(geometry.physicalActivation))",
            "Fallback strip and dimensions: \(description(geometry.fallbackActivation))",
            "Phase 1.1 click region at these display settings: \(description(geometry.phase11Activation))",
            "Activation window frame: none (passive AppKit mouse monitor)",
            "Activation window level: none; expanded visor level: \(geometry.hasNotch ? Self.notchOverlayLevel.rawValue : Self.overlayLevel.rawValue)",
            "Fallback enabled: \(geometry.fallbackActivation != nil); fallback-only mode: false",
            "Actual event delivery and last region used: requires manual click test"
        ]
        if let region = geometry.physicalActivation {
            for (label, fraction) in [("upper", 5.0 / 6), ("middle", 0.5), ("lower", 1.0 / 6)] {
                let point = CGPoint(x: region.midX, y: region.minY + region.height * fraction)
                lines.append("Hit-test probe (\(label)) at \(NSStringFromPoint(point)): \(Self.hitTestWindow(at: point))")
            }
        }
        return lines
    }

    static func hitTestWindow(at point: CGPoint) -> String {
        let window = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        let owner = CGWindowID(exactly: window).flatMap { id in
            (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first
        }?[kCGWindowOwnerName as String] as? String
        return "\(window) (\(owner ?? "owner unavailable"))"
    }

    private func description(_ frame: CGRect?) -> String {
        frame.map { "\(NSStringFromRect($0)) (\($0.width) × \($0.height) pt)" } ?? "none"
    }
}
