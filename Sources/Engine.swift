import Foundation
import Vision
import ImageIO
import CoreGraphics
import AppKit

// MARK: - Загрузка изображений

enum ImageLoader {
    static let extensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "heic", "heif", "hif", "tif", "tiff", "gif", "bmp", "webp",
        "avif", "jxl", "jp2", "psd", "ico",
        // RAW
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "mrw", "kdc", "dcr",
    ]

    static func isImage(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Уменьшенная копия с учётом EXIF-ориентации. Для JPEG/HEIC декодер сам
    /// делает субсэмплинг, поэтому это намного быстрее полного декодирования.
    static func cgImage(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func pixelSize(url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    static func cgImage(from nsImage: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

// MARK: - «Отпечатки» изображений (Vision)

enum Fingerprint {
    static let analysisSize = 512

    static func make(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            return nil
        }
    }

    static func make(url: URL) -> VNFeaturePrintObservation? {
        guard let cg = ImageLoader.cgImage(url: url, maxPixel: analysisSize) else { return nil }
        return make(cg)
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var d: Float = .greatestFiniteMagnitude
        try? a.computeDistance(&d, to: b)
        return d
    }

    /// Перевод расстояния Vision в «процент схожести».
    /// Калибровано на ревизии 2 (векторы нормированы):
    /// та же картинка, пережатая/уменьшенная — d≈0.1…0.4 (→ 97…70%),
    /// кроп/соседний кадр серии — d≈0.5…0.7 (→ 60…40%),
    /// несвязанные снимки — d≈0.9…1.3 (→ <20%).
    static func similarity(distance d: Float, revision: Int) -> Double {
        let x = Double(d) / (revision >= 2 ? 0.7 : 0.7 * 28)
        return 100 * exp(-x * x)
    }

    static func archive(_ obs: VNFeaturePrintObservation) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true)
    }

    static func unarchive(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }
}

// MARK: - Кэш отпечатков на диске (повторный поиск по тем же папкам — мгновенный)

final class FingerprintCache {
    private var store: [String: Data] = [:]
    private var dirty = false
    private let lock = NSLock()
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("fingerprints.plist")
        if let data = try? Data(contentsOf: fileURL),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Data] {
            store = dict
        }
    }

    static func key(path: String, size: Int, mtime: Date) -> String {
        "\(path)|\(size)|\(Int(mtime.timeIntervalSince1970))"
    }

    func get(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func set(_ key: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        store[key] = data
        dirty = true
    }

    func save() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = store
        dirty = false
        lock.unlock()
        if let data = try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func clear() {
        lock.lock()
        store = [:]
        dirty = false
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return store.count
    }

    var diskSize: Int {
        (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

// MARK: - Поиск

struct Match: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let similarity: Double
    let exampleIndex: Int
    let fileSize: Int
    let modified: Date
}

struct FileEntry {
    let url: URL
    let size: Int
    let modified: Date
}

final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

struct SearchOptions {
    var recursive = true
    var minFileSize = 0          // байт
    var excludePaths: Set<String> = []
    var keepFloor: Double = 15   // результаты ниже этого порога не храним вовсе
}

enum SearchEngine {
    /// Обход папок. Вызывает `onCount` по мере нахождения файлов.
    static func collectFiles(folders: [URL], options: SearchOptions, cancel: CancelFlag, onCount: (Int) -> Void) -> [FileEntry] {
        var result: [FileEntry] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for folder in folders {
            var opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
            if !options.recursive { opts.insert(.skipsSubdirectoryDescendants) }
            guard let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: opts, errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in en {
                if cancel.isCancelled { return result }
                guard ImageLoader.isImage(url) else { continue }
                // Пропускаем миниатюры/служебные папки медиатеки Фото
                let p = url.path
                if p.contains(".photoslibrary/") && (p.contains("/resources/derivatives/") || p.contains("/scopes/") || p.contains("/private/")) { continue }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let size = v.fileSize ?? 0
                if size < options.minFileSize { continue }
                if options.excludePaths.contains(p) { continue }
                guard seen.insert(p).inserted else { continue }
                result.append(FileEntry(url: url, size: size, modified: v.contentModificationDate ?? .distantPast))
                if result.count % 200 == 0 { onCount(result.count) }
            }
        }
        onCount(result.count)
        return result
    }

    /// Сравнение каждого файла с образцами. Работает параллельно на всех ядрах.
    static func compare(
        files: [FileEntry],
        examples: [VNFeaturePrintObservation],
        options: SearchOptions,
        cache: FingerprintCache,
        cancel: CancelFlag,
        onProgress: @escaping (_ done: Int, _ newMatches: [Match], _ failed: Int) -> Void
    ) {
        guard !examples.isEmpty else { return }
        let revision = examples[0].requestRevision
        let lock = NSLock()
        var done = 0
        var failed = 0
        var pending: [Match] = []
        var lastFlush = Date()

        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let chunk = max(1, (files.count + workers * 8 - 1) / (workers * 8))
        let chunks = stride(from: 0, to: files.count, by: chunk).map { $0..<min($0 + chunk, files.count) }

        DispatchQueue.concurrentPerform(iterations: chunks.count) { ci in
            for i in chunks[ci] {
                if cancel.isCancelled { return }
                autoreleasepool {
                    let f = files[i]
                    let key = FingerprintCache.key(path: f.url.path, size: f.size, mtime: f.modified) + "|r\(revision)"
                    var obs: VNFeaturePrintObservation?
                    if let data = cache.get(key) { obs = Fingerprint.unarchive(data) }
                    if obs == nil, let fresh = Fingerprint.make(url: f.url) {
                        obs = fresh
                        if let data = Fingerprint.archive(fresh) { cache.set(key, data) }
                    }
                    var match: Match?
                    if let obs {
                        var best = -1.0, bestIdx = 0
                        for (idx, ex) in examples.enumerated() {
                            let s = Fingerprint.similarity(distance: Fingerprint.distance(ex, obs), revision: revision)
                            if s > best { best = s; bestIdx = idx }
                        }
                        if best >= options.keepFloor {
                            match = Match(url: f.url, similarity: best, exampleIndex: bestIdx, fileSize: f.size, modified: f.modified)
                        }
                    }
                    lock.lock()
                    done += 1
                    if obs == nil { failed += 1 }
                    if let match { pending.append(match) }
                    var flush: ([Match], Int, Int)?
                    if Date().timeIntervalSince(lastFlush) > 0.15 {
                        flush = (pending, done, failed)
                        pending = []
                        lastFlush = Date()
                    }
                    lock.unlock()
                    if let flush { onProgress(flush.1, flush.0, flush.2) }
                }
            }
        }
        lock.lock()
        let rest = pending
        let d = done, fl = failed
        lock.unlock()
        onProgress(d, rest, fl)
        cache.save()
    }
}
