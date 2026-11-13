//
//  LocalizationManager.swift
//  Localization
//
//  Created by AnhPT on 02/07/2026.
//

import Foundation
import Observation

/// In-app language switching without an app restart, using the Observation
/// framework (iOS 17+). Resolves strings from the selected language's `.lproj`
/// bundle — works with both legacy `.strings` files and modern **String Catalogs
/// (`.xcstrings`)**, which compile into the same per-language tables.
///
/// The most convenient setup is a single modifier that injects both the manager
/// and the SwiftUI `\.locale` (so dates/numbers/plurals follow the language too):
///
/// ```swift
/// @State private var l10n = LocalizationManager.shared
///
/// ContentView()
///     .localized(l10n)            // inject manager + environment locale
///
/// // then, anywhere:
/// Text(l10n("welcome_title"))     // callAsFunction
/// "items_count".localized(5)      // String sugar via the shared manager
/// ```
@MainActor
@Observable
public final class LocalizationManager {
    public static let shared = LocalizationManager()

    /// Current language code — a full BCP-47 identifier matching a bundled
    /// `.lproj` where possible, e.g. "en", "vi", "fil", "zh-Hant", "pt-BR".
    public private(set) var language: String

    /// Locale derived from the current language — feed this into `\.locale`.
    public var locale: Locale { Locale(identifier: language) }

    @ObservationIgnored private var bundle: Bundle
    @ObservationIgnored private let sourceBundle: Bundle
    @ObservationIgnored private let systemWide: Bool
    @ObservationIgnored private let persistsSelection: Bool
    @ObservationIgnored private let storeKey = "anvyx.localization.language"
    @ObservationIgnored private let defaultLanguage: String
    @ObservationIgnored private var baseBundle: Bundle
    @ObservationIgnored private let defaults: UserDefaults
    // Tracked so replacing the overrides re-renders views that read a string.
    private var overrides: [String: [String: String]] = [:]

    /// Optional on-device translator for **missing** keys. Inject it (e.g. wiring
    /// `TranslationKit`) and any untranslated string is auto-translated from the
    /// base language, cached, and the view re-renders when the result arrives.
    /// Keeps this package dependency-free — the provider is supplied by the app.
    ///
    /// A translation is only used when its printf placeholders match the base
    /// string's (see ``FormatSignature``); otherwise the base text is kept.
    @ObservationIgnored
    public var translationProvider: (@Sendable (_ text: String, _ target: Locale.Language) async -> String?)?
    // Tracked so filling a translation re-renders views that read the string.
    private var translationCache: [String: String] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    /// - Parameters:
    ///   - bundle: where `.lproj` folders live (`.main`, or `.module` for a package).
    ///   - defaultLanguage: fallback when nothing valid is stored and none of the
    ///     device's preferred languages is bundled.
    ///   - systemWide: when `true` (default), swizzles `Bundle.main` so even plain
    ///     `Text("key")` / `NSLocalizedString` switch instantly. Set `false` to only
    ///     affect `LocalizedText` / `l10n(...)` lookups.
    ///   - persistsSelection: when `true` (default), the initial language is the
    ///     stored selection (if still bundled), else the best bundled match for
    ///     the device's preferred languages, else `defaultLanguage`; and
    ///     `setLanguage` stores the choice. When `false` the manager starts at
    ///     `defaultLanguage` and stores nothing.
    public convenience init(bundle: Bundle = .main, defaultLanguage: String = "en", systemWide: Bool = true, persistsSelection: Bool = true) {
        self.init(bundle: bundle, defaultLanguage: defaultLanguage, systemWide: systemWide,
                  persistsSelection: persistsSelection, defaults: .standard,
                  preferredLanguages: Locale.preferredLanguages)
    }

