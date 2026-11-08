import AppKit
import ApplicationServices
import TranslationCore

enum SmokePassage {
  static let original = """
    A small tool should fit naturally into your day. Select a passage, understand its meaning, and return to what you were reading.

    The interface stays quiet, so the words can take the lead. A little space between paragraphs makes a long passage easier to follow.
    """
  static let translated = """
    小工具应该自然地融入日常。选中一段文字，读懂它的意思，再回到原来的阅读中。

    界面保持克制，让文字成为主角。段落之间留一点空隙，长文也会更容易读下去。
    """
  static let short = "Good design makes room for what matters."
}

/// Explicit smoke-test argument only. These fixtures are never used by the normal app.
@MainActor
final class SmokeSelection {
  var text = SmokePassage.original
}

struct SmokeTranslationClient: TranslationServing {
  func stream(text: String, settings: SettingsDraft) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      // Intentionally ignore consumer cancellation to exercise late-response isolation.
      Task {
        try? await Task.sleep(for: .milliseconds(text == "old" ? 400 : 40))
        let translated =
          text == "old"
          ? "旧请求"
          : text == SmokePassage.short
            ? "好的设计，会为真正重要的内容留出空间。"
            : text.hasPrefix("Reading paragraph")
              ? String(repeating: "每段原文下方紧接译文，长文可以继续向下滚动。\n\n", count: 24)
              : SmokePassage.translated
        let middle = translated.index(translated.startIndex, offsetBy: translated.count / 2)
        continuation.yield(String(translated[..<middle]))
        try? await Task.sleep(for: .milliseconds(180))
        if text == "failure" {
          continuation.finish(throwing: TranslationError.incomplete)
        } else {
          continuation.yield(String(translated[middle...]))
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

  static func checkCentered(_ frame: NSRect, in visibleFrame: NSRect) throws {
    guard abs(frame.midX - visibleFrame.midX) <= 1,
      abs(frame.midY - visibleFrame.midY) <= 1,
      visibleFrame.insetBy(dx: 7, dy: 7).contains(frame)
    else { throw TranslationError.invalidResponse }
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
    source.text = SmokePassage.original
    model.translateSelection()
    try await wait { model.state.phase == .completed }
    try await Task.sleep(for: .milliseconds(500))
    guard model.state.original == source.text, !model.state.translated.contains("旧请求"),
      panel.isVisible
    else { throw TranslationError.invalidResponse }
    guard TranslationReading(state: model.state).isPaired else {
      throw TranslationError.invalidResponse
    }
    panel.setAppearanceForSmoke(.aqua)
    try await Task.sleep(for: .milliseconds(120))
    try panel.snapshot(to: directory.appendingPathComponent("translation.png"))
    try panel.clickButtonForSmoke(identifier: "copyTranslation")
    guard panel.copiedTextForSmoke == model.state.translated, panel.isVisible else {
      throw TranslationError.invalidResponse
    }
    checks["copyCompleteTranslation"] = "passed: actual button, isolated pasteboard"
    panel.setAppearanceForSmoke(.darkAqua)
    try await Task.sleep(for: .milliseconds(120))
    try panel.snapshot(to: directory.appendingPathComponent("translation-dark.png"))
    panel.setAppearanceForSmoke(.aqua)
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

    for phase in ["loading", "streaming", "completed", "failed"] {
      source.text = phase == "failed" ? "failure" : "Hello, world."
      model.translateSelection()
      try await wait {
        switch phase {
        case "loading": model.state.phase == .translating && model.state.translated.isEmpty
        case "streaming": model.state.phase == .translating && !model.state.translated.isEmpty
        case "completed": model.state.phase == .completed
        default: model.state.phase == .failed
        }
      }
      try panel.clickCloseButtonForSmoke()
      try await wait { !panel.isVisible && model.state.phase == .hidden }
      try await Task.sleep(for: .milliseconds(500))
      guard !panel.isVisible, model.state.original.isEmpty, model.state.translated.isEmpty else {
        throw TranslationError.invalidResponse
      }
    }
    checks["closeButtonInFourStatesAndLateResponse"] = "passed: actual NSButton action, fixture"

    source.text = SmokePassage.short
    model.translateSelection()
    try await wait { panel.readingMeasurement.canResize }
    guard model.state.phase == .completed, panel.frame.height < 320,
      abs(panel.frame.height - panel.readingMeasurement.height) <= 2,
      let screen = model.displayScreen
    else { throw TranslationError.invalidResponse }
    try checkCentered(panel.frame, in: screen.visibleFrame)
    try panel.snapshot(to: directory.appendingPathComponent("translation-short.png"))
    checks["shortTextFitsContent"] = "passed: measured actual window"
    checks["shortWindowHeight"] = String(describing: panel.frame.height)
    model.close()

    source.text = String(repeating: "Reading paragraph remains available in full.\n\n", count: 24)
    model.translateSelection()
    try await wait { panel.readingMeasurement.canResize }
    guard TranslationReading(state: model.state).blocks.count == 24,
      panel.frame.height <= 530, panel.readingMeasurement.height > panel.frame.height,
      panel.scrollToBottomForSmoke()
    else { throw TranslationError.invalidResponse }
    try await Task.sleep(for: .milliseconds(120))
    try panel.snapshot(to: directory.appendingPathComponent("translation-long-bottom.png"))
    checks["longParagraphsScrollWithinBoundedWindow"] = "passed: actual scroll view, 24 pairs"
    model.close()

    model.translateSelection()
    try await wait { panel.readingMeasurement.canResize }
    guard panel.scrollOffsetForSmoke == 0 else { throw TranslationError.invalidResponse }
    panel.postEscapeForSmoke()
    try await wait { !panel.isVisible && model.state.phase == .hidden }
    checks["newSessionStartsAtTop"] = "passed: same long text, new session"
    checks["escapeClosesBorderlessPanel"] = "passed: own-app key event"

    source.text = "failure"
    model.translateSelection()
    try await wait { panel.readingMeasurement.canResize }
    try panel.snapshot(to: directory.appendingPathComponent("translation-error.png"))
    model.close()
    panel.setAppearanceForSmoke(nil)

    // Real windows, injected trigger coordinates: no cursor movement or other-app automation.
    source.text = String(repeating: "A longer paragraph remains scrollable.\n\n", count: 80)
    for screen in NSScreen.screens {
      let bounds = screen.frame.insetBy(dx: 2, dy: 2)
      var initialFrame: NSRect?
      for point in [
        NSPoint(x: bounds.minX, y: bounds.minY), NSPoint(x: bounds.maxX, y: bounds.minY),
        NSPoint(x: bounds.minX, y: bounds.maxY), NSPoint(x: bounds.maxX, y: bounds.maxY),
      ] {
        model.translateSelection(at: point)
        try await wait { model.state.phase == .translating }
        guard model.displayScreen === screen, panel.isVisible else {
          throw TranslationError.invalidResponse
        }
        try checkCentered(panel.frame, in: screen.visibleFrame)
        if let initialFrame, initialFrame != panel.frame { throw TranslationError.invalidResponse }
        initialFrame = panel.frame
        try await wait { model.state.phase == .completed }
        try checkCentered(panel.frame, in: screen.visibleFrame)
        guard initialFrame == panel.frame else { throw TranslationError.invalidResponse }
        model.close()
      }
    }
    for visible in [
      NSRect(x: 0, y: 24, width: 1280, height: 700),
      NSRect(x: -1600, y: 100, width: 1600, height: 900),
      NSRect(x: 100, y: -600, width: 320, height: 260),
    ] {
      try checkCentered(TranslationPanelController.centeredFrame(in: visible), in: visible)
    }
    checks["centeredAtAllFourTriggerCorners"] = "passed: injected coordinates, actual windows"
    checks["stableFrameWhileStreamingLongText"] = "passed: fixture"
    checks["smallAndNegativeScreenBounds"] = "passed: geometry only"
    checks["placementScreenCount"] = String(NSScreen.screens.count)
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
