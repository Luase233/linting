import SwiftUI
import Charts

struct RecommendationExplanationView: View {
    let snapshot: AdaptiveDecisionSnapshot?
    let track: RecommendedTrack
    let candidates: [RecommendedTrack]
    @ObservedObject private var profiles = TrackProfileStore.shared
    private struct Factor: Identifiable { let id: String; let title: String; let value: Double }
    private var chosen: AdaptiveCandidateSnapshot? { snapshot?.candidate(track.id) }
    private var factors: [Factor] {
        guard let chosen else { return [] }
        let names = [("discovery", "探索与熟悉度先验"), ("favorite", "明确喜欢先验"), ("artist", "常听艺人先验"),
            ("recency", "近期重复扣分"), ("variety", "艺人重复扣分"), ("intent", "手动方向先验"),
            ("visual_intent", "听歌意图直接先验"), ("self_reported_mood", "自报感受直接先验"),
            ("acceptance", "旧版接受贡献"), ("rejection", "旧版拒绝贡献"),
            ("affinity", "明确偏好贡献"), ("replay", "回听贡献"),
            ("continuation", "持续收听贡献"), ("fit", "明确当下合适贡献"),
            ("baseline", "中性基线校正"), ("historical_remainder", "历史未细分项")]
        let values = RecommendationScoreDefinition.explanationFactors(score: chosen.score,
            predictions: chosen.predictions, storedFactors: chosen.scoreFactors)
        let known = Set(names.map(\.0))
        return names.compactMap { key, name in values[key].map { Factor(id: key, title: name, value: $0) } }
            + values.keys.filter { !known.contains($0) }.sorted().compactMap { key in
                values[key].map { Factor(id: key, title: key, value: $0) }
            }
    }

    private var selectionTitle: String {
        switch snapshot?.selection {
        case "manual_search": return "搜索点播"
        case "manual_playlist": return "歌单点播"
        case "manual_candidate": return "你选择了候选歌曲"
        case "manual_replay": return "你主动重播"
        case "manual_previous": return "你返回了上一首"
        case "diagnostic": return "设备测试播放"
        case "manual_selection": return "你主动点播"
        default: return chosen?.probability == nil ? "手动选择记录" : "按当下依据选曲"
        }
    }

