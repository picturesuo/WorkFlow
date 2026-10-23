# Security policy

## Reporting

Please do not open a public issue for a vulnerability that could expose credentials or private dictation. Instead, use GitHub's private vulnerability reporting for this repository.

Include the affected version, macOS version, reproduction steps, and impact. Do not include a real provider API key or private transcript.

## Credential boundary

WorkFlow stores Bedrock, Azure OpenAI, and OpenAI-compatible API keys in separate macOS Keychain items and never intentionally writes them to logs, preferences, recordings, exports, or the repository. A report that shows otherwise is high priority.

Diagnostic logs contain operational status only. They do not include transcript text, dropped-file paths, or provider response bodies.

After an identity upgrade, WorkFlow writes a legacy credential under its current Keychain service before removing the old item. Failed reads or writes leave the legacy item intact for a later retry and never print credential material.

Rotate the AWS key immediately if you believe it has been exposed. AWS recommends automatically refreshed short-term Bedrock API keys for production; they expire within 12 hours. If you use a long-term key for personal exploration, set an explicit expiration and grant only the model-invocation permissions WorkFlow needs.

Audio remains local. A remote cleanup provider receives transcript text only when cleanup is enabled and it is the selected provider. Plain HTTP is rejected for Azure OpenAI endpoints and for remote OpenAI-compatible endpoints; it is accepted only for loopback hosts used by local services such as Ollama or LM Studio. Provider failures and suspiciously expansive responses fall back to the local transcript. Drafting a custom filter with AI sends the request, the optional class or assignment, and the optional pasted example to the selected provider only after the user presses Send; WorkFlow stores only the resulting filter the user saves and the request's token counts, never the conversation or example. Learning from a finished document, pasted or read locally from a PDF, Word, RTF, OpenDocument, or text file, reads History locally and sends only short matched edits with a few words of context to the selected provider after the user selects Learn; the provider may only name preferences from a fixed list, and WorkFlow stores each validated preference as a fixed template with fingerprints of its supporting edits, never the document or the edit text. New dictations keep their recognizer transcript, cleanup input, emitted text, and paste outcome locally with their History item, and deleting the item deletes them.

WorkFlow is distributed directly rather than through the Mac App Store because global shortcuts and targeted paste require Accessibility and event-monitoring capabilities. Public binaries must be signed with Developer ID, use the hardened runtime, and be notarized. The app disables library validation only to load its bundled speech-runtime libraries; report any build that loads code from outside its signed bundle.
