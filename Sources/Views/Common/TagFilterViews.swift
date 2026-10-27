import SwiftUI

/// Faixa de tags do Explorar: botão com a lista completa, as tags escolhidas (toque remove)
/// e as mais comuns entre as obras carregadas, gêneros fixos antes das outras (toque escolhe).
struct TagChipsBar: View {
    let tags: [GenreTags.Count]
    @Binding var selection: Set<String>
    var suggestions = 10

    @State private var showPicker = false

    private var suggested: [GenreTags.Count] {
        Array(tags.filter { $0.count > 0 && !selection.contains($0.key) }.prefix(suggestions))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { showPicker = true } label: {
                    Label(selection.isEmpty ? "Tags" : "Tags (\(selection.count))", systemImage: "tag")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                ForEach(selection.sorted(by: { label(for: $0) < label(for: $1) }), id: \.self) { key in
                    Button { selection.remove(key) } label: {
                        HStack(spacing: 4) {
                            Text(label(for: key))
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.footnote)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Remover tag \(label(for: key))")
                }

                ForEach(suggested) { tag in
                    Button { selection.insert(tag.key) } label: {
                        Text(tag.label).font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
        }
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                TagPickerList(tags: tags, selection: $selection)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("OK") { showPicker = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func label(for key: String) -> String {
        tags.first(where: { $0.key == key })?.label ?? GenreTags.label(for: key)
    }
}

/// Todas as tags com quantas obras têm cada uma; marca várias (a obra precisa ter todas).
/// Os gêneros fixos vêm primeiro, em ordem alfabética; depois, as outras tags das fontes.
struct TagPickerList: View {
    let tags: [GenreTags.Count]
    @Binding var selection: Set<String>
    var footer = "Aparecem só as obras com todas as tags marcadas. Os gêneros estão sempre na lista; as outras tags vêm das obras já carregadas."

    @State private var search = ""

    private var filtered: [GenreTags.Count] {
        let query = search.trimmed
        guard !query.isEmpty else { return tags.filter { !selection.contains($0.key) } }
        return tags.filter { GenreTags.search(query, matches: $0) }
    }

    private var genres: [GenreTags.Count] {
        filtered.filter(\.isGenre).sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private var others: [GenreTags.Count] {
        filtered.filter { !$0.isGenre }
    }

    /// Escolhidas no topo, inclusive as que não estão entre as obras carregadas
    /// (ex.: vieram da página de uma obra).
    private var chosen: [GenreTags.Count] {
        selection.map { key in tags.first { $0.key == key } ?? GenreTags.Count(key: key, label: GenreTags.label(for: key), count: 0) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    var body: some View {
        List {
            if !chosen.isEmpty && search.trimmed.isEmpty {
                Section("Escolhidas") {
                    ForEach(chosen) { tag in
                        row(label: tag.label, key: tag.key, count: tag.count > 0 ? tag.count : nil)
                    }
                }
            }
            if !genres.isEmpty {
                Section("Gêneros") {
                    ForEach(genres) { tag in
                        row(label: tag.label, key: tag.key, count: tag.count > 0 ? tag.count : nil)
                    }
                }
            }
            Section {
                ForEach(others) { tag in
                    row(label: tag.label, key: tag.key, count: tag.count)
                }
            } header: {
                if !others.isEmpty && !genres.isEmpty { Text("Outras tags") }
            } footer: {
                Text(tags.isEmpty ? "As tags aparecem quando as obras terminam de carregar." : footer)
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar tag")
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Limpar") { selection.removeAll() }
                    .disabled(selection.isEmpty)
            }
        }
    }

    private func row(label: String, key: String, count: Int?) -> some View {
        Button {
            if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
        } label: {
            HStack {
                Image(systemName: selection.contains(key) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(key) ? Color.accentColor : .secondary)
                Text(label).foregroundStyle(.primary)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .tint(.primary)
        .accessibilityAddTraits(selection.contains(key) ? .isSelected : [])
    }
}
