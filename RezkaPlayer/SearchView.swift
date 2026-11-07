import SwiftUI

struct SearchView: View {
    @State private var path: [MediaItem] = []
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searched = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    if loading { ProgressView().padding(.top, 40) }
                    if let error { ErrorBanner(text: error) { submit() } }
                    if searched, !loading, error == nil, results.isEmpty {
                        Text("Ничего не найдено").foregroundStyle(.secondary).padding(.top, 40)
                    }
                    if !searched, !loading {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Введите название или вставьте ссылку на фильм/сериал HDRezka")
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }
                        .padding(.top, 60).padding(.horizontal, 24)
                    }
                    MediaGrid(items: results)
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Поиск")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Название или ссылка")
            .onSubmit(of: .search) { submit() }
            .rezkaDestinations()
        }
    }

    private func submit() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        // A pasted HDRezka link opens the title directly.
        if q.hasPrefix("http"), q.contains(".html") {
            let id = extractPostID(fromURL: q) ?? 0
            path.append(MediaItem(id: id, url: q, title: "Загрузка…"))
            return
        }

        Task { @MainActor in
            loading = true; error = nil; searched = true
            defer { loading = false }
            do {
                results = try await RezkaClient.shared.search(q)
            } catch {
                results = []
                self.error = error.localizedDescription
            }
        }
    }
}
