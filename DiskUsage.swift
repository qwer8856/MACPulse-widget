import Foundation
import Darwin

struct DiskUsageItem {
    let url: URL
    let bytes: UInt64
    let isDirectory: Bool
}

struct DiskScanResult {
    let root: URL
    let items: [DiskUsageItem]
    let skipped: Int
    let visited: Int
    let finished: Bool
    let cancelled: Bool
    var total: UInt64 { items.reduce(0) { $0 + $1.bytes } }
}

final class DiskScanCancellation {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

enum DiskUsageScanner {
    private struct FileID: Hashable { let device: dev_t; let inode: ino_t }

    static func scan(root: URL, cancellation: DiskScanCancellation, onProgress: (DiskScanResult) -> Void = { _ in }) -> DiskScanResult {
        let manager = FileManager.default
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else {
            return DiskScanResult(root: root, items: [], skipped: 1, visited: 0, finished: true, cancelled: false)
        }
        var items: [DiskUsageItem] = []
        var skipped = 0, visited = 0
        var seen = Set<FileID>()
        let children: [URL]
        do { children = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent } }
        catch { return DiskScanResult(root: root, items: [], skipped: 1, visited: 0, finished: true, cancelled: false) }
        var lastProgress = ProcessInfo.processInfo.systemUptime
        for child in children {
            if cancellation.isCancelled { break }
            var info = stat()
            guard lstat(child.path, &info) == 0, info.st_dev == rootInfo.st_dev else { skipped += 1; continue }
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
            var bytes: UInt64 = 0
            func countFile(_ info: stat) {
                visited += 1
                let identity = FileID(device: info.st_dev, inode: info.st_ino)
                if seen.insert(identity).inserted { bytes += UInt64(max(0, info.st_blocks)) * 512 }
            }
            countFile(info)
            if isDirectory {
                let enumerator = manager.enumerator(at: child, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in skipped += 1; return true })
                if let enumerator {
                    while let entry = enumerator.nextObject() as? URL {
                        if cancellation.isCancelled { break }
                        var childInfo = stat()
                        guard lstat(entry.path, &childInfo) == 0 else { skipped += 1; enumerator.skipDescendants(); continue }
                        if childInfo.st_dev != rootInfo.st_dev { skipped += 1; enumerator.skipDescendants(); continue }
                        if childInfo.st_mode & S_IFMT == S_IFLNK { enumerator.skipDescendants() }
                        countFile(childInfo)
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastProgress >= 0.3 {
                            onProgress(DiskScanResult(root: root, items: items + [DiskUsageItem(url: child, bytes: bytes, isDirectory: true)],
                                skipped: skipped, visited: visited, finished: false, cancelled: false))
                            lastProgress = now
                        }
                    }
                } else { skipped += 1 }
            }
            items.append(DiskUsageItem(url: child, bytes: bytes, isDirectory: isDirectory))
        }
        return DiskScanResult(root: root, items: items, skipped: skipped, visited: visited, finished: true, cancelled: cancellation.isCancelled)
    }
}
