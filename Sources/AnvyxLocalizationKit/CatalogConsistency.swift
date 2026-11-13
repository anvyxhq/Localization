//
//  CatalogConsistency.swift
//  Localization
//

import Foundation

/// One inconsistency found by ``CatalogConsistency/problems(in:referenceLanguage:)``.
public struct CatalogProblem: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        /// The key exists in another language but not in this one.
        case missingKey
        /// The string's printf placeholders differ from the reference language's.
        case formatMismatch
        /// The `.strings` file could not be read as a string table.
        case unreadableTable
    }

    public let kind: Kind
    /// Language code of the `.lproj` the problem was found in.
    public let language: String
    /// Table name (the `.strings` file name without extension).
    public let table: String
    /// The affected key; empty for ``Kind/unreadableTable``.
    public let key: String

    public var description: String {
        switch kind {
        case .missingKey: "\(language).lproj/\(table).strings: missing key \"\(key)\""
        case .formatMismatch: "\(language).lproj/\(table).strings: placeholders of \"\(key)\" differ from the reference language"
        case .unreadableTable: "\(language).lproj/\(table).strings: not a readable string table"
        }
    }
}

/// Checks that the string tables of a bundle agree across languages. Meant to
/// be called from a unit test:
///
/// ```swift
/// func testStringsAreConsistent() {
///     let problems = CatalogConsistency.problems(in: .module)
///     XCTAssertTrue(problems.isEmpty, problems.map(\.description).joined(separator: "\n"))
/// }
/// ```
///
/// It reads the compiled per-language `.strings` tables (which is also what a
/// String Catalog builds into). Plural variants in `.stringsdict` files are not
/// inspected.
public enum CatalogConsistency {

    /// Every key must exist in every language, and each string must have the
    /// same ``FormatSignature`` as its counterpart in the reference language.
    ///
    /// - Parameters:
    ///   - bundle: the bundle holding the `.lproj` folders.
    ///   - referenceLanguage: language the placeholders are compared against.
    ///     Defaults to the bundle's development localization, or the first
    ///     language alphabetically when that one is not bundled.
    /// - Returns: the problems found, in a stable order; empty when consistent.
    public static func problems(in bundle: Bundle, referenceLanguage: String? = nil) -> [CatalogProblem] {
        let languages = bundle.localizations.filter { $0 != "Base" }.sorted()
        var problems: [CatalogProblem] = []
        // table → language → strings
        var tables: [String: [String: [String: String]]] = [:]

        for language in languages {
            guard let folder = bundle.url(forResource: language, withExtension: "lproj"),
                  let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            else { continue }
            for file in files where file.pathExtension == "strings" {
                let table = file.deletingPathExtension().lastPathComponent
                guard let strings = NSDictionary(contentsOf: file) as? [String: String] else {
                    problems.append(.init(kind: .unreadableTable, language: language, table: table, key: ""))
                    continue
                }
                tables[table, default: [:]][language] = strings
            }
        }

        let preferred = [referenceLanguage, bundle.developmentLocalization].compactMap { $0 }
        for table in tables.keys.sorted() {
            let perLanguage = tables[table] ?? [:]
            let keys = Set(perLanguage.values.flatMap(\.keys)).sorted()
            let order = preferred.filter(languages.contains) + languages
            for key in keys {
                let reference = order.lazy.compactMap { perLanguage[$0]?[key] }.first
                for language in languages {
                    guard let value = perLanguage[language]?[key] else {
                        problems.append(.init(kind: .missingKey, language: language, table: table, key: key))
                        continue
                    }
                    if let reference, !FormatSignature.isCompatible(value, with: reference) {
                        problems.append(.init(kind: .formatMismatch, language: language, table: table, key: key))
                    }
                }
            }
        }
        return problems
    }
}
