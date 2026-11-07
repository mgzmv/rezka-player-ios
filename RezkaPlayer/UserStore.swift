import Foundation
import SwiftUI

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id: Int { item.id }
    var item: MediaItem
    var translatorID: Int
    var season: Int?
    var episode: Int?
    var position: Double
    var duration: Double
    var updatedAt: Date
}

/// Favorites, watch history, resume positions and watched flags. Stored as JSON in Application Support.
@MainActor
final class UserStore: ObservableObject {
    static let shared = UserStore()

    @Published private(set) var favorites: [MediaItem] = []
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var positions: [String: Double] = [:]
    @Published private(set) var watched: Set<String> = []

    private struct Snapshot: Codable {
        var favorites: [MediaItem] = []
        var history: [HistoryEntry] = []
        var positions: [String: Double] = [:]
        var watched: Set<String> = []
    }

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("userdata.json")
        load()
    }

    // MARK: Keys

    private func posKey(_ id: Int, _ season: Int?, _ episode: Int?) -> String {
        "\(id)|\(season ?? 0)|\(episode ?? 0)"
    }

    // MARK: Favorites

    func isFavorite(_ id: Int) -> Bool { favorites.contains { $0.id == id } }

    func toggleFavorite(_ item: MediaItem) {
        if let idx = favorites.firstIndex(where: { $0.id == item.id }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(item, at: 0)
        }
        save()
    }

    // MARK: Progress

    func position(media: MediaItem, season: Int?, episode: Int?) -> Double {
        positions[posKey(media.id, season, episode)] ?? 0
    }

    func isWatched(media: MediaItem, season: Int?, episode: Int?) -> Bool {
        watched.contains(posKey(media.id, season, episode))
    }

    func lastEntry(for id: Int) -> HistoryEntry? { history.first { $0.id == id } }

    func record(media: MediaItem, translatorID: Int, season: Int?, episode: Int?, position: Double, duration: Double) {
        guard position.isFinite, position >= 0 else { return }
        let key = posKey(media.id, season, episode)
        positions[key] = position
        if duration > 0, position / duration > 0.92 { watched.insert(key) }

        history.removeAll { $0.id == media.id }
        history.insert(
            HistoryEntry(item: media, translatorID: translatorID, season: season, episode: episode,
                         position: position, duration: duration, updatedAt: Date()),
            at: 0
        )
        if history.count > 200 { history = Array(history.prefix(200)) }
        save()
    }

    func removeHistory(_ id: Int) {
        history.removeAll { $0.id == id }
        save()
    }

    func clearHistory() {
        history = []
        positions = [:]
        watched = []
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        favorites = snap.favorites
        history = snap.history
        positions = snap.positions
        watched = snap.watched
    }

    private func save() {
        let snap = Snapshot(favorites: favorites, history: history, positions: positions, watched: watched)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
