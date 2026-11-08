import AppKit
import ApplicationServices
import SwiftUI
import TranslationCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private var settingsWindow: NSWindow?
  private var settingsModel: SettingsModel?
  private var smoke: (directory: URL, phase: String)?
  private var hotKeys: HotKeyController?
  private var translation: TranslationController?
  private var translationPanel: TranslationPanelController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let arguments = CommandLine.arguments
    if arguments == [arguments[0], "--accessibility-status"] {
      // Launch via Launch Services to inspect this bundle's own permission without prompting.
      print("{\"accessibilityTrusted\":\(AXIsProcessTrusted())}")
      NSApp.terminate(nil)
      return
    }
    if arguments.count == 4, arguments[1] == "--smoke-test",
      ["save", "reload", "translation", "portable-save", "portable-reload"].contains(arguments[3])
    {
      let directory = URL(fileURLWithPath: arguments[2])
      guard directory.lastPathComponent.hasPrefix("quick-translate-smoke-") else { exit(2) }
      smoke = (directory, arguments[3])
    }
    let portableSmoke = smoke?.phase.hasPrefix("portable-") == true
    let location = EnvironmentLocation(
      projectPath: Bundle.main.object(forInfoDictionaryKey: "QTEnvironmentFile") as? String,
      homeDirectory: portableSmoke
        ? smoke!.directory : FileManager.default.homeDirectoryForCurrentUser)
    if portableSmoke {
      guard location.createsParentDirectory,
        location.fileURL.path.hasPrefix(smoke!.directory.path + "/")
      else { exit(2) }
    }
    let store = EnvironmentSettingsStore(
      fileURL: portableSmoke || smoke == nil
        ? location.fileURL : smoke!.directory.appendingPathComponent(".env"),
      createsParentDirectory: (portableSmoke || smoke == nil) && location.createsParentDirectory)
    settingsModel = SettingsModel(store: store)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = BrandIcon.image(size: 18, style: .menu)
    item.button?.toolTip = "Quick Translate"
    let menu = NSMenu()
    let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)
    menu.addItem(.separator())
    let quit = NSMenuItem(
      title: "退出 Quick Translate", action: #selector(quitApp), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
    installApplicationMenu()
    if let smoke {
      showSettings()
      Task {
        try? await Task.sleep(for: .milliseconds(500))
        await runSmoke(
          in: smoke.directory, phase: smoke.phase.replacingOccurrences(of: "portable-", with: ""))
      }
    } else {
      setupTranslation(store: store)
      Task {
        do {
          let configuration = try await store.load().draft
          let shortcutWarning = applyShortcut(configuration.shortcut)
          if shortcutWarning != nil || (try? configuration.validated()) == nil { showSettings() }
        } catch { showSettings() }
      }
    }
  }

  private func setupTranslation(
    store: EnvironmentSettingsStore,
    client: any TranslationServing = OpenAITranslationClient(),
    pasteboard: NSPasteboard = .general,
    capture: @escaping @MainActor (NSRunningApplication?) async throws -> String = {
      try await SystemSelection().capture(from: $0)
    }
  ) {
    let model = TranslationController(store: store, client: client, capture: capture)
    let panel = TranslationPanelController(model: model, pasteboard: pasteboard) { [weak self] in
      self?.translation?.close()
      self?.showSettings()
    }
    panel.onDismiss = { [weak model] in model?.close() }
    model.onBegin = { [weak panel] in panel?.hide() }
    model.onChange = { [weak model, weak panel] in
      guard let model else { return }
      if model.state.phase == .hidden {
        panel?.hide()
      } else if model.state.phase != .capturing {
        panel?.show(on: model.displayScreen)
      }
    }
    let keys = HotKeyController()
    keys.onPress = { [weak model] in model?.translateSelection() }
    hotKeys = keys
    translation = model
    translationPanel = panel
    settingsModel?.onSaved = { [weak self] choice in self?.applyShortcut(choice) }
  }

  private func applyShortcut(_ choice: Shortcut) -> String? {
    guard let hotKeys else { return nil }
    do {
      try hotKeys.register(choice)
      settingsModel?.activeShortcutDescription = "当前快捷键：\(choice.label)"
      return nil
    } catch {
      settingsModel?.activeShortcutDescription =
        hotKeys.shortcut.map { "当前仍使用：\($0.label)" } ?? "快捷键未启用，可能与其他应用冲突，请更换组合。"
      return "配置已保存，但所选快捷键未启用。可能与其他应用冲突，请更换组合。"
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showSettings()
    return true
  }

  private func installApplicationMenu() {
    let menu = NSMenu()
    let root = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "退出 Quick Translate", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    root.submenu = appMenu
    menu.addItem(root)
    let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
    let edit = NSMenu(title: "编辑")
    for (title, action, key) in [
      ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a"),
    ] {
      edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
    }
    editRoot.submenu = edit
    menu.addItem(editRoot)
    NSApp.mainMenu = menu
  }

  @objc func showSettings() {
    let shouldReload = settingsWindow?.isVisible != true
    if settingsWindow == nil, let model = settingsModel {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 576, height: 440),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
      window.title = "Quick Translate 设置"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: SettingsView(state: model))
      window.center()
      settingsWindow = window
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
    if shouldReload, let model = settingsModel {
      Task { await model.reload() }
    }
  }

  @objc private func quitApp() { NSApp.terminate(nil) }

  /// Runs the actual application and menu actions against an isolated fixture, never the user's .env.
  private func runSmoke(in directory: URL, phase: String) async {
    do {
      guard let model = settingsModel, let window = settingsWindow,
        let menu = statusItem?.menu
      else { throw SettingsError.unreadableFile }
      window.close()
      menu.performActionForItem(at: 0)
      guard window.isVisible else { throw SettingsError.unreadableFile }
      await model.reload()
      if phase != "reload" {
        model.baseURL = "https://example.com/compatible-mode/v1"
        model.model = "smoke-test-model"
        model.apiKey = "fixture-not-a-real-api-key"
        await model.save()
        guard model.succeeded else { throw SettingsError.unwritableFile }
        model.model = ""
        await model.save()
        guard !model.succeeded else { throw SettingsError.invalidValue }
        await model.reload()
      }
      guard model.succeeded, model.model == "smoke-test-model",
        model.apiKey == "fixture-not-a-real-api-key"
      else { throw SettingsError.unreadableFile }
      var checks = [String: String]()
      // Removing the reload button must still leave a way to recover from external file changes.
      model.model = "unsaved edit"
      menu.performActionForItem(at: 0)
      try await Task.sleep(for: .milliseconds(50))
      guard model.model == "unsaved edit", model.saveButtonTitle == "保存配置" else {
        throw SettingsError.invalidValue
      }
      let previous = try await model.store.load()
      var external = previous.draft
      external.model = "external edit"
      _ = try await model.store.save(external, expectedRevision: previous.revision)
      await model.save()
      guard !model.succeeded, model.message.contains("关闭并重新打开") else {
        throw SettingsError.changedOnDisk
      }
      window.close()
      menu.performActionForItem(at: 0)
      try await TranslationSmoke.wait { !model.busy && model.model == "external edit" }
      model.model = "smoke-test-model"
      await model.save()
      guard model.succeeded, model.message.isEmpty, model.saveButtonTitle == "已保存" else {
        throw SettingsError.unwritableFile
      }
      checks["settingsReopenReloadsAndVisibleReopenPreservesEdits"] = "passed: own-app menu"
      checks["externalChangeConflictAndRecovery"] = "passed: isolated file"
      checks["compactSaveFeedback"] = "passed"
      guard statusItem?.button?.image?.isTemplate == true,
        let icon = Bundle.main.url(forResource: "QuickTranslate", withExtension: "icns"),
        NSImage(contentsOf: icon) != nil
      else { throw SettingsError.unreadableFile }
      checks["bundledIconAndMenuTemplate"] = "passed"
      if phase == "translation" {
        let source = SmokeSelection()
        setupTranslation(
          store: model.store, client: SmokeTranslationClient(),
          pasteboard: NSPasteboard(name: NSPasteboard.Name(directory.lastPathComponent)),
          capture: { _ in source.text })
        guard let translation, let translationPanel, let hotKeys else {
          throw TranslationError.invalidResponse
        }
        let translationChecks = try await TranslationSmoke.run(
          model: translation, panel: translationPanel, source: source,
          settingsWindow: window, hotKeys: hotKeys, directory: directory)
        checks.merge(translationChecks) { current, _ in current }
      }
      try await Task.sleep(for: .milliseconds(200))
      if let snapshot = CGWindowListCreateImage(
        .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
        [.boundsIgnoreFraming, .bestResolution])
      {
        let bitmap = NSBitmapImageRep(cgImage: snapshot)
        try bitmap.representation(using: .png, properties: [:])?.write(
          to: directory.appendingPathComponent("settings-\(phase).png"))
      }
      let report = [
        "phase": phase, "result": "passed", "menuOpen": "passed", "fileStorage": "passed",
      ].merging(checks) { current, _ in current }
      try JSONSerialization.data(withJSONObject: report).write(
        to: directory.appendingPathComponent("\(phase).json"))
      print("APP SMOKE \(phase): PASS")
      menu.performActionForItem(at: 2)
    } catch {
      // Keep even diagnostic paths free of credentials and file contents.
      print("APP SMOKE \(phase): FAIL")
      exit(1)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    translation?.close()
    translationPanel?.hide()
    hotKeys?.stop()
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    settingsWindow?.close()
  }
}

@main
struct QuickTranslateApp {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--export-icon" {
      do {
        try BrandIcon.export(to: URL(fileURLWithPath: CommandLine.arguments[2]))
      } catch {
        print("Unable to export application icon.")
        exit(1)
      }
      return
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
  }
}
