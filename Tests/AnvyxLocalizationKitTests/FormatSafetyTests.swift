//
//  FormatSafetyTests.swift
//  Localization
//

import XCTest
@testable import AnvyxLocalizationKit

/// Builds a throwaway bundle with one `Localizable.strings` per language.
func makeBundle(_ tables: [String: [String: String]],
                file: StaticString = #filePath, line: UInt = #line) throws -> Bundle {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("l10n-\(UUID().uuidString).bundle")
    for (language, strings) in tables {
        let folder = root.appendingPathComponent("\(language).lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let body = strings.sorted { $0.key < $1.key }.map { key, value in
            "\"\(escape(key))\" = \"\(escape(value))\";"
        }.joined(separator: "\n")
        try body.write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
    }
    return try XCTUnwrap(Bundle(url: root), file: file, line: line)
}

private func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

/// Test helper: fails once per inconsistency in the bundle's string tables.
func assertCatalogConsistent(bundle: Bundle, file: StaticString = #filePath, line: UInt = #line) {
    for problem in CatalogConsistency.problems(in: bundle) {
        XCTFail(problem.description, file: file, line: line)
    }
}

final class FormatSignatureTests: XCTestCase {
    func testPlainTextHasEmptySignature() {
        XCTAssertEqual(FormatSignature("Hello")?.arguments, [:])
        XCTAssertEqual(FormatSignature("100%% sure")?.arguments, [:])
    }

    func testSequentialSpecifiers() {
        XCTAssertEqual(FormatSignature("%@ has %d items (%.2f%%)")?.arguments,
                       [1: .object, 2: .integer, 3: .floatingPoint])
        XCTAssertEqual(FormatSignature("%-5ld %08.3lf %s %p %c")?.arguments,
                       [1: .integer, 2: .floatingPoint, 3: .cString, 4: .pointer, 5: .character])
    }

    func testPositionalOrderDoesNotMatter() {
        XCTAssertEqual(FormatSignature("%1$@ owes %2$d"), FormatSignature("%2$d from %1$@"))
        XCTAssertEqual(FormatSignature("%@ owes %d"), FormatSignature("%2$d from %1$@"))
        XCTAssertEqual(FormatSignature("%1$@ and %1$@")?.arguments, [1: .object])
    }

    func testDetectsDroppedAddedAndRetyped() {
        XCTAssertNotEqual(FormatSignature("%@ owes %d"), FormatSignature("%@ owes"))
        XCTAssertNotEqual(FormatSignature("%@"), FormatSignature("%@ %@"))
        XCTAssertNotEqual(FormatSignature("%d"), FormatSignature("%@"))
        XCTAssertNotEqual(FormatSignature("%1$@ %2$d"), FormatSignature("%1$d %2$@"))
    }

    func testMalformedFormats() {
        XCTAssertNil(FormatSignature("100%"))
        XCTAssertNil(FormatSignature("% @x %y"))
        XCTAssertNil(FormatSignature("%*d"))
        XCTAssertNil(FormatSignature("%1$@ %d"))        // mixed
        XCTAssertNil(FormatSignature("%1$@ %1$d"))      // one slot, two kinds
        XCTAssertNil(FormatSignature("%0$@"))
        XCTAssertNil(FormatSignature("%n"))
    }

    func testCompatibility() {
        XCTAssertTrue(FormatSignature.isCompatible("Xin chào %@", with: "Hello %@"))
        XCTAssertFalse(FormatSignature.isCompatible("Xin chào", with: "Hello %@"))
        XCTAssertFalse(FormatSignature.isCompatible("Xin chào % @", with: "Hello"))
        XCTAssertTrue(FormatSignature.isCompatible("Pin 50%", with: "Battery 50%"))
    }
}

@MainActor
final class TranslationFormatSafetyTests: XCTestCase {
    private func manager(_ bundle: Bundle) -> LocalizationManager {
        LocalizationManager(bundle: bundle, defaultLanguage: "en", systemWide: false, persistsSelection: false)
    }

