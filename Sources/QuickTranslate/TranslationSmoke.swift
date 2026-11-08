import AppKit
import ApplicationServices
import TranslationCore

/// Explicit smoke-test argument only. These fixtures are never used by the normal app.
@MainActor
final class SmokeSelection {
  var text = "Hello, world.\n\nSelect English text and press the shortcut."
}

struct SmokeTranslationClient: TranslationServing {
  func stream(text: String, settings: SettingsDraft) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      // Intentionally ignore consumer cancellation to exercise late-response isolation.
      Task {
        try? await Task.sleep(for: .milliseconds(text == "old" ? 400 : 40))
        continuation.yield(text == "old" ? "旧请求" : "你好，世界。\n\n")
        try? await Task.sleep(for: .milliseconds(180))
        if text == "failure" {
          continuation.finish(throwing: TranslationError.incomplete)
        } else {
          continuation.yield("选中英文并按下快捷键，即可查看中文翻译。")
          continuation.finish()
        }
      }
    }
  }
}

@MainActor
enum TranslationSmoke {
  static func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<150 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw TranslationError.timeout
  }

  static func run(
    model: TranslationController, panel: TranslationPanelController, source: SmokeSelection,
    settingsWindow: NSWindow, hotKeys: HotKeyController, directory: URL
  ) async throws -> [String: String] {
    var checks = [String: String]()
    if !AXIsProcessTrusted() {
      do {
        _ = try await SystemSelection().capture(from: NSWorkspace.shared.frontmostApplication)
        throw TranslationError.invalidResponse
      } catch TranslationError.permissionRequired {
        checks["permissionDenied"] = "passed"
      }
    } else {
      checks["permissionDenied"] = "not-run: permission already granted"
    }
    // Actual OS registration; never synthesize keystrokes into another user's application.
    try hotKeys.register(.optionD)
    guard let choice = hotKeys.shortcut, choice == .optionD else {
      throw HotKeyController.RegistrationError()
    }
    checks["optionDRegistration"] = "passed"
    let competing = HotKeyController()
    defer { competing.stop() }
    do {
      try competing.register(choice)
      throw TranslationError.invalidResponse
    } catch is HotKeyController.RegistrationError {}
    checks["hotKeyRegistrationAndConflict"] = "passed"
    checks["hotKeyReplacementPreservesPreviousOnConflict"] = "not-run: no alternate key available"
    for alternate in Shortcut.allCases where alternate != choice {
      guard (try? hotKeys.register(alternate)) != nil else { continue }
      try competing.register(choice)
      do {
        try hotKeys.register(choice)
        throw TranslationError.invalidResponse
      } catch is HotKeyController.RegistrationError {}
      guard hotKeys.shortcut == alternate else { throw TranslationError.invalidResponse }
      competing.stop()
      try hotKeys.register(choice)
      checks["hotKeyReplacementPreservesPreviousOnConflict"] = "passed"
      break
    }
    source.text = "old"
    model.translateSelection()
    try await wait { model.state.phase == .translating }
    source.text = "Hello, world.\n\nSelect English text and press the shortcut."
    model.translateSelection()
    try await wait { model.state.phase == .completed }
    try await Task.sleep(for: .milliseconds(500))
    guard model.state.original == source.text, !model.state.translated.contains("旧请求"),
      panel.isVisible
    else { throw TranslationError.invalidResponse }
    try panel.snapshot(to: directory.appendingPathComponent("translation.png"))
    panel.postSmokeClick(inside: true, outsideWindow: settingsWindow)
    try await Task.sleep(for: .milliseconds(100))
    guard panel.isVisible else { throw TranslationError.invalidResponse }
    panel.postSmokeClick(inside: false, outsideWindow: settingsWindow)
    try await wait { !panel.isVisible && model.state.phase == .hidden }

    for waitForText in [false, true] {
      model.translateSelection()
      try await wait {
        model.state.phase == .translating && (!waitForText || !model.state.translated.isEmpty)
      }
      panel.postSmokeClick(inside: false, outsideWindow: settingsWindow)
      try await wait { model.state.phase == .hidden }
      try await Task.sleep(for: .milliseconds(300))
      guard !panel.isVisible else { throw TranslationError.invalidResponse }
    }

    source.text = "failure"
    model.translateSelection()
    try await wait { model.state.phase == .failed }
    guard !model.state.translated.isEmpty else { throw TranslationError.invalidResponse }
    model.retry()
    source.text = "changed clipboard fixture"
    try await wait { model.state.phase == .failed }
    guard model.state.original == "failure" else { throw TranslationError.invalidResponse }
    panel.postSmokeClick(inside: false, outsideWindow: settingsWindow)
    try await wait { model.state.phase == .hidden }

    source.text = ""
    model.translateSelection()
    try await wait { model.state.phase == .failed }
    guard model.state.original.isEmpty else { throw TranslationError.invalidResponse }
    model.close()
    checks["emptySelection"] = "passed: fixture"
    checks["retryUsesOriginal"] = "passed: fixture"
    checks["lateResponseIsolation"] = "passed: fixture"
    checks["partialFailurePreserved"] = "passed: fixture"
    checks["insideClickAndOutsideClickInFourStates"] = "passed: own-app events"
    checks["crossApplicationSelectionAndClicks"] = "not-run"
    checks["realAlibabaAPI"] = "not-run"
    return checks
  }
}
