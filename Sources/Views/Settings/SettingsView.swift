import SwiftUI

public struct SettingsView: View {
    @State private var cacheCleared = false
    @State private var repository = KeiyoushiRepository.shared
    @AppStorage("default_reader_webtoon") private var defaultReaderWebtoon = true
    @AppStorage("show_nsfw_sources") private var showNsfw = false
    @AppStorage(ContentFilter.blockAdultKey) private var blockAdult = true
    @AppStorage(ReaderPreferences.volumeButtonsKey) private var volumeButtons = true
    @AppStorage(ReaderPreferences.invertVolumeButtonsKey) private var invertVolumeButtons = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ExtensionsView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Extensões Keiyoushi")
                                .font(.headline)
                            Text("\(repository.supportedSourceCount) de \(repository.totalSourceCount) fontes ativas no app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Mostrar fontes +18", isOn: $showNsfw)

                    Button {
                        Task { await repository.refreshLive() }
                    } label: {
                        HStack {
                            Text("Atualizar índice do repositório")
                            Spacer()
                            if repository.isLoading {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(repository.isLoading)
                } header: {
                    Text("Fontes")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let error = repository.lastError {
                            Text("Falha ao atualizar: \(error)")
                                .foregroundStyle(.red)
                        } else if let updated = repository.lastUpdated {
                            Text("Índice de \(updated.formatted(date: .abbreviated, time: .shortened)). Atualizar traz domínios novos dos sites.")
                        }
                    }
                }

                Section {
                    Toggle("Bloquear obras com tag adulta", isOn: $blockAdult)
                } header: {
                    Text("Conteúdo")
                } footer: {
                    Text("Esconde do catálogo e da busca as obras que alguma fonte marca com a tag Adult, Adulto ou +18. Tags como “Vida Adulta” não são bloqueadas.")
                }

                Section {
                    Toggle("Modo Webtoon por padrão", isOn: $defaultReaderWebtoon)
                    Toggle("Virar página com o volume", isOn: $volumeButtons)
                    Toggle("Inverter botões de volume", isOn: $invertVolumeButtons)
                        .disabled(!volumeButtons)
                } header: {
                    Text("Leitor")
                } footer: {
                    if volumeButtons {
                        Text(ReaderPreferences.volumeButtonsFooter(inverted: invertVolumeButtons))
                    }
                }

                Section(header: Text("Armazenamento & Cache")) {
                    Button(role: .destructive) {
                        ImageCache.shared.clearCache()
                        MetadataCache.shared.clear()
                        cacheCleared = true
                    } label: {
                        HStack {
                            Text("Limpar Cache de Imagens")
                            Spacer()
                            if cacheCleared {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                Section(header: Text("Sobre o Aplicativo")) {
                    HStack {
                        Text("Versão")
                        Spacer()
                        Text("1.0.0 (TestFlight Build 1)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Repositório de fontes")
                        Spacer()
                        Text("keiyoushi/extensions")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Configurações")
        }
    }
}
