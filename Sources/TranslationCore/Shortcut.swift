public enum Shortcut: String, CaseIterable, Sendable {
  case optionD = "option-d"
  case controlOptionT = "control-option-t"
  case commandShiftY = "command-shift-y"
  case controlOptionSpace = "control-option-space"

  public var label: String {
    switch self {
    case .optionD: "⌥D"
    case .controlOptionT: "⌃⌥T"
    case .commandShiftY: "⌘⇧Y"
    case .controlOptionSpace: "⌃⌥空格"
    }
  }
}
