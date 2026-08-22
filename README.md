# AutoRecord

轻量化 macOS 自动录制工具。基于 ROI 颜色检测自动启停录制,零第三方依赖,单二进制。

## 特性

- **自动录制** — 监控 ROI 区域颜色变化,触发后自动录制
- **手动录制** — 快捷键手动控制录制启停
- **ROI 颜色检测** — 支持最多 3 个 ROI 区域,按颜色变化触发
- **状态栏状态** — 实时显示监控中 / 录制状态与文件名
- **预置保存位置** — 可选择外置硬盘作为默认保存路径
- **轻量化** — 纯 Swift + AVFoundation,单二进制,无运行时依赖

## 系统要求

- macOS 12 Monterey 或更高
- AVFoundation 兼容采集卡
- (可选)外置硬盘用于保存录制文件

## 下载

从 [GitHub Releases](https://github.com/jeremyzhu666/auto-record/releases) 下载最新版本。

## 使用

### 基本操作

1. 打开 AutoRecord,主窗口显示摄像头预览
2. 在设置面板(⌘,)中配置:
   - 保存路径(支持外置硬盘)
   - ROI 区域(最多 3 个)
   - 触发颜色和容差
3. 开始监控,满足触发条件后自动录制
4. 录制文件命名:`EXT_YYMMDD_HHMMSS_XX.mov`(自动)/ `INT_YYMMDD_HHMMSS_XX.mov`(手动)

### 快捷键

| 按键 | 功能 |
|------|------|
| ⌘, | 打开 / 关闭设置 |
| ⌘R | 手动录制开关 |
| ⌘Q | 退出应用 |

### 状态栏说明

- `监控中` — 正在等待触发条件
- `录制（EXT）：文件名` — 自动录制进行中
- `录制（INT）：文件名` — 手动录制进行中

## 构建

```bash
swiftc -O -target arm64-apple-macos12 \
    main.swift AppState.swift PreviewTab.swift SettingsTab.swift SharedTypes.swift TriggerLogic.swift \
    -framework AVFoundation -framework AppKit -framework CoreVideo \
    -o AutoRecord
```

## 项目结构

| 文件 | 说明 |
|------|------|
| `main.swift` | 应用入口,App 生命周期 |
| `AppState.swift` | 全局状态管理 |
| `PreviewTab.swift` | 预览窗口与 ROI 渲染 |
| `SettingsTab.swift` | 设置面板 UI |
| `SharedTypes.swift` | 共享类型定义 |
| `TriggerLogic.swift` | 触发检测逻辑 |

## 许可证

本项目仅供个人使用。