    private func settle(_ manager: LocalizationManager, _ key: String, _ arguments: [CVarArg], until expected: String) async {
        for _ in 0..<100 where manager.string(key, arguments: arguments) != expected {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testMangledTranslationFallsBackToBase() async throws {
        let bundle = try makeBundle(["en": ["count": "%d of %@"], "fr": ["x": "x"]])
        let manager = manager(bundle)
        let calls = Counter()
        // Drops a placeholder and retypes the other: must never be used as a format.
        manager.translationProvider = { _, _ in await calls.increment(); return "%@ sur" }
        manager.setLanguage("fr")

        XCTAssertEqual(manager.string("count", 2, "5"), "2 of 5")
        for _ in 0..<100 where await calls.value == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(manager.string("count", 2, "5"), "2 of 5")
        let count = await calls.value
        XCTAssertEqual(count, 1, "a rejected translation must not be requested again")
    }

    func testReorderedTranslationIsUsed() async throws {
        let bundle = try makeBundle(["en": ["count": "%d of %@"], "fr": ["x": "x"]])
        let manager = manager(bundle)
        manager.translationProvider = { _, _ in "%2$@ : %1$d" }
        manager.setLanguage("fr")
        _ = manager.string("count", 2, "5")
        await settle(manager, "count", [2, "5"], until: "5 : 2")
        XCTAssertEqual(manager.string("count", 2, "5"), "5 : 2")
    }

    func testBaseStringEqualToItsKeyIsStillTranslated() async throws {
        let bundle = try makeBundle(["en": ["OK": "OK"], "fr": ["x": "x"]])
        let manager = manager(bundle)
        manager.translationProvider = { _, _ in "D'accord" }
        manager.setLanguage("fr")
        _ = manager.string("OK")
        await settle(manager, "OK", [], until: "D'accord")
        XCTAssertEqual(manager.string("OK"), "D'accord")
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@MainActor
final class OverrideTests: XCTestCase {
    private func makeManager() throws -> LocalizationManager {
        let bundle = try makeBundle([
            "en": ["title": "Title", "count": "%d of %@", "legal": "Terms", "only_en": "Base only", "same": "same"],
            "fr": ["title": "Titre", "count": "%d sur %@", "legal": "Conditions", "same": "same"],
        ])
        return LocalizationManager(bundle: bundle, defaultLanguage: "en", systemWide: false, persistsSelection: false)
    }

    func testLookupOrder() throws {
        let manager = try makeManager()
        let rejected = manager.setOverrides(["fr": ["title": "Mon titre"], "en": ["only_en": "Custom base"]])
        XCTAssertEqual(rejected, [])

        XCTAssertEqual(manager.string("title"), "Title")            // en has no override for title
        XCTAssertEqual(manager.string("only_en"), "Custom base")
        manager.setLanguage("fr")
        XCTAssertEqual(manager.string("title"), "Mon titre")        // override, current language
        XCTAssertEqual(manager.string("legal"), "Conditions")       // bundle, current language
        XCTAssertEqual(manager.string("only_en"), "Base only")      // base bundle (en override is not fr's)
        XCTAssertEqual(manager.string("nope"), "nope")

        manager.setOverrides([:])
        XCTAssertEqual(manager.string("title"), "Titre")
    }

    func testRejectsUnknownProtectedAndMismatched() throws {
        let manager = try makeManager()
        let rejected = manager.setOverrides(
            ["fr": ["nope": "x", "legal": "Hacked", "count": "%@ sur %@", "title": "OK", "same": "pareil", "only_en": "Repli"]],
            protectedKeys: ["legal"]
        )
        XCTAssertEqual(rejected, [
            .init(language: "fr", key: "count", reason: .formatMismatch),
            .init(language: "fr", key: "legal", reason: .protectedKey),
            .init(language: "fr", key: "nope", reason: .unknownKey),
        ])
        manager.setLanguage("fr")
        XCTAssertEqual(manager.string("count", 1, "3"), "1 sur 3")
        XCTAssertEqual(manager.string("legal"), "Conditions")
        XCTAssertEqual(manager.string("nope"), "nope")
        XCTAssertEqual(manager.string("title"), "OK")
        XCTAssertEqual(manager.string("same"), "pareil")     // value == key is a real entry
        XCTAssertEqual(manager.string("only_en"), "Repli")   // key known through the base language
    }

    func testOverrideWithReorderedPlaceholdersFormats() throws {
        let manager = try makeManager()
        XCTAssertEqual(manager.setOverrides(["FR": ["count": "%2$@ / %1$d"]]), [])
        manager.setLanguage("fr")
        XCTAssertEqual(manager.string("count", 1, "3"), "3 / 1")
    }
}

final class InitialLanguageTests: XCTestCase {
    private func resolve(stored: String? = nil, preferred: [String], available: [String]) -> String {
        LocalizationManager.initialLanguage(stored: stored, preferred: preferred, available: available, fallback: "en")
    }

    func testFilipinoIsNotFinnish() {
        XCTAssertEqual(resolve(preferred: ["fil-PH"], available: ["en", "fi"]), "en")
        XCTAssertEqual(resolve(preferred: ["fil-PH"], available: ["en", "fi", "fil"]), "fil")
    }

    func testKeepsScriptAndRegion() {
        XCTAssertEqual(resolve(preferred: ["zh-Hant-TW"], available: ["en", "zh-Hans", "zh-Hant"]), "zh-Hant")
        XCTAssertEqual(resolve(preferred: ["pt-BR"], available: ["en", "pt-PT", "pt-BR"]), "pt-BR")
        XCTAssertEqual(resolve(preferred: ["en-GB"], available: ["Base", "fr", "en"]), "en")
    }

    func testUnbundledDeviceLanguageUsesNextPreferenceThenFallback() {
        XCTAssertEqual(resolve(preferred: ["ja-JP", "fr-FR"], available: ["en", "fr"]), "fr")
        XCTAssertEqual(resolve(preferred: ["ja-JP"], available: ["en", "fr"]), "en")
        XCTAssertEqual(resolve(preferred: ["ja-JP"], available: ["fr", "de"]), "en")
        XCTAssertEqual(resolve(preferred: ["ja-JP"], available: []), "en")
    }

    func testStoredSelectionIsValidated() {
        XCTAssertEqual(resolve(stored: "fr", preferred: ["en-US"], available: ["en", "fr"]), "fr")
        XCTAssertEqual(resolve(stored: "PT_br", preferred: ["en-US"], available: ["en", "pt-BR"]), "pt-BR")
        XCTAssertEqual(resolve(stored: "de", preferred: ["fr-FR"], available: ["en", "fr"]), "fr")
    }

    @MainActor
    func testManagerResolvesAndPersists() throws {
        let bundle = try makeBundle(["en": ["k": "English"], "zh-Hant": ["k": "繁體"], "fr": ["k": "Français"]])
        let suite = "l10n-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        func make(_ preferred: [String]) -> LocalizationManager {
            LocalizationManager(bundle: bundle, defaultLanguage: "en", systemWide: false,
                                persistsSelection: true, defaults: defaults, preferredLanguages: preferred)
        }
        let first = make(["zh-Hant-HK", "en"])
        XCTAssertEqual(first.language, "zh-Hant")
        XCTAssertEqual(first.string("k"), "繁體")

        first.setLanguage("fr")
        XCTAssertEqual(make(["zh-Hant-HK"]).language, "fr")

        defaults.set("xx", forKey: "anvyx.localization.language")   // no longer bundled
        XCTAssertEqual(make(["zh-Hant-HK"]).language, "zh-Hant")
    }
}

final class CatalogConsistencyTests: XCTestCase {
    func testConsistentCatalogHasNoProblems() throws {
        let bundle = try makeBundle([
            "en": ["a": "A %@", "b": "%1$d of %2$@", "p": "100%% done"],
            "vi": ["a": "A %@", "b": "%2$@: %1$d", "p": "Xong 100%%"],
        ])
        assertCatalogConsistent(bundle: bundle)
    }

    func testReportsMissingKeysAndMismatchedPlaceholders() throws {
        let bundle = try makeBundle([
            "en": ["a": "A %@", "b": "%d items", "c": "C"],
            "vi": ["a": "A", "b": "%d mục", "d": "D"],
        ])
        XCTAssertEqual(CatalogConsistency.problems(in: bundle, referenceLanguage: "en"), [
            .init(kind: .formatMismatch, language: "vi", table: "Localizable", key: "a"),
            .init(kind: .missingKey, language: "vi", table: "Localizable", key: "c"),
            .init(kind: .missingKey, language: "en", table: "Localizable", key: "d"),
        ])
    }

    func testFixtureBundleReportsItsKnownGap() {
        // The fixture deliberately leaves keys untranslated (translation-fallback tests).
        let problems = CatalogConsistency.problems(in: .module)
        XCTAssertTrue(problems.contains(.init(kind: .missingKey, language: "fr", table: "Localizable", key: "greeting")))
        XCTAssertFalse(problems.contains { $0.kind != .missingKey })
    }
}
