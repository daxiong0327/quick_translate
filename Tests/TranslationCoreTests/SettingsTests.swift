import Foundation
import Testing

@testable import TranslationCore

private struct TestDirectory {
  let url: URL
  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "quick-translate-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
  func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite("Project environment settings")
struct SettingsTests {
  private var valid: SettingsDraft {
    SettingsDraft(
      baseURL: "https://example.com/compatible-mode/v1", model: "test-model",
      apiKey: "fixture-only-not-a-real-key")
  }

  @Test func rejectsUnsafeOrIncompleteConfiguration() throws {
    for url in [
      "http://example.com/v1", "https:///", "https://user:pass@example.com",
      "https://example.com?key=secret", "https://example.com/#fragment", "https://exa mple.com",
    ] {
      var draft = valid
      draft.baseURL = url
      #expect(throws: SettingsError.invalidURL) { try draft.validated() }
    }
    var draft = valid
    draft.model = " "
    #expect(throws: SettingsError.missingModel) { try draft.validated() }
    draft = valid
    draft.apiKey = ""
    #expect(throws: SettingsError.missingKey) { try draft.validated() }
    draft.apiKey = "first\nsecond"
    #expect(throws: SettingsError.invalidValue) { try draft.validated() }
    draft = valid
    draft.apiKey = "  fixture  "
    #expect(try draft.validated().apiKey == "fixture")
  }

  @Test func descriptionsRedactCredentials() {
    #expect(!String(describing: valid).contains(valid.apiKey))
    #expect(!String(reflecting: valid).contains(valid.apiKey))
  }

  @Test func parsesQuotesCommentsExportAndLiteralShellText() throws {
    let document = try EnvironmentDocument(
      """
      # configuration
      export OPENAI_BASE_URL='https://example.com/v1' # comment
      OPENAI_MODEL=model-name # comment
      DASHSCOPE_API_KEY="literal$HOME$(never-execute)`never`#suffix"
      OTHER=unchanged
      """)
    #expect(document.draft.baseURL == "https://example.com/v1")
    #expect(document.draft.model == "model-name")
    #expect(document.draft.apiKey == "literal$HOME$(never-execute)`never`#suffix")
    let decoded = try EnvironmentDocument(#"DASHSCOPE_API_KEY="quoted\"key\\suffix""#)
    #expect(decoded.draft.apiKey == "quoted\"key\\suffix")
  }

  @Test func rejectsMalformedOrDuplicateValuesWithoutLeakingSecrets() {
    for line in [
      "DASHSCOPE_API_KEY=\"secret\"unexpected", "DASHSCOPE_API_KEY=\"secret",
      "DASHSCOPE_API_KEY=\"secret\\q\"",
    ] {
      do {
        _ = try EnvironmentDocument(line)
        Issue.record("Malformed file was accepted")
      } catch { #expect(!error.localizedDescription.contains("secret")) }
    }
    #expect(throws: SettingsError.duplicateKey("OPENAI_MODEL")) {
      try EnvironmentDocument("OPENAI_MODEL=first\nOPENAI_MODEL=second")
    }
  }

  @Test func saveReloadPreservesOtherEntriesAndRestrictsPermissions() async throws {
    let dir = try TestDirectory()
    defer { dir.remove() }
    let file = dir.url.appendingPathComponent(".env")
    try Data("# keep this comment\nUNRELATED=leave-me\n".utf8).write(to: file)
    let store = EnvironmentSettingsStore(fileURL: file)
    let before = try await store.load()
    let saved = try await store.save(valid, expectedRevision: before.revision)
    let loaded = try await EnvironmentSettingsStore(fileURL: file).load()
    #expect(loaded.draft == valid)
    #expect(saved.revision == loaded.revision)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("# keep this comment\nUNRELATED=leave-me"))
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path) == [".env"])
  }

  @Test func missingFileCanBeCreatedAndLoaded() async throws {
    let dir = try TestDirectory()
    defer { dir.remove() }
    let store = EnvironmentSettingsStore(fileURL: dir.url.appendingPathComponent(".env"))
    let empty = try await store.load()
    #expect(empty.draft == SettingsDraft())
    _ = try await store.save(valid, expectedRevision: empty.revision)
    let loaded = try await store.load()
    #expect(loaded.draft == valid)
  }

  @Test func externalModificationIsNotOverwritten() async throws {
    let dir = try TestDirectory()
    defer { dir.remove() }
    let file = dir.url.appendingPathComponent(".env")
    let store = EnvironmentSettingsStore(fileURL: file)
    let before = try await store.load()
    let external = Data("# manually changed\nOPENAI_MODEL=external".utf8)
    try external.write(to: file)
    await #expect(throws: SettingsError.changedOnDisk) {
      try await store.save(valid, expectedRevision: before.revision)
    }
    #expect(try Data(contentsOf: file) == external)
  }

  @Test func invalidSavePreservesExistingFile() async throws {
    let dir = try TestDirectory()
    defer { dir.remove() }
    let file = dir.url.appendingPathComponent(".env")
    let store = EnvironmentSettingsStore(fileURL: file)
    let empty = try await store.load()
    let saved = try await store.save(valid, expectedRevision: empty.revision)
    let bytes = try Data(contentsOf: file)
    await #expect(throws: SettingsError.invalidURL) {
      try await store.save(SettingsDraft(), expectedRevision: saved.revision)
    }
    #expect(try Data(contentsOf: file) == bytes)
  }

  @Test func rejectsSymlinksDirectoriesLargeAndInvalidUTF8Files() async throws {
    let dir = try TestDirectory()
    defer { dir.remove() }
    let target = dir.url.appendingPathComponent("target")
    try Data("private".utf8).write(to: target)
    let link = dir.url.appendingPathComponent(".env")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    for file in [link, dir.url] {
      await #expect(throws: SettingsError.unsupportedFile) {
        try await EnvironmentSettingsStore(fileURL: file).load()
      }
    }
    for data in [Data(repeating: 65, count: 65_537), Data([0xff, 0xfe])] {
      try data.write(to: target)
      await #expect(throws: SettingsError.unsupportedFile) {
        try await EnvironmentSettingsStore(fileURL: target).load()
      }
    }
  }

  @Test func missingParentReportsSaveFailure() async throws {
    let dir = try TestDirectory()
    defer { dir.remove() }
    let file = dir.url.appendingPathComponent("absent/.env")
    let store = EnvironmentSettingsStore(fileURL: file)
    let before = try await store.load()
    await #expect(throws: SettingsError.unwritableFile) {
      try await store.save(valid, expectedRevision: before.revision)
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }
}
