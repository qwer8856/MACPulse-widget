import AppKit

extension BatteryMetric {
    var iconImage: NSImage? {
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: summary)?.withSymbolConfiguration(.preferringMonochrome()) else { return nil }
        guard lowPowerMode else { return symbolImage }
        let image = NSImage(size: symbolImage.size, flipped: false) { rect in
            symbolImage.draw(in: rect)
            NSColor.systemYellow.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = summary
        return image
    }
}

enum MenuBarStyle: String, CaseIterable {
    case standard, compact, stacked

    var label: String {
        switch self {
        case .standard: return "默认横排"
        case .compact: return "紧凑图标"
        case .stacked: return "上下双行"
        }
    }
}

final class MenuBarStylePicker: NSSegmentedControl {
    var onChange: ((MenuBarStyle) -> Void)?
    var style: MenuBarStyle {
        get { MenuBarStyle.allCases.indices.contains(selectedSegment) ? MenuBarStyle.allCases[selectedSegment] : .standard }
        set { selectedSegment = MenuBarStyle.allCases.firstIndex(of: newValue)! }
    }

    init() {
        super.init(frame: .zero)
        segmentCount = MenuBarStyle.allCases.count
        trackingMode = .selectOne
        segmentDistribution = .fillEqually
        font = .systemFont(ofSize: 11)
        for (index, style) in MenuBarStyle.allCases.enumerated() { setLabel(style.label, forSegment: index) }
        style = .standard
        setAccessibilityLabel("菜单栏样式")
        target = self
        action = #selector(changeStyle)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changeStyle() { onChange?(style) }
}

struct MenuBarPresentation {
    let image: NSImage?
    let title: NSAttributedString
    let width: CGFloat
    let batteryOverlay: (image: NSImage, frame: NSRect)?

    init(style: MenuBarStyle, metrics: Set<MenuBarMetric>, snapshot: MetricsSnapshot?, battery: BatteryMetric?, updateAvailable: Bool) {
        let symbol = updateAvailable ? "arrow.down.circle.fill" : "waveform.path.ecg"
        let text: NSMutableAttributedString
        let baseWidth: CGFloat
        if metrics.isEmpty {
            batteryOverlay = nil
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: "系统状态")
            image?.size = NSSize(width: 14, height: 14)
            text = NSMutableAttributedString(attributedString: MenuBarMetric.attributedTitle(for: metrics, snapshot: snapshot, battery: battery))
            baseWidth = MenuBarMetric.width(for: metrics)
        } else {
            let rendered = Self.metricImage(style: style, metrics: metrics, snapshot: snapshot, battery: battery, symbol: symbol)
            image = rendered.image
            batteryOverlay = rendered.batteryFrame.flatMap { frame in battery?.iconImage.map { ($0, frame) } }
            text = NSMutableAttributedString(string: "")
            baseWidth = ceil(image!.size.width) + 20
        }
        let updateText = updateAvailable ? (text.length == 0 ? "有新版本" : "  有新版本") : ""
        text.append(NSAttributedString(string: updateText, attributes: [.font: MenuBarMetric.font]))
        title = text
        width = updateAvailable ? max(34, baseWidth) + ceil((updateText as NSString).size(withAttributes: [.font: MenuBarMetric.font]).width) + (metrics.isEmpty ? 0 : 4) : baseWidth
    }

    func apply(to statusItem: NSStatusItem) {
        if statusItem.length != width { statusItem.length = width }
        guard let button = statusItem.button else { return }
        button.attributedTitle = title
        button.image = image
        button.imagePosition = title.length == 0 ? .imageOnly : .imageLeading
        let existing = button.subviews.compactMap { $0 as? MenuBarBatteryOverlayView }.first
        if let batteryOverlay {
            let view = existing ?? MenuBarBatteryOverlayView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            view.overlay = batteryOverlay
            if view.superview == nil { button.addSubview(view) }
            view.needsDisplay = true
        } else { existing?.removeFromSuperview() }
    }

