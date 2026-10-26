import SwiftUI

/// Faixa de tags (obras de uma tag): botão com a lista completa, as tags escolhidas (toque remove)
/// e as mais comuns entre as obras carregadas (toque escolhe).
struct TagChipsBar: View {
    let tags: [GenreTags.Count]
    @Binding var selection: Set<String>
    var suggestions = 10

    @State private var showPicker = false

    private var suggested: [GenreTags.Count] {
        Array(tags.filter { !selection.contains($0.key) }.prefix(suggestions))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                Button { showPicker = true } label: {
                    Chip(title: "Tags", count: selection.isEmpty ? nil : selection.count, systemImage: "tag")
                }

                ForEach(selection.sorted(by: { label(for: $0) < label(for: $1) }), id: \.self) { key in
                    Button { selection.remove(key) } label: {
                        Chip(title: label(for: key), isSelected: true, removable: true)
                    }
                    .accessibilityLabel("Remover tag \(label(for: key))")
                }

                ForEach(suggested) { tag in
                    Button { selection.insert(tag.key) } label: {
                        Chip(title: tag.label, muted: true)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Space.margin)
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
struct TagPickerList: View {
    let tags: [GenreTags.Count]
    @Binding var selection: Set<String>
    var footer = "Aparecem só as obras com todas as tags marcadas. A lista cresce à medida que mais obras carregam."

    @State private var search = ""

    private var filtered: [GenreTags.Count] {
        let query = search.trimmed
        guard !query.isEmpty else { return tags.filter { !selection.contains($0.key) } }
        return tags.filter { $0.label.localizedStandardContains(query) || GenreTags.key(for: query) == $0.key }
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
            Section {
                ForEach(filtered) { tag in
                    row(label: tag.label, key: tag.key, count: tag.count)
                }
            } footer: {
                Text(tags.isEmpty ? "As tags aparecem quando as obras terminam de carregar." : footer)
            }
        }
        .themedList()
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
                    .foregroundStyle(selection.contains(key) ? Theme.accent : Theme.inkTertiary)
                Text(label).foregroundStyle(Theme.ink)
                Spacer()
                if let count {
                    Text("\(count)")
                        .textRole(.caption)
                        .monospacedDigit()
                }
            }
        }
        .tint(Theme.ink)
        .accessibilityAddTraits(selection.contains(key) ? .isSelected : [])
    }
}
