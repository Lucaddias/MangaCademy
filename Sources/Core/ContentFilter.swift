import Foundation

/// Filtro de obras com tag de conteúdo adulto ("Adult", "Adulto", "+18"...).
/// Compara a tag inteira: "Vida Adulta" (gênero comum de slice of life) não é bloqueada.
public enum ContentFilter {
    public static let blockAdultKey = "block_adult_tags"

    /// Ligado por padrão.
    public static var blockAdult: Bool {
        UserDefaults.standard.object(forKey: blockAdultKey) as? Bool ?? true
    }

    private static let adultTags: Set<String> = [
        "adult", "adults", "adulto", "adultos", "adulta", "adultas",
        "+18", "18+", "18", "r18", "r 18", "r-18",
        "adult content", "conteudo adulto", "contenido adulto", "mature 18",
    ]

    public static func normalizeTag(_ tag: String) -> String {
        tag.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#()[]")))
            .lowercased()
    }

    public static func isAdultTag(_ tag: String) -> Bool {
        adultTags.contains(normalizeTag(tag))
    }

    public static func isAdult(genres: [String]) -> Bool {
        genres.contains(where: isAdultTag)
    }

    /// Deve esconder a obra com estas tags, segundo o ajuste atual?
    public static func shouldBlock(genres: [String]) -> Bool {
        blockAdult && isAdult(genres: genres)
    }
}
