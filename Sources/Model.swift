import Foundation
import AppKit
import Vision
import SwiftUI
import UniformTypeIdentifiers

struct ExampleImage: Identifiable {
    let id = UUID()
    let url: URL?          // nil — если вставлено из буфера обмена
    let name: String
    let image: NSImage
    let print: VNFeaturePrintObservation
}

enum SortOrder: String, CaseIterable, Identifiable {
    case similarity = "По схожести"
    case date = "По дате"
    case name = "По имени"
    case size = "По размеру"
    var id: String { rawValue }
}

enum Preset: String, CaseIterable, Identifiable {
    case copies = "Копии"
    case close = "Очень похожие"
    case similar = "Похожие"
    case loose = "Отдалённо"
    var id: String { rawValue }
    var threshold: Double {
        switch self {
        case .copies: 75
        case .close: 55
        case .similar: 40
        case .loose: 25
        }
    }
    var hint: String {
        switch self {
        case .copies: "Тот же снимок: другой размер, формат, сжатие, лёгкая правка"
        case .close: "Копии + кадрирование, фильтры, соседние кадры серии"
        case .similar: "Тот же объект или сцена с другого ракурса"
        case .loose: "Похожие по сюжету и композиции — много лишнего"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // Ввод
    @Published var examples: [ExampleImage] = []
    @Published var folders: [URL] = [] { didSet { saveFolders() } }
    @Published var threshold: Double = UserDefaults.standard.object(forKey: "threshold") as? Double ?? 55 {
        didSet { UserDefaults.standard.set(threshold, forKey: "threshold") }
    }
    @Published var recursive: Bool = UserDefaults.standard.object(forKey: "recursive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(recursive, forKey: "recursive") }
    }
    @Published var skipTiny: Bool = UserDefaults.standard.object(forKey: "skipTiny") as? Bool ?? true {
        didSet { UserDefaults.standard.set(skipTiny, forKey: "skipTiny") }
    }

    // Состояние поиска
    @Published var isSearching = false
    @Published var phase = ""
    @Published var processed = 0
    @Published var total = 0
    @Published var failed = 0
    @Published var allMatches: [Match] = []
    @Published var lastSearchSummary: String?
    @Published var errorMessage: String?
    @Published var loadingExample = false

    // Результаты
    @Published var sortOrder: SortOrder = .similarity
    @Published var selection: Set<URL> = []
    @Published var focused: URL?
    @Published var tileSize: Double = UserDefaults.standard.object(forKey: "tileSize") as? Double ?? 170 {
        didSet { UserDefaults.standard.set(tileSize, forKey: "tileSize") }
    }

    let cache = FingerprintCache()
    private var cancelFlag: CancelFlag?
    private var startTime = Date()

    init() {
        if let paths = UserDefaults.standard.stringArray(forKey: "folders") {
            folders = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        if folders.isEmpty {
            let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            folders = [pics]
        }
    }

    private func saveFolders() {
        UserDefaults.standard.set(folders.map(\.path), forKey: "folders")
    }

    var visibleMatches: [Match] {
        let filtered = allMatches.filter { $0.similarity >= threshold }
        switch sortOrder {
        case .similarity: return filtered.sorted { $0.similarity > $1.similarity }
        case .date: return filtered.sorted { $0.modified > $1.modified }
        case .name: return filtered.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        case .size: return filtered.sorted { $0.fileSize > $1.fileSize }
        }
    }

    var canSearch: Bool { !examples.isEmpty && !folders.isEmpty && !isSearching }

    // MARK: Образцы

    func chooseExamples() {
        let panel = NSOpenPanel()
        panel.title = "Выберите фото-образец"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { addExamples(panel.urls) }
    }

    func addExamples(_ urls: [URL]) {
        let images = urls.filter { ImageLoader.isImage($0) || (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false) }
        guard !images.isEmpty else {
            if !urls.isEmpty { errorMessage = "Это не похоже на изображение." }
            return
        }
        loadingExample = true
        Task.detached(priority: .userInitiated) {
            var loaded: [ExampleImage] = []
            for url in images {
                guard let cg = ImageLoader.cgImage(url: url, maxPixel: Fingerprint.analysisSize),
                      let fp = Fingerprint.make(cg) else { continue }
                let preview = ImageLoader.cgImage(url: url, maxPixel: 600) ?? cg
                let img = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
                loaded.append(ExampleImage(url: url, name: url.lastPathComponent, image: img, print: fp))
            }
            let result = loaded
            await MainActor.run {
                let loaded = result
                self.loadingExample = false
                if loaded.isEmpty { self.errorMessage = "Не удалось прочитать изображение." }
                self.examples.append(contentsOf: loaded)
                self.allMatches = []
            }
        }
    }

    func addExample(nsImage: NSImage, name: String) {
        guard let cg = ImageLoader.cgImage(from: nsImage), let fp = Fingerprint.make(cg) else {
            errorMessage = "Не удалось прочитать изображение из буфера обмена."
            return
        }
        examples.append(ExampleImage(url: nil, name: name, image: nsImage, print: fp))
        allMatches = []
    }

    func pasteExample() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addExamples(urls)
        } else if let img = NSImage(pasteboard: pb) {
            addExample(nsImage: img, name: "Из буфера обмена")
        } else {
            errorMessage = "В буфере обмена нет изображения."
        }
    }

    func removeExample(_ ex: ExampleImage) {
        examples.removeAll { $0.id == ex.id }
        allMatches = []
    }

    // MARK: Папки

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = "Где искать"
        panel.prompt = "Добавить"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK { addFolders(panel.urls) }
    }

