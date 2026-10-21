import Foundation

/// Compara títulos em idiomas diferentes pelo significado das palavras:
/// "Ilusão de Amor: Superstar", "El amor es una ilusión Superstar" e
/// "Love is an Illusion! - Superstar" viram o mesmo conjunto {love, illusion, superstar}.
public enum TitleConcepts {
    /// Conjunto de conceitos de um título (sem artigos/preposições, traduzido para inglês).
    public static func tokens(_ title: String) -> Set<String> {
        var out = Set<String>()
        for raw in TitleKey.normalize(title).split(separator: " ") {
            var word = String(raw)
            if stopwords.contains(word) { continue }
            if let mapped = dictionary[word] {
                out.insert(mapped)
                continue
            }
            // Plural simples: "classes" → "classe", "hunters" → "hunter"
            if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") {
                word.removeLast()
                if stopwords.contains(word) { continue }
                if let mapped = dictionary[word] {
                    out.insert(mapped)
                    continue
                }
            }
            // Cognatos: "classe" ≈ "class", "planeta" ≈ "planet", "ultimato" ≈ "ultimate"
            if word.count >= 5, let last = word.last, "aeo".contains(last) {
                word.removeLast()
            }
            out.insert(word)
        }
        return out
    }

    /// Conceito vindo do vocabulário comum (amor, rei, torre...). Títulos feitos só dessas
    /// palavras pedem uma confirmação extra (capa parecida) antes de serem fundidos.
    public static func isCommon(_ token: String) -> Bool {
        concepts.contains(token)
    }

    /// Índice de Jaccard entre dois conjuntos de conceitos.
    public static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let shared = a.intersection(b).count
        return Double(shared) / Double(a.count + b.count - shared)
    }

    /// Um conceito distintivo o bastante para confirmar uma suspeita (capa parecida, por exemplo).
    public static func isDistinctive(_ token: String) -> Bool {
        token.count >= 4 || token.allSatisfy(\.isNumber) || token.unicodeScalars.contains { $0.value > 0x2E80 }
    }

    // MARK: - Vocabulário

    private static let stopwords: Set<String> = [
        // inglês
        "a", "an", "the", "of", "and", "to", "in", "on", "at", "is", "are", "was", "be", "as", "by", "for", "from",
        "with", "my", "your", "his", "her", "its", "our", "their", "i", "me", "you", "he", "she", "it", "we", "they",
        "this", "that", "s", "t", "im", "ive", "will", "into",
        // português
        "o", "os", "as", "um", "uma", "uns", "umas", "de", "do", "da", "dos", "das", "e", "em", "no", "na", "nos", "nas",
        "ao", "aos", "com", "por", "para", "pra", "pelo", "pela", "meu", "minha", "meus", "minhas", "seu", "sua", "seus",
        "suas", "eu", "ele", "ela", "que", "se", "esse", "essa", "este", "esta", "isso", "isto", "sou", "foi", "desde",
        // espanhol
        "el", "la", "lo", "los", "las", "un", "una", "unos", "unas", "del", "al", "y", "en", "con", "mi", "mis", "tu", "su", "sus", "yo",
        "es", "soy",
        // francês
        "le", "les", "une", "des", "du", "et", "au", "aux", "ma", "mon", "mes", "est",
    ]

    /// Palavras frequentes em títulos de mangá/manhwa (pt/es/fr → inglês).
    private static let dictionary: [String: String] = {
        let groups: [String: [String]] = [
            "love": ["amor", "amour", "love"],
            "illusion": ["ilusao", "ilusion", "illusion"],
            "god": ["deus", "dios", "dieu"],
            "goddess": ["deusa", "diosa", "deesse"],
            "king": ["rei", "rey", "roi"],
            "queen": ["rainha", "reina", "reine"],
            "prince": ["principe", "prince"],
            "princess": ["princesa", "princesse"],
            "emperor": ["imperador", "emperador", "empereur"],
            "empress": ["imperatriz", "emperatriz", "imperatrice"],
            "empire": ["imperio", "empire"],
            "duke": ["duque", "duc"],
            "duchess": ["duquesa", "duchesse"],
            "knight": ["cavaleiro", "caballero", "chevalier"],
            "warrior": ["guerreiro", "guerrero", "guerrier"],
            "hero": ["heroi", "heroe", "heros"],
            "heroine": ["heroina", "heroine"],
            "villain": ["vilao", "villano", "mechant"],
            "villainess": ["villana", "vila", "malvada"],
            "demon": ["demonio", "demon", "demonios"],
            "devil": ["diabo", "diablo", "diable"],
            "angel": ["anjo", "angel", "ange"],
            "dragon": ["dragao", "dragon"],
            "mage": ["mago", "maga", "mage"],
            "magic": ["magia", "magie", "magico", "magica"],
            "sorcerer": ["feiticeiro", "hechicero", "sorcier"],
            "witch": ["bruxa", "bruja", "sorciere"],
            "hunter": ["cacador", "cazador", "chasseur"],
            "sword": ["espada", "epee"],
            "swordsman": ["espadachim", "espadachin"],
            "level": ["nivel", "niveis", "niveles", "niveau"],
            "system": ["sistema", "systeme"],
            "player": ["jogador", "jugador", "joueur"],
            "game": ["jogo", "juego", "jeu"],
            "tower": ["torre", "tour"],
            "world": ["mundo", "monde"],
            "life": ["vida", "vie"],
            "death": ["morte", "muerte", "mort"],
            "dead": ["morto", "muerto"],
            "blood": ["sangue", "sangre", "sang"],
            "return": ["retorno", "regreso", "volta", "retour"],
            "regression": ["regressao", "regresion"],
            "regressor": ["regressor", "regresor"],
            "reincarnation": ["reencarnacao", "reencarnacion", "reincarnation"],
            "reincarnated": ["reencarnado", "reencarnada", "reincarne"],
            "rebirth": ["renascimento", "renacimiento", "renaissance"],
            "reborn": ["renascido", "renascida", "renacido", "renacida"],
            "academy": ["academia", "academie"],
            "school": ["escola", "escuela", "ecole", "colegio"],
            "daughter": ["filha", "hija", "fille"],
            "son": ["filho", "hijo", "fils"],
            "brother": ["irmao", "hermano", "frere"],
            "sister": ["irma", "hermana", "soeur"],
            "mom": ["mae", "madre", "mere", "mama", "mamae", "mother", "mom", "mum"],
            "dad": ["pai", "padre", "pere", "papa", "papai", "father", "dad"],
            "uncle": ["tio", "oncle"],
            "aunt": ["tia", "tante"],
            "husband": ["marido", "esposo", "mari"],
            "wife": ["esposa", "femme"],
            "bride": ["noiva", "novia", "mariee"],
            "marriage": ["casamento", "matrimonio", "boda", "mariage"],
            "contract": ["contrato", "contrat"],
            "superstar": ["superestrela", "superestrella", "superstar"],
            "star": ["estrela", "estrella", "etoile"],
            "moon": ["lua", "luna", "lune"],
            "sun": ["sol", "soleil"],
            "night": ["noite", "noche", "nuit"],
            "heart": ["coracao", "corazon", "coeur"],
            "end": ["fim", "fin"],
            "beginning": ["comeco", "comienzo", "inicio", "debut"],
            "after": ["depois", "despues", "apres"],
            "before": ["antes", "avant"],
            "last": ["ultimo", "ultima", "dernier", "derniere"],
            "first": ["primeiro", "primeira", "primero", "primera", "premier", "premiere"],
            "strongest": ["forte", "fuerte", "mais forte", "strongest"],
            "power": ["poder", "pouvoir"],
            "secret": ["segredo", "secreto"],
            "curse": ["maldicao", "maldicion", "malediction"],
            "cursed": ["amaldicoado", "amaldicoada", "maldito", "maldita", "maudit"],
            "legend": ["lenda", "leyenda", "legende"],
            "legendary": ["lendario", "lendaria", "legendario", "legendaria", "legendaire"],
            "master": ["mestre", "maestro", "maitre"],
            "disciple": ["discipulo", "disciple"],
            "student": ["aluno", "aluna", "alumno", "alumna", "estudante", "estudiante", "etudiant"],
            "teacher": ["professor", "professora", "profesor", "profesora"],
            "monster": ["monstro", "monstruo", "monstre"],
            "infinite": ["infinito", "infinita", "infini"],
            "eternal": ["eterno", "eterna", "eternel"],
            "chaos": ["caos"],
            "fate": ["destino", "destin"],
            "shadow": ["sombra", "ombre"],
            "dark": ["escuro", "escura", "oscuro", "oscura", "sombre"],
            "darkness": ["escuridao", "oscuridad", "tenebres"],
            "light": ["luz", "lumiere"],
            "fire": ["fogo", "fuego", "feu"],
            "ice": ["gelo", "hielo", "glace"],
            "hell": ["inferno", "infierno", "enfer"],
            "war": ["guerra", "guerre"],
            "battle": ["batalha", "batalla", "bataille"],
            "assassin": ["assassino", "assassina", "asesino", "asesina"],
            "thief": ["ladrao", "ladron", "voleur"],
            "doctor": ["medico", "medica", "doutor", "doctora"],
            "guide": ["guia", "guide"],
            "survival": ["sobrevivencia", "supervivencia", "survie"],
            "family": ["familia", "famille"],
            "cat": ["gato", "gata", "chat"],
            "dog": ["cachorro", "perro", "chien"],
            "wolf": ["lobo", "loup"],
            "fox": ["raposa", "zorro", "renard"],
            "flower": ["flor", "fleur"],
            "baby": ["bebe"],
            "child": ["crianca", "nino", "nina", "enfant"],
            "boy": ["menino", "garoto", "chico", "garcon"],
            "girl": ["menina", "garota", "chica", "fille"],
            "man": ["homem", "hombre", "homme"],
            "woman": ["mulher", "mujer"],
            "lord": ["senhor", "senor", "seigneur"],
            "lady": ["senhora", "senora", "dama", "dame"],
            "rich": ["rico", "rica", "riche"],
            "new": ["novo", "nova", "nuevo", "nueva", "nouveau", "nouvelle"],
            "age": ["idade", "edad", "ano", "anos", "years", "year", "age", "ans", "an"],
            "season": ["temporada", "saison"],
            "part": ["parte", "partie"],
            "only": ["so", "somente", "apenas", "solamente"],
            "genius": ["genio", "genie", "prodigio"],
            "trash": ["lixo", "basura"],
            "count": ["conde", "comte"],
            "disaster": ["desastre", "catastrofe"],
            "calamity": ["calamidade", "calamidad"],
            "class": ["classe", "clase", "class"],
            "rank": ["rank", "ranque", "rango"],
            "dungeon": ["masmorra", "mazmorra", "donjon"],
            "slave": ["escravo", "escrava", "esclavo", "esclava"],
            "beast": ["besta", "bestia", "fera"],
            "ghost": ["fantasma"],
            "spirit": ["espirito", "espiritu"],
            "soul": ["alma"],
            "body": ["corpo", "cuerpo"],
            "eye": ["olho", "olhos", "ojo", "ojos"],
            "hand": ["mao", "maos", "mano", "manos"],
            "time": ["tempo", "tiempo", "temps"],
            "day": ["dia", "jour"],
            "path": ["caminho", "camino", "chemin"],
            "road": ["estrada", "carretera"],
            "sky": ["ceu", "cielo", "ciel"],
            "sea": ["mar", "mer"],
            "mountain": ["montanha", "montana", "montagne"],
            "city": ["cidade", "ciudad", "ville"],
            "house": ["casa", "maison"],
            "palace": ["palacio", "palais"],
            "castle": ["castelo", "castillo", "chateau"],
            "kingdom": ["reino", "royaume"],
            "villa": ["mansao", "mansion"],
            "servant": ["servo", "serva", "sirviente"],
            "maid": ["empregada", "criada", "doncella"],
            "butler": ["mordomo", "mayordomo"],
            "chef": ["cozinheiro", "cocinero", "chef"],
            "idol": ["idolo", "idola"],
            "actor": ["ator", "atriz", "actriz"],
            "singer": ["cantor", "cantora", "cantante"],
            "boss": ["chefe", "jefe"],
            "ceo": ["presidente", "diretor"],
            "secretary": ["secretaria", "secretario"],
            "office": ["escritorio", "oficina"],
            "kiss": ["beijo", "beso", "baiser"],
            "tears": ["lagrimas", "lagrima", "larmes"],
            "flame": ["chama", "llama"],
            "lightning": ["relampago", "raio", "rayo"],
            "storm": ["tempestade", "tormenta", "tempete"],
            "snow": ["neve", "nieve", "neige"],
            "winter": ["inverno", "invierno", "hiver"],
            "summer": ["verao", "verano", "ete"],
            "spring": ["primavera", "printemps"],
            "autumn": ["outono", "otono", "automne"],
            "black": ["preto", "preta", "negro", "negra", "noir", "noire"],
            "white": ["branco", "branca", "blanco", "blanca", "blanc", "blanche"],
            "red": ["vermelho", "vermelha", "rojo", "roja", "rouge"],
            "blue": ["azul", "bleu"],
            "golden": ["dourado", "dourada", "dorado", "dorada", "ouro", "oro"],
            "silver": ["prata", "plata", "argent"],
            "great": ["grande", "gran"],
            "small": ["pequeno", "pequena", "petit", "petite"],
            "young": ["jovem", "joven", "jeune"],
            "old": ["velho", "velha", "viejo", "vieja"],
            "beautiful": ["linda", "lindo", "bela", "belo", "bonita", "bonito", "belle"],
            "ugly": ["feio", "feia", "feo", "fea"],
            "lazy": ["preguicoso", "preguicosa", "perezoso", "perezosa"],
            "evil": ["mal", "maligno", "maligna", "malvado"],
            "pure": ["puro", "pura"],
            "true": ["verdadeiro", "verdadeira", "verdadero", "verdadera", "vrai"],
            "fake": ["falso", "falsa", "faux"],
            "hidden": ["oculto", "oculta", "escondido", "escondida"],
            "forbidden": ["proibido", "proibida", "prohibido", "prohibida", "interdit"],
            "crazy": ["louco", "louca", "loco", "loca", "fou"],
            "invincible": ["invencivel", "invencible"],
            "immortal": ["imortal", "inmortal"],
            "supreme": ["supremo", "suprema"],
            "absolute": ["absoluto", "absoluta"],
            "martial": ["marcial", "marciais", "marciales"],
            "arts": ["artes", "arte"],
            "sect": ["seita", "secta"],
            "clan": ["cla", "clan"],
            "heaven": ["paraiso", "cielos"],
            "heavenly": ["celestial"],
            "returned": ["retornado", "retornada", "regresado", "regresada"],
            "returns": ["retorna", "regresa", "volve", "volta"],
            "transmigrated": ["transmigrado", "transmigrada"],
            "possessed": ["possuido", "possuida", "poseido", "poseida"],
            "obsessed": ["obcecado", "obcecada", "obsesionado", "obsesionada"],
            "tyrant": ["tirano", "tirana", "tyran"],
            "beloved": ["amado", "amada", "querido", "querida"],
            "lover": ["amante", "namorado", "namorada"],
            "fiance": ["noivo", "novio", "prometido", "prometida"],
            "divorce": ["divorcio"],
            "revenge": ["vinganca", "venganza", "vengeance"],
            "betrayal": ["traicao", "traicion", "trahison"],
            "mercenary": ["mercenario", "mercenaria"],
            "soldier": ["soldado", "soldat"],
            "general": ["general"],
            "commander": ["comandante"],
        ]
        var map: [String: String] = [:]
        for (concept, words) in groups.sorted(by: { $0.key < $1.key }) {
            for word in words where !word.contains(" ") && map[word] == nil {
                map[word] = concept
            }
        }
        return map
    }()

    private static let concepts = Set(dictionary.values)
}
