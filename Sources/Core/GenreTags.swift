import Foundation

/// Tags das obras unificadas entre fontes e idiomas: "School Life", "Vida Escolar" e "Escolar"
/// viram a mesma tag "Escolar". Tags fora da lista continuam valendo, comparadas pelo texto.
public enum GenreTags {
    /// Uma tag e quantas obras carregadas a têm.
    public struct Count: Identifiable, Hashable {
        public let key: String
        public let label: String
        public let count: Int
        public var id: String { key }
    }

    private struct Genre {
        let key: String
        let label: String
        let synonyms: [String]
    }

    // Sinônimos com ou sem acento: tudo passa por `normalize` antes de comparar
    private static let genres: [Genre] = [
        Genre(key: "action", label: "Ação", synonyms: ["action", "ação", "acción", "aksi", "azione", "aksiyon", "hành động", "actie"]),
        Genre(key: "adventure", label: "Aventura", synonyms: ["adventure", "aventura", "aventure", "petualangan", "avventura", "macera", "phiêu lưu", "abenteuer"]),
        Genre(key: "comedy", label: "Comédia", synonyms: ["comedy", "comédia", "comedia", "comédie", "komedi", "commedia", "hài hước", "komödie"]),
        Genre(key: "drama", label: "Drama", synonyms: ["drama", "drame", "dram"]),
        Genre(key: "fantasy", label: "Fantasia", synonyms: ["fantasy", "fantasia", "fantasía", "fantastique", "fantasi", "fantastico", "fantastik", "kỳ ảo", "fantasie"]),
        Genre(key: "romance", label: "Romance", synonyms: ["romance", "romântico", "romántico", "romantic", "romansa", "romantik", "romantizm", "tình cảm", "ngôn tình", "romantique", "romântica", "romántica"]),
        Genre(key: "school", label: "Escolar", synonyms: ["school life", "school", "schoollife", "vida escolar", "escolar", "colegial", "escola", "escuela", "colegio", "sekolah", "kehidupan sekolah", "vie scolaire", "scolaire", "okul", "học đường", "vita scolastica"]),
        Genre(key: "scifi", label: "Ficção científica", synonyms: ["sci-fi", "scifi", "sci fi", "science fiction", "ficção científica", "ciencia ficción", "ciência ficção", "fiksi ilmiah", "fantascienza", "bilim kurgu", "khoa học viễn tưởng"]),
        Genre(key: "slice-of-life", label: "Slice of life", synonyms: ["slice of life", "cotidiano", "vida cotidiana", "vida diária", "recuentos de la vida", "tranche de vie", "kehidupan sehari-hari", "günlük yaşam"]),
        Genre(key: "horror", label: "Terror", synonyms: ["horror", "terror", "horreur", "horor", "kinh dị", "orrore"]),
        Genre(key: "mystery", label: "Mistério", synonyms: ["mystery", "mistério", "misterio", "mystère", "misteri", "gizem", "bí ẩn", "mistero"]),
        Genre(key: "thriller", label: "Suspense", synonyms: ["thriller", "suspense", "suspenso", "suspens", "gerilim"]),
        Genre(key: "psychological", label: "Psicológico", synonyms: ["psychological", "psicológico", "psicológica", "psychologique", "psikologis", "psikolojik", "tâm lý", "psicologico"]),
        Genre(key: "supernatural", label: "Sobrenatural", synonyms: ["supernatural", "sobrenatural", "surnaturel", "supranatural", "doğaüstü", "siêu nhiên", "soprannaturale"]),
        Genre(key: "isekai", label: "Isekai", synonyms: ["isekai", "outro mundo", "otro mundo", "another world", "other world"]),
        Genre(key: "reincarnation", label: "Reencarnação", synonyms: ["reincarnation", "reencarnação", "reencarnación", "réincarnation", "reinkarnasi", "transmigration", "transmigração", "rebirth", "renascimento"]),
        Genre(key: "regression", label: "Regressão", synonyms: ["regression", "regressão", "regresión", "regressor"]),
        Genre(key: "time-travel", label: "Viagem no tempo", synonyms: ["time travel", "viagem no tempo", "viaje en el tiempo", "voyage temporel"]),
        Genre(key: "martial-arts", label: "Artes marciais", synonyms: ["martial arts", "artes marciais", "artes marciales", "arts martiaux", "bela diri", "võ thuật", "dövüş sanatları"]),
        Genre(key: "murim", label: "Murim", synonyms: ["murim"]),
        Genre(key: "wuxia", label: "Wuxia / Cultivo", synonyms: ["wuxia", "xianxia", "xuanhuan", "cultivation", "cultivo", "cultivação"]),
        Genre(key: "sports", label: "Esportes", synonyms: ["sports", "sport", "esportes", "esporte", "deportes", "deporte", "olahraga", "spor", "thể thao"]),
        Genre(key: "historical", label: "Histórico", synonyms: ["historical", "histórico", "histórica", "historique", "sejarah", "tarihi", "lịch sử"]),
        Genre(key: "shounen", label: "Shounen", synonyms: ["shounen", "shonen", "shōnen"]),
        Genre(key: "shoujo", label: "Shoujo", synonyms: ["shoujo", "shojo", "shōjo"]),
        Genre(key: "seinen", label: "Seinen", synonyms: ["seinen"]),
        Genre(key: "josei", label: "Josei", synonyms: ["josei"]),
        Genre(key: "harem", label: "Harém", synonyms: ["harem", "harém"]),
        Genre(key: "reverse-harem", label: "Harém reverso", synonyms: ["reverse harem", "harém reverso", "harem inverso"]),
        Genre(key: "mecha", label: "Mecha", synonyms: ["mecha", "mechas"]),
        Genre(key: "magic", label: "Magia", synonyms: ["magic", "magia", "magie", "sihir", "ma pháp"]),
        Genre(key: "tragedy", label: "Tragédia", synonyms: ["tragedy", "tragédia", "tragedia", "tragédie", "trajedi", "bi kịch"]),
        Genre(key: "military", label: "Militar", synonyms: ["military", "militar", "militaire", "militer", "askeri", "quân đội"]),
        Genre(key: "music", label: "Música", synonyms: ["music", "música", "musique", "musik", "müzik", "âm nhạc"]),
        Genre(key: "cooking", label: "Culinária", synonyms: ["cooking", "culinária", "cocina", "cuisine", "gourmet", "food", "comida", "memasak"]),
        Genre(key: "boys-love", label: "Boys' Love", synonyms: ["boys' love", "boys love", "bl", "yaoi", "shounen ai", "shonen ai"]),
        Genre(key: "girls-love", label: "Girls' Love", synonyms: ["girls' love", "girls love", "gl", "yuri", "shoujo ai", "shojo ai"]),
        Genre(key: "superhero", label: "Super-heróis", synonyms: ["superhero", "super hero", "superheroes", "super herói", "super-herói", "super heróis", "superhéroes"]),
        Genre(key: "superpower", label: "Superpoderes", synonyms: ["super power", "super powers", "superpower", "superpowers", "superpoderes", "super poderes"]),
        Genre(key: "overpowered", label: "Protagonista OP", synonyms: ["overpowered", "op mc", "mc op", "protagonista op", "protagonista overpowered"]),
        Genre(key: "revenge", label: "Vingança", synonyms: ["revenge", "vingança", "venganza", "vengeance", "balas dendam"]),
        Genre(key: "villainess", label: "Vilã", synonyms: ["villainess", "vilã", "villana"]),
        Genre(key: "zombies", label: "Zumbis", synonyms: ["zombies", "zombie", "zumbi", "zumbis", "zombis"]),
        Genre(key: "monsters", label: "Monstros", synonyms: ["monsters", "monster", "monstros", "monstruos", "monstres"]),
        Genre(key: "demons", label: "Demônios", synonyms: ["demons", "demon", "demônios", "demônio", "demonios", "demonio"]),
        Genre(key: "vampires", label: "Vampiros", synonyms: ["vampire", "vampires", "vampiro", "vampiros"]),
        Genre(key: "games", label: "Jogos", synonyms: ["game", "games", "jogo", "jogos", "video games", "videojuegos", "juegos"]),
        Genre(key: "system", label: "Sistema", synonyms: ["system", "sistema"]),
        Genre(key: "crime", label: "Crime / Policial", synonyms: ["crime", "crimen", "criminal", "police", "policial", "policía", "polícia"]),
        Genre(key: "medical", label: "Médico", synonyms: ["medical", "médico", "medicina"]),
        Genre(key: "apocalypse", label: "Pós-apocalíptico", synonyms: ["post-apocalyptic", "post apocalyptic", "apocalypse", "apocalipse", "pós-apocalíptico", "apocalíptico", "postapocalíptico"]),
        Genre(key: "survival", label: "Sobrevivência", synonyms: ["survival", "sobrevivência", "supervivencia", "survie"]),
        Genre(key: "gender-bender", label: "Troca de gênero", synonyms: ["gender bender", "genderswap", "gender swap", "troca de gênero", "cambio de sexo"]),
        Genre(key: "family", label: "Família", synonyms: ["family", "família", "familia", "famille"]),
        Genre(key: "animals", label: "Animais", synonyms: ["animals", "animais", "animales", "animaux"]),
        Genre(key: "ecchi", label: "Ecchi", synonyms: ["ecchi"]),
        Genre(key: "gore", label: "Gore", synonyms: ["gore"]),
        Genre(key: "manhwa", label: "Manhwa", synonyms: ["manhwa"]),
        Genre(key: "manhua", label: "Manhua", synonyms: ["manhua"]),
        Genre(key: "webtoon", label: "Webtoon", synonyms: ["webtoon", "webtoons"]),
    ]

