import AppKit
import SwiftUI
import TranslationCore

@MainActor
final class SettingsModel: ObservableObject {
  @Published var baseURL = ""
  @Published var model = ""
  @Published var apiKey = ""
  @Published var shortcut: Shortcut = .optionD
  @Published var activeShortcutDescription = "快捷键尚未启用"
  var onSaved: ((Shortcut) -> String?)?
  @Published var busy = false
  @Published var message = ""
  @Published var succeeded = false
  @Published private var savedDraft: SettingsDraft?
  private var revision: String?
  let store: EnvironmentSettingsStore

  init(store: EnvironmentSettingsStore) { self.store = store }

  private var draft: SettingsDraft {
    SettingsDraft(baseURL: baseURL, model: model, apiKey: apiKey, shortcut: shortcut)
  }

  var saveButtonTitle: String {
    succeeded && savedDraft == draft ? "已保存" : "保存配置"
  }

  func reload() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let snapshot = try await store.load()
      baseURL = snapshot.draft.baseURL
      model = snapshot.draft.model
      apiKey = snapshot.draft.apiKey
      shortcut = snapshot.draft.shortcut
      revision = snapshot.revision
      succeeded = true
      savedDraft = nil
      message = ""
    } catch {
      revision = nil
      report(error)
    }
  }

  func save() async {
    guard !busy else { return }
    guard let revision else {
      succeeded = false
      message = "无法读取配置，请关闭并重新打开设置后再保存。"
      return
    }
    busy = true
    defer { busy = false }
    do {
      let snapshot = try await store.save(draft, expectedRevision: revision)
      self.revision = snapshot.revision
      baseURL = snapshot.draft.baseURL
      model = snapshot.draft.model
      apiKey = snapshot.draft.apiKey
      succeeded = true
      savedDraft = snapshot.draft
      message = ""
      if let warning = onSaved?(shortcut) {
        succeeded = false
        message = warning
      }
    } catch { report(error) }
  }

  private func report(_ error: Error) {
    succeeded = false
    switch error as? SettingsError {
    case .changedOnDisk:
      message = "配置已在外部修改。请关闭并重新打开设置后，再进行编辑。"
    case .unreadableFile:
      message = "无法读取配置，请检查文件权限后关闭并重新打开设置。"
    default:
      message = (error as? SettingsError)?.errorDescription ?? "配置操作失败，请关闭并重新打开设置后再试。"
    }
  }
}

struct SettingsView: View {
  @ObservedObject var state: SettingsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(nsImage: BrandIcon.image(size: 48, style: .app))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("Quick Translate").font(.title2.weight(.semibold))
          Text("英文阅读，随选随译").foregroundStyle(.secondary)
        }
      }
      Form {
        TextField("接口地址", text: $state.baseURL, prompt: Text("https://…/compatible-mode/v1"))
          .accessibilityIdentifier("baseURL")
        TextField("模型名称", text: $state.model, prompt: Text("填写阿里云控制台中的模型名称"))
          .accessibilityIdentifier("model")
        SecureField("API Key", text: $state.apiKey, prompt: Text("保存在本项目 .env"))
          .accessibilityIdentifier("apiKey")
        Picker("翻译快捷键", selection: $state.shortcut) {
          ForEach(Shortcut.allCases, id: \.self) { choice in Text(choice.label).tag(choice) }
        }
      }.textFieldStyle(.roundedBorder).disabled(state.busy)
      Text(state.activeShortcutDescription).font(.caption).foregroundStyle(.secondary)
      Button("打开辅助功能权限设置…") {
        if let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
          NSWorkspace.shared.open(url)
        }
      }.buttonStyle(.link)
      if !state.succeeded, !state.message.isEmpty {
        Text(state.message).font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("settingsMessage")
      }
      HStack {
        Spacer()
        if state.busy { ProgressView().controlSize(.small) }
        Button(state.saveButtonTitle) { Task { await state.save() } }
          .keyboardShortcut(.defaultAction).accessibilityIdentifier("saveSettings")
      }.disabled(state.busy)
    }
    .padding(28).frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}
