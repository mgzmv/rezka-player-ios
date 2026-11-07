import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer

struct PlaybackContext: Identifiable {
    let id = UUID()
    var media: MediaItem
    var translatorID: Int
    var season: Int?
    var episode: Int?
    var titleText: String
    var streams: StreamSet?
    var localURL: URL?
    var details: MediaDetails? = nil
    var seasons: [SeasonInfo] = []
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

// MARK: - Custom AVPlayerLayer Surface + PiP + AirPlay

final class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct CustomVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let fillScreen: Bool
    let onLayerReady: (AVPlayerLayer) -> Void

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect
        DispatchQueue.main.async {
            onLayerReady(view.playerLayer)
        }
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        let targetGravity: AVLayerVideoGravity = fillScreen ? .resizeAspectFill : .resizeAspect
        if uiView.playerLayer.videoGravity != targetGravity {
            uiView.playerLayer.videoGravity = targetGravity
        }
    }
}

struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Player ViewModel

@MainActor
final class PlayerModel: NSObject, ObservableObject {
    let player = AVPlayer()

    @Published var context: PlaybackContext
    @Published var currentQuality: QualityOption?
    @Published var currentSubtitle: SubtitleTrack?
    @Published var cueText = ""
    @Published var errorText: String?

    @Published var isPlaying = false
    @Published var isBuffering = true
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var bufferedTime: Double = 0
    @Published var playbackRate: Float = 1.0
    @Published var fillScreen = false
    @Published var isPipSupported = false
    @Published var isSwitchingEpisode = false

    private var pipController: AVPictureInPictureController?
    private var cues: [SubtitleCue] = []
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var lastSaved = Date.distantPast

    var qualities: [QualityOption] { context.streams?.qualities ?? [] }
    var subtitles: [SubtitleTrack] { context.streams?.subtitles ?? [] }

    var episodesInCurrentSeason: [Episode] {
        guard let s = context.season else { return [] }
        return context.seasons.first(where: { $0.number == s })?.episodes ?? []
    }

    var nextEpisode: Episode? {
        guard let s = context.season, let e = context.episode else { return nil }
        let eps = episodesInCurrentSeason
        if let idx = eps.firstIndex(where: { $0.number == e }), idx + 1 < eps.count {
            return eps[idx + 1]
        }
        if let nextSeason = context.seasons.first(where: { $0.number == s + 1 }),
           let firstEp = nextSeason.episodes.first {
            return firstEp
        }
        return nil
    }

    var previousEpisode: Episode? {
        guard let s = context.season, let e = context.episode else { return nil }
        let eps = episodesInCurrentSeason
        if let idx = eps.firstIndex(where: { $0.number == e }), idx > 0 {
            return eps[idx - 1]
        }
        if let prevSeason = context.seasons.first(where: { $0.number == s - 1 }),
           let lastEp = prevSeason.episodes.last {
            return lastEp
        }
        return nil
    }

