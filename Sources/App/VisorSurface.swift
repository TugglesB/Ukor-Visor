import SwiftUI

struct VisorControl {
    let key: RokuKey?
    let symbol: String
    let label: String
    let frame: CGRect

    private init(_ key: RokuKey, _ symbol: String, _ label: String,
                 _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat = 36) {
        self.key = key
        self.symbol = symbol
        self.label = label
        frame = CGRect(x: VisorGeometry.anchor + x - width / 2, y: y - height / 2,
                       width: width, height: height)
    }

    private init(settingsFrame: CGRect) {
        key = nil
        symbol = "gearshape.fill"
        label = "Settings"
        frame = settingsFrame
    }

    private static let powerAndOptions: [Self] = [
        .init(.power, "power", "Power", -202, 32, 56),
        .init(.options, "asterisk", "Roku Options", -139, 32, 56)
    ]

    private static func arrow(_ key: RokuKey, _ label: String, x: CGFloat, y: CGFloat) -> Self {
        .init(key, "", label, x, y, 48, 23)
    }

    private static let directionPad: [Self] = [
        arrow(.up, "Up", x: 0, y: 27),
        arrow(.left, "Left", x: -61, y: 53),
        .init(.ok, "", "OK", 0, 53, 59, 24),
        arrow(.right, "Right", x: 61, y: 53),
        arrow(.down, "Down", x: 0, y: 79)
    ]

    private static let playback: [Self] = [
        .init(.home, "house", "Home", 126, 32, 37),
        .init(.back, "arrow.uturn.backward", "Back", 168, 32, 37),
        .init(.play, "playpause.fill", "Play or Pause", 210, 32, 37),
        .init(.stop, "stop.fill", "Stop (unsupported by Roku ECP)", 252, 32, 37),
        .init(.quieter, "speaker.minus.fill", "Volume Down", 294, 32, 37),
        .init(.louder, "speaker.plus.fill", "Volume Up", 336, 32, 37)
    ]

    private static let seekControls: [Self] = [
        .init(.rewind, "backward.fill", "Rewind", 210, 74, 37, 29),
        .init(.fastForward, "forward.fill", "Fast Forward", 252, 74, 37, 29)
    ]

    var isDirectionPad: Bool { Self.directionPad.contains { $0.key == key } }

    static let all = powerAndOptions + directionPad + playback + seekControls
    static let settings = Self(settingsFrame: VisorGeometry.settingsControlFrame)

    // Controls and their shading use the same artwork coordinates.
    static let backplates = [
        paddedBounds(of: powerAndOptions, verticalPadding: 7),
        paddedBounds(of: directionPad, verticalPadding: 4),
        paddedBounds(of: playback, verticalPadding: 7),
        paddedBounds(of: seekControls, verticalPadding: 2)
    ]

    private static func paddedBounds(of controls: [Self], verticalPadding: CGFloat) -> CGRect {
        controls.reduce(CGRect.null) { $0.union($1.frame) }
            .insetBy(dx: -7, dy: -verticalPadding)
    }
}

private enum VisorOuterCorner {
    static let radius: CGFloat = 26

    static func controlOffset(for radius: CGFloat) -> CGFloat { 0.448 * radius }

    // Continue from a horizontal bottom edge into the vertical left edge.
    static func addBottomLeft(to path: inout Path, left: CGFloat, bottom: CGFloat, radius: CGFloat) {
        let cap = controlOffset(for: radius)
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addCurve(to: CGPoint(x: left, y: bottom - radius),
                      control1: CGPoint(x: left + cap, y: bottom),
                      control2: CGPoint(x: left, y: bottom - cap))
    }
}

struct VisorOutline: Shape {
    var wings: CGFloat
    var drop: CGFloat
    var topExtension: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(wings, drop) }
        set { (wings, drop) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let extensionAmount = min(1, max(0, wings))
        let descent = min(1, max(0, drop))
        let reach = max(extensionAmount, descent)
        guard reach > 0 else { return Path() }
        let factor = rect.width / VisorGeometry.artworkSize.width
        let middle = VisorGeometry.anchor

        let centerHalfWidth = 107 * reach
        let leftSpan = centerHalfWidth + (VisorGeometry.leftSpan - 107) * extensionAmount
        let rightSpan = centerHalfWidth + (VisorGeometry.rightSpan - 107) * extensionAmount
        let top = -topExtension * reach
        let wing = top + VisorGeometry.wingHeight * reach
        let bottom = VisorGeometry.wingHeight * reach + (VisorGeometry.depth - VisorGeometry.wingHeight) * descent
        let endRadius = VisorOuterCorner.radius * reach
        let leftShoulder = min(117 * reach, leftSpan - endRadius)
        let rightShoulder = min(117 * reach, rightSpan - endRadius)
        let floor = (57 + min(12, topExtension * 0.38)) * reach
        let leftCurve = leftShoulder - floor
        let rightCurve = rightShoulder - floor
        let leftEdge = middle - leftSpan
        let rightEdge = middle + rightSpan

        // Extend the right wing under the transport columns as the visor drops.
        let flatWingWidth = rightSpan - endRadius - rightShoulder
        let seekScale = flatWingWidth / (VisorGeometry.rightSpan - VisorOuterCorner.radius - 117)
        let seekBottom = wing + (95 - VisorGeometry.wingHeight) * descent * seekScale
        func seekX(_ offset: CGFloat) -> CGFloat {
            middle + rightShoulder + (offset - 117) * seekScale
        }

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * factor, y: rect.minY + (y + topExtension) * factor)
        }

        let cap = VisorOuterCorner.controlOffset(for: endRadius)
        var p = Path()
        p.move(to: point(leftEdge + endRadius, top))
        p.addLine(to: point(rightEdge - endRadius, top))
        p.addCurve(to: point(rightEdge, top + endRadius),
                   control1: point(rightEdge - cap, top), control2: point(rightEdge, top + cap))
        p.addLine(to: point(rightEdge, wing - endRadius))
        p.addCurve(to: point(rightEdge - endRadius, wing),
                   control1: point(rightEdge, wing - cap), control2: point(rightEdge - cap, wing))
        p.addLine(to: point(seekX(309), wing))
        p.addCurve(to: point(seekX(279), seekBottom),
                   control1: point(seekX(294), wing), control2: point(seekX(296), seekBottom))
        p.addLine(to: point(seekX(183), seekBottom))
        p.addCurve(to: point(seekX(153), wing),
                   control1: point(seekX(166), seekBottom), control2: point(seekX(168), wing))
        p.addLine(to: point(middle + rightShoulder, wing))
        p.addCurve(to: point(middle + floor, bottom),
                   control1: point(middle + rightShoulder - rightCurve * 0.53, wing),
                   control2: point(middle + floor + rightCurve * 0.48, bottom))
        p.addLine(to: point(middle - floor, bottom))
        p.addCurve(to: point(middle - leftShoulder, wing),
                   control1: point(middle - floor - leftCurve * 0.48, bottom),
                   control2: point(middle - leftShoulder + leftCurve * 0.53, wing))
        let lowerLeft = point(leftEdge, wing)
        VisorOuterCorner.addBottomLeft(to: &p, left: lowerLeft.x, bottom: lowerLeft.y,
                                      radius: endRadius * factor)
        p.addLine(to: point(leftEdge, top + endRadius))
        p.addCurve(to: point(leftEdge + endRadius, top),
                   control1: point(leftEdge, top + cap), control2: point(leftEdge + cap, top))
        p.closeSubpath()
        return p
    }
}

