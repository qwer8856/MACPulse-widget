import AppKit

private final class NetworkHistoryGraphView: NSView {
    private var downloads: [Double] = []
    private var uploads: [Double] = []

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 82) }

    func append(_ metric: NetworkMetric?) {
        let download = max(0, metric?.downloadBytesPerSecond ?? 0)
        let upload = max(0, metric?.uploadBytesPerSecond ?? 0)
        downloads.append(download)
        uploads.append(upload)
        if downloads.count > 60 { downloads.removeFirst(downloads.count - 60) }
        if uploads.count > 60 { uploads.removeFirst(uploads.count - 60) }
        setAccessibilityElement(true)
        setAccessibilityLabel("最近 60 个网络速率样本")
        setAccessibilityValue("下载 \(NetworkText.rate(metric?.downloadBytesPerSecond))，上传 \(NetworkText.rate(metric?.uploadBytesPerSecond))")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let drawingBounds = bounds.insetBy(dx: 1, dy: 1)
        guard drawingBounds.width > 2, drawingBounds.height > 2 else { return }

        NSColor.labelColor.withAlphaComponent(0.10).setStroke()
        let midline = NSBezierPath()
        midline.move(to: NSPoint(x: drawingBounds.minX, y: drawingBounds.midY))
        midline.line(to: NSPoint(x: drawingBounds.maxX, y: drawingBounds.midY))
        midline.lineWidth = 1
        midline.stroke()

        let maximum = max(1, (downloads + uploads).max() ?? 0)
        drawLine(downloads, in: drawingBounds, maximum: maximum, color: .systemCyan)
        drawLine(uploads, in: drawingBounds, maximum: maximum, color: .systemGreen)
    }

    private func drawLine(_ readings: [Double], in rect: NSRect, maximum: Double, color: NSColor) {
        guard readings.count > 1, maximum > 0 else { return }
        let path = NSBezierPath()
        for (index, reading) in readings.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(max(1, readings.count - 1))
            let y = rect.maxY - rect.height * CGFloat(min(1, max(0, reading / maximum)))
            index == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
        }
        color.withAlphaComponent(0.88).setStroke()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
    }
}

final class NetworkDetailsView: NSView {
    private let compact: Bool
    private let speedTest: NetworkSpeedTest
    private let downloadValue = NSTextField(labelWithString: "--")
    private let uploadValue = NSTextField(labelWithString: "--")
    private let interfacesValue = NSTextField(labelWithString: "正在读取")
    private let receivedValue = NSTextField(labelWithString: "0 B")
    private let sentValue = NSTextField(labelWithString: "0 B")
    private let graph = NetworkHistoryGraphView(frame: .zero)
    private let speedStatus = NSTextField(labelWithString: "手动测速，未开始")
    private let downloadResult = NSTextField(labelWithString: "--")
    private let uploadResult = NSTextField(labelWithString: "--")
    private let latencyResult = NSTextField(labelWithString: "--")
    private let completedAt = NSTextField(labelWithString: "")
    private let activity = NSProgressIndicator()
    private var startButton: NSButton!
    private var cancelButton: NSButton!
    private var observerToken: UUID?
    private var lastSampledAt: Date?

    var preferredHeight: CGFloat { compact ? 286 : 306 }

