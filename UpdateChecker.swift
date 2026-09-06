import AppKit

struct ReleaseVersion: Comparable {
    let components: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        components = parts.compactMap { Int($0) }
    }
    var text: String { components.map(String.init).joined(separator: ".") }
    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct PublishedRelease {
    let version: ReleaseVersion
    let url: URL
    static func decode(_ data: Data) throws -> PublishedRelease {
        struct Payload: Decodable {
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
        }
        let release = try JSONDecoder().decode(Payload.self, from: data)
        guard !release.draft, !release.prerelease, let version = ReleaseVersion(release.tag_name) else {
            throw URLError(.cannotParseResponse)
        }
        return PublishedRelease(version: version, url: URL(string: "https://github.com/qwer8856/MACPulse-widget/releases/tag/" + release.tag_name)!)
    }
}

enum UpdatePhase { case idle, checking, finished, failed }

struct UpdateState {
    let currentVersion: String
    var release: PublishedRelease?
    var phase: UpdatePhase = .idle
    var error: String?
    var available: Bool {
        guard let current = ReleaseVersion(currentVersion), let release else { return false }
        return release.version > current
    }
    var message: String {
        switch phase {
        case .idle: return "尚未检查更新"
        case .checking: return "正在检查更新…"
        case .failed: return error ?? "检查失败，请重试"
        case .finished:
            if available { return "有新版本" }
            if let current = ReleaseVersion(currentVersion), let release, current > release.version { return "当前版本高于正式发布版" }
            return "已是最新版本"
        }
    }
}

final class UpdateChecker {
    static let endpoint = URL(string: "https://api.github.com/repos/qwer8856/MACPulse-widget/releases/latest")!
    static var installedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    private let session: URLSession
    private var task: URLSessionDataTask?
    private var generation = UUID()
    private(set) var state: UpdateState
    var onChange: ((UpdateState) -> Void)?

    init(currentVersion: String = UpdateChecker.installedVersion, session: URLSession? = nil) {
        state = UpdateState(currentVersion: currentVersion)
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }
    func check() {
        precondition(Thread.isMainThread)
        guard task == nil else { return }
        guard ReleaseVersion(state.currentVersion) != nil else {
            state.phase = .failed; state.error = "无法识别当前版本"; onChange?(state); return
        }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MacPulse-Widget/" + state.currentVersion, forHTTPHeaderField: "User-Agent")
        let token = UUID(); generation = token
        state.phase = .checking; state.error = nil
        task = session.dataTask(with: request) { [weak self] data, response, error in
            let release: PublishedRelease?
            let message: String?
            if let error = error as? URLError {
                release = nil
                message = error.code == .timedOut ? "检查超时，请重试" : "无法连接 GitHub，请重试"
            } else if let response = response as? HTTPURLResponse, response.statusCode == 200, response.url == Self.endpoint,
                      let data, data.count <= 2_000_000, let parsed = try? PublishedRelease.decode(data) {
                release = parsed; message = nil
            } else {
                release = nil
                let code = (response as? HTTPURLResponse)?.statusCode
                message = code == 403 || code == 429 ? "检查频率受限，请稍后重试" : (code == 404 ? "暂无正式发布版本" : "无法读取版本信息，请重试")
            }
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in
                guard let self, self.generation == token else { return }
                self.task = nil
                self.state.phase = release == nil ? .failed : .finished
                if let release { self.state.release = release }
                self.state.error = message
                self.onChange?(self.state)
            }
        }
        onChange?(state)
        task?.resume()
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

final class UpdateStatusView: NSView {
    let current = NSTextField(labelWithString: "")
    let latest = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "尚未检查更新")
    let checkButton = NSButton()
    let downloadButton = NSButton()
    var onCheck: (() -> Void)?
    var onDownload: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let separator = NSBox(); separator.boxType = .separator
        for field in [current, latest, status] {
            field.font = .systemFont(ofSize: 11)
            field.lineBreakMode = .byTruncatingTail
        }
        latest.alignment = .right
        for (button, symbol, title, action) in [(checkButton, "arrow.triangle.2.circlepath", "检查更新", #selector(check)), (downloadButton, "arrow.down.to.line", "下载新版本", #selector(download))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageOnly; button.bezelStyle = .rounded
            button.target = self; button.action = action; button.toolTip = title
            button.setAccessibilityLabel(title)
        }
        for view in [separator, current, latest, status, checkButton, downloadButton] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor), separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            current.leadingAnchor.constraint(equalTo: leadingAnchor), current.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            latest.trailingAnchor.constraint(equalTo: trailingAnchor), latest.centerYAnchor.constraint(equalTo: current.centerYAnchor),
            current.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -4), latest.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: leadingAnchor), status.centerYAnchor.constraint(equalTo: checkButton.centerYAnchor),
            status.trailingAnchor.constraint(equalTo: checkButton.leadingAnchor, constant: -8),
            downloadButton.trailingAnchor.constraint(equalTo: trailingAnchor), downloadButton.widthAnchor.constraint(equalToConstant: 32),
            downloadButton.topAnchor.constraint(equalTo: current.bottomAnchor, constant: 6), downloadButton.heightAnchor.constraint(equalToConstant: 24),
            checkButton.trailingAnchor.constraint(equalTo: downloadButton.leadingAnchor, constant: -6), checkButton.widthAnchor.constraint(equalToConstant: 32),
            checkButton.centerYAnchor.constraint(equalTo: downloadButton.centerYAnchor), checkButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        update(UpdateState(currentVersion: UpdateChecker.installedVersion))
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ state: UpdateState) {
        current.stringValue = "当前 " + state.currentVersion
        latest.stringValue = (state.available ? "新版本 " : "最新 ") + (state.release?.version.text ?? "--")
        latest.textColor = state.available ? .systemBlue : .secondaryLabelColor
        status.stringValue = state.message
        status.textColor = state.available ? .systemBlue : .secondaryLabelColor
        current.toolTip = current.stringValue; latest.toolTip = latest.stringValue; status.toolTip = state.message
        checkButton.isEnabled = state.phase != .checking
        downloadButton.isEnabled = state.available
    }
    @objc private func check() { onCheck?() }
    @objc private func download() { onDownload?() }
}
