# 构建与验证

## 环境

- macOS 与 Xcode，项目最低 iOS 版本为 17.0。
- 这份源码的发布检查使用 Xcode 15.3 / iOS 17.4 SDK；更新工具链的结果请以自己的构建为准。
- 真机运行需要 iOS 17+ 的 iPhone、开发者模式，以及支持工程能力的签名配置。工程包含 HealthKit entitlement；若签名报能力不支持，请先检查开发者团队及 provisioning profile。
- 无需安装 CocoaPods、第三方 Swift Package 或独立后端。

## 真机运行

```bash
git clone https://github.com/Luase233/linting.git
cd linting
open ios/BGMPrototype.xcodeproj
```

选中 `BGMPrototype` target，在 Signing & Capabilities 中选择自己的 Team、设置自己唯一的 Bundle Identifier，并确认 HealthKit 能力和签名匹配。连接 iPhone，选择设备，点击 Run。设备上可能还需要按系统提示信任开发者。

内部工程名保留 `BGMPrototype`，安装后显示名称为「霖听」。仓库不包含开发者证书或 provisioning profile。修改 Bundle Identifier 会安装为独立应用，原应用的学习数据不会自动迁移。

## 首次配置

1. 在账号入口登录自己的网易云账号。歌曲搜索、歌单与播放使用音乐平台服务，能否播放完整歌曲取决于账号和版权权限。
2. 按需授权健康读取。拒绝授权或没有健康样本也可以使用其他功能。
3. 若使用位置功能，主动定位并添加命名地点。大陆高德底图使用显示坐标转换；其他底图请检查设置中的大陆地图修正选项。
4. 若使用云端分析，在「歌曲与照片理解」填写阿里百炼北京地域 API Key。Key 保存在本机 Keychain，不填写也可以使用播放器及本地学习。
5. 照片仅在主动选择分析时发送。可以调整近期图片保留策略、填写自己的听歌想法，并纠正不合适的推测。

当前源码固定歌曲文本模型 `qwen-flash-2025-07-28`、照片模型 `qwen3-vl-flash-2026-01-22`。如果服务商调整版本或计费，应同时审阅 `SongAnalysisBudget.swift` 中的模型、预留量、预算与价格假设。

## 无签名构建检查

在仓库根目录运行：

```bash
xcodebuild -quiet \
  -project ios/BGMPrototype.xcodeproj \
  -target BGMPrototype \
  -configuration Release \
  -sdk iphoneos \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO \
  SYMROOT=/tmp/linting-public-products \
  OBJROOT=/tmp/linting-public-objects \
  build
```

该命令检查源码与资源能否编译，不生成可直接安装的签名 IPA，不验证健康权限、云端服务、真实音频输出或后台控制。

## 可离线执行的行为检查

```bash
bash scripts/check-core.sh
```

脚本在临时目录编译并执行现有检查：播放证据、分数语义、目标迁移、BPM 估计、云端预算、照片时间戳、情境时效与地点质量。无需账号、网络请求、付费调用或手机数据。测试使用合成数据，不能证明对真实用户的推荐质量。

`ios/Tests` 还包含云端协议、数据库、地点等专项检查，每个文件是独立程序，需要配套源码和相应平台框架；上述脚本不宣称运行全部专项检查。

真机诊断代码只在 Debug 构建且明确配置 `LINTING_DEVICE_CHECK=1` 时触发。普通启动不会执行自动播放测试；诊断产生的本机报告不要提交到仓库。

## 本地评估新目标

```bash
python3 scripts/evaluate-recommendations.py /path/to/local/linting-v2.sqlite
```

仅使用自己导出的数据库副本，若有 WAL，须与数据库放在同一目录。脚本不联网、只读访问，输出聚合数据；不要将数据库提交到仓库。旧版本没有兼容的新目标标签时，会如实报告样本不足。
