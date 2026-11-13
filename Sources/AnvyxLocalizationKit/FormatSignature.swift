//
//  FormatSignature.swift
//  Localization
//

import Foundation

/// The argument list a printf-style format string expects: which argument
/// position takes which kind of value.
///
/// Two strings with the same signature can be swapped for one another as the
/// format of `String(format:arguments:)` without changing how the arguments are
/// read. A translation may reorder placeholders (`"%2$@ %1$d"`), change flags,
/// width or precision, but must not drop, add or retype one — formatting with a
/// mismatched specifier reads the argument list incorrectly.
///
/// ```swift
/// FormatSignature("%d of %@") == FormatSignature("%2$@ / %1$d")   // true
/// FormatSignature("%d of %@") == FormatSignature("%@ of %@")      // false
/// FormatSignature("100%")                                         // nil (dangling %)
/// ```
///
/// `%%` is a literal percent sign and is not part of the signature.
public struct FormatSignature: Hashable, Sendable {

    /// The kind of value a conversion reads from the argument list.
    public enum Argument: Hashable, Sendable {
        /// `%@`
        case object
        /// `%d`, `%i`, `%u`, `%x`, `%X`, `%o` (and the legacy `%D`, `%U`, `%O`)
        case integer
        /// `%c`, `%C`
        case character
        /// `%f`, `%e`, `%g`, `%a` and their uppercase forms
        case floatingPoint
        /// `%s`, `%S`
        case cString
        /// `%p`
        case pointer
    }

    /// Expected argument kind per 1-based argument position.
    public let arguments: [Int: Argument]

    /// Parses `format`. Returns `nil` when the string is not a well-formed
    /// format: a `%` that does not start a known specifier, a `*` width or
    /// precision, positional and non-positional specifiers mixed together, or
    /// one position used with two different kinds.
    public init?(_ format: String) {
        let bytes = Array(format.utf8)
        var arguments: [Int: Argument] = [:]
        var sequential = 0
        var usesPositions: Bool?
        var index = 0

        func digits() -> Int? {
            var value: Int?
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                let next = (value ?? 0) &* 10 &+ Int(bytes[index] - 0x30)
                value = min(next, 1_000_000)
                index += 1
            }
            return value
        }

        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "%") else { index += 1; continue }
            index += 1
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: "%") { index += 1; continue }

            // Optional `n$` position; otherwise the digits were a width.
            var position: Int?
            let start = index
            if let number = digits(), index < bytes.count, bytes[index] == UInt8(ascii: "$") {
                guard number >= 1 else { return nil }
                position = number
                index += 1
            } else {
                index = start
            }

            // Flags, width, precision.
            while index < bytes.count, Self.flags.contains(bytes[index]) { index += 1 }
            _ = digits()
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                _ = digits()
            }
            // Length modifiers.
            while index < bytes.count, Self.lengths.contains(bytes[index]) { index += 1 }

            guard index < bytes.count, let kind = Self.conversions[bytes[index]] else { return nil }
            index += 1

            let positional = position != nil
            if let usesPositions, usesPositions != positional { return nil }
            usesPositions = positional

            let slot: Int
            if let position {
                slot = position
            } else {
                sequential += 1
                slot = sequential
            }
            if let existing = arguments[slot], existing != kind { return nil }
            arguments[slot] = kind
        }
        self.arguments = arguments
    }

    /// `true` when `candidate` can stand in for `reference` as a format string:
    /// both parse to the same signature, or neither is a well-formed format
    /// (plain text such as `"50%"`, which must not be formatted with arguments
    /// in the first place).
    public static func isCompatible(_ candidate: String, with reference: String) -> Bool {
        FormatSignature(candidate) == FormatSignature(reference)
    }

    private static let flags: Set<UInt8> = Set("-+ #0'".utf8)
    private static let lengths: Set<UInt8> = Set("hlqztjL".utf8)
    private static let conversions: [UInt8: Argument] = {
        var table: [UInt8: Argument] = [:]
        for byte in "@".utf8 { table[byte] = .object }
        for byte in "diuxXoDUO".utf8 { table[byte] = .integer }
        for byte in "cC".utf8 { table[byte] = .character }
        for byte in "fFeEgGaA".utf8 { table[byte] = .floatingPoint }
        for byte in "sS".utf8 { table[byte] = .cString }
        for byte in "p".utf8 { table[byte] = .pointer }
        return table
    }()
}
