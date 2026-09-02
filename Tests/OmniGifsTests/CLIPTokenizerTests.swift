import Testing

@testable import OmniGifs

struct CLIPTokenizerTests {
    private let startToken: Int32 = 49_406
    private let endToken: Int32 = 49_407

    @Test func resourcesMatchReferenceCLIPDimensions() throws {
        let tokenizer = try CLIPTokenizer()

        #expect(tokenizer.mergeRuleCount == 48_894)
        #expect(tokenizer.tokenCount == 49_408)
    }

    @Test func exactTokenIDsMatchOpenCLIPReference() throws {
        let tokenizer = try CLIPTokenizer()

        try assertEncoding("lorem", body: [12_880, 332], using: tokenizer)
        try assertEncoding("lorem ipsum", body: [12_880, 332, 1_719, 8_257], using: tokenizer)
        try assertEncoding(
            "Lorem ipsum dolor!",
            body: [12_880, 332, 1_719, 8_257, 2_287, 541, 256],
            using: tokenizer
        )
        try assertEncoding(
            "  lorem\tipsum\ndolor  ",
            body: [12_880, 332, 1_719, 8_257, 2_287, 541],
            using: tokenizer
        )
        try assertEncoding(
            "CAFÉ naïve 日本語 🤯",
            body: [15_304, 1_097, 35_689, 563, 39_121, 44_353, 34_002, 508, 37_595],
            using: tokenizer
        )
        try assertEncoding(
            "Lorem ipsum, dolor",
            body: [12_880, 332, 1_719, 8_257, 267, 2_287, 541],
            using: tokenizer
        )
    }

    @Test func canonicalUnicodeFormsProduceIdenticalTokens() throws {
        let tokenizer = try CLIPTokenizer()

        let composed = try tokenizer.encode("é")
        let decomposed = try tokenizer.encode("e\u{301}")

        #expect(composed == decomposed)
        #expect(Array(composed.prefix(3)) == [startToken, 4_166, endToken])
    }

    @Test func specialTokensUseTheirReservedIDs() throws {
        let tokenizer = try CLIPTokenizer()

        try assertEncoding("<|startoftext|>", body: [startToken], using: tokenizer)
        try assertEncoding("<|endoftext|>", body: [endToken], using: tokenizer)
    }

    @Test func tokenizerRejectsWrongMergeCount() {
        do {
            _ = try CLIPTokenizer(mergesText: "#version: 0.2\ni n\n")
            Issue.record("Tokenizer accepted an incomplete merge table")
        } catch CLIPTokenizer.TokenizerError.malformedResources {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func tokenizerTruncatesLongInputAndPreservesEndToken() throws {
        let tokens = try CLIPTokenizer().encode(
            Array(repeating: "lorem", count: 200).joined(separator: " ")
        )

        #expect(tokens.count == 77)
        #expect(tokens.first == startToken)
        #expect(tokens.last == endToken)
        #expect(!tokens.contains(0))
    }

    private func assertEncoding(
        _ text: String,
        body: [Int32],
        using tokenizer: CLIPTokenizer
    ) throws {
        let actual = try tokenizer.encode(text)
        var expected = [startToken] + body + [endToken]
        expected.append(contentsOf: repeatElement(0, count: 77 - expected.count))
        #expect(actual == expected, "Token mismatch for \(text)")
    }
}
