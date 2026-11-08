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
  private(set) var anchor = NSPoint.zero

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

  func translateSelection() {
    start(source: NSWorkspace.shared.frontmostApplication, text: nil)
  }

  func retry() {
    guard !state.original.isEmpty, state.phase == .failed else { return }
    start(source: nil, text: state.original)
  }

  private func start(source: NSRunningApplication?, text: String?) {
    worker?.cancel()
    let id = state.begin()
    anchor = NSEvent.mouseLocation
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

struct TranslationView: View {
  @ObservedObject var controller: TranslationController
  let settings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Image(systemName: "character.bubble.fill").foregroundStyle(.blue)
        Text("英文 → 简体中文").font(.headline)
        Spacer()
        Button(action: settings) { Image(systemName: "gearshape") }.buttonStyle(.borderless).help(
          "设置")
        Button("复制译文") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(controller.state.translated, forType: .string)
        }.disabled(controller.state.translated.isEmpty)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if !controller.state.original.isEmpty {
            Text("原文").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(controller.state.original).textSelection(.enabled).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack {
              Text("译文").font(.caption.weight(.medium)).foregroundStyle(.secondary)
              if controller.state.phase == .translating { ProgressView().controlSize(.mini) }
            }
            if controller.state.translated.isEmpty, controller.state.phase == .translating {
              Text("正在翻译…").foregroundStyle(.secondary)
            } else {
              Text(controller.state.translated).textSelection(.enabled).lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          if let message = controller.state.errorMessage {
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
            if !controller.state.original.isEmpty {
              Button("重试") { controller.retry() }
            } else {
              Button("打开设置") { settings() }
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
      }.frame(height: controller.state.original.isEmpty ? 110 : 330)
      Text("点击窗口外部关闭").font(.caption).foregroundStyle(.tertiary)
    }.padding(20).frame(width: 460).background(Color(nsColor: .windowBackgroundColor))
  }
}

private final class TranslationPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class TranslationPanelController {
  private let panel: NSPanel
  private var globalMonitor: Any?
  private var localMonitor: Any?
  var onDismiss: (() -> Void)?
  var isVisible: Bool { panel.isVisible }

  init(model: TranslationController, settings: @escaping () -> Void) {
    panel = TranslationPanel(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 430),
      styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered,
      defer: false)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.isMovableByWindowBackground = true
    panel.contentView = NSHostingView(
      rootView: TranslationView(controller: model, settings: settings))
  }

  func show(near point: NSPoint) {
    guard !panel.isVisible else { return }
    panel.contentView?.layoutSubtreeIfNeeded()
    let visible =
      (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame ?? .zero
    var frame = panel.frame
    frame.origin.x = min(max(point.x + 12, visible.minX + 8), visible.maxX - frame.width - 8)
    frame.origin.y = min(
      max(point.y - frame.height - 12, visible.minY + 8), visible.maxY - frame.height - 8)
    panel.setFrame(frame, display: true)
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
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
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
}
