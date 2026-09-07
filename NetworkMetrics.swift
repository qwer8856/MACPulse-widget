import Darwin
import Foundation
import SystemConfiguration

struct NetworkMetric {
    let sampledAt: Date
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let interfaces: [String]
}

struct NetworkInterfaceCounters: Equatable {
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

protocol NetworkCounterReader {
    // nil is a transient read failure. An empty dictionary is a successful read with no active network.
    func readCounters() -> [String: NetworkInterfaceCounters]?
    func displayName(for interface: String) -> String
}

extension NetworkCounterReader {
    func displayName(for interface: String) -> String { interface }
}

private final class SystemNetworkCounterReader: NetworkCounterReader {
    private struct RouteMessagePrefix {
        let messageLength: UInt16
        let version: UInt8
        let type: UInt8
    }

    private var labelsByName: [String: String] = [:]

    func readCounters() -> [String: NetworkInterfaceCounters]? {
        let activeInterfaces = activeHardwareInterfaces()
        labelsByName = activeInterfaces
        let activeNames = Set(activeInterfaces.keys)
        guard !activeNames.isEmpty else { return [:] }

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var byteCount = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, u_int($0.count), nil, &byteCount, nil, 0)
        }
        guard sizeResult == 0, byteCount > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: byteCount)
        let readResult = mib.withUnsafeMutableBufferPointer { mibBuffer in
            bytes.withUnsafeMutableBytes { byteBuffer in
                sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), byteBuffer.baseAddress, &byteCount, nil, 0)
            }
        }
        guard readResult == 0 else { return nil }

        let expectedIndices = Dictionary(uniqueKeysWithValues: activeNames.map { ($0, if_nametoindex($0)) })
            .filter { $0.value != 0 }
        guard !expectedIndices.isEmpty else { return [:] }
        let namesByIndex = Dictionary(uniqueKeysWithValues: expectedIndices.map { ($0.value, $0.key) })

        var result: [String: NetworkInterfaceCounters] = [:]
        var offset = 0
        while offset + MemoryLayout<RouteMessagePrefix>.size <= byteCount {
            let header: RouteMessagePrefix = bytes.withUnsafeBytes {
                $0.baseAddress!.advanced(by: offset).loadUnaligned(as: RouteMessagePrefix.self)
            }
            let messageLength = Int(header.messageLength)
            guard messageLength >= MemoryLayout<RouteMessagePrefix>.size, offset + messageLength <= byteCount else { break }

            if header.type == RTM_IFINFO2, messageLength >= MemoryLayout<if_msghdr2>.size {
                let interface: if_msghdr2 = bytes.withUnsafeBytes {
                    $0.baseAddress!.advanced(by: offset).loadUnaligned(as: if_msghdr2.self)
                }
                let flags = UInt32(bitPattern: interface.ifm_flags)
                let isRunning = flags & UInt32(IFF_UP) != 0 && flags & UInt32(IFF_RUNNING) != 0
                if isRunning, let name = namesByIndex[UInt32(interface.ifm_index)] {
                    result[name] = NetworkInterfaceCounters(receivedBytes: interface.ifm_data.ifi_ibytes,
                                                            sentBytes: interface.ifm_data.ifi_obytes)
                }
            }
            offset += messageLength
        }
        return result
    }

    func displayName(for interface: String) -> String {
        labelsByName[interface] ?? interface
    }

    private func activeHardwareInterfaces() -> [String: String] {
        let configured = configuredHardwareInterfaces()
        guard !configured.isEmpty else { return [:] }
        let linkLayerActive = linkLayerActiveInterfaceNames()
        guard !linkLayerActive.isEmpty,
              let store = SCDynamicStoreCreate(nil, "MACPulse Network" as CFString, nil, nil) else { return [:] }
        return configured.filter { name, _ in
            linkLayerActive.contains(name) && hasActiveNetworkState(name, store: store)
        }
    }

    private func configuredHardwareInterfaces() -> [String: String] {
        let allInterfaces = SCNetworkInterfaceCopyAll() as NSArray
        var result: [String: String] = [:]
        for case let interface as SCNetworkInterface in allInterfaces {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            if type == kSCNetworkInterfaceTypeIEEE80211 as String {
                result[name] = "Wi-Fi (\(name))"
            } else if type == kSCNetworkInterfaceTypeEthernet as String {
                result[name] = "以太网 (\(name))"
            }
        }
        return result
    }

    private func linkLayerActiveInterfaceNames() -> Set<String> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var result = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let rawName = current.pointee.ifa_name else { continue }
            let name = String(cString: rawName)
            let flags = UInt32(current.pointee.ifa_flags)
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0 else { continue }
            result.insert(name)
        }
        return result
    }

    private func hasActiveNetworkState(_ interface: String, store: SCDynamicStore) -> Bool {
        let linkKey = "State:/Network/Interface/\(interface)/Link" as CFString
        guard let link = SCDynamicStoreCopyValue(store, linkKey) as? [String: Any],
              (link[kSCPropNetLinkActive as String] as? NSNumber)?.boolValue == true else { return false }
        return hasEffectiveAddress(interface, family: "IPv4", addressKey: kSCPropNetIPv4Addresses, store: store)
            || hasEffectiveAddress(interface, family: "IPv6", addressKey: kSCPropNetIPv6Addresses, store: store)
    }

    private func hasEffectiveAddress(_ interface: String, family: String, addressKey: CFString,
                                     store: SCDynamicStore) -> Bool {
        let key = "State:/Network/Interface/\(interface)/\(family)" as CFString
        guard let state = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let addresses = state[addressKey as String] as? [String] else { return false }
        return addresses.contains { address in
            if family == "IPv4" { return address != "0.0.0.0" && !address.hasPrefix("169.254.") }
            let normalized = address.lowercased()
            return normalized != "::" && !normalized.hasPrefix("fe80:")
        }
    }
}

