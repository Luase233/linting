import SwiftUI

struct ListeningSettingsView: View {
    @ObservedObject var model: BGMViewModel
    // Keep the settings switch and ListeningHaptics on the same persisted preference.
    @AppStorage("listeningHapticsEnabled") private var hapticsEnabled = true

    var body: some View {
        List {
            Section {
                HStack(spacing: 18) {
                    Image("LinYiIcon")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("霖听").font(.title2.weight(.semibold))
                        Text("慢慢听，慢慢懂你")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(ListeningSettingsPalette.card)

            Section("为你选曲") {
                NavigationLink {
                    ListeningHealthView(health: model.health)
                } label: {
                    ListeningSettingsRow(title: "健康摘要", detail: "身体的线索，留在手机里", symbol: "heart.text.square")
                }
                NavigationLink {
                    ListeningSettingsCardPage(title: "歌曲理解") {
                        SongAnalysisCard()
                    }
                } label: {
                    ListeningSettingsRow(title: "歌曲理解", detail: "歌曲档案与云端分析", symbol: "sparkles")
                }
                NavigationLink {
                    ListeningLearningView(model: model)
                } label: {
                    ListeningSettingsRow(title: "听歌习惯", detail: "看看霖听正在如何了解你", symbol: "waveform.path")
                }
            }
            .listRowBackground(ListeningSettingsPalette.card)

            Section("连接与体验") {
                NavigationLink {
                    ListeningSettingsCardPage(title: "网易云账号") {
                        MusicAccountCard(account: model.musicAccount)
                    }
                } label: {
                    ListeningSettingsRow(title: "网易云账号", detail: "账号与听歌偏好", symbol: "person.crop.circle")
                }
                Toggle(isOn: $hapticsEnabled) {
                    ListeningSettingsRow(title: "触感反馈", detail: "为轻触、切歌和喜欢添一点回响", symbol: "hand.tap")
                }
                .tint(ListeningSettingsPalette.accent)
                .onChange(of: hapticsEnabled) { _, enabled in
                    if enabled { ListeningHaptics.select() }
                }
            }
            .listRowBackground(ListeningSettingsPalette.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("我的")
        .modifier(ListeningSettingsSurface())
    }
}

private enum ListeningSettingsPalette {
    static let background = Color(red: 0.07, green: 0.075, blue: 0.07)
    static let card = Color(red: 0.12, green: 0.125, blue: 0.12)
    static let accent = Color(red: 1, green: 0.48, blue: 0.14)
}

private struct ListeningSettingsSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(ListeningSettingsPalette.background)
            .foregroundStyle(.white)
            .tint(ListeningSettingsPalette.accent)
            .toolbarBackground(ListeningSettingsPalette.background, for: .navigationBar)
            .preferredColorScheme(.dark)
    }
}

private struct ListeningSettingsRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(ListeningSettingsPalette.accent)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44, alignment: .leading)
    }
}

/// Existing account and analysis controls retain their original bindings and login sheets.
private struct ListeningSettingsCardPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .buttonStyle(ListeningSettingsButtonStyle())
                .textFieldStyle(ListeningSettingsTextFieldStyle())
                .disclosureGroupStyle(ListeningSettingsDisclosureStyle())
                .controlSize(.large)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ListeningSettingsSurface())
    }
}

private struct ListeningSettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(configuration.role == .destructive ? Color.red : ListeningSettingsPalette.accent)
            .padding(.horizontal, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

private struct ListeningSettingsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.frame(minHeight: 44)
    }
}

private struct ListeningSettingsDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { @MainActor in ListeningHaptics.select() }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack {
                    configuration.label
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            if configuration.isExpanded { configuration.content }
        }
    }
}

