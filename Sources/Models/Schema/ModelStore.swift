import Foundation
import SwiftData

/// Etapas de migração entre as versões do banco, em ordem.
public enum AppMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self]
    }

    public static var stages: [MigrationStage] {
        [v1ToV2, v2ToV3]
    }

    /// V2: lista de capítulos salva (`dateFetch`, `mangaRemoteUrl`) e histórico que reabre o capítulo.
    static let v1ToV2 = MigrationStage.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)

    /// V3: categorias, rastreamento, ajustes por obra (leitor, capítulos, scanlators) e tempo de leitura.
    static let v2ToV3 = MigrationStage.lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self)
}

/// Abre o banco do app.
public enum ModelStore {
    public static var schema: Schema { Schema(versionedSchema: SchemaV3.self) }

    /// Abre (e migra, se preciso) o banco em `url`, ou no local padrão quando `url` é nil.
    public static func open(url: URL? = nil) throws -> ModelContainer {
        try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self, configurations: configuration(url: url))
    }

    /// Abre o banco sem derrubar o app: se ele não abrir nem migrar, o arquivo é guardado ao
    /// lado com o sufixo `.broken-<data>` e um banco novo é criado. `didReset` avisa a interface.
    public static func openRecovering(url: URL? = nil) -> (container: ModelContainer, didReset: Bool) {
        do {
            return (try open(url: url), false)
        } catch {
            print("[ModelStore] Falha ao abrir o banco: \(error)")
        }
        moveAside(configuration(url: url).url)
        if let container = try? open(url: url) {
            return (container, true)
        }
        // Último recurso: o app funciona nesta sessão, mas sem salvar nada.
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return (try! ModelContainer(for: schema, configurations: memory), true)
    }

    private static func configuration(url: URL?) -> ModelConfiguration {
        if let url { return ModelConfiguration(schema: schema, url: url) }
        return ModelConfiguration(schema: schema)
    }

    /// Renomeia o arquivo do banco e seus auxiliares (-wal, -shm).
    private static func moveAside(_ storeURL: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: file.path) else { continue }
            let backup = URL(fileURLWithPath: storeURL.path + ".broken-\(stamp)" + suffix)
            try? fm.moveItem(at: file, to: backup)
        }
    }
}
