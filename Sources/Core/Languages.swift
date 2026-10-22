import Foundation

/// Filtro rápido de idioma usado no catálogo e na lista de capítulos.
public enum LanguageFilter: String, CaseIterable, Identifiable {
    case portuguese = "pt"
    case english = "en"
    case all = "all"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .portuguese: return "Português"
        case .english: return "Inglês"
        case .all: return "Todos"
        }
    }

    /// Se um idioma (normalizado) pertence a este filtro.
    public func matches(_ language: String) -> Bool {
        switch self {
        case .all: return true
        case .portuguese: return LanguageCode.isPortuguese(language)
        case .english: return LanguageCode.base(language) == "en"
        }
    }

    /// Códigos de idioma do MangaDex correspondentes ao filtro.
    public var mangaDexLanguages: [String] {
        switch self {
        case .portuguese: return ["pt-br", "pt"]
        case .english: return ["en"]
        case .all: return []
        }
    }

    /// Ordem de preferência ao escolher o idioma padrão dos capítulos.
    public var preferredLanguages: [String] {
        switch self {
        case .portuguese: return ["pt-BR", "pt", "en"]
        case .english: return ["en", "pt-BR", "pt"]
        case .all: return ["pt-BR", "pt", "en"]
        }
    }
}

public enum LanguageCode {
    /// Normaliza códigos vindos de fontes diferentes: "pt-br", "pt_BR" e "pt-BR" viram "pt-BR".
    public static func normalize(_ raw: String) -> String {
        let cleaned = raw.trimmed.replacingOccurrences(of: "_", with: "-")
        guard !cleaned.isEmpty else { return "all" }
        let lower = cleaned.lowercased()
        if lower == "all" || lower == "multi" { return "all" }
        let parts = lower.split(separator: "-").map(String.init)
        guard let first = parts.first else { return lower }
        if parts.count == 1 { return first }
        let region = parts[1]
        if region.count == 2 { return "\(first)-\(region.uppercased())" }
        return "\(first)-\(region)"
    }

    public static func base(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code)).lowercased()
    }

    public static func isPortuguese(_ code: String) -> Bool {
        base(code) == "pt"
    }

    private static let displayLocale = Locale(identifier: "pt_BR")

    /// Nome legível: "Português (Brasil)", "Inglês", "Espanhol (América Latina)"...
    public static func displayName(_ code: String) -> String {
        if code == "all" { return "Vários idiomas" }
        if code == "es-la" { return "Espanhol (América Latina)" }
        let identifier = code.replacingOccurrences(of: "-", with: "_")
        let name = displayLocale.localizedString(forIdentifier: identifier) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Rótulo curto para badges: "PT-BR", "EN".
    public static func shortLabel(_ code: String) -> String {
        code == "all" ? "MULTI" : code.uppercased()
    }
}
