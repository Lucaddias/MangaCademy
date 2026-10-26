import Foundation

public enum HTTPError: LocalizedError {
    case badURL(String)
    case badStatus(Int)
    case blocked
    case parse(String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let url): return "URL inválida: \(url)"
        case .badStatus(let code): return "O site respondeu com erro HTTP \(code)"
        case .blocked: return "O site bloqueou o acesso (proteção anti-bot/Cloudflare)"
        case .parse(let what): return "Não foi possível ler \(what)"
        }
    }
}

/// Cliente HTTP compartilhado pelos motores de fonte.
public final class HTTPClient {
    public static let shared = HTTPClient()

    public static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 40
        config.httpMaximumConnectionsPerHost = 4
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config)
    }

    public func data(
        _ urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        userAgent: String = HTTPClient.browserUserAgent
    ) async throws -> (Data, URL) {
        guard let url = URL(string: urlString) else { throw HTTPError.badURL(urlString) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("pt-BR,pt;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: req)
        let finalURL = response.url ?? url
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 403 || http.statusCode == 503,
               let text = String(data: data.prefix(4096), encoding: .utf8),
               text.contains("cf-chl") || text.contains("Just a moment") || text.contains("challenge-platform") {
                throw HTTPError.blocked
            }
            throw HTTPError.badStatus(http.statusCode)
        }
        return (data, finalURL)
    }

    public func html(_ urlString: String, headers: [String: String] = [:]) async throws -> HTMLDocument {
        let (data, finalURL) = try await data(urlString, headers: headers)
        guard let doc = HTMLDocument(data: data, url: finalURL) else { throw HTTPError.parse("a página") }
        return doc
    }

    public func json(_ urlString: String, headers: [String: String] = [:], userAgent: String = HTTPClient.browserUserAgent) async throws -> Any {
        var allHeaders = headers
        allHeaders["Accept"] = allHeaders["Accept"] ?? "application/json, text/plain, */*"
        let (data, _) = try await data(urlString, headers: allHeaders, userAgent: userAgent)
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HTTPError.parse("a resposta JSON")
        }
    }

    public func postForm(_ urlString: String, fields: [(String, String)], headers: [String: String] = [:]) async throws -> (Data, URL) {
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        let body = fields
            .map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }
            .joined(separator: "&")
        return try await data(urlString, method: "POST", headers: allHeaders, body: Data(body.utf8))
    }

    public func postFormHTML(_ urlString: String, fields: [(String, String)], headers: [String: String] = [:]) async throws -> HTMLDocument {
        let (data, finalURL) = try await postForm(urlString, fields: fields, headers: headers)
        guard let doc = HTMLDocument(data: data, url: finalURL) else { throw HTTPError.parse("a página") }
        return doc
    }

    private static let formAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    public static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
    }

    public static func queryEncode(_ value: String) -> String {
        formEncode(value)
    }
}

// MARK: - JSON helpers

public extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }

    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
}

// MARK: - Shared parsing helpers

public enum ChapterNumberParser {
    private static let keywordRegex = try! NSRegularExpression(
        pattern: #"(?:cap[íi]tulo|cap\.?|chapter|ch\.?|chap\.?|ep[ií]s[oó]dio|episode|ep\.?|#)\s*(\d+(?:[.,]\d+)?)"#,
        options: [.caseInsensitive]
    )
    private static let numberRegex = try! NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)"#)

    /// Extrai o número do capítulo do nome ("Capítulo 64", "Vol. 2 Ch. 10.5"...). Retorna -1 se não houver.
    public static func parse(_ name: String) -> Double {
        let range = NSRange(name.startIndex..., in: name)
        if let m = keywordRegex.firstMatch(in: name, range: range), let r = Range(m.range(at: 1), in: name) {
            return Double(name[r].replacingOccurrences(of: ",", with: ".")) ?? -1
        }
        // Sem palavra-chave: ignora o volume e usa o último número
        let matches = numberRegex.matches(in: name, range: range)
        if let m = matches.last, let r = Range(m.range(at: 1), in: name) {
            return Double(name[r].replacingOccurrences(of: ",", with: ".")) ?? -1
        }
        return -1
    }
}

public enum DateParsing {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    /// Datas ISO-8601 com ou sem frações de segundo (até microssegundos, como "…23.466336+01:00").
    public static func iso(_ value: String) -> Date? {
        if let date = withFraction.date(from: value) ?? plain.date(from: value) { return date }
        let trimmed = value.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return trimmed == value ? nil : withFraction.date(from: trimmed)
    }
}

public enum StatusParser {
    /// 0: Desconhecido, 1: Em lançamento, 2: Completo, 3: Cancelado, 4: Hiato
    public static func parse(_ text: String?) -> Int {
        guard let t = text?.lowercased(), !t.isEmpty else { return 0 }
        let completed = ["completed", "completo", "completado", "concluído", "concluido", "finalizado", "finished", "terminé", "complété", "concluso", "completato", "مكتملة", "zakończone"]
        let ongoing = ["ongoing", "on going", "em lançamento", "em andamento", "lançando", "ativo", "updating", "publishing", "en curso", "en cours", "em postagem", "in corso", "publicándose", "publicandose", "مستمرة"]
        let hiatus = ["hiatus", "on hold", "pausado", "hiato", "en pause"]
        let cancelled = ["cancelled", "canceled", "cancelado", "dropped", "abandonado", "dropado"]
        if completed.contains(where: t.contains) { return 2 }
        if ongoing.contains(where: t.contains) { return 1 }
        if hiatus.contains(where: t.contains) { return 4 }
        if cancelled.contains(where: t.contains) { return 3 }
        return 0
    }
}

extension String {
    /// Caminho + query de uma URL absoluta (para guardar referências independentes do domínio).
    var urlPath: String {
        guard let comps = URLComponents(string: self) else { return self }
        var path = comps.percentEncodedPath
        if path.isEmpty { path = "/" }
        if let q = comps.percentEncodedQuery, !q.isEmpty { path += "?\(q)" }
        return path
    }

    var nilIfEmpty: String? {
        let t = trimmed
        return t.isEmpty ? nil : t
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
