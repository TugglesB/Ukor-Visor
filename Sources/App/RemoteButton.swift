import AppKit

final class RokuButton: NSButton {
    private let key: RokuKey?
    private let glyph: NSImage?
    private let label: String
    private var tracking: NSTrackingArea?
    private var inside = false
    private var pressed = false
    private let repeater = DirectionRepeat()
    var send: ((RokuKey, Bool) -> Void)?

    var performLocalAction: (() -> Void)?

    init(key: RokuKey?, symbol: String, label: String) {
        self.key = key
        self.label = label
        let fallback: String?
        switch key {
        case .quieter: fallback = "speaker.wave.1.fill"
        case .louder: fallback = "speaker.wave.3.fill"
        default: fallback = nil
        }
        let image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph = (image ?? fallback.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) })?
            .withSymbolConfiguration(.init(pointSize: key == nil ? 11 : (key == .power || key == .options ? 22 : 17),
                                           weight: .semibold))
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        target = self
        action = #selector(activate)
        setAccessibilityLabel(label)
        toolTip = label
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { isEnabled }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { cancelPress() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelPress() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        inside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        inside = false
        cancelPress()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        pressed = true
        needsDisplay = true
        if let key, key.repeats {
            repeater.start(key) { [weak self] key, isRepeat in self?.send?(key, isRepeat) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if !bounds.contains(convert(event.locationInWindow, from: nil)) { cancelPress() }
    }

    override func mouseUp(with event: NSEvent) {
        let trigger = pressed && key?.repeats != true && bounds.contains(convert(event.locationInWindow, from: nil))
        cancelPress()
        if trigger { activate() }
    }

    override func resignFirstResponder() -> Bool {
        cancelPress()
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "\r" else {
            super.keyDown(with: event)
            return
        }
        if !event.isARepeat { activate() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate()
        return true
    }

    @objc private func activate() {
        guard isEnabled else { return }
        if let key { send?(key, false) } else { performLocalAction?() }
    }

    private func cancelPress() {
        repeater.stop()
        pressed = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let compactPill = key?.repeats == true || key == .ok
        let corner = compactPill ? rect.height / 2 : min(11, rect.height / 2)
        let outline = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        let hovered = inside && isEnabled
        let top: NSColor
        let bottom: NSColor
        if key == .ok {
            top = NSColor(srgbRed: pressed ? 0.48 : 0.60, green: pressed ? 0.20 : 0.31,
                          blue: 1, alpha: isEnabled ? 1 : 0.72)
            bottom = NSColor(srgbRed: 0.38, green: 0.16, blue: 0.87, alpha: isEnabled ? 1 : 0.72)
        } else {
            let light = pressed ? 0.24 : hovered ? 0.43 : 0.32
            let opacity = isEnabled ? 1.0 : 0.55
            top = NSColor(srgbRed: light * 0.81, green: light * 0.75, blue: light,
                          alpha: opacity)
            bottom = NSColor(srgbRed: 0.127, green: 0.111, blue: 0.219, alpha: opacity)
        }
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        if let gradient = NSGradient(starting: top, ending: bottom) {
            let upper = CGPoint(x: rect.midX, y: isFlipped ? rect.minY : rect.maxY)
            let lower = CGPoint(x: rect.midX, y: isFlipped ? rect.maxY : rect.minY)
            gradient.draw(from: upper, to: lower, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        } else {
            top.setFill()
            outline.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        NSColor(srgbRed: 0.77, green: 0.66, blue: 1,
                alpha: focused ? 0.68 : hovered ? 0.42 : isEnabled ? 0.22 : 0.11).setStroke()
        outline.lineWidth = focused ? 1.5 : 0.9
        outline.stroke()

        let tint = NSColor.white.withAlphaComponent(isEnabled ? 0.92 : 0.29)
        if key == .ok {
            let style: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: min(19, bounds.height * 0.64), weight: .bold), .foregroundColor: tint
            ]
            let size = (label as NSString).size(withAttributes: style)
            (label as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                     withAttributes: style)
        } else if let key, let direction = DirectionGlyph.tipVector(for: key, flipped: isFlipped) {
            drawArrow(direction, tint: tint)
        } else if let glyph {
            let fit = min(1, bounds.width * 0.68 / glyph.size.width, bounds.height * 0.70 / glyph.size.height)
            let size = CGSize(width: glyph.size.width * fit, height: glyph.size.height * fit)
            let target = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: target).addClip()
            NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
            glyph.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            tint.setFill()
            target.fill(using: .sourceAtop)
            NSGraphicsContext.current?.cgContext.endTransparencyLayer()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawArrow(_ direction: CGVector, tint: NSColor) {
        let radius = min(9, bounds.height * 0.31)
        let head = radius * 0.62
        func point(_ axial: CGFloat, _ lateral: CGFloat = 0) -> CGPoint {
            CGPoint(x: bounds.midX + direction.dx * axial - direction.dy * lateral,
                    y: bounds.midY + direction.dy * axial + direction.dx * lateral)
        }

        let arrow = NSBezierPath()
        arrow.move(to: point(-radius))
        arrow.line(to: point(radius))
        arrow.move(to: point(radius - head, -head))
        arrow.line(to: point(radius))
        arrow.line(to: point(radius - head, head))
        arrow.lineWidth = 2.1
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        tint.setStroke()
        arrow.stroke()
    }
}
