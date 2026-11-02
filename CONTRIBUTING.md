# Contributing

Thanks for helping to improve CineFlix. Bug reports, ideas, documentation fixes and code are all welcome.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## What this project is, and is not

CineFlix is a client for a media server that **you** run, with content **you** have the rights to. Contributions that locate, scrape,
index or link to unlicensed content, that bypass access controls or DRM, or that add advertising or tracking will not be accepted.

## Before you start

- Search [existing issues](https://github.com/mustafazeya/cineflix-ios/issues) first.
- For anything bigger than a small fix, open an issue to discuss it before writing code. This avoids wasted work.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Reporting a bug

Use the bug report form and include your iPhone model and iOS version, how you installed the app, the steps to reproduce, and what you expected.
Never paste API keys or tokens. Remove them from screenshots and logs.

## Development setup

See [docs/build-and-install.md](docs/build-and-install.md) for the toolchain, secrets and signing, and [docs/testing.md](docs/testing.md) for the UI tests.
In short: install Xcode 27 and XcodeGen, copy the two example `.xcconfig` files in `Config/`, run `xcodegen generate`, and open the project.

## Pull requests

1. Fork the repository and create a branch from `main`, named for the change, for example `fix-back-warning` or `docs-auto-install`.
2. Keep the change focused. Do not mix refactors with fixes.
3. Make sure the app builds and the UI tests for the screens you touched pass ([docs/testing.md](docs/testing.md)). Try it on a real iPhone when you can.
4. Update the docs and [CHANGELOG.md](CHANGELOG.md) when behaviour changes.
5. Open a pull request and fill in the template. Say how you tested it and on which device or simulator.

### Commit messages

Write short, imperative subjects such as `Fix resume position for page players`, and add a body when the reason is not obvious.
One logical change per commit.

### Code and design standards

- Swift 6 and SwiftUI, no third-party packages without a discussion first.
- Support Dynamic Type, VoiceOver labels and both orientations where they apply.
- Follow the design rules in [docs/architecture.md](docs/architecture.md#design-rules): neutral palette, system fonts and SF Symbols, no emoji.
- Never commit secrets or signing details. `Config/Secrets.xcconfig` and `Config/Signing.xcconfig` must stay out of version control.

## Licensing of contributions

By contributing you agree that your work is licensed under the [MIT License](LICENSE) of this project.
