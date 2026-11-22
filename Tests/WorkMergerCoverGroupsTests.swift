import Foundation
import Testing
@testable import MihonReader

/// Obras com a mesma capa que o `WorkMerger` deixou separadas.
struct WorkMergerCoverGroupsTests {
    /// Capa igual em fontes diferentes, sem título em comum: não é a mesma obra.
    @Test func sameCoverWithUnrelatedTitlesStaysSeparate() {
        var merger = WorkMerger()
        let cover: UInt64 = 0xABCD_1234_5678_9F00
        merger.add(SourceMangaItem(sourceId: "fonte-a", remoteUrl: "/a", title: "Dragon Ball", coverUrl: nil),
                   sourceName: "A", coverHash: cover)
        merger.add(SourceMangaItem(sourceId: "fonte-b", remoteUrl: "/b", title: "Cozinha Japonesa", coverUrl: nil),
                   sourceName: "B", coverHash: cover)
        #expect(merger.works.count == 2)
    }

    /// A mesma capa repetida dentro de uma fonte é capa genérica do site: nunca funde obras.
    @Test func coverRepeatedInsideOneSourceIsGeneric() {
        var merger = WorkMerger()
        let placeholder: UInt64 = 0x1111_2222_3333_4444
        for (i, title) in ["Obra Um", "Obra Dois", "Obra Tres"].enumerated() {
            merger.add(SourceMangaItem(sourceId: "site", remoteUrl: "/\(i)", title: title, coverUrl: nil),
                       sourceName: "Site", coverHash: placeholder)
        }
        #expect(merger.works.count == 3)
    }

    /// Diagnóstico com o snapshot real: `MERGER_SNAPSHOT=<work_metadata_v1.json>` (via
    /// `TEST_RUNNER_MERGER_SNAPSHOT` no xcodebuild). Sem a variável, o teste não faz nada.
    /// Os títulos saem do slug da URL, então são aproximados; o relatório vai para o stdout.
    @Test func listsSeparatedCoverGroupsFromSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["MERGER_SNAPSHOT"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let entries = try JSONDecoder().decode([String: SnapshotEntry].self, from: data)

        var merger = WorkMerger()
        var entriesByHash: [UInt64: [String]] = [:]
        var skipped = 0
        for key in entries.keys.sorted() {
            guard let colon = key.firstIndex(of: ":") else { skipped += 1; continue }
            let sourceId = String(key[..<colon])
            let remoteUrl = String(key[key.index(after: colon)...])
            let entry = entries[key]!
            let slug = remoteUrl.split(separator: "/").last.map(String.init) ?? remoteUrl
            let item = SourceMangaItem(
                sourceId: sourceId,
                remoteUrl: remoteUrl,
                title: slug.replacingOccurrences(of: "-", with: " "),
                coverUrl: entry.coverUrl,
                altTitles: entry.altTitles ?? [],
                genres: entry.genres ?? [],
                hasFullMetadata: true
            )
            let hash = entry.coverHash.flatMap { UInt64($0, radix: 16) }
            merger.add(item, sourceName: sourceId, coverHash: hash)
            if let hash { entriesByHash[hash, default: []].append(item.id) }
        }

        var workOf: [String: Int] = [:]
        for (index, work) in merger.works.enumerated() {
            for ref in work.refs { workOf[ref.id] = index }
        }

        var report = "\nGRUPOS DE CAPA IGUAL SEPARADOS (entradas lidas: \(entries.count), sem ':' ignoradas: \(skipped))\n"
        var groups = 0
        for (hash, ids) in entriesByHash.sorted(by: { $0.value.count > $1.value.count }) where ids.count >= 2 {
            let works = Set(ids.compactMap { workOf[$0] }).sorted()
            guard works.count >= 2 else { continue }
            groups += 1
            let sources = Set(ids.map { $0.split(separator: ":").first.map(String.init) ?? "" })
            let kind = sources.count == 1 ? "capa genérica (uma fonte)" : "\(sources.count) fontes"
            report += "\n\(String(hash, radix: 16)) · \(ids.count) entradas · \(kind) · \(works.count) obras separadas\n"
            for index in works {
                let work = merger.works[index]
                report += "  - \(work.title) [\(work.refs.map(\.sourceId).joined(separator: ", "))]\n"
            }
        }
        report += "\nTotal de grupos separados: \(groups) · obras no merger: \(merger.works.count)\n"
        if let reportPath = ProcessInfo.processInfo.environment["MERGER_REPORT"] {
            try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        }
    }
}

/// Campos de `work_metadata_v1.json` que o diagnóstico usa.
private struct SnapshotEntry: Decodable {
    let coverHash: String?
    let coverUrl: String?
    let altTitles: [String]?
    let genres: [String]?
}