    private static func metricImage(style: MenuBarStyle, metrics: Set<MenuBarMetric>, snapshot: MetricsSnapshot?, battery: BatteryMetric?, symbol: String) -> (image: NSImage, batteryFrame: NSRect?) {
        let selected = MenuBarMetric.statusOrder.filter { metrics.contains($0) }
        let font = style == .stacked ? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium) : MenuBarMetric.font
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black]
        let networkLayout = NetworkRateLayout(font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium))
        let itemSpacing: CGFloat = style == .standard ? 8 : 4
        let networkSpacing: CGFloat = selected.count > 1 && metrics.contains(.network) ? (style == .standard ? 2 : 4) : 0
        let widths = selected.map { metric -> CGFloat in
            if metric == .network { return networkLayout.width }
            let maximum = metric == .power ? "1000.0 W" : "100%"
            let readingWidth = ceil((maximum as NSString).size(withAttributes: attributes).width)
            if style == .standard && metric != .battery {
                return ceil(((metric.label + " " + maximum) as NSString).size(withAttributes: attributes).width)
            }
            if style == .standard { return iconWidth(metric) + 3 + readingWidth }
            if style == .compact { return iconWidth(metric) + 3 + readingWidth }
            return max(readingWidth, metric == .battery ? 22 : ceil((metric.label as NSString).size(withAttributes: labelAttributes).width)) + 2
        }
        let height: CGFloat = 20
        let size = NSSize(width: 20 + widths.reduce(0, +) + CGFloat(max(0, selected.count - 1)) * itemSpacing + networkSpacing, height: height)
        var batteryFrame: NSRect?
        if battery?.lowPowerMode == true, let index = selected.firstIndex(of: .battery) {
            let x = 20 + widths.prefix(index).reduce(0, +) + CGFloat(index) * itemSpacing
            batteryFrame = style != .stacked ? NSRect(x: x, y: (height - 12) / 2, width: iconWidth(.battery), height: 12)
                : NSRect(x: x + (widths[index] - 20) / 2, y: 11, width: 20, height: 8)
        }
        // A template image lets the native status button tint both rows for light, dark and highlighted states.
        let image = NSImage(size: size, flipped: false) { _ in
            drawSymbol(symbol, in: NSRect(x: 0, y: (height - 14) / 2, width: 14, height: 14))
            var x: CGFloat = 20
            for (metric, width) in zip(selected, widths) {
                if metric == .network && networkSpacing > 0 {
                    x += networkSpacing
                    let divider = NSBezierPath()
                    divider.move(to: NSPoint(x: x - (itemSpacing + networkSpacing) / 2, y: 2))
                    divider.line(to: NSPoint(x: x - (itemSpacing + networkSpacing) / 2, y: height - 2))
                    divider.lineWidth = 0.5
                    NSColor.black.withAlphaComponent(0.3).setStroke()
                    divider.stroke()
                }
                let reading = value(metric, snapshot: snapshot, battery: battery) as NSString
                let readingSize = reading.size(withAttributes: attributes)
                if metric == .network {
                    networkLayout.draw(snapshot?.network?.uploadBytesPerSecond, arrow: "↑", at: NSPoint(x: x, y: 10))
                    networkLayout.draw(snapshot?.network?.downloadBytesPerSecond, arrow: "↓", at: NSPoint(x: x, y: 0))
                } else if style == .standard && metric != .battery {
                    let text = (metric.label + " " + (reading as String)) as NSString
                    text.draw(at: NSPoint(x: x, y: (height - text.size(withAttributes: attributes).height) / 2), withAttributes: attributes)
                } else if style != .stacked {
                    let symbolWidth = iconWidth(metric)
                    if metric != .battery || battery?.lowPowerMode != true {
                        drawSymbol(metricSymbol(metric, battery: battery), in: NSRect(x: x, y: (height - 12) / 2, width: symbolWidth, height: 12))
                    }
                    reading.draw(at: NSPoint(x: x + symbolWidth + 3, y: (height - readingSize.height) / 2), withAttributes: attributes)
                } else {
                    if metric == .battery {
                        if battery?.lowPowerMode != true {
                            drawSymbol(metricSymbol(metric, battery: battery), in: NSRect(x: x + (width - 20) / 2, y: 11, width: 20, height: 8))
                        }
                    } else {
                        let label = metric.label as NSString
                        let labelSize = label.size(withAttributes: labelAttributes)
                        label.draw(at: NSPoint(x: x + (width - labelSize.width) / 2, y: 10), withAttributes: labelAttributes)
                    }
                    reading.draw(at: NSPoint(x: x + (width - readingSize.width) / 2, y: 0), withAttributes: attributes)
                }
                x += width + itemSpacing
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = MenuBarMetric.title(for: metrics, snapshot: snapshot, battery: battery)
        return (image, batteryFrame)
    }

    private static func iconWidth(_ metric: MenuBarMetric) -> CGFloat { metric == .battery ? 21 : 14 }

    private static func metricSymbol(_ metric: MenuBarMetric, battery: BatteryMetric?) -> String {
        switch metric {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .power: return "bolt.fill"
        case .battery: return battery?.symbol ?? "battery.100percent"
        }
    }

    private static func drawSymbol(_ name: String, in rect: NSRect) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.preferringMonochrome()) else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    private static func value(_ metric: MenuBarMetric, snapshot: MetricsSnapshot?, battery: BatteryMetric?) -> String {
        switch metric {
        case .cpu: return MenuBarText.percent(snapshot?.cpu)
        case .memory: return MenuBarText.percent(snapshot?.memory?.percent)
        case .disk: return MenuBarText.percent(snapshot?.disk?.percent)
        case .network: return "↓ " + NetworkText.rate(snapshot?.network?.downloadBytesPerSecond) + " ↑ " + NetworkText.rate(snapshot?.network?.uploadBytesPerSecond)
        case .power: return snapshot.flatMap(MenuBarText.freshPower).map { String(format: "%.1f W", $0.watts) } ?? "--"
        case .battery: return MenuBarText.percent(battery?.percent)
        }
    }
}

