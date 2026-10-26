import Foundation

/// Filtro de obras com tag de conteúdo adulto ("Adult", "Mature", "Smut", "Hentai", "+18"...).
/// Compara a tag inteira: "Vida Adulta" (gênero comum de slice of life) não é bloqueada.
/// "Ecchi" também passa: é conteúdo sugestivo, não explícito.
public enum ContentFilter {
    private static let adultTags: Set<String> = [
        "adult", "adults", "adulto", "adultos", "adulta", "adultas", "adulte", "adultes", "adulti",
        "+18", "18+", "18", "r18", "r 18", "r-18", "+19", "19+", "r19",
        "adult content", "conteudo adulto", "contenido adulto", "mature 18",
        "mature", "maduro", "madura", "smut", "hentai", "nsfw",
        "erotica", "erotico", "erotic", "eroticism", "erotismo",
        "porn", "porno", "pornographic", "pornografia", "pornografico",
        "sexual violence", "violencia sexual", "sexual content", "conteudo sexual", "contenido sexual",
        "manhwa18", "manga18",
        // Atos sexuais explícitos (tags de sites de doujin/hentai que não usam "Adult")
        "lolicon", "shotacon", "futanari", "fingering", "anal", "anal sex", "blowjob", "oral sex", "bdsm",
        "rape", "estupro", "netorare", "ntr", "ahegao", "paizuri", "creampie", "gangbang", "threesome",
        "sexo", "sex", "sexo a tres", "sexo oral", "sex toys",
        // Classificação que o app anexa às obras do NamiComi
        "content rating: mature", "content rating: erotica", "content rating: pornographic",
    ]

    /// "Manhwa 18+", "Adulto (+18)", "R-18": a marca de idade dentro de uma tag maior.
    private static let ageMark = try! NSRegularExpression(pattern: #"(?<!\d)(18|19)\s*\+|\+\s*(18|19)(?!\d)|\br-?1[89]\b"#)

    /// Nomes de fontes marcadas como "MIXED" no índice, mas que só publicam conteúdo adulto.
    private static let adultSourceName = try! NSRegularExpression(
        pattern: #"hentai|porn|xxx|smut|nsfw|erotic|(?<![0-9])18(?![0-9])|r18"#,
        options: .caseInsensitive
    )

    public static func normalizeTag(_ tag: String) -> String {
        tag.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#()[]")))
            .lowercased()
    }

    public static func isAdultTag(_ tag: String) -> Bool {
        let normalized = normalizeTag(tag)
        if adultTags.contains(normalized) { return true }
        return ageMark.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil
    }

    public static func isAdult(genres: [String]) -> Bool {
        genres.contains(where: isAdultTag)
    }

    /// Deve esconder a obra com estas tags, segundo o ajuste atual?
    public static func shouldBlock(genres: [String]) -> Bool {
        Preferences.blockAdultTags && isAdult(genres: genres)
    }

    /// A fonte parece só de conteúdo adulto pelo nome (ex.: "Manhwa18TX")?
    public static func isAdultSourceName(_ name: String) -> Bool {
        adultSourceName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}