    init(context: PlaybackContext) {
        self.context = context
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func attachLayer(_ layer: AVPlayerLayer) {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if let pip = AVPictureInPictureController(playerLayer: layer) {
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            self.pipController = pip
            self.isPipSupported = true
        }
    }

    func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    func start() {
        setupPlayerObservers()
        loadCurrentContextStream()
    }

    private func setupPlayerObservers() {
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                Task { @MainActor in self?.tick(time.seconds) }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] p, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = (p.timeControlStatus == .playing)
                self.isBuffering = (p.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            }
        }
    }

    private func loadCurrentContextStream() {
        errorText = nil
        let resumeAt = UserStore.shared.position(media: context.media, season: context.season, episode: context.episode)

        if let local = context.localURL {
            play(url: local, at: resumeAt)
        } else if let streams = context.streams, let q = streams.pick(preferred: AppSettings.preferredQuality),
                  let url = URL(string: q.url) {
            currentQuality = q
            play(url: url, at: resumeAt)
        } else {
            errorText = "Нет доступных видеопотоков"
            isBuffering = false
            return
        }

        if let def = context.streams?.defaultSubtitleName,
           let track = subtitles.first(where: { $0.name == def }) {
            selectSubtitle(track)
        } else {
            selectSubtitle(nil)
        }
    }

    private func play(url: URL, at position: Double) {
        isBuffering = true
        let asset: AVURLAsset
        if url.isFileURL {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": RezkaClient.userAgent],
            ])
        }
        let item = AVPlayerItem(asset: asset)

        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    let dur = item.duration.seconds
                    if dur.isFinite, dur > 0 { self.duration = dur }
                case .failed:
                    self.isBuffering = false
                    self.errorText = item.error?.localizedDescription ?? "Ошибка воспроизведения"
                default:
                    break
                }
            }
        }

        bufferObservation = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return }
            let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
            Task { @MainActor in
                if end.isFinite { self?.bufferedTime = end }
            }
        }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.saveProgress()
            }
        }

        player.replaceCurrentItem(with: item)
        if position > 5 {
            let target = max(position - 2, 0)
            currentTime = target
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            currentTime = 0
        }
        player.playImmediately(atRate: playbackRate)
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, abs(currentTime - duration) < 1.5 {
                seek(to: 0)
            }
            player.playImmediately(atRate: playbackRate)
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = clamped
        isBuffering = true
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isBuffering = false
            }
        }
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func setSpeed(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player.rate = rate
        }
    }

    func selectQuality(_ q: QualityOption) {
        guard q != currentQuality, let url = URL(string: q.url) else { return }
        let t = currentTime
        currentQuality = q
        UserDefaults.standard.set(q.name, forKey: "preferredQuality")
        play(url: url, at: t.isFinite ? t + 2 : 0)
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

    func switchEpisode(_ ep: Episode) {
        guard !isSwitchingEpisode, let details = context.details else { return }
        let tr = details.translators.first(where: { $0.id == context.translatorID }) ?? details.translators.first
        guard let translator = tr else { return }

        saveProgress()
        player.pause()
        isSwitchingEpisode = true
        isBuffering = true
        errorText = nil

        Task {
            do {
                if let local = DownloadManager.shared.completed(media: details.item, season: ep.season, episode: ep.number) {
                    context.season = ep.season
                    context.episode = ep.number
                    context.titleText = "\(details.item.title) — S\(ep.season)E\(ep.number)"
                    context.streams = nil
                    context.localURL = DownloadManager.shared.localURL(for: local)
                    isSwitchingEpisode = false
                    loadCurrentContextStream()
                    return
                }

                let streams = try await RezkaClient.shared.streams(
                    details: details, translator: translator, season: ep.season, episode: ep.number
                )
                context.season = ep.season
                context.episode = ep.number
                context.titleText = "\(details.item.title) — S\(ep.season)E\(ep.number)"
                context.streams = streams
                context.localURL = nil
                isSwitchingEpisode = false
                loadCurrentContextStream()
            } catch {
                isSwitchingEpisode = false
                isBuffering = false
                errorText = error.localizedDescription
            }
        }
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        if let itemDur = player.currentItem?.duration.seconds, itemDur.isFinite, itemDur > 0 {
            duration = itemDur
        }
        if !cues.isEmpty {
            let text = cues.first(where: { t >= $0.start && t <= $0.end })?.text ?? ""
            if text != cueText { cueText = text }
        }
        if Date().timeIntervalSince(lastSaved) > 5 { saveProgress() }
    }

    func saveProgress() {
        let pos = currentTime
        let dur = duration
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
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        statusObservation = nil
        timeControlObservation = nil
        bufferObservation = nil
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - Custom App Video Player Screen

struct PlayerScreen: View {
    @StateObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    @State private var controlsVisible = true
    @State private var isLocked = false
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var seekRippleText: String?
    @State private var seekRippleLeft = false

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    init(context: PlaybackContext) {
        _model = StateObject(wrappedValue: PlayerModel(context: context))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // 1. Pure video layer (no system HUD)
                CustomVideoSurface(
                    player: model.player,
                    fillScreen: model.fillScreen,
                    onLayerReady: { model.attachLayer($0) }
                )
                .ignoresSafeArea()

                // 2. Tap & double-tap gesture zones
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            guard !isLocked else { return }
                            model.skip(by: -10)
                            showRipple("-10 сек", left: true)
                            scheduleAutoHide()
                        }
                        .onTapGesture(count: 1) {
                            toggleControls()
                        }

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            guard !isLocked else { return }
                            model.skip(by: 10)
                            showRipple("+10 сек", left: false)
                            scheduleAutoHide()
                        }
                        .onTapGesture(count: 1) {
                            toggleControls()
                        }
                }
                .ignoresSafeArea()

                // 3. Double-tap seek feedback indicator
                if let ripple = seekRippleText {
                    HStack {
                        if !seekRippleLeft { Spacer() }
                        VStack(spacing: 6) {
                            Image(systemName: seekRippleLeft ? "gobackward.10" : "goforward.10")
                                .font(.system(size: 28, weight: .bold))
                            Text(ripple)
                                .font(.footnote.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.horizontal, 60)
                        if seekRippleLeft { Spacer() }
                    }
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
                }

                // 4. Subtitles overlay
                if !model.cueText.isEmpty {
                    VStack {
                        Spacer()
                        Text(model.cueText)
                            .font(.system(size: 18, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 28)
                            .padding(.bottom, controlsVisible && !isLocked ? 96 : 28)
                            .animation(.easeInOut(duration: 0.22), value: controlsVisible)
                    }
                    .allowsHitTesting(false)
                }

                // 5. Buffering indicator when controls are hidden
                if model.isBuffering && !controlsVisible {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                        .padding(18)
                        .background(.ultraThinMaterial, in: Circle())
                        .allowsHitTesting(false)
                }

                // 6. Custom App Player Controls Overlay (auto-hides!)
                if controlsVisible {
                    playerControlsOverlay(geo: geo)
                        .transition(.opacity)
                }

                // 7. Error alert banner
                if let err = model.errorText {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                        HStack(spacing: 12) {
                            Button("Закрыть") {
                                model.stop()
                                dismiss()
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)

                            Button("Повторить") {
                                model.start()
                                scheduleAutoHide()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(22)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(24)
                }
            }
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .onAppear {
            model.start()
            scheduleAutoHide()
        }
        .onDisappear {
            hideTask?.cancel()
            model.stop()
        }
        .onChange(of: model.isPlaying) { _, _ in
            scheduleAutoHide()
        }
    }

    // MARK: - Controls Overlay

    @ViewBuilder
    private func playerControlsOverlay(geo: GeometryProxy) -> some View {
        ZStack {
            // Subtle top & bottom gradient scrim
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.75), Color.black.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 110)
                Spacer()
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.8)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 130)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if isLocked {
                VStack {
                    HStack {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isLocked = false
                            }
                            scheduleAutoHide()
                        } label: {
                            Label("Разблокировать", systemImage: "lock.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    centerControls
                    Spacer()
                    bottomBar
                }
                .padding(.horizontal, max(geo.safeAreaInsets.leading, 18))
                .padding(.top, 12)
                .padding(.bottom, max(geo.safeAreaInsets.bottom, 14))
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                model.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }

            if model.isPipSupported {
                Button {
                    model.togglePiP()
                    scheduleAutoHide()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }

            AirPlayRouteButton()
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(model.context.titleText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                if let q = model.currentQuality {
                    Text(q.name)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.leading, 4)

            Spacer(minLength: 8)

            // Episode list menu (if series)
            if !model.episodesInCurrentSeason.isEmpty {
                Menu {
                    ForEach(model.episodesInCurrentSeason) { ep in
                        Button {
                            model.switchEpisode(ep)
                            scheduleAutoHide()
                        } label: {
                            if model.context.episode == ep.number {
                                Label(ep.title, systemImage: "checkmark")
                            } else {
                                Text(ep.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "list.and.film")
                        if let e = model.context.episode {
                            Text("С\(e)").font(.footnote.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }

            // Aspect ratio (Fit / Fill)
            Button {
                model.fillScreen.toggle()
                scheduleAutoHide()
            } label: {
                Image(systemName: model.fillScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }

            // Screen lock button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isLocked = true
                }
                scheduleAutoHide()
            } label: {
                Image(systemName: "lock.open")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }

            // Quality, Subtitles & Speed Menu
            Menu {
                if !model.qualities.isEmpty {
                    Section("Качество видео") {
                        ForEach(model.qualities.reversed()) { q in
                            Button {
                                model.selectQuality(q)
                                scheduleAutoHide()
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

                Section("Скорость") {
                    ForEach(speeds, id: \.self) { spd in
                        Button {
                            model.setSpeed(spd)
                            scheduleAutoHide()
                        } label: {
                            let label = spd == 1.0 ? "Обычная (1x)" : String(format: "%gx", spd)
                            if abs(model.playbackRate - spd) < 0.01 {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                }

                if !model.subtitles.isEmpty {
                    Section("Субтитры") {
                        Button {
                            model.selectSubtitle(nil)
                            scheduleAutoHide()
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
                                scheduleAutoHide()
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
                HStack(spacing: 5) {
                    Image(systemName: "gearshape.fill")
                    if let q = model.currentQuality {
                        Text(q.name).font(.footnote.weight(.semibold))
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: - Center Transport Controls

    private var centerControls: some View {
        HStack(spacing: 38) {
            if let prev = model.previousEpisode {
                Button {
                    model.switchEpisode(prev)
                    scheduleAutoHide()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }

            Button {
                model.skip(by: -10)
                scheduleAutoHide()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button {
                model.togglePlayPause()
                scheduleAutoHide()
            } label: {
                ZStack {
                    if model.isBuffering {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.3)
                    } else {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .offset(x: model.isPlaying ? 0 : 2)
                    }
                }
                .frame(width: 74, height: 74)
                .background(.ultraThinMaterial, in: Circle())
            }

            Button {
                model.skip(by: 10)
                scheduleAutoHide()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
            }

            if let next = model.nextEpisode {
                Button {
                    model.switchEpisode(next)
                    scheduleAutoHide()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: - Bottom Scrubber Bar

    private var bottomBar: some View {
        let displayedTime = isScrubbing ? scrubTime : model.currentTime
        let total = max(model.duration, 1)
        let remaining = max(total - displayedTime, 0)

        return HStack(spacing: 12) {
            Text(Fmt.time(displayedTime))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(minWidth: 50, alignment: .leading)

            Slider(
                value: Binding(
                    get: { min(max(displayedTime, 0), total) },
                    set: { newValue in
                        scrubTime = newValue
                    }
                ),
                in: 0...total,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        hideTask?.cancel()
                    } else {
                        model.seek(to: scrubTime)
                        scheduleAutoHide()
                    }
                }
            )
            .tint(.white)

            Text("-\(Fmt.time(remaining))")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Auto-hide & ripple helpers

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.22)) {
            controlsVisible.toggle()
        }
        if controlsVisible {
            scheduleAutoHide()
        } else {
            hideTask?.cancel()
        }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard controlsVisible, model.isPlaying, !isScrubbing else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, model.isPlaying, !isScrubbing else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                controlsVisible = false
            }
        }
    }

    private func showRipple(_ text: String, left: Bool) {
        seekRippleLeft = left
        withAnimation(.easeOut(duration: 0.15)) {
            seekRippleText = text
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            withAnimation(.easeIn(duration: 0.2)) {
                if seekRippleText == text { seekRippleText = nil }
            }
        }
    }
}