@MainActor
final class VisorPresentation: ObservableObject {
    @Published var wings: CGFloat = 0
    @Published var drop: CGFloat = 0
    @Published var topExtension: CGFloat = 0
    @Published var shortcutsExpanded = false
    @Published var shortcutScale: CGFloat = 1

    func settle(at progress: CGFloat) {
        wings = progress
        drop = progress
    }
}

struct VisorSurface: View {
    @ObservedObject var presentation: VisorPresentation

    var body: some View {
        let outline = VisorOutline(wings: presentation.wings, drop: presentation.drop,
                                   topExtension: presentation.topExtension)
        GeometryReader { geometry in
            let scale = geometry.size.width / VisorGeometry.artworkSize.width
            ZStack {
                outline.fill(.ultraThinMaterial)
                outline.fill(LinearGradient(
                    colors: [
                        Color(red: 0.125, green: 0.100, blue: 0.226).opacity(0.87),
                        Color(red: 0.052, green: 0.046, blue: 0.113).opacity(0.94)
                    ], startPoint: .top, endPoint: .bottom
                ))
                ZStack {
                    ForEach(VisorControl.backplates.indices, id: \.self) { index in
                        let offset = index == 1 ? presentation.topExtension : 0
                        backplate(VisorControl.backplates[index], scale: scale, offset: offset)
                    }
                }
                .opacity(min(presentation.wings, presentation.drop))
                .clipShape(outline)
                outline.stroke(
                    LinearGradient(colors: [
                        Color(red: 0.72, green: 0.45, blue: 1).opacity(0.88),
                        Color(red: 0.54, green: 0.32, blue: 0.92).opacity(0.72)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.25
                )
                .shadow(color: Color(red: 0.48, green: 0.19, blue: 1).opacity(0.62), radius: 7, y: 2)
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private func backplate(_ frame: CGRect, scale: CGFloat, offset: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: frame.height * 0.29 * scale)
            .fill(LinearGradient(colors: [
                Color(red: 0.63, green: 0.52, blue: 1).opacity(0.075), Color.black.opacity(0.09)
            ], startPoint: .top, endPoint: .bottom))
            .frame(width: frame.width * scale, height: frame.height * scale)
            .position(x: frame.midX * scale, y: (frame.midY + offset) * scale)
    }
}

// Clip the moving piece to its window and remove the part occluded by the visor.
struct QuickLaunchShape: Shape {
    var progress: CGFloat
    let rise: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / QuickLaunchLayout.width
        let offset = QuickLaunchLayout.leadingEdge(progress: progress) * scale
        let movingRect = rect.offsetBy(dx: offset, dy: 0)
        var piece = Path()
        piece.move(to: CGPoint(x: movingRect.minX, y: movingRect.minY))
        piece.addLine(to: CGPoint(x: movingRect.maxX, y: movingRect.minY))
        piece.addLine(to: CGPoint(x: movingRect.maxX, y: movingRect.maxY))
        VisorOuterCorner.addBottomLeft(to: &piece, left: movingRect.minX, bottom: movingRect.maxY,
                                      radius: VisorOuterCorner.radius * scale)
        piece.closeSubpath()
        let artwork = QuickLaunchLayout(rise: rise).artworkFrame
        let outlineRect = CGRect(x: rect.minX - artwork.minX * scale,
                                 y: rect.minY - (artwork.minY + rise) * scale,
                                 width: VisorGeometry.artworkSize.width * scale,
                                 height: VisorGeometry.artworkSize.height * scale)
        let visor = VisorOutline(wings: 1, drop: 1, topExtension: rise)
            .path(in: outlineRect)
        return piece.intersection(Path(rect)).subtracting(visor)
    }
}
