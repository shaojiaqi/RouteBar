import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system, english = "en", traditionalChinese = "zh-Hant", simplifiedChinese = "zh-Hans"
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return L("跟随系统")
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        case .simplifiedChinese: return "简体中文"
        }
    }
    public static func resolve(_ languages: [String]) -> AppLanguage {
        for language in languages {
            let tag = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if tag.hasPrefix("zh") {
                if tag.contains("hant") { return .traditionalChinese }
                if tag.contains("hans") { return .simplifiedChinese }
                return tag.hasPrefix("zh-tw") || tag.hasPrefix("zh-hk") || tag.hasPrefix("zh-mo") ? .traditionalChinese : .simplifiedChinese
            }
            if tag.hasPrefix("en") { return .english }
        }
        return .english
    }
}

public enum RouteBarLocalization {
    public static let preferenceKey = "RouteBarLanguage"
    private static let lock = NSLock()
    private static var override: AppLanguage?
    public static var selection: AppLanguage {
        get {
            lock.lock(); let temporary = override; lock.unlock()
            return temporary ?? AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }
    public static var language: AppLanguage { selection == .system ? AppLanguage.resolve(Locale.preferredLanguages) : selection }
    public static var locale: Locale { Locale(identifier: language.rawValue) }
    /// Used by the separate privileged helper; never writes root's preferences.
    public static func useInCurrentProcess(_ language: AppLanguage?) { lock.lock(); override = language; lock.unlock() }
    public static let catalog: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "Localizations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let translations = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return translations
    }()
    public static func text(_ key: String, arguments: [String] = [], language: AppLanguage? = nil) -> String {
        let requested = language ?? self.language
        let resolved = requested == .system ? AppLanguage.resolve(Locale.preferredLanguages) : requested
        let template = catalog[key]?[resolved.rawValue] ?? key
        let regex = try! NSRegularExpression(pattern: "\\{([0-9]+)\\}")
        let source = template as NSString
        var result = "", cursor = 0
        for match in regex.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let index = Int(source.substring(with: match.range(at: 1)))!
            result += index < arguments.count ? arguments[index] : source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }
}

public func L(_ key: String, _ arguments: Any...) -> String {
    RouteBarLocalization.text(key, arguments: arguments.map { String(describing: $0) })
}

extension RouteBarLocalization {
    private struct MessagePattern {
        let key: String
        let regex: NSRegularExpression
        let indexes: [Int]
        let weight: Int
    }
    private static let exactMessages: [String: String] = {
        var result: [String: String] = [:]
        for (key, translations) in catalog where !key.contains("{0}") {
            result[key] = key
            for translation in translations.values { result[translation] = key }
        }
        return result
    }()
    private static let messagePatterns: [MessagePattern] = {
        let placeholder = try! NSRegularExpression(pattern: "\\{([0-9]+)\\}")
        var patterns: [MessagePattern] = []
        for (key, translations) in catalog where key.contains("{0}") {
            for template in Set(Array(translations.values) + [key]) {
                let source = template as NSString
                let matches = placeholder.matches(in: template, range: NSRange(location: 0, length: source.length))
                var pattern = "^", indexes: [Int] = [], cursor = 0, weight = 0
                for match in matches {
                    let literal = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    weight += literal.count
                    pattern += NSRegularExpression.escapedPattern(for: literal) + "(.*?)"
                    indexes.append(Int(source.substring(with: match.range(at: 1)))!)
                    cursor = NSMaxRange(match.range)
                }
                let ending = source.substring(from: cursor)
                weight += ending.count
                pattern += NSRegularExpression.escapedPattern(for: ending) + "$"
                if weight >= 3, let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
                    patterns.append(MessagePattern(key: key, regex: regex, indexes: indexes, weight: weight))
                }
            }
        }
        return patterns.sorted { $0.weight > $1.weight }
    }()
    /// Re-renders saved messages and a preview created before a language switch.
    /// User-supplied node names and addresses are never passed through this path.
    public static func relocalize(_ message: String, language: AppLanguage? = nil, depth: Int = 0) -> String {
        guard depth < 6 else { return message }
        if let key = exactMessages[message] { return text(key, language: language) }
        let source = message as NSString
        for entry in messagePatterns {
            guard let match = entry.regex.firstMatch(in: message, range: NSRange(location: 0, length: source.length)) else { continue }
            var arguments = [String](repeating: "", count: (entry.indexes.max() ?? -1) + 1)
            for (position, index) in entry.indexes.enumerated() {
                let captured = source.substring(with: match.range(at: position + 1))
                arguments[index] = relocalize(captured, language: language, depth: depth + 1)
            }
            return text(entry.key, arguments: arguments, language: language)
        }
        return message
    }
}
