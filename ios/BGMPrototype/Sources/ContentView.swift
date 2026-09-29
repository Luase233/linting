import PhotosUI
import SwiftUI
import UIKit

private enum ListeningStyle {
    static let background = Color(red: 0.065, green: 0.07, blue: 0.065)
    static let surface = Color(red: 0.13, green: 0.14, blue: 0.13)
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.90)
    static let orange = Color(red: 1, green: 0.48, blue: 0.14)
    static let mint = Color(red: 0.53, green: 0.84, blue: 0.78)
}

struct ContentView: View {
    @ObservedObject var model: BGMViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab = 0
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var seekPosition = 0.0
    @State private var draggingProgress = false
    @State private var detail: ListeningDetail?

    private enum ListeningDetail: String, Identifiable {
        case context, direction, explanation
        var id: String { rawValue }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                listeningPage
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("正在听", systemImage: "waveform") }.tag(0)
            NavigationStack {
                discoveryPage
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("发现", systemImage: "square.grid.2x2") }.tag(1)
            NavigationStack {
                ListeningSettingsView(model: model)
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(2)
        }
        .tint(ListeningStyle.orange)
        .preferredColorScheme(.dark)
        .toolbarBackground(ListeningStyle.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .task { await model.musicAccount.restore() }
        .onReceive(NotificationCenter.default.publisher(for: ListeningDatabase.failureNotification)) { notification in
            model.message = notification.userInfo?["message"] as? String
        }
        .onChange(of: selectedTab) { _, _ in ListeningHaptics.select() }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await loadAndAnalyze(item) }
        }
        .sheet(item: $detail) { page in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if page == .context { contextDetails }
                        else if page == .explanation, let track = model.currentTrack {
                            RecommendationExplanationView(snapshot: model.decisionSnapshot, track: track, candidates: model.recommendations)
                        } else { directionDetails }
                    }.padding(24)
                }
                .background(ListeningStyle.background)
                .navigationTitle(page == .context ? "此刻的线索" : page == .explanation ? "为什么是这首" : "给音乐一个方向")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { detail = nil } } }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(26)
        }
    }

    private var listeningPage: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("霖听").font(.system(size: 31, weight: .black, design: .rounded))
                            Text("当下，自有回响。").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            ListeningHaptics.select()
                            detail = .direction
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "slider.horizontal.3")
                                Text(model.modeSelection.title).fontWeight(.semibold)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(ListeningStyle.surface, in: Capsule())
                        }.buttonStyle(TactileButtonStyle())
                        .accessibilityLabel("音乐方向，\(model.modeSelection.title)")
                    }

                    artwork(size: min(geometry.size.width - 64, 278))

                    VStack(spacing: 14) {
                        trackHeading
                        progressControl
                        transportControls
                        feedbackControls
                    }

                    if model.currentTrack != nil {
                        Button { detail = .explanation } label: {
                            HStack {
                                Label("为什么是这首 · 看实际分数", systemImage: "chart.bar.xaxis")
                                Spacer(); Image(systemName: "chevron.right")
                            }.font(.caption.weight(.semibold)).padding(14)
                                .background(ListeningStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(TactileButtonStyle())
                    }
                    contextEntry
                    messageView
                }
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(ListeningStyle.background)
        }
    }

    private func artwork(size: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            CutCornerShape(cut: 24).fill(ListeningStyle.orange)
                .frame(width: size, height: size)
                .rotationEffect(.degrees(reduceMotion ? 0 : -3))
                .padding(8)
            TrackCover(urlString: model.currentTrack?.coverURL, trackID: model.currentTrack?.id, size: size)
                .clipShape(CutCornerShape(cut: 22))
                .overlay(CutCornerShape(cut: 22).strokeBorderFallback(ListeningStyle.paper.opacity(0.14)))
                .scaleEffect(model.isPlaying || model.currentTrack == nil ? 1 : 0.965)
                .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.78), value: model.isPlaying)
                .id(model.currentTrack?.id ?? "linyi")
                .transition(.opacity)
                .padding(8)
            HStack(spacing: 7) {
                Image(systemName: model.isPlaying ? "waveform" : "headphones")
                    .foregroundStyle(ListeningStyle.orange)
                Text(model.isLoading ? "正在为此刻选曲" : model.isPlaying ? "NOW PLAYING" : "随时，开始听")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(20)
        }
        .frame(width: size + 16, height: size + 16)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.currentTrack?.id)
        .accessibilityHidden(true)
    }

    private var trackHeading: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.currentTrack?.title ?? "给此刻，一点配乐。")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(ListeningStyle.paper)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                Text(model.currentTrack?.artist ?? "霖伊陪你，听见新的喜欢。")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.currentTrack != nil {
                Button {
                    ListeningHaptics.like()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.52)) {
                        model.feedback("liked")
                    }
                } label: {
                    Image(systemName: model.isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(model.isLiked ? ListeningStyle.orange : ListeningStyle.paper)
                        .symbolEffect(.bounce, options: .speed(1.5), value: reduceMotion ? false : model.isLiked)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(TactileButtonStyle()).disabled(model.isLoading)
                .accessibilityLabel(model.isLiked ? "取消喜欢" : "喜欢这首")
            }
        }
        .frame(minHeight: 57)
    }

    private var progressControl: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(
                get: { draggingProgress ? seekPosition : min(max(0, model.elapsed), max(1, model.duration)) },
                set: { seekPosition = $0 }
            ), in: 0...max(1, model.duration)) { editing in
                if editing { seekPosition = model.elapsed; draggingProgress = true }
                else {
                    let position = seekPosition
                    draggingProgress = false
                    ListeningHaptics.seekEnded()
                    Task { await model.seek(to: position) }
                }
            }
            .disabled(model.duration <= 0 || model.isLoading)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(formatTime(draggingProgress ? seekPosition : model.elapsed))，总时长 \(formatTime(model.duration))")
            HStack {
                Text(formatTime(draggingProgress ? seekPosition : model.elapsed))
                Spacer()
                Text(model.isLoading ? "选曲中…" : model.playbackStateText)
                    .lineLimit(1)
                Spacer()
                Text(formatTime(model.duration))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 26) {
            Button {
                ListeningHaptics.select()
                Task { await model.previous() }
            } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 25)).frame(width: 52, height: 56)
            }
            .disabled(model.currentTrack == nil || model.isLoading)
            .accessibilityLabel("上一首")

            Button(action: togglePlayback) {
                Group {
                    if model.isLoading { ProgressView().tint(ListeningStyle.background) }
                    else {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 29, weight: .bold))
                            .contentTransition(.symbolEffect(.replace.offUp))
                    }
                }
                .frame(width: 100, height: 68)
                .foregroundStyle(ListeningStyle.background)
                .background(ListeningStyle.orange, in: CutCornerShape(cut: 15))
            }
            .accessibilityLabel(model.isLoading ? "取消等待播放" : model.isPlaying ? "暂停" : "播放")

            Button {
                ListeningHaptics.next()
                Task { await model.next() }
            } label: {
                Image(systemName: "forward.end.fill").font(.system(size: 25)).frame(width: 52, height: 56)
            }
            .accessibilityLabel(model.isLoading ? "重新选择下一首" : "播放下一首")
        }
        .foregroundStyle(ListeningStyle.paper)
        .buttonStyle(TactileButtonStyle())
        .frame(maxWidth: .infinity)
    }

    private var feedbackControls: some View {
        HStack(spacing: 6) {
            Button {
                ListeningHaptics.select()
                Task { await model.replay() }
            } label: { Label("再听一次", systemImage: "arrow.counterclockwise").frame(minHeight: 44) }
            Spacer(minLength: 4)
            Button {
                ListeningHaptics.select()
                model.feedback("unsuitable")
            } label: { Label("此刻不合适", systemImage: "arrow.right").frame(minHeight: 44) }
            Menu {
                Button("不喜欢这首", systemImage: "hand.thumbsdown") {
                    ListeningHaptics.select()
                    model.feedback("disliked")
                }
                Button("为什么选这首", systemImage: "chart.bar.xaxis") { detail = .explanation }
            } label: {
                Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
            }.accessibilityLabel("更多歌曲操作")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .buttonStyle(TactileButtonStyle())
        .frame(minHeight: 44)
        .disabled(model.currentTrack == nil || model.isLoading)
    }

    private var contextEntry: some View {
        HStack(spacing: 0) {
            Button {
                ListeningHaptics.select()
                detail = .context
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle").font(.title3).foregroundStyle(ListeningStyle.mint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("此刻的线索").font(.subheadline.weight(.bold))
                        Text(model.scene == nil ? "时间 · 身体 · 听歌习惯" : "照片 · 时间 · 身体 · 听歌习惯")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .padding(16).contentShape(Rectangle())
            }.buttonStyle(TactileButtonStyle())
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 32)
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: model.isAnalyzing ? "hourglass" : "camera.viewfinder")
                    .font(.title2).frame(width: 60, height: 65)
            }
            .disabled(model.isAnalyzing)
            .accessibilityLabel(model.isAnalyzing ? "正在理解照片" : "选照片，结合近期照片与近况由阿里云分析")
        }
        .foregroundStyle(ListeningStyle.paper)
        .background(ListeningStyle.surface, in: CutCornerShape(cut: 12))
    }

    private var discoveryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("发现").font(.system(size: 34, weight: .black, design: .rounded))
                    Text("熟悉之外，也有下一首喜欢。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                NavigationLink {
                    MusicLibraryView(player: model, account: model.musicAccount)
                } label: {
                    HStack {
                        Label("搜索歌曲 · 我的网易云歌单", systemImage: "magnifyingglass").font(.headline)
                        Spacer(); Image(systemName: "chevron.right")
                    }.padding(18).frame(minHeight: 56)
                        .background(ListeningStyle.surface, in: CutCornerShape(cut: 14))
                }
                if model.preparedTrackCount > 0 {
                    Label("已准备 \(model.preparedTrackCount) 首播放地址", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(ListeningStyle.mint)
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("探索的距离", systemImage: "safari")
                            .font(.headline)
                        Spacer()
                        Text("下次选曲生效").font(.caption2).foregroundStyle(.secondary)
                    }
                    Picker("探索新歌", selection: $model.discovery) {
                        Text("贴近口味").tag(0)
                        Text("适度探索").tag(1)
                        Text("大胆一点").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.discovery) { _, _ in ListeningHaptics.select() }
                }
                .padding(18).background(ListeningStyle.surface, in: CutCornerShape(cut: 16))
                HStack(alignment: .firstTextBaseline) {
                    Text("本次候选").font(.title2.weight(.heavy))
                    Spacer()
                    Text("只选一首").font(.caption.weight(.bold)).foregroundStyle(ListeningStyle.orange)
                }
                Text("这里是这一次的其他选择。下一首会重新判断。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, -15)
                if model.recommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "rectangle.stack.badge.play").font(.system(size: 34)).foregroundStyle(ListeningStyle.mint)
                        Text("先听一首，发现就从这里开始。")
                            .font(.headline)
                        Button {
                            selectedTab = 0
                            ListeningHaptics.playPause()
                            Task { await model.play() }
                        } label: {
                            Label(model.isLoading ? "正在选曲…" : "开始听", systemImage: "play.fill")
                                .frame(minHeight: 44)
                        }.buttonStyle(.borderedProminent).disabled(model.isLoading)
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ListeningStyle.surface, in: CutCornerShape(cut: 18))
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(model.recommendations) { track in candidateRow(track) }
                    }
                }
                messageView
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.background(ListeningStyle.background)
    }

    private func candidateRow(_ track: RecommendedTrack) -> some View {
        let current = model.currentTrack?.id == track.id
        return Button {
            ListeningHaptics.next()
            Task { await model.play(track) }
        } label: {
            HStack(spacing: 13) {
                TrackCover(urlString: track.coverURL, trackID: track.id, size: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title).font(.subheadline.weight(.bold)).lineLimit(2)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if current {
                        Text("正在听这首").font(.caption2.weight(.bold)).foregroundStyle(ListeningStyle.orange)
                    }
                }
                Spacer(minLength: 2)
                Image(systemName: current ? "waveform" : "play.fill")
                    .font(.subheadline).foregroundStyle(current ? ListeningStyle.orange : ListeningStyle.paper)
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(ListeningStyle.surface, in: CutCornerShape(cut: 12))
            .overlay(CutCornerShape(cut: 12).strokeBorderFallback(current ? ListeningStyle.orange.opacity(0.7) : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(TactileButtonStyle()).disabled(model.isLoading)
            .accessibilityLabel("\(track.title)，\(track.artist)，\(current ? "重听" : "播放这首")")
    }

    @ViewBuilder private var miniPlayer: some View {
        if let track = model.currentTrack {
            HStack(spacing: 10) {
                Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { selectedTab = 0 } } label: {
                    HStack(spacing: 10) {
                        TrackCover(urlString: track.coverURL, trackID: track.id, size: 42).clipShape(RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.subheadline.weight(.bold)).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.accessibilityLabel("打开播放器，\(track.title)")
                Button(action: togglePlayback) {
                    Group {
                        if model.isLoading { ProgressView() }
                        else { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                    }.frame(width: 44, height: 44)
                }.accessibilityLabel(model.isLoading ? "取消等待播放" : model.isPlaying ? "暂停" : "播放")
                Button {
                    ListeningHaptics.next()
                    Task { await model.next() }
                } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel(model.isLoading ? "重新选择下一首" : "播放下一首")
            }
            .buttonStyle(TactileButtonStyle())
            .padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(ListeningStyle.paper)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    Rectangle().fill(ListeningStyle.orange)
                        .frame(width: geometry.size.width * min(1, max(0, model.elapsed / max(1, model.duration))), height: 2)
                }.frame(height: 2).padding(.horizontal, 14).accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private var contextDetails: some View {
        VisualContextView(model: model, selectedPhoto: $selectedPhoto)
    }

    private var directionDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("不选也可以，音乐会随此刻继续。")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(ModeSelection.allCases) { mode in
                Button {
                    model.modeSelection = mode
                    ListeningHaptics.select()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: directionSymbol(mode)).frame(width: 26)
                        Text(mode.title).font(.headline)
                        Spacer()
                        if mode == model.modeSelection { Image(systemName: "checkmark.circle.fill") }
                    }
                    .foregroundStyle(mode == model.modeSelection ? ListeningStyle.background : ListeningStyle.paper)
                    .padding(16).frame(minHeight: 52)
                    .background(mode == model.modeSelection ? ListeningStyle.orange : ListeningStyle.surface, in: CutCornerShape(cut: 12))
                }.buttonStyle(TactileButtonStyle())
            }
            Text("这是你给音乐的方向，下次选曲生效。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var messageView: some View {
        if let message = model.message, !message.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(ListeningStyle.orange).padding(.top, 2)
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.message = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("关闭提示")
            }.padding(.leading, 12).padding(.vertical, 6)
                .background(ListeningStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func togglePlayback() {
        ListeningHaptics.playPause()
        if model.isPlaying || model.isLoading { model.pause() }
        else { Task { await model.play() } }
    }

    private func directionSymbol(_ mode: ModeSelection) -> String {
        switch mode {
        case .auto: return "sparkles"
        case .focus: return "scope"
        case .relax: return "leaf"
        case .move: return "figure.walk"
        }
    }

    private func loadAndAnalyze(_ item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                model.message = "无法读取这张照片。"; return
            }
            let prepared = await Task.detached(priority: .userInitiated, operation: {
                let timestamp = PhotoTimestamp.read(from: data)
                return (PhotoProcessing.jpegForAnalysis(from: data), timestamp)
            }).value
            guard let jpeg = prepared.0 else { model.message = "无法处理这张照片。"; return }
            await model.analyzePhoto(jpegData: jpeg, capturedAt: prepared.1.capturedAt,
                captureTimeLabel: prepared.1.label)
        } catch { model.message = "选择照片失败：\(error.localizedDescription)" }
    }

    private func formatTime(_ seconds: Double) -> String {
        let value = Int(seconds.isFinite && seconds >= 0 ? seconds : 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct TrackCover: View {
    let urlString: String?
    var trackID: String? = nil
    let size: CGFloat
    @State private var loadedImage: UIImage?
    private var artworkKey: String { (trackID ?? "") + "|" + (urlString ?? "") }
    var body: some View {
        Group {
            if let loadedImage { Image(uiImage: loadedImage).resizable().scaledToFill() }
            else {
                Image("LinYiIcon").resizable().scaledToFill()
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(width: size, height: size).clipped()
        .task(id: artworkKey) {
            loadedImage = nil
            let image = await MusicArtworkStore.shared.image(trackID: trackID, urlString: urlString)
            guard !Task.isCancelled else { return }
            loadedImage = image
        }
    }
}

private struct CutCornerShape: Shape {
    var cut: CGFloat = 16
    func path(in rect: CGRect) -> Path {
        let amount = min(cut, min(rect.width, rect.height) / 3)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - amount, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + amount))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + amount, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - amount))
            path.closeSubpath()
        }
    }
    func strokeBorderFallback(_ color: Color) -> some View { stroke(color, lineWidth: 1) }
}

private struct TactileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
