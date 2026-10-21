import Foundation
import libxml2

/// Parser HTML tolerante (libxml2 do próprio iOS) com consultas XPath.
/// Substitui o Jsoup usado pelas extensões Kotlin do Keiyoushi.
public final class HTMLDocument {
    fileprivate let doc: htmlDocPtr
    public let url: URL?

    private static let parserInitialized: Bool = {
        xmlInitParser()
        return true
    }()

    public init?(data: Data, url: URL?) {
        _ = Self.parserInitialized
        let options = Int32(
            HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue |
            HTML_PARSE_NONET.rawValue | HTML_PARSE_COMPACT.rawValue
        )
        let parsed: htmlDocPtr? = data.withUnsafeBytes { raw -> htmlDocPtr? in
            guard let base = raw.baseAddress, raw.count > 0 else { return nil }
            return htmlReadMemory(
                base.assumingMemoryBound(to: CChar.self),
                Int32(raw.count),
                url?.absoluteString,
                "UTF-8",
                options
            )
        }
        guard let parsed else { return nil }
        self.doc = parsed
        self.url = url
    }

    public convenience init?(html: String, url: URL?) {
        self.init(data: Data(html.utf8), url: url)
    }

    deinit {
        xmlFreeDoc(doc)
    }

    /// Executa um XPath absoluto ("//div[...]").
    public func select(_ xpath: String) -> [HTMLElement] {
        evaluate(xpath, node: nil)
    }

    public func first(_ xpath: String) -> HTMLElement? {
        select(xpath).first
    }

    /// Conteúdo de todos os <script> concatenado (útil para regex em dados embutidos).
    public var scriptsText: String {
        select("//script").map(\.rawText).joined(separator: "\n")
    }

    fileprivate func evaluate(_ xpath: String, node: xmlNodePtr?) -> [HTMLElement] {
        guard let ctx = xmlXPathNewContext(doc) else { return [] }
        defer { xmlXPathFreeContext(ctx) }
        if let node { ctx.pointee.node = node }
        let result: xmlXPathObjectPtr? = xpath.withCString { cstr in
            cstr.withMemoryRebound(to: xmlChar.self, capacity: xpath.utf8.count + 1) { expr in
                xmlXPathEvalExpression(expr, ctx)
            }
        }
        guard let result else { return [] }
        defer { xmlXPathFreeObject(result) }
        guard let set = result.pointee.nodesetval, set.pointee.nodeNr > 0, let tab = set.pointee.nodeTab else { return [] }
        var out: [HTMLElement] = []
        out.reserveCapacity(Int(set.pointee.nodeNr))
        for i in 0..<Int(set.pointee.nodeNr) {
            if let n = tab[i] {
                out.append(HTMLElement(node: n, document: self))
            }
        }
        return out
    }

    /// Resolve uma URL relativa contra a URL do documento.
    public func absolute(_ raw: String?) -> String? {
        guard var value = raw?.trimmed, !value.isEmpty else { return nil }
        if value.hasPrefix("data:") { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        if let base = url, let resolved = URL(string: value, relativeTo: base) {
            return resolved.absoluteString
        }
        if let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let base = url, let resolved = URL(string: encoded, relativeTo: base) {
            return resolved.absoluteString
        }
        return value
    }
}

public struct HTMLElement {
    fileprivate let node: xmlNodePtr
    /// Mantém o documento vivo enquanto o elemento existir.
    public let document: HTMLDocument

    public var tagName: String {
        guard let name = node.pointee.name else { return "" }
        return String(cString: name)
    }

    public func attr(_ name: String) -> String? {
        guard let value = xmlGetProp(node, name) else { return nil }
        defer { xmlFree(value) }
        return String(cString: value)
    }

    public func hasAttr(_ name: String) -> Bool {
        attr(name) != nil
    }

    /// Atributo resolvido como URL absoluta.
    public func absAttr(_ name: String) -> String? {
        document.absolute(attr(name))
    }

    /// Texto sem normalização (conteúdo de <script>, por exemplo).
    public var rawText: String {
        guard let content = xmlNodeGetContent(node) else { return "" }
        defer { xmlFree(content) }
        return String(cString: content)
    }

    /// Texto com espaços normalizados (equivalente ao `text()` do Jsoup).
    public var text: String {
        rawText.collapsedWhitespace
    }

    /// Apenas os nós de texto filhos diretos (equivalente ao `ownText()` do Jsoup).
    public var ownText: String {
        var parts: [String] = []
        var child = node.pointee.children
        while let c = child {
            if c.pointee.type == XML_TEXT_NODE || c.pointee.type == XML_CDATA_SECTION_NODE,
               let content = xmlNodeGetContent(c) {
                parts.append(String(cString: content))
                xmlFree(content)
            }
            child = c.pointee.next
        }
        return parts.joined(separator: " ").collapsedWhitespace
    }

    /// HTML interno serializado.
    public var innerHTML: String {
        guard let buffer = xmlBufferCreate() else { return "" }
        defer { xmlBufferFree(buffer) }
        var child = node.pointee.children
        while let c = child {
            xmlNodeDump(buffer, document.doc, c, 0, 0)
            child = c.pointee.next
        }
        guard let content = buffer.pointee.content else { return "" }
        return String(cString: content)
    }

    /// XPath relativo a este elemento — use "." no início (".//a", "./div").
    public func select(_ xpath: String) -> [HTMLElement] {
        document.evaluate(xpath, node: node)
    }

    public func first(_ xpath: String) -> HTMLElement? {
        select(xpath).first
    }

    /// URL de imagem considerando os atributos de lazy-load mais comuns.
    public var imageURL: String? {
        for name in ["data-src", "data-lazy-src", "data-lzl-src", "data-cfsrc", "data-manga-src", "data-original"] {
            if let v = attr(name)?.nilIfEmpty, let abs = document.absolute(v) { return abs }
        }
        if let srcset = (attr("data-srcset") ?? attr("srcset"))?.nilIfEmpty, let best = Self.bestFromSrcset(srcset) {
            return document.absolute(best)
        }
        return absAttr("src")
    }

    private static func bestFromSrcset(_ srcset: String) -> String? {
        var best: (String, Double)?
        for candidate in srcset.split(separator: ",") {
            let parts = candidate.trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard let url = parts.first, !url.isEmpty else { continue }
            let descriptor = parts.count > 1 ? parts[1].trimmed : "1x"
            let weight = Double(descriptor.dropLast()) ?? 1
            if best == nil || weight > best!.1 { best = (url, weight) }
        }
        return best?.0
    }
}

/// Predicado XPath equivalente ao seletor CSS `.classe`.
@inline(__always)
public func cls(_ name: String) -> String {
    "contains(concat(' ', normalize-space(@class), ' '), ' \(name) ')"
}

extension String {
    var collapsedWhitespace: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
