# WorkFlow agent guide

WorkFlow is the public product name. Keep the internal Xcode scheme and module `OpenSuperWhisper`, and keep bundle identifier `com.picturesuo.Chat` until a documented migration can preserve macOS privacy grants, preferences, History, and Keychain access.

For installation and user handoff, follow `docs/AGENT_SETUP.md`. Never request, print, or place API keys in chat, terminal arguments, environment variables, source files, logs, or GitHub. Users enter provider keys only in WorkFlow's secure settings field.

Before shipping, run the focused tests in `docs/AGENT_SETUP.md`, then the full test command in `README.md`. Public app archives must pass `Scripts/package-release.sh`; do not distribute unnotarized substitutes.
