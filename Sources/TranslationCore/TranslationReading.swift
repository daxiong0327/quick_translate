import Foundation

/// A presentation snapshot. The session retains the verbatim text for selection and copying.
public struct TranslationReading: Sendable {
  public struct Block: Sendable, Equatable {
    public let original: String
    public let translated: String
  }

  public let blocks: [Block]
  public let isPaired: Bool

  public init(state: TranslationState) {
    if state.phase == .completed {
      let originals = Self.paragraphs(in: state.original)
      let translations = Self.paragraphs(in: state.translated)
      if originals.count > 1, originals.count == translations.count {
        isPaired = true
        blocks = zip(originals, translations).map { Block(original: $0, translated: $1) }
        return
      }
    }
    isPaired = false
    if !state.original.isEmpty || !state.translated.isEmpty {
      // Incomplete or reflowed output cannot reliably be paired. Never drop unmatched text.
      blocks = [Block(original: state.original, translated: state.translated)]
    } else {
      blocks = []
    }
  }

  private static func paragraphs(in text: String) -> [String] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var result: [String] = []
    var lines: [String] = []
    for line in normalized.components(separatedBy: "\n") {
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        if !lines.isEmpty {
          result.append(lines.joined(separator: "\n"))
          lines.removeAll(keepingCapacity: true)
        }
      } else {
        lines.append(line)
      }
    }
    if !lines.isEmpty { result.append(lines.joined(separator: "\n")) }
    return result
  }
}
