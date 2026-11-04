import Foundation

/// Turns a failed provider HTTP reply into a short explanation that is safe to
/// show in Settings, filter drafting, and Learn. Provider error text can quote
/// part of a key ("Incorrect API key provided: sk-…"), so key-shaped tokens are
/// removed, key errors drop the provider's text entirely, and the result is
/// capped. Request content is never part of it.
enum ProviderErrorText {
    static let maximumDetailLength = 160

    static func describe(statusCode: Int, providerMessage: String?) -> String {
        let summary: String
        var includesDetail = true
        switch statusCode {
        case 401:
            summary = "The API key was rejected. Enter a new key and Save & Test."
            includesDetail = false
        case 403:
            summary = "This key isn’t allowed to use this model or account."
            includesDetail = false
        case 404:
            summary = "The model or endpoint wasn’t found. Check the model name."
        case 408, 504:
            summary = "The provider timed out."
        case 413:
            summary = "The request was too large for this provider."
        case 429:
            summary = "Rate limit or quota reached. Try again later, or check your plan and billing."
        case 503, 529:
            summary = "The provider is overloaded right now. Try again shortly."
        case 500...599:
            summary = "The provider had a server error. Try again shortly."
        default:
            summary = HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalizedFirstLetter + "."
        }
        guard includesDetail, let detail = providerMessage.map(redacted), !detail.isEmpty else { return summary }
        return "\(summary) Provider said: \(detail)"
    }

    /// The first line of a provider message with key-shaped tokens removed,
    /// capped at `maximumDetailLength`.
    static func redacted(_ message: String) -> String {
        let firstLine = message
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        var text = firstLine
        for pattern in redactionPatterns {
            text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: [.regularExpression, .caseInsensitive])
        }
        if text.count > maximumDetailLength {
            text = String(text.prefix(maximumDetailLength - 1)) + "…"
        }
        return text
    }

    private static let redactionPatterns = [
        // OpenAI (sk-, sk-proj-, sk-svcacct-) and Anthropic (sk-ant-…) keys, masked or not.
        #"sk-[A-Za-z0-9_*\-.]{3,}"#,
        #"Bearer\s+\S+"#,
        // AWS access key IDs and Bedrock API keys.
        #"\b(AKIA|ASIA|ABSK)[A-Za-z0-9+/=]{8,}"#,
        // Any other long opaque token.
        #"[A-Za-z0-9_\-+/=*]{32,}"#
    ]
}

private extension String {
    var capitalizedFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}
