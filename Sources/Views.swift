import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Миниатюры

final class ThumbnailStore {
    static let shared = ThumbnailStore()
    private let cache = NSCache<NSURL, NSImage>()
    private let queue = DispatchQueue(label: "thumbs", qos: .userInitiated, attributes: .concurrent)
    init() { cache.countLimit = 1500 }

    func image(for url: URL, size: Int, completion: @escaping (NSImage?) -> Void) {
        if let img = cache.object(forKey: url as NSURL), Int(img.size.width) >= size || Int(img.size.height) >= size {
            completion(img); return
        }
        queue.async {
            let cg = ImageLoader.cgImage(url: url, maxPixel: size)
            let img = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            if let img { self.cache.setObject(img, forKey: url as NSURL) }
            DispatchQueue.main.async { completion(img) }
        }
    }
}

struct AsyncThumb: View {
    let url: URL
    let pixel: Int
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(url.path)#\(pixel)") {
            ThumbnailStore.shared.image(for: url, size: pixel) { img in
                image = img
                failed = img == nil
            }
        }
    }
}

// MARK: - Главное окно

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 290, idealWidth: 310, maxWidth: 380)
            VStack(spacing: 0) {
                ResultsToolbar()
                Divider()
                HSplitView {
                    ResultsGrid()
                        .frame(minWidth: 360)
                    if model.focused != nil {
                        DetailView()
                            .frame(minWidth: 260, idealWidth: 330, maxWidth: 520)
                    }
                }
                StatusBar()
            }
            .frame(minWidth: 520)
        }
        .frame(minWidth: 960, minHeight: 600)
        .alert("Ошибка", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Боковая панель

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var exampleDropTarget = false
    @State private var folderDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    exampleSection
                    foldersSection
                    settingsSection
                }
                .padding(16)
            }
            Divider()
            searchButton.padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // Образец
    private var exampleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(number: 1, title: "Что искать", trailing: model.examples.isEmpty ? nil : AnyView(
                Menu {
                    Button("Добавить ещё образец…") { model.chooseExamples() }
                    Button("Вставить из буфера") { model.pasteExample() }
                    Divider()
                    Button("Убрать все образцы", role: .destructive) { model.examples.removeAll(); model.allMatches = [] }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            ))

            if model.examples.isEmpty {
                Button { model.chooseExamples() } label: {
                    VStack(spacing: 8) {
                        if model.loadingExample {
                            ProgressView()
                        } else {
                            Image(systemName: "photo.badge.plus").font(.system(size: 34, weight: .light))
                        }
                        Text("Перетащите фото сюда\nили нажмите, чтобы выбрать")
                            .multilineTextAlignment(.center).font(.callout)
                        Text("⌘V — вставить из буфера").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                    .foregroundStyle(exampleDropTarget ? Color.accentColor : .secondary)
                    .background(RoundedRectangle(cornerRadius: 12).fill(exampleDropTarget ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).foregroundStyle(exampleDropTarget ? Color.accentColor : Color.secondary.opacity(0.5)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                let cols = model.examples.count == 1 ? 1 : 2
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
                    ForEach(model.examples) { ex in
                        ExampleTile(example: ex, large: cols == 1)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(exampleDropTarget ? Color.accentColor : .clear, lineWidth: 2))
                if model.examples.count > 1 {
                    Text("Ищутся фото, похожие на любой из образцов").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $exampleDropTarget) { providers in
            handleImageDrop(providers)
        }
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.addExamples([url]) } }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                    if let img = img as? NSImage { DispatchQueue.main.async { model.addExample(nsImage: img, name: "Перетащенное изображение") } }
                }
            }
        }
        return handled
    }

    // Папки
    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(number: 2, title: "Где искать", trailing: AnyView(
                Menu {
                    Button("Выбрать папку…") { model.chooseFolders() }
                    Divider()
                    Button("Изображения") { model.addStandardFolder(.picturesDirectory) }
                    Button("Рабочий стол") { model.addStandardFolder(.desktopDirectory) }
                    Button("Загрузки") { model.addStandardFolder(.downloadsDirectory) }
                    Button("Документы") { model.addStandardFolder(.documentDirectory) }
                    Button("Вся домашняя папка") { model.addHome() }
                    if let lib = model.photosLibrary {
                        Button("Медиатека «Фото» (оригиналы)") { model.addFolders([lib]) }
                    }
                    let vols = model.mountedVolumes
                    if !vols.isEmpty {
                        Divider()
                        ForEach(vols, id: \.self) { v in
                            Button("Диск «\(v.lastPathComponent)»") { model.addVolume(v) }
                        }
                    }
                } label: { Label("Добавить", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
            ))

            VStack(spacing: 0) {
                if model.folders.isEmpty {
                    Text("Добавьте папку кнопкой выше\nили перетащите её сюда")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                ForEach(model.folders, id: \.self) { url in
                    FolderRow(url: url)
                    if url != model.folders.last { Divider().padding(.leading, 34) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(folderDropTarget ? Color.accentColor : Color.clear, lineWidth: 2))
            .onDrop(of: [.fileURL], isTargeted: $folderDropTarget) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.addFolders([url]) } }
                    }
                }
                return true
            }
        }
    }

    // Настройки
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(number: 3, title: "Точность", trailing: nil)
            Picker("", selection: Binding(
                get: { Preset.allCases.first { $0.threshold == model.threshold } },
                set: { if let p = $0 { model.threshold = p.threshold } })) {
                ForEach(Preset.allCases) { p in Text(p.rawValue).tag(Optional(p)) }
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack {
                Text("Схожесть не ниже")
                Spacer()
                Text("\(Int(model.threshold))%").monospacedDigit().bold()
            }
            .font(.callout)
            Slider(value: $model.threshold, in: 15...99, step: 1)
            Text(Preset.allCases.min(by: { abs($0.threshold - model.threshold) < abs($1.threshold - model.threshold) })!.hint)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.allMatches.isEmpty {
                Text("Порог можно менять после поиска — результаты обновятся сразу.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Искать во вложенных папках", isOn: $model.recursive)
            Toggle("Пропускать мелкие файлы (< 15 КБ)", isOn: $model.skipTiny)
                .help("Иконки, превью и прочий мусор")
        }
        .toggleStyle(.checkbox)
    }

    private var searchButton: some View {
        Group {
            if model.isSearching {
                Button(role: .cancel) { model.stopSearch() } label: {
                    Label("Остановить", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button { model.startSearch() } label: {
                    Label("Найти похожие", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSearch)
                .help(model.examples.isEmpty ? "Сначала выберите фото-образец" : model.folders.isEmpty ? "Добавьте папку для поиска" : "⌘↩")
            }
        }
        .controlSize(.large)
    }
}

struct SectionHeader: View {
    let number: Int
    let title: String
    let trailing: AnyView?
    var body: some View {
        HStack {
            Text("\(number)")
                .font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(title).font(.headline)
            Spacer()
            trailing
        }
    }
}

struct ExampleTile: View {
    @EnvironmentObject var model: AppModel
    let example: ExampleImage
    let large: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: example.image)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: large ? 220 : 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if hover {
                        Button { model.removeExample(example) } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3)
                                .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain).padding(4).help("Убрать образец")
                    }
                }
            Text(example.name).font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
        }
        .onHover { hover = $0 }
        .contextMenu {
            if let url = example.url {
                Button("Открыть") { model.open([url]) }
                Button("Показать в Finder") { model.reveal([url]) }
                Divider()
            }
            Button("Убрать образец") { model.removeExample(example) }
        }
    }
}

