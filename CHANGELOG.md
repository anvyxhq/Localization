# Changelog

All notable changes to this package are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- **Breaking:** Products and modules were renamed to `Anvyx*` (`AnvyxLocalizationKit`) and the package now requires Swift 6.2 (Xcode 26). Update `.product(name:)` entries and `import` statements.
- **Breaking:** `language` can be a full BCP-47 code such as `zh-Hant` or `pt-BR`; it is no longer truncated to two letters. A device language that is not bundled falls back to `defaultLanguage`.

### Added

- RTL support, per-screen language override, plural sugar

### Changed

- On-device translation fallback for missing keys (P2)
- Rename module(s) -> Anvyx* (naming convention)

### Fixed

- Resolve device language against bundled localizations, validate format strings

## [3.0.2] - 2026-07-02

_No notable changes._

## [3.0.1] - 2026-07-02

_No notable changes._

## [3.0.0] - 2026-07-02

_No notable changes._

## [2.0.0] - 2026-07-01

### Added

- Instant in-app language switching (Bundle swizzle), LanguagePicker, Language model, .localized() modifier, String Catalog support

## [1.0.0] - 2026-07-01

### Changed

- In-app language switching (@Observable, iOS 17)