    init(bundle: Bundle, defaultLanguage: String, systemWide: Bool, persistsSelection: Bool,
         defaults: UserDefaults, preferredLanguages: [String]) {
        self.sourceBundle = bundle
        self.systemWide = systemWide
        self.persistsSelection = persistsSelection
        self.defaultLanguage = defaultLanguage
        self.defaults = defaults
        self.baseBundle = Self.resolveBundle(for: defaultLanguage, in: bundle) ?? bundle
        // Scoped (non-persisting) managers force `defaultLanguage`; the global one
        // resolves stored → device → default.
        let initial = persistsSelection
            ? Self.initialLanguage(stored: defaults.string(forKey: storeKey),
                                   preferred: preferredLanguages,
                                   available: bundle.localizations,
                                   fallback: defaultLanguage)
            : defaultLanguage
        self.language = initial
        self.bundle = Self.resolveBundle(for: initial, in: bundle) ?? bundle
        applySystemWide()
    }

    /// Stored selection if it is still bundled, else the bundled localization the
    /// system would pick for `preferred`, else `fallback`.
    nonisolated static func initialLanguage(stored: String?, preferred: [String],
                                            available: [String], fallback: String) -> String {
        let available = available.filter { $0 != "Base" }
        if let stored, let match = available.first(where: { canonical($0) == canonical(stored) }) {
            return match
        }
        // `preferredLocalizations` can hand back an unrelated default when nothing
        // matches, so only accept a result in a language the user actually asked for.
        let wanted = Set(preferred.compactMap { Locale.Language(identifier: $0).languageCode })
        if let device = Bundle.preferredLocalizations(from: available, forPreferences: preferred).first,
           let code = Locale.Language(identifier: device).languageCode, wanted.contains(code) {
            return device
        }
        return fallback
    }

    nonisolated private static func canonical(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// Languages bundled with the app (folders ending in `.lproj`), as rich models.
    public var availableLanguages: [Language] {
        sourceBundle.localizations
            .filter { $0 != "Base" }
            .map(Language.init(code:))
            .sorted { $0.nativeName < $1.nativeName }
    }

    public func setLanguage(_ code: String) {
        guard code != language else { return }
        bundle = Self.resolveBundle(for: code, in: sourceBundle) ?? sourceBundle
        language = code
        if persistsSelection { defaults.set(code, forKey: storeKey) }
        applySystemWide()
    }

    private func applySystemWide() {
        guard systemWide, sourceBundle == .main else { return }
        LocalizedBundle.install(bundle)
    }

    public func setLanguage(_ language: Language) {
        setLanguage(language.code)
    }

    // MARK: - Lookup

    /// Localized string for `key`, optionally formatted with `arguments`.
    public func string(_ key: String, _ arguments: CVarArg...) -> String {
        localized(key, arguments)
    }

    /// Sugar so the manager is callable directly: `l10n("key")`.
    public func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        localized(key, arguments)
    }

    /// Array-based overload for forwarding already-collected arguments.
    public func string(_ key: String, arguments: [CVarArg]) -> String {
        localized(key, arguments)
    }

    private func localized(_ key: String, _ arguments: [CVarArg]) -> String {
        let format = overrides[Self.canonical(language)]?[key]
            ?? Self.lookup(key, in: bundle)
            ?? translationFallback(for: key)   // base text, or a cached auto-translation
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }

    /// Resolve a missing key: use a cached on-device translation if present,
    /// otherwise return the base-language text and kick off a translation.
    private func translationFallback(for key: String) -> String {
        let cacheKey = "\(language)\u{1}\(key)"
        if let cached = translationCache[cacheKey] { return cached }

        // Missing everywhere → the key itself. A base string that merely equals
        // its key ("OK" = "OK") is a real string and still gets translated.
        guard let base = Self.lookup(key, in: baseBundle) else { return key }
        guard translationProvider != nil, language != defaultLanguage else { return base }
        requestTranslation(cacheKey: cacheKey, text: base, target: language)
        return base   // show base text until the translation arrives
    }

