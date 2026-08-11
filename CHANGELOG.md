# Changelog

## Unreleased

- Rename the app to Chat with a new icon and bundle identity, including a bounded migration from the previous GlowScribe install.
- Add optional Amazon Bedrock transcript cleanup using Nova Micro and the Converse API.
- Store Bedrock API keys in the macOS Keychain with an in-app connection test.
- Add a bounded raw-transcript fallback and reject assistant-style model output.
- Add latest-generation gating so stale async dictations cannot paste over a newer one.
- Keep the upstream conditional clipboard-restore timing fix for slow target apps.
- Default to Parakeet v3, hold-to-record `Fn`, auto-paste, hidden menu-bar launch, and Launch at Login.
