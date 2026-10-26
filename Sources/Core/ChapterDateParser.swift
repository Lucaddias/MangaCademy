import Foundation

/// Datas de capítulo como os sites mostram: relativas ("há 2 horas", "2 hours ago", "hace 3 días",
/// "ontem") ou absolutas em vários formatos ("outubro 6, 2026", "06/10/2026", "2026-10-06").
/// Port do `parseChapterDate` do tema Madara do Keiyoushi, com formatos extras para os outros temas.
public enum ChapterDateParser {
    /// Retorna nil quando o texto não é uma data reconhecível (ou fica no futuro).
    public static func parse(_ text: String?, language: String = "en", now: Date = Date()) -> Date? {
        guard let raw = text?.trimmed, !raw.isEmpty else { return nil }
        let value = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let date = relative(value.lowercased(), now: now) ?? absolute(value, language: language)
        // Data no futuro = formato lido errado (ex.: dia e mês trocados)
        guard let date, date <= now.addingTimeInterval(2 * 86_400) else { return nil }
        return date
    }

    // MARK: - Relativas

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func relative(_ text: String, now: Date) -> Date? {
        let calendar = utc
        if ["today", "hoje", "hoy", "aujourd"].contains(where: text.hasPrefix) {
            return calendar.startOfDay(for: now)
        }
        if ["yesterday", "ontem", "ayer", "hier"].contains(where: text.hasPrefix) {
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        }
        // Forma curta: "1h ago", "3d ago", "2mo ago"
        if let match = compactRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let amountRange = Range(match.range(at: 1), in: text), let amount = Int(text[amountRange]),
           let unitRange = Range(match.range(at: 2), in: text), let (component, multiplier) = compactUnits[String(text[unitRange])] {
            return calendar.date(byAdding: component, value: -amount * multiplier, to: now)
        }
        let number = numberRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            .flatMap { Range($0.range, in: text) }
            .flatMap { Int(text[$0]) }
        // "an hour ago", "um dia atrás", "hace una semana"
        let amount = number ?? (relativeMarkers.contains(where: text.contains) ? 1 : nil)
        guard let amount else { return nil }
        for (regex, component, multiplier) in units where matches(regex, text) {
            return calendar.date(byAdding: component, value: -amount * multiplier, to: now)
        }
        return nil
    }

    private static let relativeMarkers = ["ago", "atrás", "atras", "hace", "há ", "il y a", "fa ", "lalu", "önce", "trước"]
    private static let numberRegex = try! NSRegularExpression(pattern: #"\d+"#)
    private static let compactRegex = try! NSRegularExpression(pattern: #"^(\d+)\s*(mo|y|w|d|h|m|s)\s+ago"#)
    private static let compactUnits: [String: (Calendar.Component, Int)] = [
        "y": (.year, 1), "mo": (.month, 1), "w": (.day, 7), "d": (.day, 1), "h": (.hour, 1), "m": (.minute, 1), "s": (.second, 1),
    ]

    /// Palavras não podem vir depois de uma letra: senão "ay" casa dentro de "mayıs" e "may".
    private static func words(_ list: [String]) -> NSRegularExpression {
        let alternatives = list.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(pattern: #"(?<!\p{L})(?:"# + alternatives + ")")
    }

    private static let units: [(NSRegularExpression, Calendar.Component, Int)] = [
        (words(["year", "año", "ano", "ans", "năm", "yıl", "tahun", "anno", "anni", "سنة", "سنوات"]), .year, 1),
        (words(["month", "mês", "mes", "mois", "tháng", "ay", "bulan", "mese", "mesi", "شهر", "أشهر", "شهور"]), .month, 1),
        (words(["week", "semana", "semaine", "tuần", "hafta", "minggu", "settiman", "أسبوع", "أسابيع"]), .day, 7),
        (words(["day", "día", "dia", "jour", "hari", "gün", "ngày", "giorn", "أيام", "يوم", "天"]), .day, 1),
        (words(["hour", "hora", "heure", "jam", "saat", "giờ", "ore", "ora", "ساعة", "ساعات", "小时"]), .hour, 1),
        (words(["minute", "minuto", "min", "menit", "dakika", "phút", "دقيقة", "دقائق"]), .minute, 1),
        (words(["second", "segundo", "sec", "detik", "giây", "ثانية", "ثوان"]), .second, 1),
    ]

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Absolutas

    private static let patterns = [
        "MMMM d, yyyy", "MMM d, yyyy", "MMMM d yyyy", "MMM d yyyy",
        "d 'de' MMMM 'de' yyyy", "d 'de' MMMM, yyyy", "d MMMM yyyy", "d MMMM, yyyy", "d MMM yyyy", "d MMM, yyyy",
        "dd/MM/yyyy", "dd-MM-yyyy", "dd.MM.yyyy", "yyyy-MM-dd", "yyyy/MM/dd", "dd/MM/yy",
    ]

    private static let lock = NSLock()
    private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ pattern: String, locale: String) -> DateFormatter {
        let key = "\(locale)|\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        formatter.isLenient = false
        formatters[key] = formatter
        return formatter
    }

    private static func absolute(_ text: String, language: String) -> Date? {
        if let iso = DateParsing.iso(text) { return iso }
        // "Oct 6th, 2026" -> "Oct 6, 2026"
        let cleaned = text.replacingOccurrences(of: #"(\d)(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
        let sourceLocale = language.replacingOccurrences(of: "-", with: "_")
        var locales = [sourceLocale, "en_US_POSIX", "pt_BR", "es_ES", "fr_FR"]
        locales = locales.enumerated().filter { !locales[..<$0.offset].contains($0.element) }.map(\.element)
        // Nos EUA o mês vem antes do dia
        let ordered = LanguageCode.base(language) == "en" ? ["MM/dd/yyyy"] + patterns : patterns
        for locale in locales {
            for pattern in ordered {
                if let date = formatter(pattern, locale: locale).date(from: cleaned) { return date }
            }
        }
        return nil
    }
}
