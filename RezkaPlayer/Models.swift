import Foundation

// MARK: - Settings

enum AppSettings {
    static var mirror: String {
        var m = (UserDefaults.standard.string(forKey: "mirror") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty { m = "https://hdrezka.name" }
        if !m.hasPrefix("http") { m = "https://" + m }
        while m.hasSuffix("/") { m.removeLast() }
        return m
    }

    static var preferredQuality: String {
        UserDefaults.standard.string(forKey: "preferredQuality") ?? "1080p"
    }
}

// MARK: - Catalog models

struct MediaItem: Identifiable, Codable, Hashable {
    let id: Int
    var url: String
    var title: String
    var subtitle: String = ""
    var poster: String = ""
    var info: String = ""
    var isSeries: Bool = false
}

struct Translator: Identifiable, Hashable, Codable {
    let id: Int
    var name: String
    var camrip: String = "0"
    var ads: String = "0"
    var director: String = "0"
}

struct Episode: Identifiable, Hashable {
    let season: Int
    let number: Int
    var title: String
    var id: String { "\(season)-\(number)" }
}

struct SeasonInfo: Identifiable, Hashable {
    let number: Int
    var episodes: [Episode]
    var id: Int { number }
}

struct Preselect {
    var translatorID: Int?
    var season: Int?
    var episode: Int?
}

struct MediaDetails {
    var item: MediaItem
    var originalTitle: String
    var year: String
    var description: String
    var isSeries: Bool
    var translators: [Translator]
    var defaultTranslatorID: Int
    var preselect: Preselect
}

// MARK: - Streams

struct QualityOption: Identifiable, Hashable {
    let name: String
    let url: String
    var id: String { name }

    var height: Int {
        let base = Int(name.prefix(while: { $0.isNumber })) ?? 0
        return name.localizedCaseInsensitiveContains("ultra") ? base + 1 : base
    }
}

struct SubtitleTrack: Identifiable, Hashable {
    let name: String
    let url: String
    var id: String { url }
}

struct StreamSet {
    var qualities: [QualityOption]
    var subtitles: [SubtitleTrack]
    var defaultSubtitleName: String?

    func pick(preferred: String) -> QualityOption? {
        let sorted = qualities.sorted { $0.height < $1.height }
        guard !sorted.isEmpty else { return nil }
        if preferred == "max" { return sorted.last }
        let target = Int(preferred.prefix(while: { $0.isNumber })) ?? 1080
        return sorted.last(where: { $0.height <= target }) ?? sorted.first
    }
}

// MARK: - Helpers

enum Fmt {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

func extractPostID(fromURL url: String) -> Int? {
    guard let m = RezkaClient.match(#"/(\d+)-[^/]*\.html"#, in: url), let v = Int(m[1]) else { return nil }
    return v
}
