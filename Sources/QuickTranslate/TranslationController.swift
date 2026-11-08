import AppKit
import SwiftUI
import TranslationCore

@MainActor
final class TranslationController: ObservableObject {
  @Published private(set) var state = TranslationState()
  private let store: EnvironmentSettingsStore
  private let client: any TranslationServing
  private let capture: @MainActor (NSRunningApplication?) async throws -> String
  private var worker: Task<Void, Never>?
  var onChange: (() -> Void)?
  var onBegin: (() -> Void)?
  private(set) var displayScreen: NSScreen?

  init(
    store: EnvironmentSettingsStore, client: any TranslationServing = OpenAITranslationClient(),
    capture: @escaping @MainActor (NSRunningApplication?) async throws -> String = {
      try await SystemSelection().capture(from: $0)
    }
  ) {
    self.store = store
    self.client = client
    self.capture = capture
  }

  func translateSelection(at point: NSPoint = NSEvent.mouseLocation) {
    let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    start(source: NSWorkspace.shared.frontmostApplication, text: nil, screen: screen)
  }

  func retry() {
    guard !state.original.isEmpty, state.phase == .failed else { return }
    start(source: nil, text: state.original, screen: displayScreen)
  }

  private func start(source: NSRunningApplication?, text: String?, screen: NSScreen?) {
    worker?.cancel()
    let id = state.begin()
    displayScreen = screen
    onBegin?()
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        let configuration = try await store.load().draft.validated()
        try Task.checkCancellation()
        let input: String
        if let text {
          input = try TextPolicy.validate(text)
        } else {
          input = try TextPolicy.validate(try await capture(source))
        }
        try Task.checkCancellation()
        guard state.id == id else { return }
        state.captured(input, for: id)
        onChange?()
        for try await delta in client.stream(text: input, settings: configuration) {
          try Task.checkCancellation()
          guard state.id == id else { return }
          state.append(delta, for: id)
          onChange?()
        }
        try Task.checkCancellation()
        guard state.id == id else { return }
        state.complete(for: id)
        onChange?()
      } catch is CancellationError { return } catch {
        guard state.id == id else { return }
        let message =
          (error as? SettingsError)?.errorDescription
          ?? (error as? TranslationError)?.errorDescription ?? "翻译失败，请重试。"
        state.fail(message, for: id)
        onChange?()
      }
    }
  }

  func close() {
    worker?.cancel()
    worker = nil
    state.close()
    onChange?()
  }
}

private final class TranslationPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class TranslationPanelController {
  private let panel: NSPanel
  private let model: TranslationController
  private let pasteboard: NSPasteboard
  private var visibleFrame: NSRect?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private(set) var readingMeasurement = ReadingMeasurement()
  var onDismiss: (() -> Void)?
  var isVisible: Bool { panel.isVisible }
  var frame: NSRect { panel.frame }

