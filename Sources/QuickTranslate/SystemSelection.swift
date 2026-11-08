import AppKit
import ApplicationServices
import Carbon
import TranslationCore

@MainActor
final class HotKeyController {
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let identifier = EventHotKeyID(
    signature: 0x5154_524E, id: UInt32.random(in: 1...UInt32.max))
  private(set) var shortcut: Shortcut?
  private var pressed = false
  var onPress: (() -> Void)?

  init() {
    var types = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let context, let event else { return OSStatus(eventNotHandledErr) }
        return MainActor.assumeIsolated {
          let owner = Unmanaged<HotKeyController>.fromOpaque(context).takeUnretainedValue()
          var identifier = EventHotKeyID()
          guard
            GetEventParameter(
              event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
              nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
            identifier.signature == owner.identifier.signature,
            identifier.id == owner.identifier.id
          else { return OSStatus(eventNotHandledErr) }
          if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
            owner.pressed = false
          } else if !owner.pressed {
            owner.pressed = true
            owner.onPress?()
          }
          return noErr
        }
      }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }

  func register(_ choice: Shortcut) throws {
    if choice == shortcut, hotKey != nil { return }
    guard handler != nil else { throw RegistrationError() }
    let code: UInt32
    let modifiers: UInt32
    switch choice {
    case .optionD:
      code = UInt32(kVK_ANSI_D)
      modifiers = UInt32(optionKey)
    case .controlOptionT:
      code = UInt32(kVK_ANSI_T)
      modifiers = UInt32(controlKey | optionKey)
    case .commandShiftY:
      code = UInt32(kVK_ANSI_Y)
      modifiers = UInt32(cmdKey | shiftKey)
    case .controlOptionSpace:
      code = UInt32(kVK_Space)
      modifiers = UInt32(controlKey | optionKey)
    }
    var next: EventHotKeyRef?
    let result = RegisterEventHotKey(
      code, modifiers, identifier,
      GetApplicationEventTarget(), 0, &next)
    guard result == noErr, let next else { throw RegistrationError() }
    if let old = hotKey { UnregisterEventHotKey(old) }
    hotKey = next
    shortcut = choice
    pressed = false
  }

  func stop() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let handler { RemoveEventHandler(handler) }
    hotKey = nil
    handler = nil
    shortcut = nil
    onPress = nil
  }

  struct RegistrationError: LocalizedError {
    var errorDescription: String? { "快捷键无法注册，可能与其他应用冲突。请更换组合。" }
  }
}

@MainActor
struct SystemSelection {
  func capture(from application: NSRunningApplication?) async throws -> String {
    guard AXIsProcessTrusted() else { throw TranslationError.permissionRequired }
    guard let application,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { throw TranslationError.noSelection }
    let pid = application.processIdentifier
    if await hasKnownEmptySelection(in: pid) { throw TranslationError.noSelection }
    for _ in 0..<40 {
      try Task.checkCancellation()
      let flags = CGEventSource.flagsState(.combinedSessionState)
      if flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard
      CGEventSource.flagsState(.combinedSessionState).intersection([
        .maskCommand, .maskShift, .maskControl, .maskAlternate,
      ]).isEmpty
    else { throw TranslationError.releaseShortcut }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
      throw TranslationError.sourceChanged
    }
    let pasteboard = NSPasteboard.general
    let before = pasteboard.changeCount
    guard
      let down = CGEvent(
        keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
    else { throw TranslationError.noSelection }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    for _ in 0..<50 {
      try await Task.sleep(for: .milliseconds(20))
      try Task.checkCancellation()
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        throw TranslationError.sourceChanged
      }
      if pasteboard.changeCount != before {
        guard let text = pasteboard.string(forType: .string) else {
          throw TranslationError.noSelection
        }
        return try TextPolicy.validate(text)
      }
    }
    throw TranslationError.noSelection
  }

  private nonisolated func hasKnownEmptySelection(in pid: pid_t) async -> Bool {
    // Accessibility requests can wait on an unresponsive source app. Bound them off the UI actor.
    await Task.detached(priority: .userInitiated) {
      let application = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(application, 0.2)
      var focused: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
        let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
      else { return false }
      let element = unsafeDowncast(focused, to: AXUIElement.self)
      AXUIElementSetMessagingTimeout(element, 0.2)
      var selection: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selection)
          == .success, let selected = selection as? String
      else { return false }
      return selected.isEmpty
    }.value
  }
}
