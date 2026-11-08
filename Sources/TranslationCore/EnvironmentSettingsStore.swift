import CryptoKit
import Darwin
import Foundation

/// Owns a single, explicitly selected project file. No Keychain or system preference writes.
public actor EnvironmentSettingsStore {
  public nonisolated let fileURL: URL

  public init(fileURL: URL) { self.fileURL = fileURL }

  public func load() throws -> SettingsSnapshot {
    let data = try read()
    return SettingsSnapshot(draft: try document(data).draft, revision: revision(data))
  }

  public func save(_ draft: SettingsDraft, expectedRevision: String) throws -> SettingsSnapshot {
    let validated = try draft.validated()
    let original = try read()
    guard revision(original) == expectedRevision else { throw SettingsError.changedOnDisk }
    var doc = try document(original)
    let data = try doc.replacing(with: validated)
    guard data.count <= 65_536 else { throw SettingsError.unsupportedFile }
    let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(
      ".env.\(UUID().uuidString).tmp")
    let manager = FileManager.default
    guard
      manager.createFile(
        atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw SettingsError.unwritableFile }
    defer { try? manager.removeItem(at: temporary) }
    // Catch edits made while settings were open, and again immediately before replacement.
    guard revision(try read()) == expectedRevision else { throw SettingsError.changedOnDisk }
    guard rename(temporary.path, fileURL.path) == 0 else { throw SettingsError.unwritableFile }
    return SettingsSnapshot(draft: validated, revision: revision(data))
  }

  private func read() throws -> Data? {
    let manager = FileManager.default
    let attributes: [FileAttributeKey: Any]
    do { attributes = try manager.attributesOfItem(atPath: fileURL.path) } catch let error
      as NSError
      where error.domain == NSCocoaErrorDomain
      && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    {
      return nil
    } catch { throw SettingsError.unreadableFile }
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65_536
    else { throw SettingsError.unsupportedFile }
    do { return try Data(contentsOf: fileURL) } catch { throw SettingsError.unreadableFile }
  }

  private func document(_ data: Data?) throws -> EnvironmentDocument {
    guard let data else { return try EnvironmentDocument("") }
    guard let text = String(data: data, encoding: .utf8) else {
      throw SettingsError.unsupportedFile
    }
    return try EnvironmentDocument(text)
  }

  private func revision(_ data: Data?) -> String {
    data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "missing"
  }
}