private struct NetworkRateLayout {
    private let valueAttributes: [NSAttributedString.Key: Any]
    private let secondaryAttributes: [NSAttributedString.Key: Any]
    private let arrowWidth: CGFloat
    private let valueWidth: CGFloat
    private let unitWidth: CGFloat
    private let secondaryOffset: CGFloat

    var width: CGFloat { arrowWidth + 1 + valueWidth + 2 + unitWidth }

    init(font: NSFont) {
        valueAttributes = [.font: font, .foregroundColor: NSColor.black]
        let secondary: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.black.withAlphaComponent(0.65)]
        secondaryAttributes = secondary
        arrowWidth = ceil(("↓" as NSString).size(withAttributes: secondaryAttributes).width)
        valueWidth = ceil(max(("99.9" as NSString).size(withAttributes: valueAttributes).width,
                              ("1000" as NSString).size(withAttributes: valueAttributes).width))
        unitWidth = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s", "EB/s"]
            .map { ceil(($0 as NSString).size(withAttributes: secondary).width) }.max()!
        secondaryOffset = (("0" as NSString).size(withAttributes: valueAttributes).height - ("0" as NSString).size(withAttributes: secondaryAttributes).height) / 2
    }

    func draw(_ bytesPerSecond: Double?, arrow: String, at origin: NSPoint) {
        let parts = NetworkText.rateComponents(bytesPerSecond, compact: true)
        (arrow as NSString).draw(at: NSPoint(x: origin.x, y: origin.y + secondaryOffset), withAttributes: secondaryAttributes)
        let value = parts.value as NSString
        value.draw(at: NSPoint(x: origin.x + arrowWidth + 1 + valueWidth - value.size(withAttributes: valueAttributes).width, y: origin.y), withAttributes: valueAttributes)
        (parts.unit as NSString).draw(at: NSPoint(x: origin.x + arrowWidth + 1 + valueWidth + 2, y: origin.y + secondaryOffset), withAttributes: secondaryAttributes)
    }
}

// Keep the native template tint for text while drawing the battery in its own color.
private final class MenuBarBatteryOverlayView: NSView {
    var overlay: (image: NSImage, frame: NSRect)?
    override var isFlipped: Bool { superview?.isFlipped ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let button = superview as? NSStatusBarButton, let baseImage = button.image,
              let imageRect = button.cell?.imageRect(forBounds: button.bounds), let overlay,
              baseImage.size.width > 0, baseImage.size.height > 0 else { return }
        let scaleX = imageRect.width / baseImage.size.width, scaleY = imageRect.height / baseImage.size.height
        let frame = overlay.frame
        let rect = NSRect(x: imageRect.minX + frame.minX * scaleX,
            y: imageRect.minY + (isFlipped ? baseImage.size.height - frame.maxY : frame.minY) * scaleY,
            width: frame.width * scaleX, height: frame.height * scaleY)
        let scale = min(rect.width / overlay.image.size.width, rect.height / overlay.image.size.height)
        let size = NSSize(width: overlay.image.size.width * scale, height: overlay.image.size.height * scale)
        overlay.image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