    private static let bySynonym: [String: Genre] = {
        var map: [String: Genre] = [:]
        for genre in genres {
            for synonym in genre.synonyms { map[normalize(synonym)] = genre }
        }
        return map
    }()

    private static let labels: [String: String] = Dictionary(uniqueKeysWithValues: genres.map { ($0.key, $0.label) })

    /// Mesmo texto para "Slice-of-Life", "slice_of_life" e "Slice of Life".
    static func normalize(_ tag: String) -> String {
        ContentFilter.normalizeTag(tag)
            .replacingOccurrences(of: #"[-_/.]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"['’`]"#, with: "", options: .regularExpression)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static let lock = NSLock()
    private static var keyCache: [String: String] = [:]

    /// Chave da tag: a do gênero conhecido ou "~" + o texto normalizado.
    public static func key(for tag: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = keyCache[tag] { return cached }
        let normalized = normalize(tag)
        let key = bySynonym[normalized]?.key ?? "~" + normalized
        keyCache[tag] = key
        return key
    }

    /// Nome para mostrar de uma chave (as desconhecidas voltam com a primeira letra maiúscula).
    public static func label(for key: String) -> String {
        if let label = labels[key] { return label }
        let raw = key.hasPrefix("~") ? String(key.dropFirst()) : key
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    public static func keys(of tags: [String]) -> Set<String> {
        Set(tags.lazy.map(key(for:)).filter { $0 != "~" })
    }

    /// A obra tem todas as tags escolhidas?
    public static func matches(_ tags: [String], all required: Set<String>) -> Bool {
        required.isEmpty || required.isSubset(of: keys(of: tags))
    }

    /// Tags de uma lista de obras, das mais comuns para as menos comuns. O nome de uma tag
    /// desconhecida é a grafia que mais aparece.
    public static func counts(_ tagLists: [[String]]) -> [Count] {
        var totals: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        for tags in tagLists {
            var seen = Set<String>()
            for tag in tags {
                let key = key(for: tag)
                guard key != "~", seen.insert(key).inserted else { continue }
                totals[key, default: 0] += 1
                if labels[key] == nil { spellings[key, default: [:]][tag.trimmed, default: 0] += 1 }
            }
        }
        return totals.map { key, count in
            let spelling = spellings[key]?.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
            return Count(key: key, label: labels[key] ?? spelling ?? label(for: key), count: count)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}
