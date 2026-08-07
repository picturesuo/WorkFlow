# Security policy

## Reporting

Please do not open a public issue for a vulnerability that could expose credentials or private dictation. Instead, use GitHub's private vulnerability reporting for this repository.

Include the affected version, macOS version, reproduction steps, and impact. Do not include a real Bedrock API key or private transcript.

## Credential boundary

GlowScribe stores the Bedrock bearer token in the macOS Keychain and never intentionally writes it to logs, preferences, recordings, or the repository. A report that shows otherwise is high priority.

Rotate the AWS key immediately if you believe it has been exposed. Prefer short-term Bedrock API keys and least-privilege AWS permissions.