struct FolderRow: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName).lineLimit(1)
                Text(shortPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            Button { model.folders.removeAll { $0 == url } } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).opacity(hover ? 1 : 0.35).help("Убрать из поиска")
            .disabled(model.isSearching)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Показать в Finder") { NSWorkspace.shared.open(url) }
            Button("Убрать из поиска") { model.folders.removeAll { $0 == url } }
        }
    }

    private var displayName: String {
        if url.path.hasSuffix(".photoslibrary/originals") { return "Медиатека «Фото»" }
        return FileManager.default.displayName(atPath: url.path)
    }
    private var shortPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Панель над результатами

struct ResultsToolbar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            let count = model.visibleMatches.count
            VStack(alignment: .leading, spacing: 0) {
                Text(model.allMatches.isEmpty && !model.isSearching ? "Результаты" : "Найдено: \(count)")
                    .font(.title3.bold())
                if !model.selection.isEmpty {
                    Text("Выбрано: \(model.selection.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !model.selection.isEmpty {
                let sel = model.selectedURLs
                Button { model.reveal(sel) } label: { Image(systemName: "folder") }
                    .help("Показать в Finder")
                Button { model.exportFiles(sel, move: false) } label: { Image(systemName: "doc.on.doc") }
                    .help("Скопировать в папку…")
                Button { model.exportFiles(sel, move: true) } label: { Image(systemName: "arrow.right.doc.on.clipboard") }
                    .help("Переместить в папку…")
                Button { model.trash(sel) } label: { Image(systemName: "trash") }
                    .help("В Корзину")
                Divider().frame(height: 20)
            }
            Picker("", selection: $model.sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
            Slider(value: $model.tileSize, in: 110...320).frame(width: 90).help("Размер миниатюр")
            Image(systemName: "photo").font(.body).foregroundStyle(.secondary)
            Menu {
                Button("Выделить всё") { model.selectAll() }.keyboardShortcut("a")
                Button("Скопировать пути") { model.copyPaths(model.selectedURLs.isEmpty ? model.visibleMatches.map(\.url) : model.selectedURLs) }
                Button("Сохранить список в файл…") { model.exportList() }
                Divider()
                Button("Очистить кэш (\(model.cache.count) фото, \(ByteCountFormatter.string(fromByteCount: Int64(model.cache.diskSize), countStyle: .file)))") { model.cache.clear() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(model.isSearching && model.allMatches.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Сетка

struct ResultsGrid: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let matches = model.visibleMatches
        Group {
            if matches.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: model.tileSize, maximum: model.tileSize * 1.4), spacing: 12)], spacing: 12) {
                            ForEach(matches) { m in
                                ResultTile(match: m).id(m.url)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: model.focused) { _, f in
                        if let f { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(f) } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .background(KeyHandler())
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 12) {
            if model.isSearching {
                ProgressView().controlSize(.large)
                Text(model.phase).foregroundStyle(.secondary)
                Text("Совпадения будут появляться здесь по мере поиска").font(.caption).foregroundStyle(.tertiary)
            } else if model.lastSearchSummary != nil {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 48, weight: .light)).foregroundStyle(.secondary)
                Text("Ничего не найдено").font(.title3)
                if let best = model.allMatches.max(by: { $0.similarity < $1.similarity }) {
                    Text("Самое похожее — \(Int(best.similarity))%. Понизьте порог точности, чтобы увидеть больше.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Показать от \(max(15, Int(best.similarity) - 5))%") { model.threshold = Double(max(15, Int(best.similarity) - 5)) }
                } else {
                    Text("Попробуйте другие папки или режим «Отдалённо».").foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 54, weight: .light)).foregroundStyle(.secondary)
                Text("Поиск фото по образцу").font(.title2.bold())
                VStack(alignment: .leading, spacing: 6) {
                    Label("Выберите или перетащите фото-образец", systemImage: "1.circle")
                    Label("Укажите папки или диски для поиска", systemImage: "2.circle")
                    Label("Нажмите «Найти похожие» (⌘↩)", systemImage: "3.circle")
                }
                .foregroundStyle(.secondary)
                Text("Находит копии в другом размере и формате, после обработки,\nкадрирования, а также просто похожие снимки. Всё работает локально.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.top, 6)
            }
        }
        .padding(30)
    }
}