private struct ListeningHealthView: View {
    @ObservedObject var health: HealthKitManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("听见身体的线索").font(.title2.weight(.semibold))
                    Text("为此刻的选曲，添一份关于你的参考。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                if health.enabled {
                    VStack(alignment: .leading, spacing: 18) {
                        healthRow(health.heartText, symbol: "heart.fill")
                        Divider()
                        healthRow(health.restingHeartText, symbol: "heart")
                        Divider()
                        healthRow(health.hrvText, symbol: "waveform.path.ecg")
                        Divider()
                        healthRow(health.workoutText, symbol: "figure.run")
                        Divider()
                        healthRow(health.sleepText, symbol: "moon.zzz.fill")
                    }
                    .padding(18)
                    .background(ListeningSettingsPalette.card, in: RoundedRectangle(cornerRadius: 20))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(health.summary)
                            .font(.subheadline)
                            .foregroundStyle(ListeningSettingsPalette.accent)
                        if let updated = health.updatedAt {
                            Text("读取于 \(updated.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    VStack(spacing: 0) {
                        Button {
                            ListeningHaptics.select()
                            Task { _ = await health.refresh() }
                        } label: {
                            actionLabel(health.isRefreshing ? "正在读取…" : "更新数据", symbol: "arrow.clockwise")
                        }
                        .disabled(health.isRefreshing)
                        Divider()
                        Button {
                            ListeningHaptics.select()
                            Task { await health.enable() }
                        } label: {
                            actionLabel("更新健康权限", symbol: "checkmark.shield")
                        }
                        Divider()
                        Button(role: .destructive) {
                            ListeningHaptics.select()
                            health.disable()
                        } label: {
                            actionLabel("停用体征", symbol: "pause.circle")
                        }
                    }
                    .buttonStyle(ListeningSettingsButtonStyle())
                    .padding(.horizontal, 12)
                    .background(ListeningSettingsPalette.card, in: RoundedRectangle(cornerRadius: 20))
                } else {
                    Button {
                        ListeningHaptics.select()
                        Task { await health.enable() }
                    } label: {
                        Label("连接 Apple 健康", systemImage: "heart.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                }

                Text(health.status)
                    .font(.subheadline).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("这些数据如何使用").font(.headline)
                    Text("读取心率、静息心率、HRV、睡眠和健身摘要，与个人基线及记录时间一起参与选曲。数据缺失或较早时会降低参考权重。")
                    Text("健康摘要与个人偏好学习保存在手机。新增读取项目时，可点“更新健康权限”在系统页面选择；停用体征后，之后的选曲不再使用健康摘要。")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("健康摘要")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ListeningSettingsSurface())
        .task { _ = await health.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { _ = await health.refresh() } }
        }
    }

    private func healthRow(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(ListeningSettingsPalette.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct ListeningLearningView: View {
    @ObservedObject var model: BGMViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "waveform.path")
                        .font(.largeTitle)
                        .foregroundStyle(ListeningSettingsPalette.accent)
                        .accessibilityHidden(true)
                    Text("慢慢了解你的听歌习惯")
                        .font(.title2.weight(.semibold))
                    Text(model.learningSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(ListeningSettingsPalette.card, in: RoundedRectangle(cornerRadius: 20))

                explanation("正常听歌，就是反馈", symbol: "play.circle",
                    text: "切歌会结合实际播放时长和播放覆盖比例；回拉之后真正重听的片段也会留下线索。拖动进度条，不会把跳过的部分算作听过。")
                explanation("喜欢，与此刻合适", symbol: "heart",
                    text: "“喜欢”和“不喜欢”会调整歌曲偏好；“现在不合适”只修正当时情境的适配。健康、时间与场景和歌曲特征一起参与学习。")
                explanation("也为未知留一点余地", symbol: "sparkles",
                    text: "推荐保留发现新歌的机会。自动播完不会直接当成喜欢；暂停、播放失败和系统中断也不会被当成讨厌。")
                explanation("关于歌曲理解", symbol: "music.note.list",
                    text: "先从已有口味和歌曲线索开始，再使用缓存的歌词与资料分析。同时从有限音频片段测量 BPM；测量不足会保留未知。健康数据不会直接解释为你的情绪。")
            }
            .padding(20)
        }
        .navigationTitle("听歌习惯")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ListeningSettingsSurface())
    }

    private func explanation(_ title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.white)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
