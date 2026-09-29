import CoreLocation
import MapKit
import SwiftUI

struct UserPlacesView: View {
    @ObservedObject var manager: LocationContextManager
    @State private var editing: UserPlace?
    @State private var adding = false
    var body: some View {
        List {
            Section {
                Toggle("使用地点辅助选曲", isOn: $manager.enabled)
                Text(manager.status).font(.caption).foregroundStyle(.secondary)
                Button { manager.requestUpdate() } label: {
                    Label(manager.requesting ? "定位中…" : "更新当前位置", systemImage: "location")
                }.disabled(manager.requesting)
                Text("按需定位，不在后台持续追踪。坐标和地点名称只保存在手机；云端只接收“在家 / 在学校 / 在移动中”等类别与时间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("我的地点") {
                ForEach(manager.places) { place in
                    Button { editing = place } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(place.name).foregroundStyle(.primary)
                                Text("\(place.kind.title) · 半径 \(Int(place.radius)) 米").font(.caption).foregroundStyle(.secondary)
                                if place.coordinateSystem == nil {
                                    Text("旧版选点，请检查地图位置后重新保存").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }
                    }
                    .swipeActions { Button("删除", role: .destructive) { manager.removePlace(place.id) } }
                }
                Button { adding = true } label: { Label("添加地点", systemImage: "plus") }.disabled(!manager.hasLoadedPlaces)
                if !manager.hasLoadedPlaces { Button("读取已有地点") { Task { await manager.restore() } } }
            }
            Section {
                Text("地图上移动到学校或家，调整识别范围后保存。未落在地点范围内不会自动当成“在路上”；检测到实际移动才会标记移动中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("地图显示") {
                Toggle("修正大陆高德地图偏移", isOn: $manager.mainlandMapCorrection)
                Text("当前使用高德底图时开启；若换到其他地区的 Apple 底图请关闭。只转换地图显示和选点，地点匹配统一使用真实地理坐标。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("我的地点").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { PlaceEditor(manager: manager, place: nil) }
        .sheet(item: $editing) { PlaceEditor(manager: manager, place: $0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in manager.cancelUpdate() }
    }
}

private struct PlaceEditor: View {
    @ObservedObject var manager: LocationContextManager
    let place: UserPlace?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: UserPlace.Kind
    @State private var radius: Double
    @State private var center: CLLocationCoordinate2D
    @State private var position: MapCameraPosition
    @State private var pendingRecenter = false
    @State private var recenterRequestedAt = Date.distantFuture
    @State private var hasChosenCenter: Bool

    init(manager: LocationContextManager, place: UserPlace?) {
        self.manager = manager; self.place = place
        let coordinate = place.map { manager.mapCoordinate(for: $0) } ?? manager.lastCoordinate.map { manager.mapCoordinate($0) } ?? CLLocationCoordinate2D(latitude: 20, longitude: 105)
        _name = State(initialValue: place?.name ?? "")
        _kind = State(initialValue: place?.kind ?? .home)
        _radius = State(initialValue: place?.radius ?? 300)
        _center = State(initialValue: coordinate)
        _hasChosenCenter = State(initialValue: place != nil || manager.lastCoordinate != nil)
        let span = place != nil || manager.lastCoordinate != nil ? 0.025 : 60.0
        _position = State(initialValue: .region(MKCoordinateRegion(center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $position) {
                    MapCircle(center: center, radius: radius).foregroundStyle(.orange.opacity(0.2))
                    if let coordinate = manager.lastCoordinate, let accuracy = manager.horizontalAccuracy {
                        MapCircle(center: manager.mapCoordinate(coordinate), radius: accuracy).foregroundStyle(.blue.opacity(0.18))
                        Annotation("当前位置", coordinate: manager.mapCoordinate(coordinate)) {
                            Circle().fill(.blue).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                .onMapCameraChange(frequency: .onEnd) {
                    center = $0.region.center
                    if position.positionedByUser { hasChosenCenter = true; pendingRecenter = false }
                }
                .overlay { Image(systemName: "mappin.circle.fill").font(.largeTitle).foregroundStyle(.orange).allowsHitTesting(false) }
                .frame(minHeight: 220, maxHeight: 350)
                Form {
                    TextField("地点名称，例如：家、教学楼", text: $name)
                    Picker("地点类型", selection: $kind) { ForEach(UserPlace.Kind.allCases) { Text($0.title).tag($0) } }
                    VStack(alignment: .leading) {
                        Text("识别半径：\(Int(radius)) 米")
                        Slider(value: $radius, in: 100...2000, step: 100)
                    }
                    Button("将地图移到当前位置") {
                        pendingRecenter = true
                        recenterRequestedAt = Date()
                        manager.requestUpdate()
                    }.disabled(manager.requesting)
                    Text(manager.status).font(.caption).foregroundStyle(.secondary)
                    Text("橙色图钉是保存的地点中心；蓝点是最新定位，蓝圈是估计误差。拖动地图可手动校正。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(place == nil ? "添加地点" : "编辑地点").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let geographic = manager.geographicCoordinate(center)
                        if manager.savePlace(UserPlace(id: place?.id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            kind: kind, latitude: geographic.latitude, longitude: geographic.longitude, radius: radius, coordinateSystem: "wgs84")) {
                            dismiss()
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 40 || !hasChosenCenter || manager.requesting || !manager.hasLoadedPlaces)
                }
            }
            .onChange(of: manager.fixRevision) { _, _ in
                if pendingRecenter {
                    pendingRecenter = false
                    guard let coordinate = manager.lastCoordinate, let observedAt = manager.observedAt,
                          observedAt >= recenterRequestedAt.addingTimeInterval(-2) else { return }
                    hasChosenCenter = true
                    center = manager.mapCoordinate(coordinate)
                    position = .region(MKCoordinateRegion(center: center, span: .init(latitudeDelta: 0.008, longitudeDelta: 0.008)))
                }
            }
            .onDisappear { manager.cancelUpdate() }
        }.preferredColorScheme(.dark)
    }
}
