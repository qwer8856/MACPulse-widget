import SwiftUI
import WidgetKit
import AppKit

let nativeWidgetKind = "SystemStatusWidget"
let widgetRefreshURL = URL(string: "desktop-monitor://refresh")!

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: MetricsSnapshot?
    var powerExpired = false
    var allExpired = false
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        Self.collect(completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        Self.collect { entry in
            completion(Self.timeline(for: entry))
        }
    }

    static func collect(completion: @escaping (StatusEntry) -> Void) {
        let queue = DispatchQueue(label: "local.system-status.widget-sample", qos: .utility)
        queue.async {
            let collector = MetricsCollector()
            _ = collector.sample()
            queue.asyncAfter(deadline: .now() + 0.6) {
                let snapshot = collector.sample()
                completion(StatusEntry(date: snapshot.sampledAt, snapshot: snapshot))
            }
        }
    }

    static func timeline(for entry: StatusEntry) -> Timeline<StatusEntry> {
        var entries = [entry]
        if let power = entry.snapshot?.power {
            let expiry = power.updatedAt.addingTimeInterval(180)
            if expiry > entry.date {
                entries.append(StatusEntry(date: expiry, snapshot: entry.snapshot, powerExpired: true))
            }
        }
        // Expiration entries stop old readings appearing current if the system delays a reload.
        entries.append(StatusEntry(date: entry.date.addingTimeInterval(900), snapshot: entry.snapshot, powerExpired: true, allExpired: true))
        return Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(1)))
    }
}

struct WidgetMetric: Identifiable {
    let id: String
    let symbol: String
    let value: String
    let detail: String
    let ratio: Double?
    let color: Color
}

struct StatusWidgetContent: View {
    let entry: StatusEntry
    let family: WidgetFamily

    private var metrics: [WidgetMetric] {
        let snapshot = entry.allExpired ? nil : entry.snapshot
        let memory = snapshot?.memory
        let disk = snapshot?.disk
        let power: PowerMetric? = {
            guard !entry.powerExpired, let power = snapshot?.power, power.isFresh(at: entry.date) else { return nil }
            return power
        }()
        return [
            WidgetMetric(id: "CPU", symbol: "cpu", value: snapshot?.cpu.map { String(format: "%.0f%%", $0) } ?? "--",
                         detail: "\(ProcessInfo.processInfo.processorCount) 核", ratio: snapshot?.cpu.map { $0 / 100 }, color: .cyan),
            WidgetMetric(id: "内存", symbol: "memorychip", value: memory.map { String(format: "%.0f%%", $0.percent) } ?? "--",
                         detail: memory.map { String(format: "%.1f / %.0f GiB", $0.occupied / 1_073_741_824, $0.total / 1_073_741_824) } ?? "暂无数据",
                         ratio: memory.map { $0.percent / 100 }, color: .green),
            WidgetMetric(id: "磁盘", symbol: "internaldrive", value: disk.map { String(format: "%.0f%%", $0.percent) } ?? "--",
                         detail: disk.map { String(format: "可用 %.0f GB", $0.free / 1e9) } ?? "暂无数据",
                         ratio: disk.map { $0.percent / 100 }, color: .orange),
            WidgetMetric(id: "功率", symbol: "bolt.fill", value: power.map { String(format: "%.1f W", $0.watts) } ?? "--",
                         detail: power == nil ? (entry.powerExpired ? "读数已过期" : "暂无读数") : "供电侧估算",
                         ratio: nil, color: .pink)
        ]
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
        .fontDesign(.rounded)
        .widgetURL(widgetRefreshURL)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 11, weight: .semibold))
            Text("系统状态").font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 4)
            if family != .systemSmall {
                Link(destination: widgetRefreshURL) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("请求刷新")
                .accessibilityLabel("请求刷新系统状态")
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: 18)
    }

    private var timestamp: some View {
        HStack(spacing: 3) {
            Text(entry.allExpired ? "等待更新" : "采样")
            if let snapshot = entry.snapshot {
                Text(snapshot.sampledAt, style: .time).monospacedDigit()
            } else {
                Text("--:--")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var small: some View {
        VStack(spacing: 6) {
            header
            ForEach(metrics) { metric in
                HStack(spacing: 5) {
                    Image(systemName: metric.symbol).foregroundStyle(metric.color).frame(width: 13)
                    Text(metric.id).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Text(metric.value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }
                .font(.system(size: 11))
                .frame(maxHeight: .infinity)
            }
            timestamp.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 10) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 3) {
                            Image(systemName: metric.symbol)
                            Text(metric.id)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(metric.color)
                        Text(metric.value)
                            .font(.system(size: 23, weight: .semibold))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                            .frame(height: 29, alignment: .leading)
                        Text(metric.detail)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack {
                timestamp
                Spacer()
                Text(entry.allExpired ? "" : entry.snapshot?.memory?.pressureLabel ?? "")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], alignment: .leading, spacing: 22) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(metric.id, systemImage: metric.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(metric.color)
                        Text(metric.value)
                            .font(.system(size: 31, weight: .semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(metric.detail)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        if let ratio = metric.ratio {
                            GeometryReader { geometry in
                                Capsule().fill(metric.color.opacity(0.13))
                                Capsule().fill(metric.color.opacity(0.85))
                                    .frame(width: geometry.size.width * max(0, min(1, ratio)))
                            }.frame(height: 4)
                        } else {
                            Color.clear.frame(height: 4)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack {
                timestamp
                Spacer()
                Text(entry.allExpired ? "" : entry.snapshot?.memory?.pressureLabel ?? "")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

struct NativeStatusWidget: Widget {
    let kind = nativeWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatusProvider()) { entry in
            NativeWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("系统状态")
        .description("CPU、内存、磁盘与供电功率。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NativeWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    var body: some View {
        StatusWidgetContent(entry: entry, family: family)
            .containerBackground(.background, for: .widget)
    }
}

struct SystemStatusWidgets: WidgetBundle {
    var body: some Widget { NativeStatusWidget() }
}

#if WIDGET_EXTENSION
@main
struct WidgetExtensionEntry {
    static func main() {
        SystemStatusWidgets.main()
    }
}
#endif
