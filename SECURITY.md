# Security policy

## Reporting

Please do not open a public issue for a vulnerability that could expose credentials or private dictation. Instead, use GitHub's private vulnerability reporting for this repository.

Include the affected version, macOS version, reproduction steps, and impact. Do not include a real provider API key or private transcript.

## Credential boundary

WorkFlow stores Bedrock and OpenAI-compatible bearer tokens in separate macOS Keychain items and never intentionally writes them to logs, preferences, recordings, exports, or the repository. A report that shows otherwise is high priority.

After an identity upgrade, WorkFlow writes a legacy credential under its current Keychain service before removing the old item. Failed reads or writes leave the legacy item intact for a later retry and never print credential material.

Rotate the AWS key immediately if you believe it has been exposed. AWS recommends automatically refreshed short-term Bedrock API keys for production; they expire within 12 hours. If you use a long-term key for personal exploration, set an explicit expiration and grant only the model-invocation permissions WorkFlow needs.

Audio remains local. A remote cleanup provider receives transcript text only when cleanup is enabled and it is the selected provider. Plain HTTP is rejected for remote OpenAI-compatible endpoints; it is accepted only for loopback hosts used by local services such as Ollama or LM Studio. Provider failures and suspiciously expansive responses fall back to the local transcript.

WorkFlow is distributed directly rather than through the Mac App Store because global shortcuts and targeted paste require Accessibility and event-monitoring capabilities. Public binaries must be signed with Developer ID, use the hardened runtime, and be notarized. The app disables library validation only to load its bundled speech-runtime libraries; report any build that loads code from outside its signed bundle.