struct ResultTile: View {
    @EnvironmentObject var model: AppModel
    let match: Match
    @State private var hover = false

    var body: some View {
        let selected = model.selection.contains(match.url)
        VStack(spacing: 6) {
            AsyncThumb(url: match.url, pixel: Int(model.tileSize * 2))
                .frame(height: model.tileSize * 0.8)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    SimilarityBadge(value: match.similarity).padding(6)
                }
            Text(match.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(match.url.deletingLastPathComponent().lastPathComponent)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.18) : hover ? Color.primary.opacity(0.05) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .gesture(TapGesture(count: 2).onEnded { model.open([match.url]) })
        .simultaneousGesture(TapGesture().onEnded { model.click(match.url, modifiers: NSEvent.modifierFlags) })
        .onDrag { NSItemProvider(object: match.url as NSURL) }
        .contextMenu {
            let targets = selected ? model.selectedURLs : [match.url]
            Button("Открыть") { model.open(targets) }
            Button("Показать в Finder") { model.reveal(targets) }
            Divider()
            Button("Скопировать") { model.copyFiles(targets) }
            Button("Скопировать путь") { model.copyPaths(targets) }
            Button("Скопировать в папку…") { model.exportFiles(targets, move: false) }
            Button("Переместить в папку…") { model.exportFiles(targets, move: true) }
            Divider()
            Button("Использовать как образец") { model.addExamples([match.url]) }
            Divider()
            Button("В Корзину", role: .destructive) { model.trash(targets) }
        }
        .help(match.url.path)
    }
}