    private func requestTranslation(cacheKey: String, text: String, target: String) {
        guard !inFlight.contains(cacheKey), let provider = translationProvider else { return }
        inFlight.insert(cacheKey)
        let language = Locale.Language(identifier: target)
        Task { [weak self] in
            let translated = await provider(text, language)
            guard let self else { return }
            self.inFlight.remove(cacheKey)
            guard let translated else { return }
            // The result becomes a format string: keep it only if it reads the
            // arguments exactly like the base text, else settle on the base text.
            self.translationCache[cacheKey] =
                FormatSignature.isCompatible(translated, with: text) ? translated : text   // → re-render
        }
    }

    // MARK: - Overrides

    /// Why ``setOverrides(_:protectedKeys:)`` refused a value.
    public struct OverrideRejection: Hashable, Sendable {
        public enum Reason: Hashable, Sendable {
            /// The key is not in the bundle (neither that language nor the default one).
            case unknownKey
            /// The key is listed in `protectedKeys`.
            case protectedKey
            /// The value's printf placeholders differ from the bundled string's.
            case formatMismatch
        }

        public let language: String
        public let key: String
        public let reason: Reason
    }

    /// Replaces the override table: strings supplied at runtime (e.g. from a
    /// remote config) that take precedence over the bundled ones. Pass an empty
    /// dictionary to remove all overrides.
    ///
    /// Lookup order for ``string(_:_:)``: override for the current language →
    /// bundled string for the current language → on-device translation (if a
    /// ``translationProvider`` is set) → default-language string → the key.
    ///
    /// A value is accepted only when
    /// - its key exists in the bundle, in that language or the default language,
    /// - the key is not in `protectedKeys`, and
    /// - its ``FormatSignature`` equals the bundled string's, so it formats the
    ///   same arguments safely.
    ///
    /// Rejected values are skipped individually; the rest still apply.
    ///
    /// - Note: Overrides apply to lookups made through this manager
    ///   (``string(_:_:)``, `LocalizedText`, `String.localized`). Plain
    ///   `Text("key")` resolved through the system-wide bundle swap keeps the
    ///   bundled string.
    ///
    /// - Parameters:
    ///   - overrides: `[language code: [key: value]]`.
    ///   - protectedKeys: keys that may never be overridden (legal text, etc.).
    /// - Returns: the values that were refused, sorted by language then key.
    @discardableResult
    public func setOverrides(_ overrides: [String: [String: String]],
                             protectedKeys: Set<String> = []) -> [OverrideRejection] {
        var accepted: [String: [String: String]] = [:]
        var rejected: [OverrideRejection] = []
        for (language, table) in overrides {
            let languageBundle = Self.resolveBundle(for: language, in: sourceBundle)
            for (key, value) in table {
                let reason: OverrideRejection.Reason?
                if protectedKeys.contains(key) {
                    reason = .protectedKey
                } else if let bundled = languageBundle.flatMap({ Self.lookup(key, in: $0) })
                            ?? Self.lookup(key, in: baseBundle) {
                    reason = FormatSignature.isCompatible(value, with: bundled) ? nil : .formatMismatch
                } else {
                    reason = .unknownKey
                }
                if let reason {
                    rejected.append(.init(language: language, key: key, reason: reason))
                } else {
                    accepted[Self.canonical(language), default: [:]][key] = value
                }
            }
        }
        self.overrides = accepted
        return rejected.sorted { ($0.language, $0.key) < ($1.language, $1.key) }
    }

    /// The bundled string for `key`, or `nil` when the bundle has no entry —
    /// which is different from an entry whose text equals the key.
    private static func lookup(_ key: String, in bundle: Bundle) -> String? {
        let missing = "\u{1}anvyx.missing\u{1}"
        let value = bundle.localizedString(forKey: key, value: missing, table: nil)
        return value == missing ? nil : value
    }

    private static func resolveBundle(for code: String, in source: Bundle) -> Bundle? {
        guard let path = source.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
