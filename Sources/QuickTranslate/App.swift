import AppKit
import SwiftUI
import TranslationCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private var settingsWindow: NSWindow?
  private var settingsModel: SettingsModel?
  private var smoke: (directory: URL, phase: String)?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let arguments = CommandLine.arguments
    if arguments.count == 4, arguments[1] == "--smoke-test",
      ["save", "reload"].contains(arguments[3])
    {
      let directory = URL(fileURLWithPath: arguments[2])
      guard directory.lastPathComponent.hasPrefix("quick-translate-smoke-") else { exit(2) }
      smoke = (directory, arguments[3])
    }
    let path =
      smoke?.directory.appendingPathComponent(".env").path
      ?? Bundle.main.object(forInfoDictionaryKey: "QTEnvironmentFile") as? String
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
        ".env"
      ).path
    let store = EnvironmentSettingsStore(fileURL: URL(fileURLWithPath: path))
    settingsModel = SettingsModel(store: store)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(
      systemSymbolName: "character.bubble", accessibilityDescription: "Quick Translate")
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
    showSettings()
    if let smoke {
      Task {
        try? await Task.sleep(for: .milliseconds(500))
        await runSmoke(in: smoke.directory, phase: smoke.phase)
      }
    }
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
      if phase == "save" {
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
      ]
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
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    settingsWindow?.close()
  }
}

@main
struct QuickTranslateApp {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
  }
}
