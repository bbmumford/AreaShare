/// A release version such as "1.4.2", as used in tags ("v1.4.2") and in the
/// app's Info.plist. Only plain dotted numbers are versions: anything with a
/// suffix ("1.5.0-beta") is not, so a pre-release is never offered as an
/// update.
public struct Version: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var text = Substring(text)
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 9, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(piece)
            else { return nil }
            numbers.append(number)
        }
        parts = numbers
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    /// "1.2" and "1.2.0" are the same version.
    private func part(_ index: Int) -> Int { index < parts.count ? parts[index] : 0 }

    public static func == (a: Version, b: Version) -> Bool {
        (0..<max(a.parts.count, b.parts.count)).allSatisfy { a.part($0) == b.part($0) }
    }

    public static func < (a: Version, b: Version) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) where a.part(index) != b.part(index) {
            return a.part(index) < b.part(index)
        }
        return false
    }
}
