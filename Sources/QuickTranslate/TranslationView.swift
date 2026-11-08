import AppKit
import SwiftUI
import TranslationCore

@MainActor
enum ReadingPalette {
  static let paper = color(light: 0xFBFBF8, dark: 0x252622)
  static let ink = color(light: 0x2B302B, dark: 0xE6E8E1)
  static let muted = color(light: 0x6D736B, dark: 0xA7ADA1)
  static let line = color(light: 0xE5E8E0, dark: 0x3B3E36)

  private static func color(light: Int, dark: Int) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: CGFloat((hex >> 16) & 255) / 255,
          green: CGFloat((hex >> 8) & 255) / 255,
          blue: CGFloat(hex & 255) / 255, alpha: 1)
      })
  }
}

struct ReadingMeasurement: Equatable, Sendable {
  var sessionID: UUID?
  var canResize = false
  var height: CGFloat = 0
}

struct TranslationView: View {
  @ObservedObject var controller: TranslationController
  let settings: () -> Void
  let copy: () -> Bool
  let onMeasure: @MainActor (ReadingMeasurement) -> Void
  @State private var copied = false

  private var state: TranslationState { controller.state }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 11) {
        Image(nsImage: BrandIcon.image(size: 25, style: .mark))
          .foregroundStyle(ReadingPalette.ink).accessibilityHidden(true)
        HStack(spacing: 8) {
          Text("英文")
          Image(systemName: "arrow.right").font(.system(size: 11))
          Text("简体中文")
        }.font(.system(size: 12, weight: .medium)).foregroundStyle(ReadingPalette.muted)
        Spacer(minLength: 8)
        ReadingButton(symbol: "xmark", label: "关闭翻译", identifier: "closeTranslation") {
          controller.close()
        }.frame(width: 28, height: 28)
      }.padding(.leading, 22).padding(.trailing, 18).frame(height: 60)
      ReadingPalette.line.frame(height: 1)
      ScrollView {
        readingContent
          .padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 26)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            GeometryReader { geometry in
              let measurement = ReadingMeasurement(
                sessionID: state.id,
                canResize: state.phase == .completed || state.phase == .failed,
                height: geometry.size.height + 61)
              Color.clear.task(id: measurement) { onMeasure(measurement) }
            })
      }.id(state.id).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .foregroundStyle(ReadingPalette.ink)
    .background(ReadingPalette.paper)
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(ReadingPalette.line, lineWidth: 1))
    .onChange(of: state.id) { _ in copied = false }
    .onChange(of: state.translated) { _ in copied = false }
  }

  private var readingContent: some View {
    let reading = TranslationReading(state: state)
    return VStack(alignment: .leading, spacing: 0) {
      if !reading.blocks.isEmpty {
        HStack {
          Text("原文与译文").font(.system(size: 11, weight: .medium))
          Spacer()
          ReadingButton(
            symbol: copied ? "checkmark" : "doc.on.doc", label: "复制全部译文",
            identifier: "copyTranslation", title: copied ? "已复制" : "复制译文",
            enabled: !state.translated.isEmpty
          ) { copied = copy() }.frame(width: 88, height: 28)
        }.foregroundStyle(ReadingPalette.muted).padding(.bottom, 14)

        ForEach(Array(reading.blocks.enumerated()), id: \.offset) { index, block in
          if index > 0 {
            ReadingPalette.line.frame(height: 1).padding(.vertical, 22)
          }
          VStack(alignment: .leading, spacing: 11) {
            Text(block.original)
              .font(.system(size: 14)).lineSpacing(6)
              .foregroundStyle(ReadingPalette.muted)
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityLabel("原文：\(block.original)")
            if !block.translated.isEmpty {
              Text(block.translated)
                .font(.system(size: 17)).lineSpacing(9)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("译文：\(block.translated)")
            }
          }
        }
      }
      if state.phase == .translating {
        HStack(spacing: 8) {
          ProgressView().controlSize(.mini)
          Text("正在翻译…").font(.system(size: 12))
        }.foregroundStyle(ReadingPalette.muted).padding(.top, 16)
      }
      if let message = state.errorMessage {
        VStack(alignment: .leading, spacing: 12) {
          Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 13)).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 16) {
            if !state.original.isEmpty {
              Button("重试") { controller.retry() }
            }
            Button("打开设置") { settings() }
          }.buttonStyle(.borderless).font(.system(size: 12))
        }.padding(.top, reading.blocks.isEmpty ? 0 : 20)
      }
    }
  }
}

/// Native button actions remain accessible and legible in a non-activating panel.
private struct ReadingButton: NSViewRepresentable {
  let symbol: String
  let label: String
  let identifier: String
  var title = ""
  var enabled = true
  let action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(action: action) }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(
      title: title, target: context.coordinator, action: #selector(Coordinator.run))
    button.isBordered = false
    button.font = .systemFont(ofSize: 12)
    button.imagePosition = .imageLeading
    button.contentTintColor = .secondaryLabelColor
    button.setButtonType(.momentaryPushIn)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.action = action
    button.title = title
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
    button.identifier = NSUserInterfaceItemIdentifier(identifier)
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.isEnabled = enabled
  }

  @MainActor
  final class Coordinator: NSObject {
    var action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
  }
}
