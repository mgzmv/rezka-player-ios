import SwiftUI
import AVKit
import AVFoundation

struct PlaybackContext: Identifiable {
    let id = UUID()
    var media: MediaItem
    var translatorID: Int
    var season: Int?
    var episode: Int?
    var titleText: String
    var streams: StreamSet?
    var localURL: URL?
}

struct SubtitleCue {
    let start: Double
    let end: Double
    let text: String
}

enum VTTParser {
    static func parse(_ raw: String) -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                if parts.count >= 2,
                   let s = seconds(parts[0]),
                   let e = seconds(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") {
                    var body: [String] = []
                    i += 1
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        body.append(lines[i])
                        i += 1
                    }
                    let cleaned = body.joined(separator: "\n")
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    cues.append(SubtitleCue(start: s, end: e, text: cleaned))
                    continue
                }
            }
            i += 1
        }
        return cues
    }

    private static func seconds(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let comps = t.components(separatedBy: ":")
        guard !comps.isEmpty else { return nil }
        var total = 0.0
        for c in comps {
            guard let v = Double(c) else { return nil }
            total = total * 60 + v
        }
        return total
    }
}

@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    let context: PlaybackContext

    @Published var currentQuality: QualityOption?
    @Published var currentSubtitle: SubtitleTrack?
    @Published var cueText = ""
    @Published var errorText: String?

    private var cues: [SubtitleCue] = []
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var lastSaved = Date.distantPast

    var qualities: [QualityOption] { context.streams?.qualities ?? [] }
    var subtitles: [SubtitleTrack] { context.streams?.subtitles ?? [] }

    init(context: PlaybackContext) {
        self.context = context
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func start() {
        let resumeAt = UserStore.shared.position(media: context.media, season: context.season, episode: context.episode)

        if let local = context.localURL {
            play(url: local, at: resumeAt)
        } else if let streams = context.streams, let q = streams.pick(preferred: AppSettings.preferredQuality),
                  let url = URL(string: q.url) {
            currentQuality = q
            play(url: url, at: resumeAt)
        } else {
            errorText = "Нет доступных видеопотоков"
            return
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }

        if let def = context.streams?.defaultSubtitleName,
           let track = subtitles.first(where: { $0.name == def }) {
            selectSubtitle(track)
        }
    }

    private func play(url: URL, at position: Double) {
        let asset: AVURLAsset
        if url.isFileURL {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": RezkaClient.userAgent],
            ])
        }
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                if item.status == .failed { self?.errorText = item.error?.localizedDescription ?? "Ошибка воспроизведения" }
            }
        }
        player.replaceCurrentItem(with: item)
        if position > 10 {
            player.seek(to: CMTime(seconds: max(position - 3, 0), preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }

    func selectQuality(_ q: QualityOption) {
        guard q != currentQuality, let url = URL(string: q.url) else { return }
        let t = player.currentTime().seconds
        currentQuality = q
        UserDefaults.standard.set(q.name, forKey: "preferredQuality")
        play(url: url, at: t.isFinite ? t + 3 : 0)
    }

    func selectSubtitle(_ track: SubtitleTrack?) {
        currentSubtitle = track
        cues = []
        cueText = ""
        guard let track, let url = URL(string: track.url) else { return }
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                let text = String(decoding: data, as: UTF8.self)
                let parsed = VTTParser.parse(text)
                await MainActor.run { if self.currentSubtitle == track { self.cues = parsed } }
            }
        }
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        if !cues.isEmpty {
            let text = cues.first(where: { t >= $0.start && t <= $0.end })?.text ?? ""
            if text != cueText { cueText = text }
        }
        if Date().timeIntervalSince(lastSaved) > 5 { saveProgress() }
    }

    func saveProgress() {
        let pos = player.currentTime().seconds
        let dur = player.currentItem?.duration.seconds ?? 0
        guard pos.isFinite, pos > 1 else { return }
        lastSaved = Date()
        UserStore.shared.record(
            media: context.media, translatorID: context.translatorID,
            season: context.season, episode: context.episode,
            position: pos, duration: dur.isFinite ? dur : 0
        )
    }

    func stop() {
        saveProgress()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
    }
}

struct AVPlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.entersFullScreenWhenPlaybackBegins = false
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}

struct PlayerScreen: View {
    let context: PlaybackContext
    @StateObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    init(context: PlaybackContext) {
        self.context = context
        _model = StateObject(wrappedValue: PlayerModel(context: context))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AVPlayerControllerView(player: model.player).ignoresSafeArea()

            if !model.cueText.isEmpty {
                VStack {
                    Spacer()
                    Text(model.cueText)
                        .font(.system(size: 18, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 80)
                }
                .allowsHitTesting(false)
            }

            VStack {
                HStack(spacing: 12) {
                    Button {
                        model.stop()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Text(context.titleText)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.9))

                    Spacer()

                    if !model.qualities.isEmpty || !model.subtitles.isEmpty {
                        Menu {
                            if !model.qualities.isEmpty {
                                Section("Качество") {
                                    ForEach(model.qualities.reversed()) { q in
                                        Button {
                                            model.selectQuality(q)
                                        } label: {
                                            if model.currentQuality == q {
                                                Label(q.name, systemImage: "checkmark")
                                            } else {
                                                Text(q.name)
                                            }
                                        }
                                    }
                                }
                            }
                            if !model.subtitles.isEmpty {
                                Section("Субтитры") {
                                    Button {
                                        model.selectSubtitle(nil)
                                    } label: {
                                        if model.currentSubtitle == nil {
                                            Label("Выкл.", systemImage: "checkmark")
                                        } else {
                                            Text("Выкл.")
                                        }
                                    }
                                    ForEach(model.subtitles) { s in
                                        Button {
                                            model.selectSubtitle(s)
                                        } label: {
                                            if model.currentSubtitle == s {
                                                Label(s.name, systemImage: "checkmark")
                                            } else {
                                                Text(s.name)
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "gearshape.fill")
                                if let q = model.currentQuality { Text(q.name).font(.footnote.weight(.semibold)) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer()
            }

            if let err = model.errorText {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
                    Text(err).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(20)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                .padding()
            }
        }
        .statusBarHidden(true)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
