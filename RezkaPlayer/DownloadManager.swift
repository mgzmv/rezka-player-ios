import Foundation
import UIKit

struct DownloadItem: Codable, Identifiable, Hashable {
    enum State: String, Codable { case downloading, paused, completed, failed }

    var id: String
    var media: MediaItem
    var translatorID: Int
    var translatorName: String
    var season: Int?
    var episode: Int?
    var episodeTitle: String
    var quality: String
    var sourceURL: String
    var fileName: String
    var totalBytes: Int64 = 0
    var state: State = .downloading
    var errorText: String = ""
    var createdAt: Date = Date()

    var displayTitle: String {
        if let s = season, let e = episode { return "\(media.title) — S\(s)E\(e)" }
        return media.title
    }
}

/// Background downloads of direct .mp4 streams into Documents/Downloads (visible in the Files app).
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var received: [String: Int64] = [:]

    var backgroundCompletion: (() -> Void)?

    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    private let metaURL: URL

    nonisolated static func directory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        metaURL = support.appendingPathComponent("downloads.json")
        super.init()

        let cfg = URLSessionConfiguration.background(withIdentifier: "com.mczmv.rezkaplayer.downloads")
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.httpAdditionalHeaders = ["User-Agent": RezkaClient.userAgent]
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)

        load()
        reattachTasks()
    }

    // MARK: Public API

    func localURL(for item: DownloadItem) -> URL {
        Self.directory().appendingPathComponent(item.fileName)
    }

    func completed(media: MediaItem, season: Int?, episode: Int?) -> DownloadItem? {
        items.first {
            $0.media.id == media.id && $0.season == season && $0.episode == episode
                && $0.state == .completed
                && FileManager.default.fileExists(atPath: localURL(for: $0).path)
        }
    }

    func active(media: MediaItem, season: Int?, episode: Int?) -> DownloadItem? {
        items.first {
            $0.media.id == media.id && $0.season == season && $0.episode == episode && $0.state != .completed
        }
    }

    func enqueue(media: MediaItem, translator: Translator, season: Int?, episode: Int?,
                 episodeTitle: String, quality: QualityOption) {
        if completed(media: media, season: season, episode: episode) != nil { return }
        if let existing = active(media: media, season: season, episode: episode) {
            resume(existing.id)
            return
        }

        let id = UUID().uuidString
        var base = media.title
        if let s = season, let e = episode { base += String(format: " S%02dE%02d", s, e) }
        base += " \(quality.name)"
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: " ")
        let fileName = "\(safe)-\(id.prefix(6)).mp4"

        let item = DownloadItem(
            id: id, media: media, translatorID: translator.id, translatorName: translator.name,
            season: season, episode: episode, episodeTitle: episodeTitle,
            quality: quality.name, sourceURL: quality.url, fileName: fileName
        )
        items.insert(item, at: 0)
        save()
        startTask(for: item)
    }

    func pause(_ id: String) {
        guard let task = tasks[id] else { return }
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.resumeData[id] = data }
                self.tasks[id] = nil
                self.setState(id, .paused)
            }
        })
    }

    func resume(_ id: String) {
        guard let item = items.first(where: { $0.id == id }), tasks[id] == nil else { return }
        setState(id, .downloading)
        if let data = resumeData[id] {
            let task = session.downloadTask(withResumeData: data)
            task.taskDescription = "\(id)|\(item.fileName)"
            tasks[id] = task
            task.resume()
        } else {
            Task { await refreshSourceAndStart(item) }
        }
    }

    func delete(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        resumeData[id] = nil
        progress[id] = nil
        received[id] = nil
        if let item = items.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: localURL(for: item))
        }
        items.removeAll { $0.id == id }
        save()
    }

    var totalSize: Int64 {
        items.filter { $0.state == .completed }.reduce(0) { $0 + $1.totalBytes }
    }

    // MARK: Internals

    private func startTask(for item: DownloadItem) {
        guard let url = URL(string: item.sourceURL) else {
            setState(item.id, .failed, error: "Неверная ссылка")
            return
        }
        let task = session.downloadTask(with: url)
        task.taskDescription = "\(item.id)|\(item.fileName)"
        tasks[item.id] = task
        setState(item.id, .downloading)
        task.resume()
    }

    /// Stream links expire; re-resolve them when we have no resume data.
    private func refreshSourceAndStart(_ item: DownloadItem) async {
        do {
            let details = try await RezkaClient.shared.details(url: item.media.url, fallback: item.media)
            guard let tr = details.translators.first(where: { $0.id == item.translatorID }) ?? details.translators.first else {
                throw RezkaError.noStreams
            }
            let streams = try await RezkaClient.shared.streams(
                details: details, translator: tr, season: item.season, episode: item.episode
            )
            guard let q = streams.qualities.first(where: { $0.name == item.quality }) ?? streams.pick(preferred: item.quality) else {
                throw RezkaError.noStreams
            }
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].sourceURL = q.url
                save()
                startTask(for: items[idx])
            }
        } catch {
            setState(item.id, .failed, error: error.localizedDescription)
        }
    }

    private func setState(_ id: String, _ state: DownloadItem.State, error: String = "") {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = state
        items[idx].errorText = error
        save()
    }

    private func reattachTasks() {
        session.getAllTasks { [weak self] allTasks in
            Task { @MainActor in
                guard let self else { return }
                var live = Set<String>()
                for t in allTasks {
                    if let d = t as? URLSessionDownloadTask,
                       let id = d.taskDescription?.components(separatedBy: "|").first {
                        self.tasks[id] = d
                        live.insert(id)
                    }
                }
                for item in self.items where item.state == .downloading && !live.contains(item.id) {
                    self.setState(item.id, .paused)
                }
            }
        }
    }

    fileprivate func updateProgress(_ id: String, written: Int64, total: Int64) {
        received[id] = written
        if total > 0 {
            progress[id] = Double(written) / Double(total)
            if let idx = items.firstIndex(where: { $0.id == id }), items[idx].totalBytes != total {
                items[idx].totalBytes = total
            }
        }
    }

    fileprivate func markCompleted(_ id: String, size: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = .completed
        items[idx].totalBytes = size
        items[idx].errorText = ""
        tasks[id] = nil
        resumeData[id] = nil
        progress[id] = 1
        save()
    }

    fileprivate func markFailed(_ id: String, resume: Data?, message: String) {
        tasks[id] = nil
        if let resume { resumeData[id] = resume }
        setState(id, resume != nil ? .paused : .failed, error: message)
    }

    private func load() {
        guard let data = try? Data(contentsOf: metaURL),
              let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = decoded
        for item in items where item.state == .completed { progress[item.id] = 1 }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }
}

// MARK: - URLSession delegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription?.components(separatedBy: "|").first else { return }
        Task { @MainActor in
            self.updateProgress(id, written: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let parts = (downloadTask.taskDescription ?? "").components(separatedBy: "|")
        guard parts.count >= 2 else { return }
        let id = parts[0], fileName = parts[1...].joined(separator: "|")

        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            Task { @MainActor in self.markFailed(id, resume: nil, message: "Сервер вернул HTTP \(http.statusCode)") }
            return
        }

        let dest = Self.directory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            Task { @MainActor in self.markCompleted(id, size: size) }
        } catch {
            Task { @MainActor in self.markFailed(id, resume: nil, message: error.localizedDescription) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription?.components(separatedBy: "|").first else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }  // pause / delete handled elsewhere
        let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let message = error.localizedDescription
        Task { @MainActor in self.markFailed(id, resume: data, message: message) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
