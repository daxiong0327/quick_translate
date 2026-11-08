import Foundation
import Testing

@testable import TranslationCore

@Suite("Portable environment configuration")
struct EnvironmentLocationTests {
  @Test func installedAppUsesCurrentUserInsteadOfProjectOrWorkingDirectory() {
    for home in ["/Users/first", "/Users/another user"] {
      for projectPath in [nil, "", "relative/.env"] as [String?] {
        let location = EnvironmentLocation(
          projectPath: projectPath, homeDirectory: URL(fileURLWithPath: home))
        #expect(location.fileURL.path == home + "/.config/quick-translate/.env")
        #expect(location.createsParentDirectory)
      }
    }
    let development = EnvironmentLocation(
      projectPath: "/workspace/project/.env", homeDirectory: URL(fileURLWithPath: "/Users/first"))
    #expect(development.fileURL.path == "/workspace/project/.env")
    #expect(!development.createsParentDirectory)
  }

  @Test func firstSaveCreatesPrivateDirectoryAndSurvivesRestartWithoutChangingSiblingFiles()
    async throws
  {
    let manager = FileManager.default
    let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: home) }
    let config = home.appendingPathComponent(".config")
    try manager.createDirectory(
      at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let sibling = config.appendingPathComponent("other-tool")
    try Data("keep".utf8).write(to: sibling)
    let location = EnvironmentLocation(projectPath: nil, homeDirectory: home)
    let store = EnvironmentSettingsStore(
      fileURL: location.fileURL, createsParentDirectory: location.createsParentDirectory)
    let initial = try await store.load()
    #expect(initial.draft == SettingsDraft())
    #expect(!manager.fileExists(atPath: location.fileURL.deletingLastPathComponent().path))
    await #expect(throws: SettingsError.invalidURL) {
      try await store.save(SettingsDraft(), expectedRevision: initial.revision)
    }
    #expect(!manager.fileExists(atPath: location.fileURL.deletingLastPathComponent().path))
    let draft = SettingsDraft(
      baseURL: "https://example.com/v1", model: "fixture-model", apiKey: "fixture-key-only")
    _ = try await store.save(draft, expectedRevision: initial.revision)
    let reloaded = try await EnvironmentSettingsStore(fileURL: location.fileURL).load()
    #expect(reloaded.draft == draft)
    let fileMode =
      try manager.attributesOfItem(atPath: location.fileURL.path)[.posixPermissions] as? NSNumber
    let folderMode =
      try manager.attributesOfItem(atPath: location.fileURL.deletingLastPathComponent().path)[
        .posixPermissions] as? NSNumber
    #expect(fileMode?.intValue == 0o600)
    #expect(folderMode?.intValue == 0o700)
    #expect(
      try manager.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber == 0o755)
    #expect(try Data(contentsOf: sibling) == Data("keep".utf8))
  }

  @Test func rejectsLinkedConfigurationDirectoryWithoutWritingItsTarget() async throws {
    let manager = FileManager.default
    let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: home) }
    let target = home.appendingPathComponent("target")
    let parent = home.appendingPathComponent(".config")
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    try manager.createSymbolicLink(
      at: parent.appendingPathComponent("quick-translate"), withDestinationURL: target)
    let location = EnvironmentLocation(projectPath: nil, homeDirectory: home)
    let store = EnvironmentSettingsStore(fileURL: location.fileURL, createsParentDirectory: true)
    let initial = try await store.load()
    let draft = SettingsDraft(
      baseURL: "https://example.com/v1", model: "fixture", apiKey: "fixture")
    await #expect(throws: SettingsError.unwritableFile) {
      try await store.save(draft, expectedRevision: initial.revision)
    }
    #expect(try manager.contentsOfDirectory(atPath: target.path).isEmpty)
  }
}
