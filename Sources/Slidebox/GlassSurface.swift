import AppKit

/// Uses system glass; older systems and Reduce Transparency keep usable contrast.
final class GlassSurface: NSView {
    let body = NSView()
    private var material: NSView?
    private var observer: NSObjectProtocol?
    private let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        body.autoresizingMask = [.width, .height]
        rebuildMaterial()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.rebuildMaterial() } }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    private func rebuildMaterial() {
        body.removeFromSuperview(); material?.removeFromSuperview()
        let background: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            background = SurfaceView(color: .windowBackgroundColor)
            background.addSubview(body)
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular; glass.cornerRadius = radius; glass.contentView = body
            background = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover; blur.blendingMode = .withinWindow; blur.state = .active
            blur.addSubview(body); background = blur
        }
        background.wantsLayer = true
        background.layer?.cornerRadius = radius
        background.layer?.masksToBounds = true
        background.frame = bounds; background.autoresizingMask = [.width, .height]
        body.frame = bounds
        addSubview(background); material = background
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12; layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
    }

    override func layout() {
        super.layout()
        material?.frame = bounds; body.frame = bounds
        // Avoid deriving the shadow from the live blurred web content on each frame.
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
