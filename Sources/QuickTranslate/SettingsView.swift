import AppKit
import SwiftUI
import TranslationCore

@MainActor
final class SettingsModel: ObservableObject {
  @Published var baseURL = ""
  @Published var model = ""
  @Published var apiKey = ""
  @Published var busy = false
  @Published var message = ""
  @Published var succeeded = false
  private var revision: String?
  let store: EnvironmentSettingsStore

  init(store: EnvironmentSettingsStore) { self.store = store }

  func reload() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let snapshot = try await store.load()
      baseURL = snapshot.draft.baseURL
      model = snapshot.draft.model
      apiKey = snapshot.draft.apiKey
      revision = snapshot.revision
      succeeded = true
      message = "配置保存在项目 .env，仅在本机读取。"
    } catch {
      revision = nil
      report(error)
    }
  }

  func save() async {
    guard !busy else { return }
    guard let revision else {
      succeeded = false
      message = "请先成功读取配置，再保存。"
      return
    }
    busy = true
    defer { busy = false }
    do {
      let snapshot = try await store.save(
        SettingsDraft(baseURL: baseURL, model: model, apiKey: apiKey), expectedRevision: revision)
      self.revision = snapshot.revision
      baseURL = snapshot.draft.baseURL
      model = snapshot.draft.model
      apiKey = snapshot.draft.apiKey
      succeeded = true
      message = "已保存到 .env。接口是否可用将在实际翻译时验证。"
    } catch { report(error) }
  }

  private func report(_ error: Error) {
    succeeded = false
    message = (error as? SettingsError)?.errorDescription ?? "配置操作失败，请重新读取后再试。"
  }
}

struct SettingsView: View {
  @ObservedObject var state: SettingsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "character.bubble.fill").font(.system(size: 32)).foregroundStyle(.blue)
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
      }.textFieldStyle(.roundedBorder)
      Text("翻译时，选中的文字会发送到你配置的服务地址。复制选区会覆盖剪贴板。")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Divider()
      Text(state.store.fileURL.path).font(.caption).foregroundStyle(.secondary).textSelection(
        .enabled)
      Text(state.message).font(.callout).foregroundStyle(
        state.succeeded ? Color.secondary : Color.red
      )
      .frame(minHeight: 32, alignment: .leading).accessibilityIdentifier("settingsMessage")
      HStack {
        Button("重新读取") { Task { await state.reload() } }
        Spacer()
        if state.busy { ProgressView().controlSize(.small) }
        Button("保存配置") { Task { await state.save() } }
          .keyboardShortcut(.defaultAction).accessibilityIdentifier("saveSettings")
      }.disabled(state.busy)
    }
    .padding(28).frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
    .task { await state.reload() }
  }
}
