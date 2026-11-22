import Foundation

enum NotchHit: String {
    case physical, fallback
}

struct VisorGeometry {
    let cameraHousing: CGRect?
    let physicalActivation: CGRect?
    let fallbackActivation: CGRect?
    let phase11Activation: CGRect
    let requestedActivationSize: CGSize
    let anchorX: CGFloat
    let wingTop: CGFloat
    let scale: CGFloat
    let surfaceFrame: CGRect
    let topExtension: CGFloat

    var hasNotch: Bool { cameraHousing != nil }

    static let leftSpan: CGFloat = 254
    static let rightSpan: CGFloat = 366
    static let wingHeight: CGFloat = 65
    static let depth: CGFloat = 102
    static let glowMargin: CGFloat = 16
    static let preferredScale: CGFloat = 1.16
    static let fallbackDepth: CGFloat = 6
    static let anchor = glowMargin + leftSpan
    static let settingsControlFrame = CGRect(x: anchor + 308, y: 0, width: 24, height: 13)
    static let artworkSize = CGSize(width: leftSpan + rightSpan + glowMargin * 2, height: depth + glowMargin)

    init(screen: CGRect, visibleTop: CGFloat, notch: ClosedRange<CGFloat>?, safeTop: CGFloat,
         physicalMM: CGSize, backingScale: CGFloat = 1) {
        let scaleX = physicalMM.width > 0 ? screen.width / physicalMM.width : 0
        let scaleY = physicalMM.height > 0 ? screen.height / physicalMM.height : 0
        let width = min(250, max(70, scaleX > 0 ? 38.1 * scaleX : 108))
        let height = min(42, max(12, scaleY > 0 ? 6.35 * scaleY : 18))
        requestedActivationSize = CGSize(width: width, height: height)

        let pixelScale = max(1, backingScale)
        let gap = notch.flatMap { range -> CGRect? in
            guard safeTop > 0, range.upperBound > range.lowerBound else { return nil }
            let rect = CGRect(x: range.lowerBound, y: screen.maxY - safeTop,
                              width: range.upperBound - range.lowerBound, height: safeTop)
            let clipped = screen.intersection(rect)
            return clipped.isEmpty ? nil : clipped
        }
        cameraHousing = gap
        let center = gap?.midX ?? screen.midX
        anchorX = (center * pixelScale).rounded() / pixelScale
        let menuBottom = min(visibleTop, screen.maxY - safeTop)
        wingTop = (menuBottom * pixelScale).rounded(.down) / pixelScale

        // Take the vertical edges from the hardware safe band so the top and bottom
        // of the housing are both covered. Limit the width to the menu-bar gap.
        physicalActivation = gap.map {
            CGRect(x: $0.midX - min(width, $0.width) / 2, y: $0.minY,
                   width: min(width, $0.width), height: $0.height)
        }
        fallbackActivation = Self.fallback(below: wingTop, widthOf: physicalActivation)
        phase11Activation = CGRect(x: anchorX - width / 2, y: wingTop - height, width: width, height: height)

        let leftFit = (anchorX - screen.minX) / Self.anchor
        let rightFit = (screen.maxX - anchorX) / (Self.rightSpan + Self.glowMargin)
        scale = max(0, min(Self.preferredScale, leftFit, rightFit))
        topExtension = gap == nil ? 0 : screen.maxY - wingTop
        surfaceFrame = CGRect(x: anchorX - Self.anchor * scale,
                              y: wingTop - Self.artworkSize.height * scale,
                              width: Self.artworkSize.width * scale,
                              height: Self.artworkSize.height * scale + topExtension)
    }

    private static func fallback(below safeEdge: CGFloat, widthOf primary: CGRect?) -> CGRect? {
        primary.map {
            CGRect(x: $0.minX, y: safeEdge - fallbackDepth, width: $0.width, height: fallbackDepth)
        }
    }

    func hit(at point: CGPoint) -> NotchHit? {
        // A CGEvent at the topmost row may be on maxY, which CGRect.contains excludes.
        if let physicalActivation, point.x >= physicalActivation.minX, point.x < physicalActivation.maxX,
           point.y >= physicalActivation.minY, point.y <= physicalActivation.maxY {
            return .physical
        }
        return fallbackActivation?.contains(point) == true ? .fallback : nil
    }

    // Artwork coordinates use a top-left origin. Window frames use AppKit screen coordinates.
    func screenFrame(for artworkRect: CGRect) -> CGRect {
        CGRect(x: surfaceFrame.minX + artworkRect.minX * scale, y: wingTop - artworkRect.maxY * scale,
               width: artworkRect.width * scale, height: artworkRect.height * scale)
    }
}

struct NotchClick {
    let point: CGPoint
    let hit: NotchHit

    func completes(at release: CGPoint, in region: NotchHit?) -> Bool {
        hit == region && abs(point.x - release.x) <= 5 && abs(point.y - release.y) <= 5
    }
}
