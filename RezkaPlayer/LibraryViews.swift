import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: UserStore
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("", selection: $tab) {
                        Text("История").tag(0)
                        Text("Избранное").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)

                    if tab == 0 {
                        history
                    } else if store.favorites.isEmpty {
                        empty("Нет избранного", "Нажмите ♥ на странице фильма")
                    } else {
                        MediaGrid(items: store.favorites)
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Моё")
            .rezkaDestinations()
            .toolbar {
                if tab == 0, !store.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Очистить", role: .destructive) { store.clearHistory() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var history: some View {
        if store.history.isEmpty {
            empty("История пуста", "Здесь появятся просмотренные фильмы и серии")
        } else {
            LazyVStack(spacing: 10) {
                ForEach(store.history) { entry in
                    NavigationLink(value: entry.item) {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: entry.item.poster)) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                                else { Color.gray.opacity(0.2) }
                            }
                            .frame(width: 56, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                if let s = entry.season, let e = entry.episode {
                                    Text("Сезон \(s), серия \(e)").font(.caption).foregroundStyle(.secondary)
                                }
                                if entry.duration > 0 {
                                    ProgressView(value: min(entry.position / entry.duration, 1))
                                    Text("\(Fmt.time(entry.position)) из \(Fmt.time(entry.duration))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Удалить из истории", role: .destructive) { store.removeHistory(entry.id) }
                    }
                }
            }
        }
    }

    private func empty(_ title: String, _ hint: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(hint).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var playback: PlaybackContext?

    var body: some View {
        NavigationStack {
            Group {
                if downloads.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Нет загрузок").font(.headline)
                        Text("Скачанные фильмы и серии будут доступны офлайн").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        Section(footer: Text("Занято: \(Fmt.bytes(downloads.totalSize)). Файлы также доступны в приложении «Файлы» → Rezka.")) {
                            ForEach(downloads.items) { item in row(item) }
                        }
                    }
                }
            }
            .navigationTitle("Загрузки")
            .fullScreenCover(item: $playback) { PlayerScreen(context: $0) }
        }
    }

    private func row(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: item.media.poster)) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { Color.gray.opacity(0.2) }
            }
            .frame(width: 48, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(item.quality) · \(item.translatorName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                switch item.state {
                case .completed:
                    Text(Fmt.bytes(item.totalBytes)).font(.caption).foregroundStyle(.green)
                case .failed:
                    Text(item.errorText.isEmpty ? "Ошибка загрузки" : item.errorText)
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                default:
                    let p = downloads.progress[item.id] ?? 0
                    ProgressView(value: p)
                    Text("\(Fmt.bytes(downloads.received[item.id] ?? 0)) / \(Fmt.bytes(item.totalBytes)) · \(Int(p * 100))%")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)

            switch item.state {
            case .completed:
                ShareLink(item: downloads.localURL(for: item)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            case .downloading:
                Button { downloads.pause(item.id) } label: { Image(systemName: "pause.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
            default:
                Button { downloads.resume(item.id) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard item.state == .completed else { return }
            playback = PlaybackContext(
                media: item.media, translatorID: item.translatorID, season: item.season, episode: item.episode,
                titleText: item.displayTitle, streams: nil, localURL: downloads.localURL(for: item)
            )
        }
        .swipeActions {
            Button("Удалить", role: .destructive) { downloads.delete(item.id) }
        }
    }
}

struct SettingsView: View {
    @AppStorage("mirror") private var mirror = ""
    @AppStorage("preferredQuality") private var quality = "1080p"
    @EnvironmentObject private var store: UserStore
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Зеркало"), footer: Text("Адрес сайта HDRezka. Если основной домен заблокирован, укажите рабочее зеркало (например, https://rezka.ag).")) {
                    TextField("https://hdrezka.name", text: $mirror)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section(header: Text("Качество по умолчанию"), footer: Text("Если выбранного качества нет, берётся ближайшее меньшее. В плеере качество можно менять на лету.")) {
                    Picker("Качество", selection: $quality) {
                        ForEach(["360p", "480p", "720p", "1080p", "max"], id: \.self) {
                            Text($0 == "max" ? "Максимальное" : $0).tag($0)
                        }
                    }
                }

                Section("Данные") {
                    Button("Сбросить cookies (защита сайта)") {
                        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
                        cleared = true
                    }
                    Button("Очистить историю просмотра", role: .destructive) { store.clearHistory() }
                }

                Section(footer: Text("Rezka Player 1.0 — все данные хранятся только на устройстве.")) { EmptyView() }
            }
            .navigationTitle("Настройки")
            .alert("Готово", isPresented: $cleared) { Button("OK", role: .cancel) {} }
        }
    }
}
