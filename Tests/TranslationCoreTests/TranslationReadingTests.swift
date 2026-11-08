import Testing

@testable import TranslationCore

@Suite("Reading preserves text and paragraph correspondence")
struct TranslationReadingTests {
  private func state(_ original: String, _ translated: String, completed: Bool = true)
    -> TranslationState
  {
    var state = TranslationState()
    let id = state.begin()
    state.captured(original, for: id)
    state.append(translated, for: id)
    if completed { state.complete(for: id) }
    return state
  }

  @Test func pairsCompletedParagraphsAndKeepsInternalLineBreaks() {
    let source = "First line\nsecond line\n\nNext paragraph"
    let result = TranslationReading(state: state(source, "第一行\n第二行\n\n下一段"))
    #expect(result.isPaired)
    #expect(result.blocks.count == 2)
    #expect(result.blocks[0].original == "First line\nsecond line")
    #expect(result.blocks[0].translated == "第一行\n第二行")
    #expect(result.blocks[1].original == "Next paragraph")
    #expect(result.blocks[1].translated == "下一段")
  }

  @Test func acceptsCRLFAndWhitespaceSeparatorsWithoutCreatingEmptyPairs() {
    let result = TranslationReading(
      state: state("\r\n  First\r\n \t\r\n\r\nSecond\r\n", "第一段\n\t\n第二段\n"))
    #expect(result.isPaired)
    #expect(result.blocks.count == 2)
    #expect(result.blocks[0].original == "  First")
    #expect(result.blocks[1].original == "Second")
  }

  @Test func streamingAndFailureDoNotGuessCorrespondenceEvenWhenCountsTemporarilyMatch() {
    var current = state("First\n\nSecond", "第一段\n\n第二段未完", completed: false)
    for failed in [false, true] {
      if failed { current.fail("fixture failure", for: current.id) }
      let result = TranslationReading(state: current)
      #expect(!result.isPaired)
      #expect(result.blocks.count == 1)
      #expect(result.blocks[0].original == current.original)
      #expect(result.blocks[0].translated == current.translated)
    }
  }

  @Test func mergedOrExtraParagraphsRemainVerbatimWithoutTruncation() {
    for translation in ["合并的译文", "一\n\n二\n\n额外的一段", ""] {
      let current = state("First\n\nSecond", translation)
      let result = TranslationReading(state: current)
      #expect(!result.isPaired)
      #expect(result.blocks.count == 1)
      #expect(result.blocks[0].original == current.original)
      #expect(result.blocks[0].translated == translation)
    }
  }

  @Test func singleParagraphAndClosedSessionKeepTheirMeaning() {
    var current = state("  A single line.  ", "  单句。  ")
    let result = TranslationReading(state: current)
    #expect(!result.isPaired)
    #expect(result.blocks[0].original == current.original)
    #expect(result.blocks[0].translated == current.translated)
    current.close()
    #expect(TranslationReading(state: current).blocks.isEmpty)
  }
}
