import Foundation

/// The caption at the bottom of a frame: the length of a text, the size of an image, or what a
/// file clip holds. Only the grouping of digits follows the user's region.
enum ClipInfoFormatter {
    /// `count` is the text's `String.count`; digits are grouped for `locale`.
    static func characters(_ count: Int, locale: Locale = .current) -> String {
        let number = count.formatted(.number.grouping(.automatic).locale(locale))
        return count == 1 ? "\(number) character" : "\(number) characters"
    }

    /// Pixel counts are not grouped: `4032 × 3024`.
    static func pixels(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }

    /// A file clip holds a local reference, not the file, so there is no size to show: one file
    /// gives its extension in capitals, several give their count. `File` stands in when there is
    /// no name or no extension.
    static func files(_ names: [String]) -> String {
        if names.count > 1 { return "\(names.count) files" }
        let fileExtension = ((names.first ?? "") as NSString).pathExtension.uppercased()
        return fileExtension.isEmpty ? "File" : fileExtension
    }

    /// For a clip with several items that are not files.
    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// How often a frequent clip was used: "Used 1,234 times" in its colour band, and "used 1,234 times" spoken, where
    /// it follows the kind after a comma. Digits are grouped for `locale`. The frequent wing lists only clips used at
    /// least twice, so the count is never one.
    static func uses(_ count: Int64, spoken: Bool = false, locale: Locale = .current) -> String {
        let number = count.formatted(.number.grouping(.automatic).locale(locale))
        return "\(spoken ? "used" : "Used") \(number) times"
    }

    /// The caption as VoiceOver says it: a picture's size reads "2880 by 1800".
    static func spoken(_ info: String) -> String {
        info.replacingOccurrences(of: " × ", with: " by ")
    }
}
