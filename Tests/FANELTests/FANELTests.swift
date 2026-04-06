import XCTest
@testable import FANEL

final class LooseJSONParserTests: XCTestCase {

    func testMarkerExtraction() {
        let input = """
        some text
        [FANEL_RESPONSE_BEGIN]
        {"status":"complete","message":"ok","files_modified":[],"next_action":null,"requires_approval":false}
        [FANEL_RESPONSE_END]
        trailing text
        """
        let result = LooseJSONParser.parse(input)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .complete)
        XCTAssertEqual(result?.message, "ok")
    }

    func testBraceScanExtraction() {
        let input = """
        Here is the response:
        {"status":"complete","message":"hello","files_modified":[],"next_action":null,"requires_approval":false}
        """
        let result = LooseJSONParser.parse(input)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.message, "hello")
    }

    func testInvalidInputReturnsNil() {
        XCTAssertNil(LooseJSONParser.parse("no json here"))
        XCTAssertNil(LooseJSONParser.parse(""))
        XCTAssertNil(LooseJSONParser.parse("{broken"))
    }

    func testExtractFirstJSON() {
        let input = "prefix {\"a\":1} suffix {\"b\":2}"
        let result = LooseJSONParser.extractFirstJSON(input)
        XCTAssertEqual(result, "{\"a\":1}")
    }

    func testNestedJSON() {
        let input = "{\"outer\":{\"inner\":true}}"
        let result = LooseJSONParser.extractFirstJSON(input)
        XCTAssertEqual(result, input)
    }
}

final class EmbeddingEngineTests: XCTestCase {

    func testEmbedReturnsVector() async {
        let vec = await EmbeddingEngine.shared.embed(text: "hello world")
        XCTAssertEqual(vec.count, 128)
        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.01)
    }

    func testCosineSimilaritySameText() async {
        let a = await EmbeddingEngine.shared.embed(text: "テスト")
        let b = await EmbeddingEngine.shared.embed(text: "テスト")
        let sim = await EmbeddingEngine.shared.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 1.0, accuracy: 0.01)
    }

    func testCosineSimilarityDifferentText() async {
        let a = await EmbeddingEngine.shared.embed(text: "Swift programming")
        let b = await EmbeddingEngine.shared.embed(text: "料理のレシピ")
        let sim = await EmbeddingEngine.shared.cosineSimilarity(a, b)
        XCTAssertLessThan(sim, 0.5)
    }

    func testEmptyVectors() async {
        let sim = await EmbeddingEngine.shared.cosineSimilarity([], [])
        XCTAssertEqual(sim, 0)
    }
}
