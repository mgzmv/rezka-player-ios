import Foundation

/// Port of `decode_rezka_stream` from the Telegram bot.
/// Cleans the junk tokens, decodes Base64 and parses `[360p]url1 or url2,[720p]...`.
enum StreamDecoder {
    static let trashTokens = [
        "$$#!!@#!@##",
        "^^^!@##!!##",
        "####^!!##!@@",
        "@@@@@!##!^^^",
        "$$!!@$$@^!@#$$@",
    ]

    static func decode(_ raw: String) -> [QualityOption] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        if !(text.hasPrefix("[") && text.contains("http")) {
            if text.hasPrefix("#h") { text.removeFirst(2) }
            text = text.replacingOccurrences(of: "//_//", with: "")
            for token in trashTokens {
                text = text.replacingOccurrences(of: token, with: "")
            }
            text = text.filter { !"@#!$^".contains($0) }
            while text.count % 4 != 0 { text += "=" }
            guard let data = Data(base64Encoded: text),
                  let decoded = String(data: data, encoding: .utf8) else { return [] }
            text = decoded
        }
        return parse(text)
    }

    static func parse(_ text: String) -> [QualityOption] {
        guard let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]([^\\[]+)") else { return [] }
        let ns = text as NSString
        var result: [QualityOption] = []

        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var quality = ns.substring(with: m.range(at: 1))
            quality = quality
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var links = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            while links.hasSuffix(",") { links.removeLast() }

            let parts = links
                .components(separatedBy: " or ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // Prefer direct .mp4 over HLS manifests.
            let direct = parts.first { !$0.contains(".m3u8") && !$0.contains(":hls:") }
            if let url = direct ?? parts.first, !quality.isEmpty {
                result.append(QualityOption(name: quality, url: url))
            }
        }
        return result.sorted { $0.height < $1.height }
    }

    static func parseSubtitles(_ text: String) -> [SubtitleTrack] {
        guard let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\](https?://[^,\\[]+)") else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            SubtitleTrack(
                name: ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces),
                url: ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
