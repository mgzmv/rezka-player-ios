import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: UserStore

    private struct Category: Identifiable, Hashable {
        let title: String
        let path: String
        var id: String { path }
    }

    private let categories = [
        Category(title: "Все", path: "/"),
        Category(title: "Фильмы", path: "/films/"),
        Category(title: "Сериалы", path: "/series/"),
        Category(title: "Мультфильмы", path: "/cartoons/"),
        Category(title: "Аниме", path: "/animation/"),
    ]
    private let filters: [(String, String)] = [("Новинки", "last"), ("Популярное", "popular"), ("Смотрят", "watching")]

    @State private var category = "/"
    @State private var filter = "last"
    @State private var items: [MediaItem] = []
    @State private var page = 1
    @State private var loading = false
    @State private var canLoadMore = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if category == "/" && filter == "last", !store.history.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Продолжить просмотр").font(.headline).padding(.horizontal, 12)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(store.history.prefix(12)) { entry in
                                        NavigationLink(value: entry.item) {
                                            PosterCard(item: entry.item).frame(width: 110)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 12)
                            }
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(categories) { c in
                                Button(c.title) { category = c.path; reload() }
                                    .buttonStyle(.bordered)
                                    .tint(category == c.path ? .accentColor : .gray)
                            }
                        }
                        .padding(.horizontal, 12)
                    }

                    Picker("Раздел", selection: $filter) {
                        ForEach(filters, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)
                    .onChange(of: filter) { _, _ in reload() }

                    if let error, items.isEmpty {
                        ErrorBanner(text: error) { reload() }
                    }

                    MediaGrid(items: items) { loadMore() }

                    if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Rezka")
            .rezkaDestinations()
            .refreshable { await load(reset: true) }
            .task { if items.isEmpty { await load(reset: true) } }
        }
    }

    private func reload() { Task { await load(reset: true) } }
    private func loadMore() { guard canLoadMore, !loading else { return }; Task { await load(reset: false) } }

    @MainActor
    private func load(reset: Bool) async {
        if loading && !reset { return }
        loading = true
        defer { loading = false }
        if reset { page = 1; canLoadMore = true }
        do {
            let fetched = try await RezkaClient.shared.catalog(path: category, filter: filter, page: page)
            error = nil
            if reset {
                items = fetched
            } else {
                let known = Set(items.map(\.id))
                let fresh = fetched.filter { !known.contains($0.id) }
                items += fresh
                if fresh.isEmpty { canLoadMore = false }
            }
            if fetched.isEmpty { canLoadMore = false } else { page += 1 }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
