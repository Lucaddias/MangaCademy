import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Criar, restaurar e importar backups (do app ou do Mihon), e exportar a biblioteca em CSV.
struct BackupView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var settings = BackupSettings.shared
    @State private var shareItem: ShareFile?
    @State private var importing = false
    @State private var pending: PendingRestore?
    @State private var message: String?
    @State private var automaticBackups: [URL] = []

    private struct ShareFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private struct PendingRestore: Identifiable {
        let id = UUID()
        let backup: AppBackup
        let source: String
    }

    var body: some View {
        Form {
            Section {
                Button("Criar backup") { export { try BackupManager.writeBackupFile(context: modelContext) } }
                Button("Restaurar backup") { importing = true }
            } footer: {
                Text("Restaurar mescla com o que já existe: fica o maior progresso de cada capítulo. Aceita backups do MangaCademy (.mcbackup) e do Mihon/Tachiyomi (.tachibk).")
            }

            Section {
                Picker("Backup automático", selection: $settings.intervalHours) {
                    Text("Desligado").tag(0)
                    Text("A cada 6 horas").tag(6)
                    Text("A cada 12 horas").tag(12)
                    Text("Diário").tag(24)
                    Text("A cada 2 dias").tag(48)
                    Text("Semanal").tag(24 * 7)
                }
                Stepper("Manter \(settings.keepCount) backups", value: $settings.keepCount, in: 1...10)
                if let last = settings.lastAutomatic {
                    LabeledContent("Último", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                ForEach(automaticBackups, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { load(url) }
                }
            } header: {
                Text("Automático")
            } footer: {
                Text("Salvos em Arquivos › No meu iPhone › MangaCademy › Backups.")
            }

            Section("Exportar") {
                Button("Lista da biblioteca (CSV)") {
                    export {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Biblioteca.csv")
                        try BackupManager.csv(context: modelContext).write(to: url, atomically: true, encoding: .utf8)
                        return url
                    }
                }
            }
        }
        .navigationTitle("Backup")
        .onAppear(perform: refreshList)
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { load(url) }
        }
        .confirmationDialog("Restaurar backup?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { item in
            Button("Restaurar \(item.backup.mangas.count) obras") {
                let summary = BackupManager.restore(item.backup, context: modelContext)
                NotificationCenter.default.post(name: .downloadsChanged, object: nil)
                message = summary.text
            }
        } message: { item in
            Text("Backup \(item.source) de \(item.backup.createdAt.formatted(date: .abbreviated, time: .shortened)).")
        }
        .alert("Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
    }

    private func export(_ make: () throws -> URL) {
        do { shareItem = ShareFile(url: try make()) } catch { message = error.localizedDescription }
    }

    private func refreshList() {
        automaticBackups = ((try? FileManager.default.contentsOfDirectory(at: BackupManager.backupsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mcbackup" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "tachibk" || url.pathExtension.lowercased() == "proto" {
                var backup = MihonBackupImporter.convert(try MihonBackupImporter.parse(data))
                backup.createdAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                pending = PendingRestore(backup: backup, source: "do Mihon")
            } else {
                pending = PendingRestore(backup: try BackupManager.decode(data), source: "do MangaCademy")
            }
        } catch {
            message = "Não foi possível ler o arquivo: \(error.localizedDescription)"
        }
    }
}

/// Folha de compartilhamento do sistema.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
