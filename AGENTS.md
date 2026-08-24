# WorkFlow agent guide

WorkFlow is the public product name and `com.picturesuo.WorkFlow` is its bundle identifier. Keep the internal Xcode scheme and module `OpenSuperWhisper` for source continuity. Preserve the non-destructive preferences and Application Support migration from the legacy `com.picturesuo.Chat` and `com.picturesuo.GlowScribe` identities. Move a legacy Keychain credential only after writing it successfully under WorkFlow, then remove the stale legacy credential. macOS privacy grants cannot migrate and must be granted once to WorkFlow.

For installation and user handoff, follow `docs/AGENT_SETUP.md`. Never request, print, or place API keys in chat, terminal arguments, environment variables, source files, logs, or GitHub. Users enter provider keys only in WorkFlow's secure settings field.

Before shipping, run the focused tests in `docs/AGENT_SETUP.md`, then the full test command in `README.md`. Public app archives must pass `Scripts/package-release.sh`; do not distribute unnotarized substitutes.
