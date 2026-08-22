# AutoRecord

轻量化 macOS 自动录制工具。对接采集卡视频流,基于 ROI 颜色检测自动启停录制,无需手动值守。

## 特性

- **自动录制** — 在画面中划定圆形 ROI,当指定颜色(红/白/绿)进入区域自动开始录制,颜色消失自动停止
- **手动录制** — 按 `R` 键随时启停
- **实时预览** — 主窗口显示采集卡画面,支持 ROI 拖拽/缩放
- **状态栏** — 顶部实时显示 `监控中` / `录制（自动）：文件名` / `录制（手动）：文件名`
- **安全书签** — 首次选目录授权后自动记住,支持外置硬盘,无需反复授权
- **零依赖** — 纯 Swift + AppKit + AVFoundation,无第三方库

## 快捷键

| 键 | 功能 |
|---|---|
| `R` | 手动录制 开/停 |
| `M` | 监控 开/停 |
| `Cmd+,` | 设置窗口 开/关 |

## 架构

```
main.swift         入口:窗口/菜单/快捷键
AppState.swift     状态中枢:采集引擎 + 录制状态机 + 文件保存
PreviewTab.swift    主窗口:预览 + ROI 交互
SettingsTab.swift   设置窗口:ROI 列表 + 参数配置
TriggerLogic.swift  检测算法:ROI 内目标色匹配
SharedTypes.swift   共享类型:RGB / ROI / 通知名 / 颜色预设
```

## 编译

```bash
swiftc -O main.swift AppState.swift PreviewTab.swift SettingsTab.swift SharedTypes.swift TriggerLogic.swift -o AutoRecord
```

通用二进制:

```bash
SDK=$(xcrun --sdk macosx --show-sdk-path)
swiftc -target arm64-apple-macos12 -sdk "$SDK" -O *.swift -o AutoRecord_arm64
swiftc -target x86_64-apple-macos12 -sdk "$SDK" -O *.swift -o AutoRecord_x86
lipo -create -output AutoRecord AutoRecord_arm64 AutoRecord_x86
```

## 文件命名

录制文件按 `前缀_YYMMDD_HHMMSS_随机字母.mov` 格式自动命名(EXT=自动/INT=手动):

- `EXT_260823_120530_AB.mov` — 自动触发录制
- `INT_260823_120530_CD.mov` — 手动录制

## 系统要求

- macOS 12+
- 采集卡(Blackmagic / UltraStudio / DeckLink 或其他 AVFoundation 兼容设备)

## 权限

- **摄像头** — 预览与录制必需
- **麦克风** — 录制时可能采集音频
- **文件夹访问** — 首次选择保存目录时授权一次,之后自动写入(含外置硬盘)
