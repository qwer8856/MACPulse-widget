import AppKit
import Darwin
import Foundation

enum SpeedTestPhase: Equatable {
    case idle
    case running
    case finished
    case failed
    case cancelled
}

struct SpeedTestResult {
    let downloadMbps: Double?
    let uploadMbps: Double?
    let latencyMilliseconds: Double?
    let measuredAt: Date

    var hasMeasurement: Bool {
        downloadMbps != nil || uploadMbps != nil || latencyMilliseconds != nil
    }
}

struct SpeedTestState {
    let phase: SpeedTestPhase
    let result: SpeedTestResult?
    let message: String
    let isRunning: Bool
    let startedAt: Date?

    static let idle = SpeedTestState(phase: .idle, result: nil, message: "尚未测速", isRunning: false, startedAt: nil)
}

/// Runs the system networkQuality utility directly. All public state and callbacks are confined to the main thread.
final class NetworkSpeedTest {
    static let shared = NetworkSpeedTest()

    private static let maximumCapturedOutput = 1_000_000
    private static let defaultTimeout: TimeInterval = 40
    private static let defaultExecutable = URL(fileURLWithPath: "/usr/bin/networkQuality")
    // -M bounds the tool run; the outer timeout leaves time to drain output and clean up.
    private static let defaultArguments = ["-c", "-s", "-M", "15"]

    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let completionQueue = DispatchQueue(label: "local.macpulse.network-speed-test", qos: .utility, attributes: .concurrent)
    private var process: Process?
    private var timeoutWorkItem: DispatchWorkItem?
    private var generation = UUID()
    private var observers: [UUID: (SpeedTestState) -> Void] = [:]
    // Cancellation removes an active process from the UI state, but it remains retained here until it exits.
    private var terminatingProcesses: [ObjectIdentifier: Process] = [:]
    private(set) var state: SpeedTestState = .idle

    /// Alternate executable and arguments are for deterministic tests; production uses /usr/bin/networkQuality -c -s.
    init(executableURL: URL = NetworkSpeedTest.defaultExecutable,
         arguments: [String] = NetworkSpeedTest.defaultArguments,
         timeout: TimeInterval = NetworkSpeedTest.defaultTimeout) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = max(1, timeout.isFinite ? timeout : NetworkSpeedTest.defaultTimeout)
    }

    @discardableResult
    func addObserver(_ observer: @escaping (SpeedTestState) -> Void) -> UUID {
        precondition(Thread.isMainThread)
        let identifier = UUID()
        observers[identifier] = observer
        observer(state)
        return identifier
    }

    func removeObserver(_ identifier: UUID) {
        precondition(Thread.isMainThread)
        observers.removeValue(forKey: identifier)
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !state.isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            publish(phase: .failed, result: nil, message: "系统测速工具不可用", startedAt: nil)
            return
        }

        let token = UUID()
        generation = token
        let startedAt = Date()
        publish(phase: .running, result: nil, message: "正在测速…", startedAt: startedAt)

        let stdout = Pipe()
        let stderr = Pipe()
        let output = CapturedOutput(limit: Self.maximumCapturedOutput)
        let errors = CapturedOutput(limit: Self.maximumCapturedOutput)
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        drainGroup.enter()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self, weak process] finishedProcess in
            guard let self, process === finishedProcess else { return }
            let status = finishedProcess.terminationStatus
            let reason = finishedProcess.terminationReason
            drainGroup.notify(queue: self.completionQueue) { [weak self, weak process] in
                guard let self, let process else { return }
                let completion = Self.completion(for: status,
                                                 reason: reason,
                                                 output: output.data,
                                                 outputWasTruncated: output.wasTruncated,
                                                 errors: errors.data,
                                                 errorsWereTruncated: errors.wasTruncated)
                RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self, weak process] in
                    guard let self, let process else { return }
                    self.terminatingProcesses.removeValue(forKey: ObjectIdentifier(process))
                    guard self.generation == token, self.process === process else { return }
                    self.finish(process: process, completion: completion, startedAt: startedAt)
                }
            }
        }

        do {
            try process.run()
            self.process = process
            drain(stdout.fileHandleForReading, into: output, group: drainGroup)
            drain(stderr.fileHandleForReading, into: errors, group: drainGroup)
            scheduleTimeout(for: process, token: token, startedAt: startedAt)
        } catch {
            stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForWriting.closeFile()
            drain(stdout.fileHandleForReading, into: output, group: drainGroup)
            drain(stderr.fileHandleForReading, into: errors, group: drainGroup)
            generation = UUID()
            publish(phase: .failed, result: nil, message: "无法启动系统测速工具", startedAt: nil)
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        guard let process, state.isRunning else { return }
        let startedAt = state.startedAt
        generation = UUID()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        self.process = nil
        retainUntilExit(process)
        terminate(process: process)
        publish(phase: .cancelled, result: nil, message: "测速已取消", startedAt: startedAt)
    }

    /// Used during application shutdown. It only terminates a process started by this instance.
    func stop() {
        precondition(Thread.isMainThread)
        generation = UUID()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        guard let process else { return }
        let startedAt = state.startedAt
        self.process = nil
        retainUntilExit(process)
        terminate(process: process)
        if state.isRunning {
            publish(phase: .cancelled, result: nil, message: "测速已停止", startedAt: startedAt)
        }
    }

    private func drain(_ handle: FileHandle, into output: CapturedOutput, group: DispatchGroup) {
        completionQueue.async {
            defer { group.leave() }
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                output.append(chunk)
            }
        }
    }

    private func scheduleTimeout(for process: Process, token: UUID, startedAt: Date) {
        let workItem = DispatchWorkItem { [weak self, weak process] in
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self, weak process] in
                guard let self, let process, self.generation == token, self.process === process, self.state.isRunning else { return }
                self.generation = UUID()
                self.timeoutWorkItem = nil
                self.process = nil
                self.retainUntilExit(process)
                self.terminate(process: process)
                self.publish(phase: .failed, result: nil, message: "测速超时，请检查网络后重试", startedAt: startedAt)
            }
        }
        timeoutWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func finish(process: Process, completion: Completion, startedAt: Date) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        self.process = nil
        switch completion {
        case let .success(result, message):
            publish(phase: .finished, result: result, message: message, startedAt: startedAt)
        case let .failure(message, partialResult):
            publish(phase: .failed, result: partialResult, message: message, startedAt: startedAt)
        }
    }

    private func retainUntilExit(_ process: Process) {
        terminatingProcesses[ObjectIdentifier(process)] = process
    }

    private func terminate(process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        // This waits off-main. A force kill requires the original Process object, its original PID, and liveness.
        completionQueue.async { [process] in
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning, pid > 0, process.processIdentifier == pid, kill(pid, 0) == 0 {
                _ = kill(pid, SIGKILL)
            }
            process.waitUntilExit()
        }
    }

    private func publish(phase: SpeedTestPhase, result: SpeedTestResult?, message: String, startedAt: Date?) {
        precondition(Thread.isMainThread)
        state = SpeedTestState(phase: phase, result: result, message: message, isRunning: phase == .running, startedAt: startedAt)
        let callbacks = Array(observers.values)
        for callback in callbacks { callback(state) }
    }
}

