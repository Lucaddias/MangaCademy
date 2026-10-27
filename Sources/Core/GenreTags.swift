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
        /// Gênero da lista fixa (não uma tag solta de uma fonte).
        public var isGenre: Bool { !key.hasPrefix("~") }
    }

    struct Genre {
        let key: String
        let label: String
        let synonyms: [String]
    }

    // Sinônimos com ou sem acento: tudo passa por `normalize` antes de comparar.
    // Só entra sinônimo que quem escolhe a tag aceitaria em todos os resultados. Ficam de fora:
    // falsos cognatos ("roman" em francês e alemão, "роман" e "powieść" querem dizer livro, não romance),
    // tags compostas (ラブコメ, 로맨스 판타지) e as ambíguas (穿越 é isekai ou viagem no tempo; ロボット nem sempre é mecha)
    static let genres: [Genre] = [
        Genre(key: "action", label: "Ação", synonyms: ["action", "ação", "acción", "aksi", "azione", "aksiyon", "hành động", "actie", "アクション", "动作", "動作", "액션", "экшен", "экшн", "боевик", "أكشن", "اكشن", "แอ็คชั่น", "แอคชั่น", "akcja"]),
        Genre(key: "adventure", label: "Aventura", synonyms: ["adventure", "aventura", "aventure", "petualangan", "avventura", "macera", "phiêu lưu", "abenteuer", "冒険", "冒险", "冒險", "모험", "приключения", "مغامرة", "مغامرات", "ผจญภัย", "przygoda", "przygodowe"]),
        Genre(key: "comedy", label: "Comédia", synonyms: ["comedy", "comédia", "comedia", "comédie", "komedi", "commedia", "hài hước", "komödie", "コメディ", "コメディー", "ギャグ", "搞笑", "喜剧", "喜劇", "코미디", "개그", "комедия", "كوميدي", "كوميديا", "ตลก", "คอมเมดี้", "komedia"]),
        Genre(key: "drama", label: "Drama", synonyms: ["drama", "drame", "dram", "ドラマ", "剧情", "劇情", "드라마", "драма", "دراما", "ดราม่า", "dramat"]),
        Genre(key: "fantasy", label: "Fantasia", synonyms: ["fantasy", "fantasia", "fantasía", "fantastique", "fantasi", "fantastico", "fantastik", "kỳ ảo", "fantasie", "ファンタジー", "奇幻", "魔幻", "판타지", "фэнтези", "фентези", "فانتازيا", "خيال", "แฟนตาซี"]),
        Genre(key: "romance", label: "Romance", synonyms: ["romance", "romântico", "romántico", "romantic", "romansa", "romantik", "romantizm", "tình cảm", "ngôn tình", "romantique", "romântica", "romántica", "恋愛", "ロマンス", "恋爱", "戀愛", "爱情", "愛情", "言情", "로맨스", "романтика", "رومانسي", "رومانسية", "رومانس", "โรแมนติก", "โรแมนซ์", "romans", "romantyczne"]),
        Genre(key: "school", label: "Escolar", synonyms: ["school life", "school", "schoollife", "vida escolar", "escolar", "colegial", "escola", "escuela", "colegio", "sekolah", "kehidupan sekolah", "vie scolaire", "scolaire", "okul", "học đường", "vita scolastica", "学園", "学校", "スクールライフ", "校园", "校園", "학원", "학교", "школа", "школьная жизнь", "مدرسي", "مدرسة", "الحياة المدرسية", "โรงเรียน", "ชีวิตในโรงเรียน", "szkoła", "życie szkolne"]),
        // Nos sites russos "фантастика" é ficção científica; fantasia é "фэнтези"
        Genre(key: "scifi", label: "Ficção científica", synonyms: ["sci-fi", "scifi", "sci fi", "science fiction", "ficção científica", "ciencia ficción", "ciência ficção", "fiksi ilmiah", "fantascienza", "bilim kurgu", "khoa học viễn tưởng", "sf", "サイエンスフィクション", "科幻", "공상과학", "научная фантастика", "фантастика", "خيال علمي", "ไซไฟ", "fantastyka naukowa"]),
        Genre(key: "slice-of-life", label: "Slice of life", synonyms: ["slice of life", "cotidiano", "vida cotidiana", "vida diária", "recuentos de la vida", "tranche de vie", "kehidupan sehari-hari", "günlük yaşam", "日常", "일상", "повседневность", "شريحة من الحياة", "ชีวิตประจำวัน", "okruchy życia"]),
        Genre(key: "horror", label: "Terror", synonyms: ["horror", "terror", "horreur", "horor", "kinh dị", "orrore", "ホラー", "恐怖", "호러", "공포", "ужасы", "хоррор", "رعب", "สยองขวัญ"]),
        Genre(key: "mystery", label: "Mistério", synonyms: ["mystery", "mistério", "misterio", "mystère", "misteri", "gizem", "bí ẩn", "mistero", "ミステリー", "ミステリ", "推理", "悬疑", "懸疑", "미스터리", "추리", "детектив", "غموض", "ลึกลับ", "tajemnica"]),
        Genre(key: "thriller", label: "Suspense", synonyms: ["thriller", "suspense", "suspenso", "suspens", "gerilim", "サスペンス", "スリラー", "惊悚", "驚悚", "스릴러", "триллер", "إثارة", "تشويق", "ระทึกขวัญ"]),
        Genre(key: "psychological", label: "Psicológico", synonyms: ["psychological", "psicológico", "psicológica", "psychologique", "psikologis", "psikolojik", "tâm lý", "psicologico", "心理", "심리", "психология", "психологическое", "نفسي", "نفسية", "จิตวิทยา", "psychologiczne"]),
        Genre(key: "supernatural", label: "Sobrenatural", synonyms: ["supernatural", "sobrenatural", "surnaturel", "supranatural", "doğaüstü", "siêu nhiên", "soprannaturale", "超自然", "灵异", "靈異", "초자연", "сверхъестественное", "мистика", "خارق للطبيعة", "เหนือธรรมชาติ", "nadprzyrodzone"]),
        Genre(key: "isekai", label: "Isekai", synonyms: ["isekai", "outro mundo", "otro mundo", "another world", "other world", "異世界", "异世界", "이세계", "исекай", "другой мир", "ايسكاي", "إيسكاي", "عالم آخر", "ต่างโลก"]),
        Genre(key: "reincarnation", label: "Reencarnação", synonyms: ["reincarnation", "reencarnação", "reencarnación", "réincarnation", "reinkarnasi", "transmigration", "transmigração", "rebirth", "renascimento", "転生", "转生", "轉生", "重生", "환생", "реинкарнация", "перерождение", "تناسخ", "إعادة التجسد", "เกิดใหม่", "reinkarnacja"]),
        Genre(key: "regression", label: "Regressão", synonyms: ["regression", "regressão", "regresión", "regressor", "회귀", "регрессия", "regresja"]),
        Genre(key: "time-travel", label: "Viagem no tempo", synonyms: ["time travel", "viagem no tempo", "viaje en el tiempo", "voyage temporel", "タイムトラベル", "タイムスリップ", "时间旅行", "時間旅行", "시간여행", "путешествия во времени", "السفر عبر الزمن", "เดินทางข้ามเวลา", "podróże w czasie"]),
        Genre(key: "martial-arts", label: "Artes marciais", synonyms: ["martial arts", "artes marciais", "artes marciales", "arts martiaux", "bela diri", "võ thuật", "dövüş sanatları", "武術", "武术", "格闘技", "무술", "боевые искусства", "فنون قتالية", "ศิลปะการต่อสู้", "sztuki walki"]),
        Genre(key: "murim", label: "Murim", synonyms: ["murim", "무림", "무협", "мурим"]),
        Genre(key: "wuxia", label: "Wuxia / Cultivo", synonyms: ["wuxia", "xianxia", "xuanhuan", "cultivation", "cultivo", "cultivação", "武侠", "武俠", "仙侠", "仙俠", "玄幻", "修真", "修仙", "уся", "сянься", "культивация", "kultywacja"]),
        Genre(key: "sports", label: "Esportes", synonyms: ["sports", "sport", "esportes", "esporte", "deportes", "deporte", "olahraga", "spor", "thể thao", "スポーツ", "运动", "運動", "体育", "體育", "스포츠", "спорт", "رياضة", "رياضي", "رياضية", "กีฬา", "sportowe"]),
        Genre(key: "historical", label: "Histórico", synonyms: ["historical", "histórico", "histórica", "historique", "sejarah", "tarihi", "lịch sử", "歴史", "历史", "歷史", "역사", "사극", "история", "исторический", "تاريخي", "ประวัติศาสตร์", "ย้อนยุค", "historyczne"]),
        // Só os nomes de demografia: 少年, 少女 e 青年 sozinhos também marcam o personagem (menino, menina, rapaz)
        Genre(key: "shounen", label: "Shounen", synonyms: ["shounen", "shonen", "shōnen", "少年漫画", "少年漫畫", "сёнэн", "сёнен", "شونين", "โชเน็น"]),
        Genre(key: "shoujo", label: "Shoujo", synonyms: ["shoujo", "shojo", "shōjo", "少女漫画", "少女漫畫", "сёдзё", "сёдзе", "شوجو", "โชโจ"]),
        Genre(key: "seinen", label: "Seinen", synonyms: ["seinen", "青年漫画", "青年漫畫", "сэйнэн", "сейнен", "سينين"]),
        Genre(key: "josei", label: "Josei", synonyms: ["josei", "女性漫画", "女性漫畫", "дзёсэй", "дзёсей", "جوسي"]),
        Genre(key: "harem", label: "Harém", synonyms: ["harem", "harém", "ハーレム", "后宫", "後宮", "하렘", "гарем", "حريم", "ฮาเร็ม"]),
        Genre(key: "reverse-harem", label: "Harém reverso", synonyms: ["reverse harem", "harém reverso", "harem inverso", "逆ハーレム", "逆后宫", "역하렘", "обратный гарем", "حريم عكسي", "odwrócony harem"]),
        Genre(key: "mecha", label: "Mecha", synonyms: ["mecha", "mechas", "メカ", "机甲", "機甲", "메카", "меха", "ميكا"]),
        Genre(key: "magic", label: "Magia", synonyms: ["magic", "magia", "magie", "sihir", "ma pháp", "魔法", "마법", "магия", "سحر", "เวทมนตร์"]),
        Genre(key: "tragedy", label: "Tragédia", synonyms: ["tragedy", "tragédia", "tragedia", "tragédie", "trajedi", "bi kịch", "悲劇", "悲剧", "비극", "трагедия", "مأساة", "مأساوي", "โศกนาฏกรรม"]),
        Genre(key: "military", label: "Militar", synonyms: ["military", "militar", "militaire", "militer", "askeri", "quân đội", "軍事", "ミリタリー", "军事", "밀리터리", "군사", "военный", "военное", "عسكري", "ทหาร", "wojskowe"]),
        Genre(key: "music", label: "Música", synonyms: ["music", "música", "musique", "musik", "müzik", "âm nhạc", "音楽", "音乐", "音樂", "음악", "музыка", "موسيقى", "موسيقي", "ดนตรี", "muzyka"]),
        Genre(key: "cooking", label: "Culinária", synonyms: ["cooking", "culinária", "cocina", "cuisine", "gourmet", "food", "comida", "memasak", "料理", "グルメ", "美食", "요리", "кулинария", "طبخ", "طهي", "ทำอาหาร", "อาหาร", "gotowanie", "kulinaria"]),
        Genre(key: "boys-love", label: "Boys' Love", synonyms: ["boys' love", "boys love", "bl", "yaoi", "shounen ai", "shonen ai", "ボーイズラブ", "やおい", "耽美", "яой", "сёнэн-ай", "ياوي", "วาย"]),
        Genre(key: "girls-love", label: "Girls' Love", synonyms: ["girls' love", "girls love", "gl", "yuri", "shoujo ai", "shojo ai", "百合", "ガールズラブ", "백합", "юри", "сёдзё-ай", "يوري", "ยูริ"]),
        Genre(key: "superhero", label: "Super-heróis", synonyms: ["superhero", "super hero", "superheroes", "super herói", "super-herói", "super heróis", "superhéroes", "スーパーヒーロー", "超级英雄", "超級英雄", "슈퍼히어로", "супергерои", "أبطال خارقين", "ซูเปอร์ฮีโร่", "superbohaterowie"]),
        Genre(key: "superpower", label: "Superpoderes", synonyms: ["super power", "super powers", "superpower", "superpowers", "superpoderes", "super poderes", "超能力", "异能", "異能", "초능력", "이능력", "сверхспособности", "суперсила", "قوى خارقة", "พลังพิเศษ", "supermoce"]),
        Genre(key: "overpowered", label: "Protagonista OP", synonyms: ["overpowered", "op mc", "mc op", "protagonista op", "protagonista overpowered", "먼치킨"]),
        Genre(key: "revenge", label: "Vingança", synonyms: ["revenge", "vingança", "venganza", "vengeance", "balas dendam", "復讐", "复仇", "復仇", "복수", "месть", "انتقام", "แก้แค้น", "zemsta"]),
        Genre(key: "villainess", label: "Vilã", synonyms: ["villainess", "vilã", "villana", "悪役令嬢", "恶役千金", "惡役千金", "악녀", "злодейка"]),
        Genre(key: "zombies", label: "Zumbis", synonyms: ["zombies", "zombie", "zumbi", "zumbis", "zombis", "ゾンビ", "丧尸", "喪屍", "좀비", "зомби", "زومبي", "ซอมบี้"]),
        Genre(key: "monsters", label: "Monstros", synonyms: ["monsters", "monster", "monstros", "monstruos", "monstres", "モンスター", "魔物", "怪物", "몬스터", "괴물", "монстры", "وحوش", "มอนสเตอร์", "สัตว์ประหลาด", "potwory"]),
        Genre(key: "demons", label: "Demônios", synonyms: ["demons", "demon", "demônios", "demônio", "demonios", "demonio", "悪魔", "恶魔", "惡魔", "악마", "демоны", "شياطين", "ปีศาจ", "demony"]),
        Genre(key: "vampires", label: "Vampiros", synonyms: ["vampire", "vampires", "vampiro", "vampiros", "吸血鬼", "ヴァンパイア", "뱀파이어", "вампиры", "مصاصي دماء", "مصاص دماء", "แวมไพร์", "wampiry"]),
        Genre(key: "games", label: "Jogos", synonyms: ["game", "games", "jogo", "jogos", "video games", "videojuegos", "juegos", "ゲーム", "游戏", "遊戲", "게임", "игры", "видеоигры", "ألعاب", "เกม", "gry"]),
        Genre(key: "system", label: "Sistema", synonyms: ["system", "sistema", "系统", "系統", "시스템", "система", "نظام", "ระบบ"]),
        Genre(key: "crime", label: "Crime / Policial", synonyms: ["crime", "crimen", "criminal", "police", "policial", "policía", "polícia", "犯罪", "범죄", "криминал", "جريمة", "อาชญากรรม", "kryminał"]),
        Genre(key: "medical", label: "Médico", synonyms: ["medical", "médico", "medicina", "医療", "医疗", "醫療", "의학", "메디컬", "медицина", "طبي", "การแพทย์", "medyczne"]),
        Genre(key: "apocalypse", label: "Pós-apocalíptico", synonyms: ["post-apocalyptic", "post apocalyptic", "apocalypse", "apocalipse", "pós-apocalíptico", "apocalíptico", "postapocalíptico", "終末", "ポストアポカリプス", "末世", "末日", "아포칼립스", "종말", "постапокалипсис", "апокалипсис", "نهاية العالم", "วันสิ้นโลก", "postapokaliptyczne", "apokalipsa"]),
        Genre(key: "survival", label: "Sobrevivência", synonyms: ["survival", "sobrevivência", "supervivencia", "survie", "サバイバル", "生存", "서바이벌", "생존", "выживание", "نجاة", "เอาชีวิตรอด", "przetrwanie"]),
        Genre(key: "gender-bender", label: "Troca de gênero", synonyms: ["gender bender", "genderswap", "gender swap", "troca de gênero", "cambio de sexo", "性転換", "性转", "性轉", "성전환", "гендерная интрига", "смена пола", "สลับเพศ", "zmiana płci"]),
        Genre(key: "family", label: "Família", synonyms: ["family", "família", "familia", "famille", "家族", "家庭", "가족", "семья", "عائلي", "عائلة", "ครอบครัว", "rodzina"]),
        Genre(key: "animals", label: "Animais", synonyms: ["animals", "animais", "animales", "animaux", "動物", "动物", "동물", "животные", "حيوانات", "สัตว์", "zwierzęta"]),
        Genre(key: "ecchi", label: "Ecchi", synonyms: ["ecchi", "этти", "эччи", "إيتشي", "ايتشي"]),
        Genre(key: "gore", label: "Gore", synonyms: ["gore", "血腥", "고어"]),
        Genre(key: "manhwa", label: "Manhwa", synonyms: ["manhwa", "манхва", "مانهوا", "มังฮวา"]),
        Genre(key: "manhua", label: "Manhua", synonyms: ["manhua", "маньхуа", "مانها", "มังฮัว"]),
        Genre(key: "webtoon", label: "Webtoon", synonyms: ["webtoon", "webtoons", "웹툰", "вебтун", "ويبتون", "เว็บตูน"]),
    ]

    private static let bySynonym: [String: Genre] = {
        var map: [String: Genre] = [:]
        for genre in genres {
            for synonym in genre.synonyms { map[normalize(synonym)] = genre }
        }
        return map
    }()

    private static let labels: [String: String] = Dictionary(uniqueKeysWithValues: genres.map { ($0.key, $0.label) })

    /// Sinônimos já normalizados de cada gênero, para a busca por pedaço ("ロマ" acha Romance).
    private static let searchTerms: [String: [String]] = Dictionary(uniqueKeysWithValues: genres.map { ($0.key, $0.synonyms.map(normalize)) })

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

    /// A busca do seletor acha a tag? Pelo nome mostrado ou, nos gêneros, por um pedaço de qualquer
    /// sinônimo: "romantic", "恋愛" e "романт" acham Romance.
    public static func search(_ query: String, matches tag: Count) -> Bool {
        if tag.label.localizedStandardContains(query) || key(for: query) == tag.key { return true }
        let normalized = normalize(query)
        guard !normalized.isEmpty, let terms = searchTerms[tag.key] else { return false }
        return terms.contains { $0.contains(normalized) }
    }

    /// Tags de uma lista de obras: primeiro os gêneros da lista fixa, depois as outras tags; em cada
    /// grupo, das mais comuns para as menos comuns. O nome de uma tag desconhecida é a grafia que mais
    /// aparece. Com `includeAllGenres`, os gêneros que nenhuma obra tem entram com contagem zero.
    public static func counts(_ tagLists: [[String]], includeAllGenres: Bool = false) -> [Count] {
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
        if includeAllGenres {
            for genre in genres where totals[genre.key] == nil { totals[genre.key] = 0 }
        }
        return totals.map { key, count in
            let spelling = spellings[key]?.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
            return Count(key: key, label: labels[key] ?? spelling ?? label(for: key), count: count)
        }
        .sorted { lhs, rhs in
            if lhs.isGenre != rhs.isGenre { return lhs.isGenre }
            return lhs.count != rhs.count ? lhs.count > rhs.count : lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }
}
