import Foundation
import CryptoKit
import SwiftSoup

enum RezkaError: LocalizedError {
    case http(Int)
    case parse(String)
    case noStreams
    case challengeFailed

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Ошибка сервера (HTTP \(code))"
        case .parse(let what): return "Не удалось разобрать ответ: \(what)"
        case .noStreams: return "Видеопотоки не найдены"
        case .challengeFailed: return "Не удалось пройти защиту сайта (Anubis)"
        }
    }
}

/// HDRezka client: Anubis proof-of-work, page parsing, AJAX streams. Same logic as the Telegram bot.
final class RezkaClient {
    static let shared = RezkaClient()

    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 25
        cfg.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
        ]
        session = URLSession(configuration: cfg)
    }

    // MARK: - Helpers

    static func match(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    static func origin(of urlString: String) -> String {
        guard let u = URL(string: urlString), let scheme = u.scheme, let host = u.host else { return AppSettings.mirror }
        return "\(scheme)://\(host)"
    }

    static func absolute(_ url: String, base: String) -> String {
        if url.hasPrefix("http") { return url }
        if url.hasPrefix("//") { return "https:" + url }
        if url.isEmpty { return "" }
        return base + (url.hasPrefix("/") ? url : "/" + url)
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func str(_ any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.lowercased() == "false" || t == "0" || t.lowercased() == "null" { return nil }
            return t
        }
        return nil
    }

    // MARK: - Networking + Anubis

    private func rawGet(_ url: URL, referer: String? = nil) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { throw RezkaError.http(http.statusCode) }
        return String(decoding: data, as: UTF8.self)
    }

    func html(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw RezkaError.parse("URL") }
        var text = try await rawGet(url, referer: Self.origin(of: urlString))
        if text.contains("anubis_challenge") {
            try await solveChallenge(html: text, base: Self.origin(of: urlString), redir: urlString)
            text = try await rawGet(url, referer: Self.origin(of: urlString))
            if text.contains("anubis_challenge") { throw RezkaError.challengeFailed }
        }
        return text
    }

    private func solveChallenge(html: String, base: String, redir: String) async throws {
        guard let m = Self.match(#"<script id="anubis_challenge"[^>]*>(.*?)</script>"#, in: html, options: [.dotMatchesLineSeparators]),
              let data = m[1].data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = json["rules"] as? [String: Any],
              let challenge = json["challenge"] as? [String: Any],
              let randomData = challenge["randomData"] as? String,
              let challengeID = challenge["id"] as? String
        else { throw RezkaError.challengeFailed }

        let difficulty = (rules["difficulty"] as? Int) ?? 2
        let prefix = String(repeating: "0", count: difficulty)
        let started = Date()

        let solution: (Int, String) = await Task.detached(priority: .userInitiated) {
            var nonce = 0
            while true {
                let digest = SHA256.hash(data: Data((randomData + String(nonce)).utf8))
                let hex = digest.map { String(format: "%02x", $0) }.joined()
                if hex.hasPrefix(prefix) { return (nonce, hex) }
                nonce += 1
            }
        }.value

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        var comps = URLComponents(string: base + "/.within.website/x/cmd/anubis/api/pass-challenge")!
        comps.queryItems = [
            URLQueryItem(name: "id", value: challengeID),
            URLQueryItem(name: "response", value: solution.1),
            URLQueryItem(name: "nonce", value: String(solution.0)),
            URLQueryItem(name: "redir", value: redir),
            URLQueryItem(name: "elapsedTime", value: String(max(elapsed, 1))),
        ]
        guard let url = comps.url else { throw RezkaError.challengeFailed }
        _ = try await rawGet(url)
    }

    private func ajax(base: String, referer: String, params: [String: String]) async throws -> [String: Any] {
        for attempt in 0..<2 {
            var req = URLRequest(url: URL(string: base + "/ajax/get_cdn_series/")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            req.setValue(referer, forHTTPHeaderField: "Referer")
            req.setValue(base, forHTTPHeaderField: "Origin")
            req.httpBody = params
                .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
                .joined(separator: "&")
                .data(using: .utf8)

            let (data, _) = try await session.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
            let text = String(decoding: data, as: UTF8.self)
            if attempt == 0, text.contains("anubis_challenge") {
                try await solveChallenge(html: text, base: base, redir: referer)
                continue
            }
            break
        }
        throw RezkaError.parse("ответ AJAX")
    }

    // MARK: - Catalog

    func parseItems(_ html: String, base: String) -> [MediaItem] {
        guard let doc = try? SwiftSoup.parse(html),
              let els = try? doc.select(".b-content__inline_item") else { return [] }
        var seen = Set<Int>()
        var out: [MediaItem] = []

        for el in els.array() {
            guard let idStr = try? el.attr("data-id"), let id = Int(idStr), !seen.contains(id) else { continue }

            var url = (try? el.attr("data-url")) ?? ""
            if url.isEmpty {
                url = (try? el.select(".b-content__inline_item-link a").first()?.attr("href")) ?? ""
            }
            url = Self.absolute(url, base: base)

            let title = (try? el.select(".b-content__inline_item-link a").first()?.text()) ?? ""
            let misc = (try? el.select(".b-content__inline_item-link div").first()?.text()) ?? ""
            let img = (try? el.select("img").first()?.attr("src")) ?? ""
            let info = (try? el.select("span.info").first()?.text()) ?? ""
            let isSeries = !((try? el.select(".cat.series").array()) ?? []).isEmpty || !info.isEmpty

            guard !url.isEmpty, !title.isEmpty else { continue }
            seen.insert(id)
            out.append(MediaItem(
                id: id, url: url, title: title, subtitle: misc,
                poster: Self.absolute(img, base: base), info: info, isSeries: isSeries
            ))
        }
        return out
    }

    /// path: "/", "/films/", "/series/", ...; filter: "last" | "popular" | "watching"
    func catalog(path: String, filter: String, page: Int) async throws -> [MediaItem] {
        let base = AppSettings.mirror
        var p = path
        if !p.hasSuffix("/") { p += "/" }
        if page > 1 { p += "page/\(page)/" }
        let text = try await html("\(base)\(p)?filter=\(filter)")
        return parseItems(text, base: base)
    }

    func search(_ query: String) async throws -> [MediaItem] {
        let base = AppSettings.mirror
        let q = Self.formEncode(query)
        let text = try await html("\(base)/search/?do=search&subaction=search&q=\(q)")
        return parseItems(text, base: base)
    }

    // MARK: - Details

    static func parseFragment(_ url: String) -> Preselect {
        var pre = Preselect()
        guard let idx = url.firstIndex(of: "#") else { return pre }
        let frag = String(url[url.index(after: idx)...])
        if let m = match(#"t:(\d+)"#, in: frag) { pre.translatorID = Int(m[1]) }
        if let m = match(#"s:(\d+)"#, in: frag) { pre.season = Int(m[1]) }
        if let m = match(#"e:(\d+)"#, in: frag) { pre.episode = Int(m[1]) }
        return pre
    }

    func details(url fullURL: String, fallback: MediaItem? = nil) async throws -> MediaDetails {
        let clean = fullURL.components(separatedBy: "#").first ?? fullURL
        let base = Self.origin(of: clean)
        let text = try await html(clean)
        let doc = try SwiftSoup.parse(text)

        var postID = 0
        var defaultTranslator = 0
        var isSeries = clean.contains("/series/")

        if let m = Self.match(#"initCDN(Series|Movies)Events\s*\(\s*(\d+)\s*,\s*(\d+)"#, in: text) {
            isSeries = (m[1] == "Series")
            postID = Int(m[2]) ?? 0
            defaultTranslator = Int(m[3]) ?? 0
        } else if let m = Self.match(#"initCDN(Series|Movies)Events\s*\(\s*(\d+)"#, in: text) {
            isSeries = (m[1] == "Series")
            postID = Int(m[2]) ?? 0
        }
        if postID == 0 { postID = extractPostID(fromURL: clean) ?? fallback?.id ?? 0 }
        guard postID != 0 else { throw RezkaError.parse("ID фильма") }

        var translators: [Translator] = []
        for li in try doc.select("#translators-list li").array() {
            guard let idStr = try? li.attr("data-translator_id"), let tid = Int(idStr) else { continue }
            var name = (try? li.text()) ?? ""
            if name.isEmpty { name = (try? li.attr("title")) ?? "" }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            func flag(_ k: String) -> String { ((try? li.attr(k)) ?? "").isEmpty ? "0" : ((try? li.attr(k)) ?? "0") }
            translators.append(Translator(
                id: tid, name: name.isEmpty ? "Озвучка \(tid)" : name,
                camrip: flag("data-camrip"), ads: flag("data-ads"), director: flag("data-director")
            ))
        }
        if translators.isEmpty {
            translators = [Translator(id: defaultTranslator, name: "Оригинал")]
        }
        if defaultTranslator == 0 || !translators.contains(where: { $0.id == defaultTranslator }) {
            defaultTranslator = translators.first?.id ?? 0
        }

        var title = (try? doc.select(".b-post__title h1").first()?.text()) ?? ""
        if title.isEmpty { title = fallback?.title ?? ((try? doc.title()) ?? "Без названия") }
        let original = (try? doc.select(".b-post__origtitle").first()?.text()) ?? ""
        let year = (try? doc.select("a[href*=/year/]").first()?.text()) ?? ""
        let desc = (try? doc.select(".b-post__description_text").first()?.text()) ?? ""
        var poster = (try? doc.select("meta[property=og:image]").first()?.attr("content")) ?? ""
        if poster.isEmpty { poster = fallback?.poster ?? "" }

        let item = MediaItem(
            id: postID, url: clean, title: title, subtitle: [year, original].filter { !$0.isEmpty }.joined(separator: " · "),
            poster: Self.absolute(poster, base: base), info: "", isSeries: isSeries
        )
        return MediaDetails(
            item: item, originalTitle: original, year: year, description: desc,
            isSeries: isSeries, translators: translators, defaultTranslatorID: defaultTranslator,
            preselect: Self.parseFragment(fullURL)
        )
    }

    // MARK: - Episodes & streams

    func seasons(base: String, postID: Int, translatorID: Int, referer: String) async throws -> [SeasonInfo] {
        let json = try await ajax(base: base, referer: referer, params: [
            "id": String(postID), "translator_id": String(translatorID), "action": "get_episodes",
        ])
        let episodesHTML = (json["episodes"] as? String) ?? ""
        let seasonsHTML = (json["seasons"] as? String) ?? ""
        guard !episodesHTML.isEmpty else { throw RezkaError.parse("список серий") }

        var map: [Int: [Episode]] = [:]
        let epDoc = try SwiftSoup.parse(episodesHTML)
        for li in try epDoc.select("li[data-season_id][data-episode_id]").array() {
            guard let s = Int((try? li.attr("data-season_id")) ?? ""),
                  let e = Int((try? li.attr("data-episode_id")) ?? "") else { continue }
            let t = ((try? li.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            map[s, default: []].append(Episode(season: s, number: e, title: t.isEmpty ? "Серия \(e)" : t))
        }
        if let sDoc = try? SwiftSoup.parse(seasonsHTML),
           let items = try? sDoc.select("li.b-simple_season__item, li[data-tab_id]").array() {
            for li in items {
                let raw = (try? li.attr("data-tab_id")) ?? ""
                let sub = (try? li.attr("data-tab_sub_id")) ?? ""
                if let s = Int(raw.isEmpty ? sub : raw), map[s] == nil { map[s] = [] }
            }
        }
        return map.keys.sorted().map { s in
            SeasonInfo(number: s, episodes: (map[s] ?? []).sorted { $0.number < $1.number })
        }
    }

    func streams(
        details: MediaDetails, translator: Translator, season: Int?, episode: Int?
    ) async throws -> StreamSet {
        let base = Self.origin(of: details.item.url)
        var params: [String: String] = [
            "id": String(details.item.id),
            "translator_id": String(translator.id),
        ]
        if details.isSeries {
            params["season"] = String(season ?? 1)
            params["episode"] = String(episode ?? 1)
            params["action"] = "get_stream"
        } else {
            params["is_camrip"] = translator.camrip
            params["is_ads"] = translator.ads
            params["is_director"] = translator.director
            params["action"] = "get_movie"
        }

        let json = try await ajax(base: base, referer: details.item.url, params: params)
        guard let raw = json["url"] as? String, !raw.isEmpty else { throw RezkaError.noStreams }
        let qualities = StreamDecoder.decode(raw)
        guard !qualities.isEmpty else { throw RezkaError.noStreams }

        var subs: [SubtitleTrack] = []
        if let s = Self.str(json["subtitle"]) { subs = StreamDecoder.parseSubtitles(s) }
        return StreamSet(qualities: qualities, subtitles: subs, defaultSubtitleName: Self.str(json["subtitle_def"]))
    }
}
