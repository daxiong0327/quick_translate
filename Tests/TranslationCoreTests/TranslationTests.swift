import Foundation
import Testing

@testable import TranslationCore

private func event(_ text: String, finish: String? = nil) -> String {
  let reason: Any = finish.map { $0 as Any } ?? NSNull()
  let data = try! JSONSerialization.data(withJSONObject: [
    "choices": [["delta": ["content": text], "finish_reason": reason]]
  ])
  return "data: \(String(decoding: data, as: UTF8.self))\n\n"
}

private func decode(_ stream: String) throws -> String {
  var decoder = TranslationStreamDecoder()
  var result = ""
  for byte in stream.utf8 { if let delta = try decoder.feed(byte) { result += delta } }
  if let tail = try decoder.finish() { result += tail }
  try decoder.validateCompletion()
  return result
}

@Suite("Translation contracts and stream parsing")
struct TranslationTests {
  @Test func streamParsesUnicodeAcrossByteBoundariesAndFinishes() throws {
    #expect(
      try decode(
        ": heartbeat\n\n" + event("你好，") + event("世界 🌏", finish: "stop") + "data: [DONE]\n\n")
        == "你好，世界 🌏")
  }

  @Test func acceptsCRLFMultilineEventsAndUsageChunks() throws {
    let body =
      "data: {\r\ndata: \"choices\": [{\"delta\": {\"content\": \"译文\"}, \"finish_reason\": \"stop\"}]}\r\n\r\n"
    #expect(try decode(body + "data: {\"choices\": []}\n\ndata: [DONE]\n\n") == "译文")
  }

  @Test func acceptsNullableFieldsInAlibabaCompatibleChunks() throws {
    // Alibaba's documented stream includes null tool/function fields on ordinary text chunks.
    let first =
      "data: {\"choices\":[{\"delta\":{\"content\":\"译文\",\"tool_calls\":null,\"function_call\":null},\"finish_reason\":null}]}\n\n"
    let last =
      "data: {\"choices\":[{\"delta\":{\"content\":\"\",\"tool_calls\":null,\"function_call\":null},\"finish_reason\":\"stop\"}]}\n\n"
    #expect(try decode(first + last + "data: [DONE]\n\n") == "译文")
  }

  @Test func missingNewlineAtEndIsHandled() throws {
    #expect(try decode(event("完整", finish: "stop").trimmingCharacters(in: .newlines)) == "完整")
  }

  @Test func incompleteOrTruncatedResponsesAreNotSuccessful() {
    #expect(throws: TranslationError.incomplete) { try decode(event("部分")) }
    #expect(throws: TranslationError.incomplete) { try decode(event("部分") + "data: [DONE]\n\n") }
    #expect(throws: TranslationError.incomplete) { try decode(event("部分", finish: "length")) }
    #expect(throws: TranslationError.incomplete) {
      try decode(event("部分", finish: "content_filter"))
    }
  }

  @Test func emptyWhitespaceAndInvalidResponsesAreRejected() {
    #expect(throws: TranslationError.emptyResponse) { try decode(event("  \n", finish: "stop")) }
    #expect(throws: TranslationError.invalidResponse) { try decode("data: not-json\n\n") }
    #expect(throws: TranslationError.invalidResponse) {
      try decode("data: {\"error\":\"fixture\"}\n\n")
    }
    #expect(throws: TranslationError.invalidResponse) {
      try decode("data: {\"choices\":[{\"delta\":{\"tool_calls\":[]}}]}\n\n")
    }
    #expect(throws: TranslationError.invalidResponse) {
      try decode("data: {\"choices\":[{\"delta\":{\"content\":12}}]}\n\n")
    }
  }

  @Test func truncatedFinalFragmentIsDeliveredBeforeFailure() throws {
    for body in [event("最后一段", finish: "length"), event("最后一段").trimmingCharacters(in: .newlines)] {
      var decoder = TranslationStreamDecoder()
      var received = ""
      for byte in body.utf8 {
        if let delta = try decoder.feed(byte) { received += delta }
      }
      if let tail = try decoder.finish() { received += tail }
      #expect(received == "最后一段")
      #expect(throws: TranslationError.incomplete) { try decoder.validateCompletion() }
    }
  }

  @Test func streamLimitsPreventUnboundedBuffers() {
    #expect(throws: TranslationError.invalidResponse) {
      try decode("data: " + String(repeating: "a", count: 262_145))
    }
    #expect(throws: TranslationError.invalidResponse) {
      try decode(
        String(repeating: "data: " + String(repeating: "a", count: 1024) + "\n", count: 257))
    }
  }

  @Test func rejectsInvalidUTF8() {
    var decoder = TranslationStreamDecoder()
    #expect(throws: TranslationError.invalidResponse) {
      _ = try decoder.feed(0xff)
      _ = try decoder.feed(10)
    }
  }

  @Test func textBoundariesPreserveParagraphs() throws {
    #expect(try TextPolicy.validate("  paragraph\n\nnext  ") == "  paragraph\n\nnext  ")
    #expect(throws: TranslationError.noSelection) { try TextPolicy.validate(" \n ") }
    #expect(try TextPolicy.validate(String(repeating: "a", count: 12_000)).count == 12_000)
    #expect(throws: TranslationError.tooLong) {
      try TextPolicy.validate(String(repeating: "a", count: 12_001))
    }
  }

  @Test func requestHasOnlyCurrentTextAndCompatibleFields() throws {
    let config = SettingsDraft(
      baseURL: "https://fixture.invalid/v1/", model: "fixture-model", apiKey: "fixture")
    let request = try OpenAITranslationClient.request(text: "Translate this.", settings: config)
    #expect(request.url?.absoluteString == "https://fixture.invalid/v1/chat/completions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    let requestBody = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    #expect(body["stream"] as? Bool == true)
    #expect(body["model"] as? String == "fixture-model")
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(messages.count == 2)
    #expect(messages.last?["content"] == "Translate this.")
  }

  @Test func staleResultsCannotReplaceNewSessionOrReopenClosedSession() {
    var state = TranslationState()
    let a = state.begin()
    state.captured("A", for: a)
    state.append("甲", for: a)
    let b = state.begin()
    state.captured("A stale", for: a)
    state.fail("late error", for: a)
    state.captured("B", for: b)
    state.append("old", for: a)
    state.complete(for: a)
    #expect(state.original == "B")
    #expect(state.translated.isEmpty)
    #expect(state.errorMessage == nil)
    state.append("乙", for: b)
    state.close()
    state.append("late", for: b)
    state.complete(for: b)
    state.fail("late", for: b)
    #expect(state.phase == .hidden)
    #expect(state.original.isEmpty && state.translated.isEmpty)
  }

  @Test func partialTextSurvivesFailureAndTerminalStatesIgnoreMoreData() {
    var state = TranslationState()
    let id = state.begin()
    state.captured("Original", for: id)
    state.append("部分", for: id)
    state.fail("incomplete", for: id)
    state.append("ignored", for: id)
    state.complete(for: id)
    #expect(state.phase == .failed)
    #expect(state.translated == "部分")
    #expect(state.original == "Original")
    let next = state.begin()
    state.captured("next", for: next)
    state.append("成功", for: next)
    state.complete(for: next)
    state.fail("late", for: next)
    #expect(state.phase == .completed)
    #expect(state.errorMessage == nil)
  }

  @Test func shortcutRoundTripsAndInvalidValueIsRejected() throws {
    for shortcut in Shortcut.allCases {
      var document = try EnvironmentDocument("# initial\n")
      let original = SettingsDraft(
        baseURL: "https://fixture.invalid/v1", model: "fixture", apiKey: "fixture",
        shortcut: shortcut)
      let text = String(decoding: try document.replacing(with: original), as: UTF8.self)
      #expect(try EnvironmentDocument(text).draft == original)
    }
    #expect(throws: SettingsError.malformedFile(line: 1)) {
      try EnvironmentDocument("QT_SHORTCUT=unknown")
    }
    #expect(try EnvironmentDocument("").draft.shortcut == .optionD)
  }

  @Test func clientProcessesControlledHTTPStream() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let client = OpenAITranslationClient(session: session)
    var output = ""
    for try await delta in client.stream(
      text: "Hello",
      settings: SettingsDraft(
        baseURL: "https://fixture.invalid/success/v1", model: "fixture", apiKey: "fixture"))
    { output += delta }
    #expect(output == "你好")
  }

  @Test func clientMapsHTTPFailureAndKeepsPartialResponse() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let client = OpenAITranslationClient(session: session)
    for code in [400, 401, 403, 404, 429, 500] {
      await #expect(throws: TranslationError.http(code)) {
        for try await _ in client.stream(
          text: "Hello",
          settings: SettingsDraft(
            baseURL: "https://fixture.invalid/error\(code)/v1", model: "fixture", apiKey: "fixture")
        ) {}
      }
    }
    var partial = ""
    do {
      for try await text in client.stream(
        text: "Hello",
        settings: SettingsDraft(
          baseURL: "https://fixture.invalid/incomplete/v1", model: "fixture", apiKey: "fixture"))
      { partial += text }
      Issue.record("Missing terminal event must fail")
    } catch { #expect(error as? TranslationError == .incomplete) }
    #expect(partial == "部分")
  }

  @Test func clientMapsTransportFailuresAndPreservesFinalTruncatedDelta() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let client = OpenAITranslationClient(session: session)
    for (path, expected) in [
      ("timeout", TranslationError.timeout), ("network", .network), ("truncated", .incomplete),
    ] {
      var received = ""
      do {
        for try await delta in client.stream(
          text: "Hello",
          settings: SettingsDraft(
            baseURL: "https://fixture.invalid/\(path)/v1", model: "fixture", apiKey: "fixture"))
        {
          received += delta
        }
        Issue.record("Expected controlled failure")
      } catch { #expect(error as? TranslationError == expected) }
      if path == "truncated" { #expect(received == "最后一段") }
    }
  }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "fixture.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url else { return }
    if url.path.contains("timeout") || url.path.contains("network") {
      client?.urlProtocol(
        self,
        didFailWithError: URLError(
          url.path.contains("timeout") ? .timedOut : .notConnectedToInternet))
      return
    }
    let code = [400, 401, 403, 404, 429, 500].first { url.path.contains("error\($0)") } ?? 200
    let response = HTTPURLResponse(
      url: url, statusCode: code, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/event-stream"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let body =
      url.path.contains("incomplete")
      ? event("部分")
      : (url.path.contains("truncated")
        ? event("最后一段", finish: "length") : event("你好", finish: "stop") + "data: [DONE]\n\n")
    let data = Data(body.utf8)
    for offset in stride(from: 0, to: data.count, by: 3) {
      client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 3, data.count)))
    }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