  init(
    model: TranslationController, pasteboard: NSPasteboard = .general,
    settings: @escaping () -> Void
  ) {
    self.model = model
    self.pasteboard = pasteboard
    panel = TranslationPanel(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.isMovableByWindowBackground = true
    let content = NSHostingView(
      rootView: TranslationView(
        controller: model, settings: settings,
        copy: { [weak model] in
          guard let model, !model.state.translated.isEmpty else { return false }
          pasteboard.clearContents()
          return pasteboard.setString(model.state.translated, forType: .string)
        }, onMeasure: { [weak self] in self?.updateMeasurement($0) }))
    // Size is owned by the panel, never SwiftUI's growing streaming text.
    content.sizingOptions = []
    panel.contentView = content
  }

  static func centeredFrame(in visibleFrame: NSRect, preferredHeight: CGFloat = 530) -> NSRect {
    let width = min(480, max(1, visibleFrame.width - 16))
    let height = min(max(190, preferredHeight), 530, max(1, visibleFrame.height - 16))
    return NSRect(
      x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2,
      width: width, height: height)
  }

  func show(on screen: NSScreen?) {
    guard !panel.isVisible else { return }
    guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
    visibleFrame = screen.visibleFrame
    readingMeasurement = ReadingMeasurement()
    let width = Self.centeredFrame(in: screen.visibleFrame).width
    // Reserve room for the translation once, then hold still until the request ends.
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 6
    let source = NSAttributedString(
      string: String(model.state.original.prefix(2000)),
      attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: style])
    let sourceHeight = source.boundingRect(
      with: NSSize(width: max(1, width - 52), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height
    let reservedHeight = max(220, 166 + sourceHeight * 1.8)
    panel.setFrame(
      Self.centeredFrame(in: screen.visibleFrame, preferredHeight: reservedHeight), display: true)
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.orderFrontRegardless()
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]) { [weak self] _ in
      MainActor.assumeIsolated { self?.onDismiss?() }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown,
    ]) { [weak self] event in
      let suppress = MainActor.assumeIsolated {
        guard let self else { return false }
        if event.type == .keyDown {
          if event.window === self.panel, event.keyCode == 53 {
            self.onDismiss?()
            return true
          }
        } else if event.window !== self.panel {
          self.onDismiss?()
        }
        return false
      }
      return suppress ? nil : event
    }
  }

  func hide() {
    panel.orderOut(nil)
    visibleFrame = nil
    readingMeasurement = ReadingMeasurement()
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
  }

  private func updateMeasurement(_ measurement: ReadingMeasurement) {
    guard panel.isVisible, measurement.sessionID == model.state.id,
      model.state.phase != .hidden, measurement.height.isFinite, measurement.height > 0,
      let visibleFrame
    else { return }
    readingMeasurement = measurement
    guard measurement.canResize else { return }
    let size = Self.centeredFrame(
      in: visibleFrame, preferredHeight: ceil(measurement.height)
    ).size
    guard abs(panel.frame.height - size.height) > 1 else { return }
    // Preserve the current center if the user has dragged the window, while staying on screen.
    let x = min(
      max(panel.frame.midX - size.width / 2, visibleFrame.minX + 8),
      visibleFrame.maxX - size.width - 8)
    let y = min(
      max(panel.frame.midY - size.height / 2, visibleFrame.minY + 8),
      visibleFrame.maxY - size.height - 8)
    panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
  }

  func setAppearanceForSmoke(_ appearance: NSAppearance.Name?) {
    panel.appearance = appearance.flatMap { NSAppearance(named: $0) }
  }

  var copiedTextForSmoke: String? { pasteboard.string(forType: .string) }

  private var scrollView: NSScrollView? {
    func findScroll(in view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView { return scroll }
      return view.subviews.lazy.compactMap { findScroll(in: $0) }.first
    }
    return panel.contentView.flatMap { findScroll(in: $0) }
  }

  var scrollOffsetForSmoke: CGFloat? { scrollView?.contentView.bounds.minY }

  func scrollToBottomForSmoke() -> Bool {
    guard let scroll = scrollView, let document = scroll.documentView
    else { return false }
    let distance = document.bounds.height - scroll.contentView.bounds.height
    guard distance > 0 else { return false }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: distance))
    scroll.reflectScrolledClipView(scroll.contentView)
    return scroll.contentView.bounds.minY > 0
  }

  func postEscapeForSmoke() {
    if let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
      isARepeat: false, keyCode: 53)
    {
      NSApp.postEvent(event, atStart: false)
    }
  }

  func snapshot(to url: URL) throws {
    guard
      let image = CGWindowListCreateImage(
        .null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
        [.boundsIgnoreFraming, .bestResolution])
    else { throw TranslationError.invalidResponse }
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(
      to: url)
  }

  func postSmokeClick(inside: Bool, outsideWindow: NSWindow) {
    let target = inside ? panel : outsideWindow
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      if let event = NSEvent.mouseEvent(
        with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
      {
        NSApp.postEvent(event, atStart: false)
      }
    }
  }

  func clickCloseButtonForSmoke() throws {
    try clickButtonForSmoke(identifier: "closeTranslation")
  }

  func clickButtonForSmoke(identifier: String) throws {
    func findButton(in view: NSView) -> NSButton? {
      if let button = view as? NSButton, button.identifier?.rawValue == identifier {
        return button
      }
      return view.subviews.lazy.compactMap { findButton(in: $0) }.first
    }
    guard let content = panel.contentView, let button = findButton(in: content),
      !button.isHidden, button.isEnabled
    else { throw TranslationError.invalidResponse }
    button.performClick(nil)
  }
}
