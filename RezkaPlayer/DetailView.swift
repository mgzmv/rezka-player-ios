import SwiftUI

private struct DownloadChoice: Identifiable {
    let id = UUID()
    let streams: StreamSet
    let translator: Translator
    let season: Int?
    let episode: Int?
    let episodeTitle: String
}

struct DetailView: View {
    let item: MediaItem

    @EnvironmentObject private var store: UserStore
    @EnvironmentObject private var downloads: DownloadManager

    @State private var details: MediaDetails?
    @State private var error: String?
    @State private var translator: Translator?
    @State private var seasons: [SeasonInfo] = []
    @State private var selectedSeason = 1
    @State private var selectedEpisode: Int?
    @State private var loadingSeasons = false
    @State private var busy = false
    @State private var expandedDescription = false
    @State private var playback: PlaybackContext?
    @State private var downloadChoice: DownloadChoice?
    @State private var alertText: String?

    private var shown: MediaItem { details?.item ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let error, details == nil {
                    ErrorBanner(text: error) { Task { await loadDetails() } }
                } else if let details {
                    content(details)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationTitle(shown.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.toggleFavorite(shown)
                } label: {
                    Image(systemName: store.isFavorite(shown.id) ? "heart.fill" : "heart")
                        .foregroundStyle(store.isFavorite(shown.id) ? .red : .accentColor)
                }
            }
        }
        .task { if details == nil { await loadDetails() } }
        .overlay {
            if busy {
                ProgressView("Получаю поток…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .fullScreenCover(item: $playback) { ctx in PlayerScreen(context: ctx) }
        .confirmationDialog("Качество для загрузки", isPresented: Binding(
            get: { downloadChoice != nil },
            set: { if !$0 { downloadChoice = nil } }
        ), presenting: downloadChoice) { choice in
            ForEach(choice.streams.qualities.sorted { $0.height > $1.height }) { q in
                Button(q.name) {
                    downloads.enqueue(
                        media: shown, translator: choice.translator,
                        season: choice.season, episode: choice.episode,
                        episodeTitle: choice.episodeTitle, quality: q
                    )
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: { _ in
            Text("Файл сохранится в приложении и будет доступен офлайн")
        }
        .alert("Ошибка", isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: URL(string: shown.poster)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack { Color.gray.opacity(0.2); Image(systemName: "film").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                Text(shown.title).font(.title3.bold())
                if !shown.subtitle.isEmpty {
                    Text(shown.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if let d = details, !d.year.isEmpty, !shown.subtitle.contains(d.year) {
                    Text(d.year).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func content(_ d: MediaDetails) -> some View {
        if !d.description.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(d.description)
                    .font(.subheadline)
                    .lineLimit(expandedDescription ? nil : 5)
                Button(expandedDescription ? "Свернуть" : "Подробнее") { expandedDescription.toggle() }
                    .font(.footnote)
            }
        }

        translatorMenu(d)

        if d.isSeries {
            seriesSection(d)
        } else {
            movieActions(d)
        }
    }

    private func translatorMenu(_ d: MediaDetails) -> some View {
        Menu {
            ForEach(d.translators) { t in
                Button {
                    guard t.id != translator?.id else { return }
                    translator = t
                    if d.isSeries { Task { await loadSeasons() } }
                } label: {
                    if t.id == translator?.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                }
            }
        } label: {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                Text(translator?.name ?? "Озвучка")
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .padding(12)
            .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(d.translators.count < 2)
    }

    private func movieActions(_ d: MediaDetails) -> some View {
        let offline = downloads.completed(media: d.item, season: nil, episode: nil)
        let active = downloads.active(media: d.item, season: nil, episode: nil)
        let pos = store.position(media: d.item, season: nil, episode: nil)

        return VStack(spacing: 10) {
            Button {
                Task { await play(season: nil, episode: nil, title: d.item.title) }
            } label: {
                Label(pos > 10 ? "Продолжить с \(Fmt.time(pos))" : "Смотреть", systemImage: "play.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)

            if offline != nil {
                Label("Загружено — доступно офлайн", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(.green)
            } else if let active {
                DownloadStatusRow(item: active)
            } else {
                Button {
                    Task { await prepareDownload(season: nil, episode: nil, title: d.item.title) }
                } label: {
                    Label("Скачать", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func seriesSection(_ d: MediaDetails) -> some View {
        if loadingSeasons {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if seasons.isEmpty {
            Text("Серии не найдены для этой озвучки").foregroundStyle(.secondary)
        } else {
            seasonPicker
            let eps = seasons.first(where: { $0.number == selectedSeason })?.episodes ?? []

            if let epNum = selectedEpisode, let ep = eps.first(where: { $0.number == epNum }) {
                let pos = store.position(media: d.item, season: ep.season, episode: ep.number)
                Button {
                    Task { await play(season: ep.season, episode: ep.number, title: "\(d.item.title) — S\(ep.season)E\(ep.number)") }
                } label: {
                    Label(pos > 10 ? "Продолжить S\(ep.season)E\(ep.number) · \(Fmt.time(pos))" : "Смотреть S\(ep.season)E\(ep.number)",
                          systemImage: "play.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }

            VStack(spacing: 0) {
                ForEach(eps) { ep in
                    episodeRow(d, ep)
                    Divider()
                }
            }
        }
    }

    private var seasonPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(seasons) { s in
                    Button("Сезон \(s.number)") {
                        selectedSeason = s.number
                        selectedEpisode = s.episodes.first?.number
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedSeason == s.number ? .accentColor : .gray)
                }
            }
        }
    }

    private func episodeRow(_ d: MediaDetails, _ ep: Episode) -> some View {
        let watched = store.isWatched(media: d.item, season: ep.season, episode: ep.number)
        let offline = downloads.completed(media: d.item, season: ep.season, episode: ep.number)
        let active = downloads.active(media: d.item, season: ep.season, episode: ep.number)

        return HStack(spacing: 12) {
            Button {
                selectedEpisode = ep.number
                Task { await play(season: ep.season, episode: ep.number, title: "\(d.item.title) — S\(ep.season)E\(ep.number)") }
            } label: {
                HStack {
                    Image(systemName: watched ? "checkmark.circle.fill" : "play.circle")
                        .foregroundStyle(watched ? .green : .accentColor)
                    Text(ep.title).foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if offline != nil {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
            } else if let active {
                DownloadStatusRow(item: active, compact: true)
            } else {
                Button {
                    Task { await prepareDownload(season: ep.season, episode: ep.number, title: ep.title) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    @MainActor
    private func loadDetails() async {
        error = nil
        do {
            let d = try await RezkaClient.shared.details(url: item.url, fallback: item)
            details = d

            let last = store.lastEntry(for: d.item.id)
            let wantedID = d.preselect.translatorID ?? last?.translatorID ?? d.defaultTranslatorID
            translator = d.translators.first(where: { $0.id == wantedID }) ?? d.translators.first

            if d.isSeries {
                selectedSeason = d.preselect.season ?? last?.season ?? 1
                selectedEpisode = d.preselect.episode ?? last?.episode
                await loadSeasons()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func loadSeasons() async {
        guard let d = details, let tr = translator else { return }
        loadingSeasons = true
        defer { loadingSeasons = false }
        do {
            let result = try await RezkaClient.shared.seasons(
                base: RezkaClient.origin(of: d.item.url), postID: d.item.id,
                translatorID: tr.id, referer: d.item.url
            )
            seasons = result
            if !result.contains(where: { $0.number == selectedSeason }) {
                selectedSeason = result.first?.number ?? 1
                selectedEpisode = nil
            }
            let eps = result.first(where: { $0.number == selectedSeason })?.episodes ?? []
            if selectedEpisode == nil || !eps.contains(where: { $0.number == selectedEpisode }) {
                selectedEpisode = eps.first?.number
            }
        } catch {
            seasons = []
            alertText = error.localizedDescription
        }
    }

    @MainActor
    private func play(season: Int?, episode: Int?, title: String) async {
        guard let d = details, let tr = translator else { return }

        if let local = downloads.completed(media: d.item, season: season, episode: episode) {
            playback = PlaybackContext(
                media: d.item, translatorID: local.translatorID, season: season, episode: episode,
                titleText: title, streams: nil, localURL: downloads.localURL(for: local)
            )
            return
        }

        busy = true
        defer { busy = false }
        do {
            let streams = try await RezkaClient.shared.streams(details: d, translator: tr, season: season, episode: episode)
            playback = PlaybackContext(
                media: d.item, translatorID: tr.id, season: season, episode: episode,
                titleText: title, streams: streams, localURL: nil
            )
        } catch {
            alertText = error.localizedDescription
        }
    }

    @MainActor
    private func prepareDownload(season: Int?, episode: Int?, title: String) async {
        guard let d = details, let tr = translator else { return }
        busy = true
        defer { busy = false }
        do {
            let streams = try await RezkaClient.shared.streams(details: d, translator: tr, season: season, episode: episode)
            downloadChoice = DownloadChoice(streams: streams, translator: tr, season: season, episode: episode, episodeTitle: title)
        } catch {
            alertText = error.localizedDescription
        }
    }
}

struct DownloadStatusRow: View {
    let item: DownloadItem
    var compact = false
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        let p = downloads.progress[item.id] ?? 0
        HStack(spacing: 8) {
            if item.state == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                ProgressView(value: p).frame(width: compact ? 44 : 120)
            }
            if !compact {
                Text(item.state == .paused ? "Пауза" : item.state == .failed ? "Ошибка" : "\(Int(p * 100))%")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                if item.state == .downloading { downloads.pause(item.id) } else { downloads.resume(item.id) }
            } label: {
                Image(systemName: item.state == .downloading ? "pause.circle" : "play.circle")
            }
            .buttonStyle(.borderless)
        }
    }
}
