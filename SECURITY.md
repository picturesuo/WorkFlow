# Security policy

## Reporting

Please do not open a public issue for a vulnerability that could expose credentials or private dictation. Instead, use GitHub's private vulnerability reporting for this repository.

Include the affected version, macOS version, reproduction steps, and impact. Do not include a real Bedrock API key or private transcript.

## Credential boundary

Chat stores the Bedrock bearer token in the macOS Keychain and never intentionally writes it to logs, preferences, recordings, or the repository. A report that shows otherwise is high priority.

Rotate the AWS key immediately if you believe it has been exposed. AWS recommends automatically refreshed short-term Bedrock API keys for production; they expire within 12 hours. If you use a long-term key for personal exploration, set an explicit expiration and grant only the model-invocation permissions Chat needs.

Chat is distributed directly rather than through the Mac App Store because global shortcuts and targeted paste require Accessibility and event-monitoring capabilities. Public binaries must be signed with Developer ID, use the hardened runtime, and be notarized. The app disables library validation only to load its bundled speech-runtime libraries; report any build that loads code from outside its signed bundle.
