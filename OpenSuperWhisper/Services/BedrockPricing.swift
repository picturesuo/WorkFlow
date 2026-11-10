import Foundation

struct BedrockPricing {
    static let asOfDate = "August 21, 2026"
    static let pricingURL = URL(string: "https://aws.amazon.com/bedrock/pricing/")!

    // AWS Price List API, US on-demand pricing. The Converse API reports tokens,
    // so the estimate can be calculated without inspecting transcript contents.
    static let novaMicroInputUSDPerMillionTokens = 0.035
    static let novaMicroOutputUSDPerMillionTokens = 0.14

    static func supports(modelID: String) -> Bool {
        let normalizedModelID = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalizedModelID == "amazon.nova-micro-v1:0"
            || normalizedModelID == "us.amazon.nova-micro-v1:0"
    }

    static func estimateUSD(
        modelID: String,
        inputTokens: Int?,
        outputTokens: Int?
    ) -> Double? {
        guard supports(modelID: modelID),
              let inputTokens,
              let outputTokens,
              inputTokens >= 0,
              outputTokens >= 0 else {
            return nil
        }

        return (Double(inputTokens) * novaMicroInputUSDPerMillionTokens
            + Double(outputTokens) * novaMicroOutputUSDPerMillionTokens) / 1_000_000
    }

    static func formatUSD(_ amount: Double) -> String {
        let format: String
        switch amount {
        case 0:
            format = "$%.2f"
        case ..<0.0001:
            format = "$%.6f"
        case ..<0.01:
            format = "$%.4f"
        default:
            format = "$%.2f"
        }
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), amount)
    }
}
