# Contributing

WorkFlow is my personal project, published so you can fork it and shape it around your own writing. That decides what fits here.

## Forks for features

New features usually belong in your fork. The README's [Make it yours](README.md#make-it-yours) section points to the settings and code worth changing first.

## Bug reports

Open an issue with what you did, what you expected, what happened, your macOS version, and the commit you built. Name the cleanup provider and model if cleanup was involved. Never include an API key, account ID, or private transcript; redact them and say that you did.

## Bug-fix pull requests

- Keep each one small and about one bug.
- Run the headless test command in the README's Development section and make sure it passes. If you skipped an interactive suite, say which one.
- Add or update a test that fails without your fix.
- Say how you tested it, including whether you tried real microphone, paste, shortcut, or provider behavior by hand, since the automated suite doesn't cover them.
- Don't commit build output, downloaded models, keys, or personal History.

You can use AI coding tools. You, the person opening the pull request, are accountable for it: understand the change and make sure it passes the checks above.

## Security

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## License

By contributing, you agree that your contribution is licensed under the MIT license in [LICENSE](LICENSE). Keep the existing copyright and [NOTICE](NOTICE) attribution intact.
