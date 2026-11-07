import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PhotoFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Поиск фото по образцу") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Выбрать образец…") { model.chooseExamples() }
                    .keyboardShortcut("o")
                Button("Добавить папку для поиска…") { model.chooseFolders() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Вставить образец из буфера") { model.pasteExample() }
                    .keyboardShortcut("v")
                Button("Скопировать выбранные файлы") { model.copyFiles(model.selectedURLs) }
                    .keyboardShortcut("c")
                    .disabled(model.selection.isEmpty)
                Button("Выделить всё") { model.selectAll() }
                    .keyboardShortcut("a")
            }
            CommandMenu("Поиск") {
                Button("Найти похожие") { model.startSearch() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canSearch)
                Button("Остановить") { model.stopSearch() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isSearching)
                Divider()
                Button("Показать в Finder") { model.reveal(model.selectedURLs) }
                    .keyboardShortcut("r")
                    .disabled(model.selection.isEmpty)
                Button("Переместить в Корзину") { model.trash(model.selectedURLs) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.isEmpty)
            }
        }
    }
}
