import PhotosUI
import SwiftUI

struct VisualContextView: View {
    @ObservedObject var model: BGMViewModel
    @Binding var selectedPhoto: PhotosPickerItem?

    private let accent = Color(red: 1, green: 0.48, blue: 0.14)
    private var priorPhotoCount: Int {
        let limit = model.sceneMemoryPolicy == .recent24h ? 4 : model.sceneMemoryPolicy == .recent2h ? 2 : 0
        return min(limit, model.sceneMemorySnapshot?.photoCount ?? 0)
    }
    private var submittedNote: String {
        String(model.userNote.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Label("把此刻告诉霖听", systemImage: "sparkles").font(.title3.bold()).foregroundStyle(accent)
                Text("照片、前后的变化，加上你自己的感受，一起帮助音乐找到方向。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            selfReportSection
            photoSection
            if let analysis = model.lastSceneAnalysis {
                Divider()
                evidenceSection(analysis)
                intentSection
                imageTimeline(analysis)
            } else if let scene = model.scene {
                Text(scene.scene).font(.headline)
                Text(scene.description).font(.subheadline).foregroundStyle(.secondary)
            }
            Divider()
            memorySection
            NavigationLink {
                UserPlacesView(manager: model.locationContext)
            } label: {
                Label("给常去的地方起名字", systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
            if let message = model.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task { await model.refreshSceneMemory() }
        .onChange(of: model.lastSceneAnalysis?.analyzedAt) { _, _ in
            Task { await model.refreshSceneMemory() }
        }
    }

    private var selfReportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("我现在的感受").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], spacing: 8) {
                ForEach(SelfReportedMood.allCases, id: \.rawValue) { mood in
                    Button {
                        model.selfReportedMood = mood
                        ListeningHaptics.select()
                    } label: {
                        Text(mood.title).font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(model.selfReportedMood == mood ? accent.opacity(0.2) : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(model.selfReportedMood == mood ? accent : .clear, lineWidth: 1))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(model.selfReportedMood == mood ? .isSelected : [])
                }
            }
            TextField("可选：刚忙完一天，想放空一下……", text: $model.userNote, axis: .vertical)
                .lineLimit(2...4).padding(12)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: model.userNote) { _, note in
                    if note.count > 400 { model.userNote = String(note.prefix(400)) }
                }
            Text("感受由你填写；照片只推测活动与听歌方向，不作心理或健康判断。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label(model.isAnalyzing ? "正在理解此刻…" : "选照片，结合近况理解此刻", systemImage: "camera.viewfinder")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 46)
            }.buttonStyle(.borderedProminent).disabled(model.isAnalyzing)
            Text(priorPhotoCount > 0
                ? "这次会把所选照片和最多 \(priorPhotoCount) 张近期照片上传阿里云，并结合你写下的近况与场景摘要。"
                : "这次会把所选照片上传阿里云，并结合你写下的近况与已有场景摘要。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func evidenceSection(_ analysis: CloudSceneAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(analysis.scene, systemImage: "photo.on.rectangle.angled").font(.headline)
            Text(analysis.description).font(.subheadline).foregroundStyle(.secondary)
            Text("分析于 " + analysis.analyzedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
            if let report = analysis.userReport,
               report.note != submittedNote {
                Text("近况已修改；上次照片推测仍保留，选照片后可结合新的描述再分析。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let change = analysis.temporalChange, !change.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("前后有什么变化").font(.subheadline.weight(.semibold))
                    Text(change).font(.subheadline).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            if let location = analysis.locationLabel, !location.isEmpty {
                Label("分析时的位置 · " + location, systemImage: "mappin.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var intentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这时可能想听什么").font(.headline)
            if let hypothesis = model.inferredListeningIntent {
                HStack(alignment: .firstTextBaseline) {
                    Text(hypothesis.intent.title).font(.title3.bold())
                    Spacer()
                    Text(hypothesis.confidence, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(hypothesis.source.title + " · " + hypothesis.evidence)
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("百分比是参与选曲的参考强度，不代表判断正确率；未确认的照片推测还会进一步降低权重。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("线索还不够，你可以直接选一个方向。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let notice = model.lastSceneAnalysis?.intentNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            Text(model.intentConfirmationText).font(.caption).foregroundStyle(accent)
            HStack(spacing: 12) {
                if model.inferredListeningIntent != nil {
                    Button(model.inferredIntentConfirmed ? "已确认" : "对，就是这个方向") {
                        model.confirmInferredIntent()
                        ListeningHaptics.select()
                    }.buttonStyle(.borderedProminent).disabled(model.inferredIntentConfirmed)
                }
                Menu {
                    ForEach(ListeningIntent.allCases, id: \.rawValue) { intent in
                        Button(intent.title) { model.correctInferredIntent(intent) }
                    }
                    Divider()
                    Button("恢复自动推测") { model.resetInferredIntent() }
                } label: { Label("改一下", systemImage: "slider.horizontal.3").frame(minHeight: 44) }
                    .buttonStyle(.bordered)
            }
            Picker("照片推测如何参与选曲", selection: $model.inferredIntentPolicy) {
                Text("自动轻量参考").tag(InferredIntentPolicy.automatic)
                Text("先由我确认").tag(InferredIntentPolicy.confirmOnly)
            }.pickerStyle(.segmented)
            Text(model.inferredIntentPolicy == .automatic
                ? "未确认的推测只轻量参与下一首；你的选择和听歌反馈更优先。"
                : "照片中的方向先展示给你，确认或修改后才参与选曲。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func imageTimeline(_ analysis: CloudSceneAnalysis) -> some View {
        if let times = analysis.imageTimes, !times.isEmpty {
            DisclosureGroup("本次参考的 \(times.count) 张照片与时间") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(times) { time in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(time.isCurrent ? "本次选择" : "近期照片").font(.caption.weight(.semibold))
                            if let date = time.capturedAt {
                                Text("拍摄 · " + date.formatted(date: .abbreviated, time: .shortened))
                            } else if let label = time.captureTimeLabel, !label.isEmpty {
                                Text("拍摄记录 · " + label)
                            } else { Text("拍摄时间未知") }
                            Text("选择 · " + time.selectedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }.font(.caption2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("记住一小段近况").font(.headline)
            Picker("近期照片保留方式", selection: Binding(
                get: { model.sceneMemoryPolicy },
                set: { policy in Task { await model.changeSceneMemoryPolicy(policy) } }
            )) {
                ForEach(SceneMemoryPolicy.allCases, id: \.rawValue) { policy in
                    Text(policy.title).tag(policy)
                }
            }.pickerStyle(.menu)
            Text(model.sceneMemoryPolicy.detail).font(.caption).foregroundStyle(.secondary)
            if let memory = model.sceneMemorySnapshot {
                Text("本机近期保留 \(memory.photoCount) 张照片、\(memory.summaryCount) 条场景摘要。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button("清除照片与场景记录", role: .destructive) {
                Task { await model.clearSceneMemory() }
            }.font(.caption).frame(minHeight: 44)
        }
    }
}