    private var comparisonRows: [(rank: Int, item: AdaptiveCandidateSnapshot)] {
        guard let snapshot else { return [] }
        let ranked = snapshot.candidates.sorted {
            $0.score == $1.score ? $0.trackID < $1.trackID : $0.score > $1.score
        }.enumerated().map { (rank: $0.offset + 1, item: $0.element) }
        var shown = Array(ranked.prefix(8))
        if !shown.contains(where: { $0.item.trackID == track.id }), let selected = ranked.first(where: { $0.item.trackID == track.id }) {
            shown.append(selected)
        }
        return shown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(track.title).font(.title2.bold())
                Text(track.artist).foregroundStyle(.secondary)
            }
            if let snapshot, let chosen {
                evidenceSummary(chosen)
                contextInfluences(snapshot)
                DisclosureGroup("查看算法诊断：分数、倾向与抽样") {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        Text(chosen.probability == nil ? "模型参考分" : "本轮排序总分").font(.caption).foregroundStyle(.secondary)
                        Text(chosen.score, format: .number.precision(.fractionLength(3))).font(.largeTitle.bold().monospacedDigit())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if let probability = chosen.probability {
                            Text(probability, format: .percent.precision(.fractionLength(1))).font(.title2.bold().monospacedDigit())
                            Text("本轮被抽中概率").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(selectionTitle).font(.headline)
                            Text(snapshot.selection == "diagnostic" ? "设备验证，不参与抽样" : "由你指定，不参与本轮抽样").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(snapshot.at.formatted(date: .abbreviated, time: .standard) + " · " + snapshot.policyVersion)
                    .font(.caption2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Text("排序分怎样算出来").font(.headline)
                    Text("各项实际贡献相加得到排序分；负值减少优先级，正值提高优先级。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Chart(factors) { factor in
                        BarMark(xStart: .value("起点", min(0, factor.value)), xEnd: .value("分数", max(0, factor.value)), y: .value("因素", factor.title))
                            .foregroundStyle(factor.id == "baseline" ? Color.gray : factor.value >= 0 ? Color.orange : Color.red)
                            .annotation(position: factor.value >= 0 ? .trailing : .leading) {
                                Text(String(format: "%+.3f", factor.value)).font(.caption2.monospacedDigit())
                            }
                    }.chartXAxisLabel("分值贡献（全部相加 = 总分）")
                        .frame(height: CGFloat(max(5, factors.count)) * 31 + 35)
                        .padding(.horizontal, 8)
                    Text("总分不是百分制，也不适合跨轮比较。新目标独立学习，旧快照保留当时公式。显示保留三位，合计用原始精度。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(chosen.probability == nil
                        ? "这是点播时的模型参考值，不是选择这首的原因；点播没有候选排序先验，也没有抽样概率。"
                        : "时间、健康、场景与歌曲特征参与模型；直接先验不是情境影响的全部。当前输出均未经独立概率校准。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                predictionRows(chosen)
                if chosen.probability != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("抽中概率是选曲规则，不是适合你的概率。").font(.caption.bold())
                        if let budget = snapshot.explorationBudget {
                            Text("本轮探索预算 " + String(format: "%.0f%%", budget * 100) + "；仅在质量门槛内、存在兴趣关联且证据不足的候选中探索。其余概率分配给优先候选。")
                                .font(.caption2)
                        } else if let temperature = snapshot.samplingTemperature, let exploration = snapshot.uniformExploration {
                            Text(String(format: "抽样概率 = %.0f%% × softmax(总分 ÷ %.2f) + %.0f%% ÷ 候选数", (1 - exploration) * 100, temperature, exploration * 100))
                                .font(.caption2.monospacedDigit())
                        } else {
                            Text("历史快照未记录抽样参数，保留当时的原始概率。").font(.caption2)
                        }
                        Text("本轮共 \(snapshot.candidates.count) 首候选，最终概率合计为 100%。未通过策略门槛的候选为 0；下方展示前八名和本次选中歌曲。旧版快照仍显示旧规则。")
                            .font(.caption)
                    }.foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("本轮候选对照").font(.headline)
                        ForEach(comparisonRows, id: \.item.trackID) { row in
                            let item = row.item
                            HStack {
                                Text("\(row.rank)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title ?? candidates.first { $0.id == item.trackID }?.title ?? (item.trackID == track.id ? track.title : "歌曲 \(item.trackID)"))
                                        .font(.caption).lineLimit(1)
                                    Text([item.artist, item.recallChannels?.joined(separator: " · ") ?? item.sourceTag].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.trackID == track.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange) }
                                Text(item.score, format: .number.precision(.fractionLength(2))).font(.caption.monospacedDigit())
                                if let p = item.probability { Text(p, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()).frame(width: 38) }
                            }
                        }
                    }
                }
                }
            } else {
                Text("这首歌还没有可用的决策快照；完成选曲后会显示真实依据。").foregroundStyle(.secondary)
            }
            Divider()
            tempoSection
            Text(profiles.evidenceSummary(for: track.id)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func evidenceSummary(_ candidate: AdaptiveCandidateSnapshot) -> some View {
        let evidence = candidate.effectiveEvidence ?? [:]
        let count = evidence.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 12) {
            Label(selectionTitle, systemImage: "waveform.path").font(.headline)
            Text(candidate.probability == nil ? "由你选择，继续记录真实反馈" :
                candidate.selectionRole == "explore" ? "通过门槛，尝试了解的新候选" :
                candidate.selectionRole == "main" ? "本轮优先候选" : "历史推荐记录")
                .font(.title3.bold())
            Text(count == 0 ? "这首歌的有效反馈仍不足，当前主要参考已有口味、歌曲资料和可用情境。" :
                "这首歌有 \(count) 项有效目标记录；同一次播放可能支持多个目标，不能视为 \(count) 次独立验证。")
                .font(.subheadline).foregroundStyle(.secondary)
            if let channels = candidate.recallChannels, !channels.isEmpty {
                Text("从这里找到它：" + channels.joined(separator: " · ")).font(.caption)
            }
            if (candidate.scoreFactors?["favorite"] ?? 0) > 0 {
                Label("你明确喜欢过这首歌", systemImage: "heart").font(.caption)
            }
            if (candidate.scoreFactors?["artist"] ?? 0) > 0 {
                Label("与你常听的艺人有关", systemImage: "person.wave.2").font(.caption)
            }
            Text("是否适合此刻，以你的反馈为准；目前不展示未经校准的“适合百分比”。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func contextInfluences(_ snapshot: AdaptiveDecisionSnapshot) -> some View {
        if let influences = snapshot.contextInfluences, !influences.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("情境实际改变了什么").font(.headline)
                ForEach(influences, id: \.source) { influence in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(["visual": "图片", "image": "图片", "place": "位置", "location": "位置", "health": "体征"][influence.source] ?? influence.source).font(.subheadline.bold())
                            Spacer()
                            Text(influence.coverage > 0 ? (influence.rankingChanged ? "改变排序" : "未改变排序") : "本轮缺少有效线索")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let effect = influence.candidateEffects.first(where: { $0.trackID == track.id }) {
                            Text(String(format: "移除该类线索后对照：本曲贡献差 %+.3f；选择分布变化 %.1f%%。", effect.scoreDelta, influence.totalVariation * 100))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if !influence.missing.isEmpty {
                            Text(influence.missing.joined(separator: "；")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("这是同一轮候选的移除对照，只说明线索怎样影响决策；不能证明体验改善或因果关系。图片曾引用地点时，两者相关，影响不能相加。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func predictionLabels(_ candidate: AdaptiveCandidateSnapshot) -> [(String, String, String)] {
        if candidate.predictions["continuation"] != nil {
            return [("continuation", "持续收听", "可观察结果"), ("fit", "当下合适", "明确反馈"),
                    ("affinity", "长期偏好", "明确喜欢"), ("replay", "主动回听", "实际重听")]
        }
        return [("acceptance", "旧版接受", "软目标"), ("rejection", "旧版拒绝", "软目标"),
                ("affinity", "明确偏好", "高更有利"), ("replay", "主动回听", "高更有利")]
    }

    private func predictionRows(_ candidate: AdaptiveCandidateSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("模型倾向诊断").font(.headline)
            Text("范围 0–100，来自多种反馈的软目标学习；不是校准后的发生概率，也不要求相加为 100。未学习的中性初值不代表有一半把握。")
                .font(.caption).foregroundStyle(.secondary)
            Text("持续收听只描述可观察的播放结果；当下合适来自明确反馈；喜欢描述长期口味。它们不是彼此独立的统计证据，排序系数仍是待验证的工程参数。旧版接受／拒绝软目标仅供历史诊断。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(predictionLabels(candidate), id: \.0) { key, title, direction in
                if let value = candidate.predictions[key], value.isFinite {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(title).font(.caption.bold())
                            Text(direction).font(.caption2).foregroundStyle(key == "rejection" ? Color.red : Color.secondary)
                            Spacer()
                            Text(String(format: "%.1f / 100", min(1, max(0, value)) * 100)).font(.caption.monospacedDigit())
                        }
                        ProgressView(value: min(1, max(0, value))).tint(key == "rejection" ? .red : .orange)
                        if let count = candidate.predictionUpdates?[key] {
                            Text(count == 0 ? "当时尚无这类学习记录，使用中性初值。" : "模型全局更新 \(count) 次；不代表这首歌有同等证据量。")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else { Text("旧快照未记录该项学习次数。").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private var tempoSection: some View {
        let tempo = profiles.tempoSummary(for: track.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("音频节拍抽样", systemImage: "metronome").font(.headline)
                Spacer()
                if let bpm = tempo.bpm { Text("\(Int(bpm.rounded())) BPM").font(.title3.bold().monospacedDigit()) }
                else { Text("待测量 / 未知").font(.caption).foregroundStyle(.secondary) }
            }
            Text(tempo.message).font(.caption).foregroundStyle(.secondary)
            Text(tempo.samplingSummary).font(.caption).foregroundStyle(.secondary)
            if !tempo.segments.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(tempo.segments.enumerated()), id: \.offset) { _, segment in
                        HStack {
                            Text("\(timeLabel(segment.startSeconds))–\(timeLabel(segment.endSeconds))")
                                .font(.caption.monospacedDigit())
                            Spacer()
                            if let bpm = segment.bpm {
                                Text("\(Int(bpm.rounded())) BPM").font(.caption.bold().monospacedDigit())
                            } else { Text("节拍不明确").font(.caption).foregroundStyle(.secondary) }
                            Text("\(Int((segment.confidence * 100).rounded()))%")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("分段百分比是节拍估计可信度，不是听歌偏好。仅资源片段的结果不会作为整曲 BPM 进入推荐。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(chosen?.features["music.tempo"] != nil ? "本轮决策已使用当时缓存的节拍特征。" : "本轮决策未使用 BPM；当前测量完成后用于后续推荐。")
                .font(.caption2).foregroundStyle(.secondary)
            if let confidence = tempo.confidence {
                Text("节拍估计可信度 \(Int((confidence * 100).rounded()))% · 音频样本 \(Int(tempo.analyzedAudioSeconds ?? 0)) 秒")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("片段节拍可能出现半拍或双拍误差，BPM 不是歌曲适合你的充分条件。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "未知" }
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

}
