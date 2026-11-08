import Foundation

/// Development builds name their project file; distributed builds use the current user's file.
public struct EnvironmentLocation: Sendable {
  public let fileURL: URL
  public let createsParentDirectory: Bool

  public init(projectPath: String?, homeDirectory: URL) {
    if let projectPath, projectPath.hasPrefix("/") {
      fileURL = URL(fileURLWithPath: projectPath)
      createsParentDirectory = false
    } else {
      fileURL = homeDirectory.appendingPathComponent(".config/quick-translate/.env")
      createsParentDirectory = true
    }
  }
}
