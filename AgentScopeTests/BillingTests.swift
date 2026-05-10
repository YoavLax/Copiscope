import XCTest
@testable import AgentScope

final class BillingTests: XCTestCase {

    func testModelVendorDetection() {
        XCTAssertEqual(ModelVendor.from(model: "claude-opus-4.6"), .anthropic)
        XCTAssertEqual(ModelVendor.from(model: "claude-haiku-4.5"), .anthropic)
        XCTAssertEqual(ModelVendor.from(model: "claude-sonnet-4.6"), .anthropic)
        XCTAssertEqual(ModelVendor.from(model: "gpt-4o"), .openai)
        XCTAssertEqual(ModelVendor.from(model: "gpt-4o-mini-2024-07-18"), .openai)
        XCTAssertEqual(ModelVendor.from(model: "gemini-2.5-pro"), .google)
        XCTAssertEqual(ModelVendor.from(model: nil), .openai)
    }

    func testCostEstimation() {
        // Claude Opus: 15/MTok input, 75/MTok output
        let cost = estimateCostFromTokens(
            model: "claude-opus-4.6",
            inputTokens: 1_000_000,
            outputTokens: 100_000,
            cachedTokens: 0
        )
        // 1M input tokens * $15/MTok + 100K output tokens * $75/MTok
        let expected = 15.0 + 7.5
        XCTAssertEqual(cost, expected, accuracy: 0.01)
    }

    func testCostEstimationWithCache() {
        // 1M input tokens, 500K cached
        let cost = estimateCostFromTokens(
            model: "claude-opus-4.6",
            inputTokens: 1_000_000,
            outputTokens: 100_000,
            cachedTokens: 500_000
        )
        // Uncached: 500K * $15/MTok = $7.50
        // Cached: 500K * $1.50/MTok = $0.75
        // Output: 100K * $75/MTok = $7.50
        let expected = 7.5 + 0.75 + 7.5
        XCTAssertEqual(cost, expected, accuracy: 0.01)
    }

    func testGpt4oMiniCost() {
        let cost = estimateCostFromTokens(
            model: "gpt-4o-mini-2024-07-18",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cachedTokens: 0
        )
        // $0.15/MTok input + $0.60/MTok output
        let expected = 0.15 + 0.60
        XCTAssertEqual(cost, expected, accuracy: 0.01)
    }

    func testUnknownModelZeroCost() {
        let cost = estimateCostFromTokens(
            model: "unknown-model",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cachedTokens: 0
        )
        XCTAssertEqual(cost, 0.0, accuracy: 0.001)
    }

    func testModelCatalogLoading() {
        let json = """
        [{"id":"claude-opus-4.6","name":"Claude Opus","vendor":"anthropic","billing":{"is_premium":true,"multiplier":1.25},"model_picker_category":"powerful"}]
        """
        let catalog = loadModelCatalog(from: json.data(using: .utf8)!)
        let billing = catalog.billing(for: "claude-opus-4.6")
        XCTAssertEqual(billing.id, "claude-opus-4.6")
        XCTAssertEqual(billing.multiplier, 1.25)
        XCTAssertEqual(billing.isPremium, true)
        XCTAssertEqual(billing.category, "powerful")
    }
}
