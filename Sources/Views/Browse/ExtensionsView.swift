import SwiftUI

/// Lista das extensões do repositório Keiyoushi e quais delas têm motor no app.
public struct ExtensionsView: View {
    @State private var repository = KeiyoushiRepository.shared
    @State private var searchText = ""
    @State private var language: LanguageFilter = .portuguese
    @State private var onlySupported = true
    @AppStorage("show_nsfw_sources") private var includeNsfw = false

    public init() {}

    private var filteredExtensions: [KeiyoushiExtensionItem] {
        repository.filterExtensions(
            query: searchText,
            language: language,
            includeNsfw: includeNsfw,
            onlySupported: onlySupported
        )
    }

    public var body: some View {
        let items = filteredExtensions
        List {
            Section {
                Picker("Idioma", selection: $language) {
                    ForEach(LanguageFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Somente suportadas no iOS", isOn: $onlySupported)
            } footer: {
                Text("\(items.count) extensões · \(repository.supportedSourceCount) de \(repository.totalSourceCount) fontes do Keiyoushi funcionam no app")
            }

            Section {
                ForEach(items) { ext in
                    ExtensionRow(item: ext)
                }
            }
        }
        .navigationTitle("Repositório Keiyoushi")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Buscar extensão ou scan...")
        .refreshable {
            await repository.refreshLive()
        }
    }
}

private struct ExtensionRow: View {
    let item: KeiyoushiExtensionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AsyncMangaCover(urlString: item.iconUrl, cornerRadius: 8)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        if item.isNsfw {
                            BadgeView("18+", color: .red)
                        }
                    }
                    Text("v\(item.version) • \(item.engine?.type ?? "sem motor iOS")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if item.isSupported {
                    BadgeView("Ativa", color: .green)
                } else {
                    BadgeView("Indisponível", color: .secondary)
                }
            }

            if !item.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(item.sources) { src in
                            Text("\(src.name) · \(LanguageCode.shortLabel(LanguageCode.normalize(src.lang)))")
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
