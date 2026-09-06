import AppKit

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

    init(style: MenuBarStyle, metrics: Set<MenuBarMetric>, snapshot: MetricsSnapshot?, battery: BatteryMetric?, updateAvailable: Bool) {
        let symbol = updateAvailable ? "arrow.down.circle.fill" : "waveform.path.ecg"
        let text: NSMutableAttributedString
        let baseWidth: CGFloat
        if style == .standard || metrics.isEmpty {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: "系统状态")
            image?.size = NSSize(width: 14, height: 14)
            text = NSMutableAttributedString(attributedString: MenuBarMetric.attributedTitle(for: metrics, snapshot: snapshot, battery: battery))
            baseWidth = MenuBarMetric.width(for: metrics)
        } else {
            image = Self.metricImage(style: style, metrics: metrics, snapshot: snapshot, battery: battery, symbol: symbol)
            text = NSMutableAttributedString(string: "")
            baseWidth = ceil(image!.size.width) + 20
        }
        let updateText = updateAvailable ? (text.length == 0 ? "有新版本" : "  有新版本") : ""
        text.append(NSAttributedString(string: updateText, attributes: [.font: MenuBarMetric.font]))
        title = text
        width = updateAvailable ? max(34, baseWidth) + ceil((updateText as NSString).size(withAttributes: [.font: MenuBarMetric.font]).width) + (style != .standard && !metrics.isEmpty ? 4 : 0) : baseWidth
    }

    private static func metricImage(style: MenuBarStyle, metrics: Set<MenuBarMetric>, snapshot: MetricsSnapshot?, battery: BatteryMetric?, symbol: String) -> NSImage {
        let selected = MenuBarMetric.allCases.filter { metrics.contains($0) }
        let font = style == .stacked ? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium) : MenuBarMetric.font
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black]
        let widths = selected.map { metric -> CGFloat in
            let maximum = metric == .power ? "1000.0 W" : "100%"
            let readingWidth = ceil((maximum as NSString).size(withAttributes: attributes).width)
            if style == .compact { return iconWidth(metric) + 3 + readingWidth }
            return max(readingWidth, metric == .battery ? 22 : ceil((metric.label as NSString).size(withAttributes: labelAttributes).width)) + 2
        }
        let height: CGFloat = style == .stacked ? 20 : 18
        let size = NSSize(width: 20 + widths.reduce(0, +) + CGFloat(max(0, selected.count - 1)) * 8, height: height)
        // A template image lets the native status button tint both rows for light, dark and highlighted states.
        let image = NSImage(size: size, flipped: false) { _ in
            drawSymbol(symbol, in: NSRect(x: 0, y: (height - 14) / 2, width: 14, height: 14))
            var x: CGFloat = 20
            for (metric, width) in zip(selected, widths) {
                let reading = value(metric, snapshot: snapshot, battery: battery) as NSString
                let readingSize = reading.size(withAttributes: attributes)
                if style == .compact {
                    let symbolWidth = iconWidth(metric)
                    drawSymbol(metricSymbol(metric, battery: battery), in: NSRect(x: x, y: (height - 12) / 2, width: symbolWidth, height: 12))
                    reading.draw(at: NSPoint(x: x + symbolWidth + 3, y: (height - readingSize.height) / 2), withAttributes: attributes)
                } else {
                    if metric == .battery {
                        drawSymbol(metricSymbol(metric, battery: battery), in: NSRect(x: x + (width - 20) / 2, y: 11, width: 20, height: 8))
                    } else {
                        let label = metric.label as NSString
                        let labelSize = label.size(withAttributes: labelAttributes)
                        label.draw(at: NSPoint(x: x + (width - labelSize.width) / 2, y: 10), withAttributes: labelAttributes)
                    }
                    reading.draw(at: NSPoint(x: x + (width - readingSize.width) / 2, y: 0), withAttributes: attributes)
                }
                x += width + 8
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func iconWidth(_ metric: MenuBarMetric) -> CGFloat { metric == .battery ? 21 : 14 }

    private static func metricSymbol(_ metric: MenuBarMetric, battery: BatteryMetric?) -> String {
        switch metric {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
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
        case .power: return snapshot.flatMap(MenuBarText.freshPower).map { String(format: "%.1f W", $0.watts) } ?? "--"
        case .battery: return MenuBarText.percent(battery?.percent)
        }
    }
}
