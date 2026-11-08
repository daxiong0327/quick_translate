import Foundation

public enum SettingsError: LocalizedError, Equatable {
  case invalidURL, missingModel, missingKey, invalidValue
  case malformedFile(line: Int)
  case duplicateKey(String)
  case unreadableFile, unwritableFile
  case changedOnDisk, unsupportedFile

  public var errorDescription: String? {
    switch self {
    case .invalidURL: "请填写有效的 HTTPS 接口地址，不要包含用户名、密码、查询参数或片段。"
    case .missingModel: "请填写模型名称。"
    case .missingKey: "请填写 API Key。"
    case .invalidValue: "配置项不能包含换行或控制字符。"
    case .malformedFile(let line): "第 \(line) 行配置格式有误，请检查引号和转义。"
    case .duplicateKey(let key): "配置项 \(key) 重复，请在 .env 中只保留一项。"
    case .unreadableFile: "无法读取 .env，请检查文件权限后重新读取。"
    case .unwritableFile: "无法保存 .env，原配置未被替换。请检查目录权限。"
    case .changedOnDisk: ".env 已被外部修改，请先重新读取，再保存。"
    case .unsupportedFile: ".env 必须是本地普通 UTF-8 文本文件，大小不超过 64 KB。"
    }
  }
}

public struct SettingsDraft: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var baseURL: String
  public var model: String
  public var apiKey: String

  public init(baseURL: String = "", model: String = "", apiKey: String = "") {
    self.baseURL = baseURL
    self.model = model
    self.apiKey = apiKey
  }

  public var description: String { "SettingsDraft(credentials: <redacted>)" }
  public var debugDescription: String { description }

  public func validated() throws -> SettingsDraft {
    let result = SettingsDraft(
      baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      model: model.trimmingCharacters(in: .whitespacesAndNewlines),
      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    guard let url = URLComponents(string: result.baseURL), url.scheme == "https",
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil, url.url != nil,
      !result.baseURL.contains(where: { $0.isWhitespace }),
      url.port == nil || (1...65535).contains(url.port!)
    else { throw SettingsError.invalidURL }
    guard !result.model.isEmpty else { throw SettingsError.missingModel }
    guard !result.apiKey.isEmpty else { throw SettingsError.missingKey }
    for value in [result.baseURL, result.model, result.apiKey] {
      guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
      else { throw SettingsError.invalidValue }
    }
    return result
  }
}

public struct SettingsSnapshot: Sendable {
  public let draft: SettingsDraft
  public let revision: String
}

/// The file is parsed as data, never executed or expanded by a shell.
struct EnvironmentDocument {
  static let keys = ["OPENAI_BASE_URL", "OPENAI_MODEL", "DASHSCOPE_API_KEY"]
  var lines: [String]
  var positions: [String: Int] = [:]
  var values: [String: String] = [:]

  init(_ text: String) throws {
    lines = text.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
      var entry = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if entry.hasPrefix("export ") { entry = String(entry.dropFirst(7)) }
      guard !entry.hasPrefix("#"), let equal = entry.firstIndex(of: "=") else { continue }
      let key = String(entry[..<equal]).trimmingCharacters(in: .whitespaces)
      guard Self.keys.contains(key) else { continue }
      guard positions[key] == nil else { throw SettingsError.duplicateKey(key) }
      let raw = String(entry[entry.index(after: equal)...]).trimmingCharacters(
        in: .whitespacesAndNewlines)
      values[key] = try Self.decode(raw, line: index + 1)
      positions[key] = index
    }
  }

  var draft: SettingsDraft {
    SettingsDraft(
      baseURL: values[Self.keys[0]] ?? "", model: values[Self.keys[1]] ?? "",
      apiKey: values[Self.keys[2]] ?? "")
  }

  mutating func replacing(with draft: SettingsDraft) throws -> Data {
    for (key, value) in zip(Self.keys, [draft.baseURL, draft.model, draft.apiKey]) {
      let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
      let line = "\(key)=\(encoded)"
      if let index = positions[key] { lines[index] = line } else { lines.append(line) }
    }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }

  private static func decode(_ value: String, line: Int) throws -> String {
    guard let first = value.first else { return "" }
    if first == "\"" || first == "'" {
      var escaped = false
      var end: String.Index?
      for i in value.indices.dropFirst() {
        let c = value[i]
        if first == "\"", c == "\\", !escaped {
          escaped = true
          continue
        }
        if c == first, !escaped {
          end = i
          break
        }
        escaped = false
      }
      guard let end else { throw SettingsError.malformedFile(line: line) }
      let tail = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
      guard tail.isEmpty || tail.hasPrefix("#") else {
        throw SettingsError.malformedFile(line: line)
      }
      if first == "'" { return String(value[value.index(after: value.startIndex)..<end]) }
      guard let decoded = try? JSONDecoder().decode(String.self, from: Data(value[...end].utf8))
      else { throw SettingsError.malformedFile(line: line) }
      return decoded
    }
    let content =
      value.range(of: #"\s+#"#, options: .regularExpression).map { String(value[..<$0.lowerBound]) }
      ?? value
    return content.trimmingCharacters(in: .whitespaces)
  }
}