    init(compact: Bool = false, speedTest: NetworkSpeedTest = .shared) {
        self.compact = compact
        self.speedTest = speedTest
        super.init(frame: NSRect(x: 0, y: 0, width: compact ? 492 : 740, height: compact ? 286 : 306))
        buildView()
        observerToken = speedTest.addObserver { [weak self] state in
            self?.updateSpeedTest(state)
        }
        updateSpeedTest(speedTest.state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observerToken { speedTest.removeObserver(observerToken) }
    }

    func update(_ metric: NetworkMetric?) {
        downloadValue.stringValue = NetworkText.rate(metric?.downloadBytesPerSecond)
        uploadValue.stringValue = NetworkText.rate(metric?.uploadBytesPerSecond)
        if let metric {
            interfacesValue.stringValue = metric.interfaces.isEmpty ? "未检测到已连接的 Wi-Fi 或以太网" : metric.interfaces.joined(separator: "  ·  ")
        } else {
            interfacesValue.stringValue = "等待网络采样"
        }
        receivedValue.stringValue = NetworkText.bytes(metric?.receivedBytes ?? 0)
        sentValue.stringValue = NetworkText.bytes(metric?.sentBytes ?? 0)
        interfacesValue.toolTip = interfacesValue.stringValue

        if let metric, metric.sampledAt != lastSampledAt {
            graph.append(metric)
            lastSampledAt = metric.sampledAt
        }
    }

    private func buildView() {
        let downloadLabel = valueLabel("下载", color: .systemCyan)
        let uploadLabel = valueLabel("上传", color: .systemGreen)
        for field in [downloadValue, uploadValue] {
            field.font = .monospacedDigitSystemFont(ofSize: compact ? 15 : 17, weight: .semibold)
            field.alignment = .right
        }
        interfacesValue.font = .systemFont(ofSize: 11)
        interfacesValue.textColor = .secondaryLabelColor
        interfacesValue.lineBreakMode = .byTruncatingMiddle
        for field in [receivedValue, sentValue] {
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            field.alignment = .right
        }

        let interfaceTitle = valueLabel("联网网卡", color: .secondaryLabelColor)
        let receivedTitle = valueLabel("本次接收", color: .secondaryLabelColor)
        let sentTitle = valueLabel("本次发送", color: .secondaryLabelColor)
        let graphTitle = NSTextField(labelWithString: "速率趋势")
        graphTitle.font = .systemFont(ofSize: 11, weight: .medium)
        let legend = NSTextField(labelWithString: "下载")
        legend.font = .systemFont(ofSize: 10)
        legend.textColor = .systemCyan
        let uploadLegend = NSTextField(labelWithString: "上传")
        uploadLegend.font = .systemFont(ofSize: 10)
        uploadLegend.textColor = .systemGreen
        let legends = NSStackView(views: [legend, uploadLegend])
        legends.orientation = .horizontal; legends.spacing = 10

        let graphHeader = NSView(frame: .zero)
        for view in [graphTitle, legends] { view.translatesAutoresizingMaskIntoConstraints = false; graphHeader.addSubview(view) }
        NSLayoutConstraint.activate([
            graphTitle.leadingAnchor.constraint(equalTo: graphHeader.leadingAnchor), graphTitle.centerYAnchor.constraint(equalTo: graphHeader.centerYAnchor),
            legends.trailingAnchor.constraint(equalTo: graphHeader.trailingAnchor), legends.centerYAnchor.constraint(equalTo: graphHeader.centerYAnchor)
        ])

        let separator = NSBox(); separator.boxType = .separator
        let speedTitle = NSTextField(labelWithString: "网络测速")
        speedTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        startButton = NSButton(title: "开始测速", target: self, action: #selector(startSpeedTest))
        startButton.bezelStyle = .rounded
        startButton.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "开始网络测速")
        startButton.imagePosition = .imageLeading
        startButton.toolTip = "约 15 秒，可能消耗较多流量；结果受服务器和代理影响。"
        startButton.setAccessibilityHelp(startButton.toolTip)
        startButton.identifier = NSUserInterfaceItemIdentifier("network-speed-test-start")
        startButton.setAccessibilityLabel("开始网络测速")
        startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        startButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        cancelButton = NSButton(image: NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "取消测速")!, target: self, action: #selector(cancelSpeedTest))
        cancelButton.bezelStyle = .rounded
        cancelButton.toolTip = "取消当前测速"
        cancelButton.identifier = NSUserInterfaceItemIdentifier("network-speed-test-cancel")
        cancelButton.setAccessibilityLabel("取消网络测速")
        cancelButton.isHidden = true
        cancelButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        cancelButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        activity.style = .spinning
        activity.controlSize = .small
        activity.isDisplayedWhenStopped = false
        speedStatus.font = .systemFont(ofSize: 11)
        speedStatus.textColor = .secondaryLabelColor
        speedStatus.lineBreakMode = .byTruncatingTail
        completedAt.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        completedAt.textColor = .tertiaryLabelColor
        completedAt.alignment = .right
        completedAt.setContentCompressionResistancePriority(.required, for: .horizontal)

        let speedResults = resultRow()
        let resultNames = ["下载", "上传", "延迟"]
        let resultValues = [downloadResult, uploadResult, latencyResult]
        for (index, name) in resultNames.enumerated() {
            let caption = NSTextField(labelWithString: name)
            caption.font = .systemFont(ofSize: 10)
            caption.textColor = .secondaryLabelColor
            let value = resultValues[index]
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            value.alignment = .left
            let column = NSStackView(views: [caption, value])
            column.orientation = .horizontal; column.spacing = 4; column.alignment = .centerY
            caption.setContentHuggingPriority(.required, for: .horizontal)
            caption.setContentCompressionResistancePriority(.required, for: .horizontal)
            speedResults.addArrangedSubview(column)
        }

        let rateRows = [
            row(downloadLabel, downloadValue), row(uploadLabel, uploadValue),
            row(interfaceTitle, interfacesValue), row(receivedTitle, receivedValue), row(sentTitle, sentValue)
        ]
        let rateStack = NSStackView(views: rateRows)
        rateStack.orientation = .vertical; rateStack.alignment = .leading; rateStack.spacing = 4
        rateStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        for row in rateRows { row.widthAnchor.constraint(equalTo: rateStack.widthAnchor).isActive = true }

        let controls = NSStackView()
        controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing = 6
        controls.detachesHiddenViews = false
        for control in [startButton!, cancelButton!, activity] { controls.addArrangedSubview(control) }
        // Keep the start control at a stable position while the stop/spinner controls appear.
        controls.widthAnchor.constraint(equalToConstant: 168).isActive = true
        for view in [rateStack, graphHeader, graph, separator, speedTitle, controls, speedStatus, speedResults, completedAt] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let graphHeight: CGFloat = compact ? 72 : 92
        NSLayoutConstraint.activate([
            rateStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), rateStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), rateStack.topAnchor.constraint(equalTo: topAnchor),
            graphHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), graphHeader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), graphHeader.topAnchor.constraint(equalTo: rateStack.bottomAnchor, constant: 10), graphHeader.heightAnchor.constraint(equalToConstant: 16),
            graph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), graph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), graph.topAnchor.constraint(equalTo: graphHeader.bottomAnchor, constant: 3), graph.heightAnchor.constraint(equalToConstant: graphHeight),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), separator.topAnchor.constraint(equalTo: graph.bottomAnchor, constant: 10),
            speedTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), speedTitle.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), controls.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            speedStatus.leadingAnchor.constraint(equalTo: speedTitle.trailingAnchor, constant: 10), speedStatus.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -8), speedStatus.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            speedResults.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), speedResults.trailingAnchor.constraint(equalTo: completedAt.leadingAnchor, constant: -12), speedResults.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 2), speedResults.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            completedAt.widthAnchor.constraint(equalToConstant: 64), completedAt.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), completedAt.centerYAnchor.constraint(equalTo: speedResults.centerYAnchor)
        ])
        speedTitle.setContentHuggingPriority(.required, for: .horizontal)
        speedTitle.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Keep this as a labelled accessibility group without hiding the native buttons inside it.
        setAccessibilityElement(false)
        setAccessibilityLabel("网络详情")
        update(nil)
    }

    private func valueLabel(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = color
        return label
    }

    private func row(_ label: NSTextField, _ value: NSTextField) -> NSView {
        let container = NSView(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        value.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label); container.addSubview(value)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor), label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            value.trailingAnchor.constraint(equalTo: container.trailingAnchor), value.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12)
        ])
        return container
    }

    private func resultRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fillEqually
        return row
    }

    @objc private func startSpeedTest() { speedTest.start() }
    @objc private func cancelSpeedTest() { speedTest.cancel() }

    // Internal for deterministic previews; production updates arrive through the shared observer.
    func updateSpeedTest(_ state: SpeedTestState) {
        let result = state.result
        downloadResult.stringValue = formatMbps(result?.downloadMbps)
        uploadResult.stringValue = formatMbps(result?.uploadMbps)
        latencyResult.stringValue = formatLatency(result?.latencyMilliseconds)
        if let measuredAt = result?.measuredAt {
            completedAt.stringValue = "完成 \(Self.timeFormatter.string(from: measuredAt))"
        } else {
            completedAt.stringValue = ""
        }
        let message = state.message.trimmingCharacters(in: .whitespacesAndNewlines)
        speedStatus.stringValue = state.isRunning ? (message.isEmpty ? "正在测速" : message) : (message.isEmpty ? "手动测速，未开始" : message)
        startButton.isEnabled = !state.isRunning
        cancelButton.isHidden = !state.isRunning
        if state.isRunning { activity.startAnimation(nil) } else { activity.stopAnimation(nil) }
        speedStatus.toolTip = speedStatus.stringValue
    }

    private func formatMbps(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "--" }
        return String(format: "%.1f Mbps", value)
    }

    private func formatLatency(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "--" }
        return String(format: "%.0f ms", value)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