final class NetworkCollector {
    private let reader: NetworkCounterReader
    private var previousCounters: [String: NetworkInterfaceCounters] = [:]
    private var previousSampledAt: Date?
    private var accumulatedReceivedBytes: UInt64 = 0
    private var accumulatedSentBytes: UInt64 = 0

    // Long intervals commonly cross sleep/wake. Keep the cumulative value, but do not turn it into a fake rate.
    private let maximumRateInterval: TimeInterval = 10

    init(reader: NetworkCounterReader = SystemNetworkCounterReader()) {
        self.reader = reader
    }

    func reset() {
        previousCounters.removeAll()
        previousSampledAt = nil
        accumulatedReceivedBytes = 0
        accumulatedSentBytes = 0
    }

    func resetRates() {
        previousCounters.removeAll()
        previousSampledAt = nil
    }

    func sample(now: Date = Date()) -> NetworkMetric {
        guard let counters = reader.readCounters() else {
            return NetworkMetric(sampledAt: now, downloadBytesPerSecond: nil, uploadBytesPerSecond: nil,
                                 receivedBytes: accumulatedReceivedBytes, sentBytes: accumulatedSentBytes,
                                 interfaces: previousCounters.keys.sorted().map(reader.displayName(for:)))
        }
        let interfaces = counters.keys.sorted().map(reader.displayName(for:))
        let elapsed = previousSampledAt.map { now.timeIntervalSince($0) }
        let canCalculateRate = elapsed.map { $0 > 0 && $0 <= maximumRateInterval } ?? false

        var receivedDelta: UInt64 = 0
        var sentDelta: UInt64 = 0
        var hasComparableInterface = false
        for (name, current) in counters {
            guard let previous = previousCounters[name] else { continue }
            if current.receivedBytes >= previous.receivedBytes {
                receivedDelta &+= current.receivedBytes - previous.receivedBytes
                hasComparableInterface = true
            }
            if current.sentBytes >= previous.sentBytes {
                sentDelta &+= current.sentBytes - previous.sentBytes
                hasComparableInterface = true
            }
        }

        // Counter resets and newly connected interfaces establish a fresh baseline rather than creating a spike.
        accumulatedReceivedBytes &+= receivedDelta
        accumulatedSentBytes &+= sentDelta
        previousCounters = counters
        previousSampledAt = now

        let download: Double?
        let upload: Double?
        if canCalculateRate, hasComparableInterface, let elapsed {
            download = Double(receivedDelta) / elapsed
            upload = Double(sentDelta) / elapsed
        } else {
            download = nil
            upload = nil
        }
        return NetworkMetric(sampledAt: now,
                             downloadBytesPerSecond: download,
                             uploadBytesPerSecond: upload,
                             receivedBytes: accumulatedReceivedBytes,
                             sentBytes: accumulatedSentBytes,
                             interfaces: interfaces)
    }
}

enum NetworkText {
    static func rate(_ bytesPerSecond: Double?) -> String {
        let parts = rateComponents(bytesPerSecond)
        return parts.unit.isEmpty ? parts.value : parts.value + " " + parts.unit
    }

    static func rateComponents(_ bytesPerSecond: Double?, compact: Bool = false) -> (value: String, unit: String) {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return ("--", "") }
        return components(bytesPerSecond, suffix: "/s", compact: compact)
    }

    static func bytes(_ byteCount: UInt64) -> String {
        format(Double(byteCount), suffix: "")
    }

    static func summary(_ metric: NetworkMetric?) -> String {
        guard let metric else { return "↓ --  ↑ --" }
        return "↓ \(rate(metric.downloadBytesPerSecond))  ↑ \(rate(metric.uploadBytesPerSecond))"
    }

    private static func format(_ bytes: Double, suffix: String) -> String {
        let parts = components(bytes, suffix: suffix)
        return parts.value + " " + parts.unit
    }

    private static func components(_ bytes: Double, suffix: String, compact: Bool = false) -> (value: String, unit: String) {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var value = max(0, bytes)
        var index = 0
        while index < units.count - 1, value >= 999.95 {
            value /= 1000
            index += 1
        }
        return (String(format: compact && value >= 99.95 ? "%.0f" : "%.1f", value), units[index] + suffix)
    }
}