private final class CapturedOutput {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - storage.count
        guard remaining > 0 else { truncated = true; return }
        if data.count > remaining {
            storage.append(data.prefix(remaining))
            truncated = true
        } else {
            storage.append(data)
        }
    }

    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    var wasTruncated: Bool { lock.lock(); defer { lock.unlock() }; return truncated }
}

private enum Completion {
    case success(SpeedTestResult, String)
    case failure(String, SpeedTestResult?)
}

private extension NetworkSpeedTest {
    static func completion(for status: Int32, reason: Process.TerminationReason,
                           output: Data, outputWasTruncated: Bool,
                           errors: Data, errorsWereTruncated: Bool) -> Completion {
        let result = outputWasTruncated ? nil : parseResult(output)
        if status == 0, let result, result.hasMeasurement {
            let partial = [result.downloadMbps, result.uploadMbps, result.latencyMilliseconds].contains(where: { $0 == nil })
            return .success(result, partial ? "测速完成，部分项目未返回" : "测速完成")
        }
        let diagnostic = diagnosticMessage(errors, wasTruncated: errorsWereTruncated)
        if reason == .uncaughtSignal { return .failure("测速被系统中断" + diagnostic, result) }
        if status != 0 { return .failure("测速失败" + diagnostic, result) }
        return .failure("测速未返回有效结果" + diagnostic, result)
    }

    static func parseResult(_ data: Data) -> SpeedTestResult? {
        guard !data.isEmpty else { return nil }
        let objects = jsonObjects(in: data)
        for object in objects.reversed() {
            guard let dictionary = object as? [String: Any] else { continue }
            let download = megabitsPerSecond(dictionary, capacityKey: "downlink_capacity_mbps", legacyBitsPerSecondKey: "dl_throughput")
            let upload = megabitsPerSecond(dictionary, capacityKey: "uplink_capacity_mbps", legacyBitsPerSecondKey: "ul_throughput")
            let latency = number(dictionary, keys: ["idle_latency_ms", "base_rtt"])
            let result = SpeedTestResult(downloadMbps: download, uploadMbps: upload,
                                         latencyMilliseconds: latency, measuredAt: Date())
            if result.hasMeasurement { return result }
        }
        return nil
    }

    static func number(_ dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            let number: Double?
            if let value = value as? NSNumber { number = value.doubleValue }
            else if let value = value as? String { number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            else { number = nil }
            if let number, number.isFinite, number >= 0 { return number }
        }
        return nil
    }

    static func megabitsPerSecond(_ dictionary: [String: Any], capacityKey: String, legacyBitsPerSecondKey: String) -> Double? {
        if let capacity = number(dictionary, keys: [capacityKey]) { return capacity }
        guard let bitsPerSecond = number(dictionary, keys: [legacyBitsPerSecondKey]) else { return nil }
        let megabits = bitsPerSecond / 1_000_000
        return megabits.isFinite && megabits >= 0 ? megabits : nil
    }

    static func jsonObjects(in data: Data) -> [Any] {
        if let object = try? JSONSerialization.jsonObject(with: data), let array = object as? [Any] { return array }
        if let object = try? JSONSerialization.jsonObject(with: data) { return [object] }
        // Some OS versions emit one JSON object per progress event. Extract complete object records without parsing text heuristically.
        var objects: [Any] = []
        var depth = 0
        var start: Int?
        var quote = false
        var escaped = false
        for (index, byte) in data.enumerated() {
            if quote {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quote = false }
                continue
            }
            if byte == 34 { quote = true; continue }
            if byte == 123 {
                if depth == 0 { start = index }
                depth += 1
            } else if byte == 125, depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    let fragment = data.subdata(in: start..<(index + 1))
                    if let object = try? JSONSerialization.jsonObject(with: fragment) { objects.append(object) }
                }
            }
        }
        return objects
    }

    static func diagnosticMessage(_ data: Data, wasTruncated: Bool) -> String {
        let text = String(data: data, encoding: .utf8)?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let text else { return wasTruncated ? "（错误信息过长）" : "" }
        let clipped = String(text.prefix(180))
        return "（\(clipped)\(wasTruncated ? "…" : "")）"
    }
}