    func addFolders(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let p = url.standardizedFileURL.path
            // уже покрыто существующей папкой?
            if recursive, folders.contains(where: { p == $0.path || p.hasPrefix($0.path + "/") }) { continue }
            if folders.contains(where: { $0.path == p }) { continue }
            folders.append(url.standardizedFileURL)
        }
    }

    func addStandardFolder(_ dir: FileManager.SearchPathDirectory) {
        addFolders([FileManager.default.urls(for: dir, in: .userDomainMask)[0]])
    }

    func addHome() { addFolders([FileManager.default.homeDirectoryForCurrentUser]) }

    func addVolume(_ url: URL) { addFolders([url]) }

    var mountedVolumes: [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRootFileSystemKey], options: [.skipHiddenVolumes]) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.volumeIsRootFileSystemKey]).volumeIsRootFileSystem) != true }
    }

    var photosLibrary: URL? {
        let url = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photos Library.photoslibrary/originals")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Поиск

    func startSearch() {
        guard canSearch else { return }
        let flag = CancelFlag()
        cancelFlag = flag
        isSearching = true
        allMatches = []
        selection = []
        focused = nil
        processed = 0
        total = 0
        failed = 0
        lastSearchSummary = nil
        phase = "Сбор списка файлов…"
        startTime = Date()

        var options = SearchOptions()
        options.recursive = recursive
        options.minFileSize = skipTiny ? 15_000 : 0
        options.excludePaths = Set(examples.compactMap { $0.url?.path })
        let folders = self.folders
        let prints = examples.map(\.print)
        let cache = self.cache

        Task.detached(priority: .userInitiated) { [weak self] in
            // Все обновления идут через главную очередь (FIFO), чтобы порядок не нарушался.
            func onMain(_ body: @escaping @MainActor (AppModel) -> Void) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.cancelFlag === flag else { return }
                        body(self)
                    }
                }
            }
            let files = SearchEngine.collectFiles(folders: folders, options: options, cancel: flag) { n in
                onMain { $0.phase = "Сбор списка файлов… \(n)" }
            }
            onMain { $0.total = files.count; $0.phase = "Сравнение" }
            SearchEngine.compare(files: files, examples: prints, options: options, cache: cache, cancel: flag) { done, newMatches, failed in
                onMain { m in
                    m.processed = max(m.processed, done)
                    m.failed = max(m.failed, failed)
                    if !newMatches.isEmpty { m.allMatches.append(contentsOf: newMatches) }
                }
            }
            onMain { $0.finish(cancelled: flag.isCancelled) }
        }
    }

    private func finish(cancelled: Bool) {
        isSearching = false
        phase = ""
        let secs = Date().timeIntervalSince(startTime)
        var s = cancelled ? "Остановлено. " : ""
        s += "Проверено \(processed) из \(total) изображений за \(Self.formatDuration(secs))"
        if failed > 0 { s += ", не прочитано: \(failed)" }
        lastSearchSummary = s
        if !cancelled, NSApp.isActive == false {
            NSApp.requestUserAttention(.informationalRequest)
        }
        if focused == nil { focused = visibleMatches.first?.url }
    }

    func stopSearch() {
        cancelFlag?.cancel()
        phase = "Остановка…"
    }

    static func formatDuration(_ s: Double) -> String {
        if s < 60 { return String(format: "%.1f с", s) }
        return "\(Int(s) / 60) мин \(Int(s) % 60) с"
    }

    var etaText: String? {
        guard isSearching, processed > 20, total > processed else { return nil }
        let elapsed = Date().timeIntervalSince(startTime)
        let rate = Double(processed) / elapsed
        let left = Double(total - processed) / rate
        return "осталось ≈ " + Self.formatDuration(left)
    }

    // MARK: Действия с результатами

    var selectedURLs: [URL] {
        let sel = selection
        return visibleMatches.map(\.url).filter { sel.contains($0) }
    }

    func click(_ url: URL, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
        } else if modifiers.contains(.shift), let anchor = focused {
            let list = visibleMatches.map(\.url)
            if let a = list.firstIndex(of: anchor), let b = list.firstIndex(of: url) {
                selection.formUnion(list[min(a, b)...max(a, b)])
            }
        } else {
            selection = [url]
        }
        focused = url
    }

    func moveFocus(by delta: Int) {
        let list = visibleMatches.map(\.url)
        guard !list.isEmpty else { return }
        var idx = focused.flatMap { list.firstIndex(of: $0) } ?? -1
        idx = max(0, min(list.count - 1, idx + delta))
        focused = list[idx]
        selection = [list[idx]]
    }

    func selectAll() { selection = Set(visibleMatches.map(\.url)) }

    func open(_ urls: [URL]) { urls.forEach { NSWorkspace.shared.open($0) } }

    func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func copyFiles(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    func exportFiles(_ urls: [URL], move: Bool) {
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = move ? "Переместить в папку" : "Скопировать в папку"
        panel.prompt = move ? "Переместить" : "Скопировать"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        var errors = 0
        for src in urls {
            var target = dest.appendingPathComponent(src.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let base = src.deletingPathExtension().lastPathComponent
                target = dest.appendingPathComponent("\(base) \(n)").appendingPathExtension(src.pathExtension)
                n += 1
            }
            do {
                if move { try FileManager.default.moveItem(at: src, to: target) } else { try FileManager.default.copyItem(at: src, to: target) }
            } catch { errors += 1 }
        }
        if move { removeFromResults(urls) }
        if errors > 0 { errorMessage = "Не удалось обработать файлов: \(errors)" }
        else { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
    }

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Переместить «\(urls[0].lastPathComponent)» в Корзину?" : "Переместить \(urls.count) файлов в Корзину?"
        alert.informativeText = "Файлы можно будет восстановить из Корзины."
        alert.addButton(withTitle: "В Корзину")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var removed: [URL] = []
        for u in urls {
            if (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil { removed.append(u) }
        }
        removeFromResults(removed)
        if removed.count < urls.count { errorMessage = "Не удалось удалить файлов: \(urls.count - removed.count)" }
    }

    private func removeFromResults(_ urls: [URL]) {
        let set = Set(urls)
        allMatches.removeAll { set.contains($0.url) }
        selection.subtract(set)
        if let f = focused, set.contains(f) { focused = visibleMatches.first?.url }
    }

    func exportList() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Найденные фото.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = visibleMatches.map { String(format: "%.0f%%\t", $0.similarity) + $0.url.path }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
