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
    var protectedItems = 0
    var total: UInt64 { items.reduce(0) { $0 + $1.bytes } }
}

final class DiskScanCancellation {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

struct DiskScanPolicy {
    private let home: String
    private let restrictedRoots: [String]
    private let selectedRoot: String?
    private let privatePackages = Set(["photoslibrary", "photolibrary", "photoboothlibrary", "musiclibrary"])

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, selectedRoot: URL? = nil) {
        self.home = home.standardizedFileURL.path
        self.selectedRoot = selectedRoot?.standardizedFileURL.path
        restrictedRoots = ["Desktop", "Documents", "Downloads", "Library", "Pictures", "Music", "Movies", ".Trash", "Dropbox", "OneDrive"].map {
            home.appendingPathComponent($0).standardizedFileURL.path
        } + ["/Library", "/System", "/Volumes", "/Network"]
    }

    func shouldSkip(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        func inside(_ path: String, _ parent: String) -> Bool { path == parent || path.hasPrefix(parent + "/") }
        var boundary = restrictedRoots.first { inside(path, $0) }
        if path.hasPrefix("/Users/"), !inside(path, home) {
            boundary = "/Users/" + url.pathComponents.dropFirst(2).first!
        }
        if privatePackages.contains(url.pathExtension.lowercased()) { boundary = path }
        guard let boundary else { return false }
        // Selecting a parent such as the home folder does not opt in to every protected child.
        return !(selectedRoot.map { inside($0, boundary) && inside(path, $0) } ?? false)
    }
}

enum DiskUsageScanner {
    private struct FileID: Hashable { let device: dev_t; let inode: ino_t }

    static func scan(root: URL, cancellation: DiskScanCancellation, policy: DiskScanPolicy = DiskScanPolicy(), onProgress: (DiskScanResult) -> Void = { _ in }) -> DiskScanResult {
        let manager = FileManager.default
        guard !policy.shouldSkip(root) else {
            return DiskScanResult(root: root, items: [], skipped: 1, visited: 0, finished: true, cancelled: false, protectedItems: 1)
        }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else {
            return DiskScanResult(root: root, items: [], skipped: 1, visited: 0, finished: true, cancelled: false)
        }
        var items: [DiskUsageItem] = []
        var skipped = 0, visited = 0, protectedItems = 0
        var seen = Set<FileID>()
        let children: [URL]
        do { children = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent } }
        catch { return DiskScanResult(root: root, items: [], skipped: 1, visited: 0, finished: true, cancelled: false) }
        var lastProgress = ProcessInfo.processInfo.systemUptime
        for child in children {
            if cancellation.isCancelled { break }
            guard !policy.shouldSkip(child) else { skipped += 1; protectedItems += 1; continue }
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
                        if policy.shouldSkip(entry) { skipped += 1; protectedItems += 1; enumerator.skipDescendants(); continue }
                        var childInfo = stat()
                        guard lstat(entry.path, &childInfo) == 0 else { skipped += 1; enumerator.skipDescendants(); continue }
                        if childInfo.st_dev != rootInfo.st_dev { skipped += 1; enumerator.skipDescendants(); continue }
                        if childInfo.st_mode & S_IFMT == S_IFLNK { enumerator.skipDescendants() }
                        countFile(childInfo)
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastProgress >= 1 {
                            onProgress(DiskScanResult(root: root, items: items + [DiskUsageItem(url: child, bytes: bytes, isDirectory: true)],
                                skipped: skipped, visited: visited, finished: false, cancelled: false, protectedItems: protectedItems))
                            lastProgress = now
                        }
                    }
                } else { skipped += 1 }
            }
            items.append(DiskUsageItem(url: child, bytes: bytes, isDirectory: isDirectory))
        }
        return DiskScanResult(root: root, items: items, skipped: skipped, visited: visited, finished: true, cancelled: cancellation.isCancelled, protectedItems: protectedItems)
    }
}