struct SimilarityBadge: View {
    let value: Double
    var body: some View {
        Text("\(Int(value.rounded()))%")
            .font(.caption.bold()).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color))
            .foregroundStyle(.white)
    }
    var color: Color {
        value >= 75 ? .green : value >= 55 ? .blue : value >= 40 ? .orange : .gray
    }
}

// MARK: - Подробности

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let url = model.focused, let match = model.allMatches.first(where: { $0.url == url }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Сравнение").font(.headline)
                        Spacer()
                        SimilarityBadge(value: match.similarity)
                        Button { model.focused = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Закрыть")
                    }
                    Text("Найдено").font(.caption).foregroundStyle(.secondary)
                    AsyncThumb(url: url, pixel: 1000)
                        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 320)
                        .onTapGesture(count: 2) { model.open([url]) }
                    if model.examples.indices.contains(match.exampleIndex) {
                        Text("Образец").font(.caption).foregroundStyle(.secondary)
                        Image(nsImage: model.examples[match.exampleIndex].image)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 160)
                    }
                    Divider()
                    InfoRow(label: "Файл", value: url.lastPathComponent)
                    InfoRow(label: "Папка", value: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    if let size = ImageLoader.pixelSize(url: url) {
                        InfoRow(label: "Размер", value: "\(Int(size.width)) × \(Int(size.height))")
                    }
                    InfoRow(label: "Объём", value: ByteCountFormatter.string(fromByteCount: Int64(match.fileSize), countStyle: .file))
                    InfoRow(label: "Изменён", value: match.modified.formatted(date: .abbreviated, time: .shortened))
                    HStack {
                        Button("Открыть") { model.open([url]) }
                        Button("В Finder") { model.reveal([url]) }
                        Spacer()
                        Button(role: .destructive) { model.trash([url]) } label: { Image(systemName: "trash") }
                            .help("В Корзину")
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
        .font(.callout)
    }
}

// MARK: - Строка состояния

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.isSearching || model.lastSearchSummary != nil {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    if model.isSearching {
                        if model.total > 0 {
                            ProgressView(value: Double(model.processed), total: Double(max(model.total, 1)))
                                .frame(maxWidth: 260)
                            Text("\(model.processed) / \(model.total)").monospacedDigit()
                            if let eta = model.etaText { Text("· \(eta)").foregroundStyle(.secondary) }
                        } else {
                            ProgressView().controlSize(.small)
                            Text(model.phase)
                        }
                        Spacer()
                        Button("Остановить") { model.stopSearch() }.controlSize(.small)
                    } else if let s = model.lastSearchSummary {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                        Text(s).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 7)
            }
        }
    }
}

// MARK: - Клавиатура: стрелки, пробел, Delete, ⌘A, Enter

struct KeyHandler: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            context.coordinator.handle(event) ? nil : event
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.model = model }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }

    final class Coordinator {
        var model: AppModel
        var monitor: Any?
        init(model: AppModel) { self.model = model }

        @MainActor func handle(_ e: NSEvent) -> Bool {
            // не мешаем вводу текста
            if let r = e.window?.firstResponder, r is NSText { return false }
            let cols = max(1, Int((e.window?.frame.width ?? 1000) / CGFloat(model.tileSize + 40)) - 1)
            switch e.keyCode {
            case 123: model.moveFocus(by: -1); return true          // ←
            case 124: model.moveFocus(by: 1); return true           // →
            case 126: model.moveFocus(by: -cols); return true       // ↑
            case 125: model.moveFocus(by: cols); return true        // ↓
            case 36, 76:                                            // Enter
                if e.modifierFlags.contains(.command) { return false }
                if !model.selectedURLs.isEmpty { model.open(model.selectedURLs); return true }
            case 49:                                                // пробел — Quick Look
                if let f = model.focused { QuickLook.show(f); return true }
            case 51, 117:                                           // Delete
                if e.modifierFlags.contains(.command), !model.selectedURLs.isEmpty { model.trash(model.selectedURLs); return true }
            default: break
            }
            return false
        }
    }
}

enum QuickLook {
    static func show(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
