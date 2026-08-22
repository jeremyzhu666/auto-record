// main.swift
// 【入口】AppDelegate:组装窗口/菜单/快捷键,启动引擎,调用 NSApp.run。
// 不含业务逻辑:UI 由 PreviewTab / SettingsTab 承担;状态 & 采集由 AppState 承担;
// 检测算法由 TriggerLogic 承担;类型契约由 SharedTypes 提供。
// ============== 三足鼎立 ==============
//   界面(PreviewTab / SettingsTab)  ──通知──  设置/AppState
//          │                                  │
//          └───── AppState.shared ────算法(TriggerLogic / sampleHasColor)
// =====================================

import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow!
    private var settingsWindow: NSWindow!
    private var previewTab: PreviewTab!
    private var settingsTab: SettingsTab!
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.engine.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppState.shared.startMonitoring()
        }
        // 启动后检查保存目录权限,外置硬盘提前授权
        AppState.shared.ensureSaveDirAccess()

        // 主窗口(预览)
        mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 672, height: 378),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        mainWindow.title = "AutoRecord"
        mainWindow.minSize = NSSize(width: 480, height: 270)
        mainWindow.contentView = NSView()
        mainWindow.contentView?.wantsLayer = true
        previewTab = PreviewTab()
        previewTab.view.frame = mainWindow.contentView!.bounds
        previewTab.view.autoresizingMask = [.width, .height]
        mainWindow.contentView?.addSubview(previewTab.view)

        // 设置窗口
        settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 430),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
        settingsWindow.title = "AutoRecord 设置"
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentView = NSView()
        settingsTab = SettingsTab()
        settingsTab.view.frame = settingsWindow.contentView!.bounds
        settingsTab.view.autoresizingMask = [.width, .height]
        settingsWindow.contentView?.addSubview(settingsTab.view)

        mainWindow.center()
        settingsWindow.setFrameTopLeftPoint(NSPoint(x: mainWindow.frame.minX, y: mainWindow.frame.maxY + 12))
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installKeyMonitor()
        setupMenu()
    }

    // R / M 快捷键,文本输入 & Cmd 组合不拦截
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let fr = event.window?.firstResponder, fr is NSTextView { return event }
            guard let chars = event.charactersIgnoringModifiers else { return event }
            if event.modifierFlags.contains(.command) { return event }
            switch chars.lowercased() {
            case "r": AppState.shared.toggleManualRecord(); return nil
            case "m": AppState.shared.toggleMonitor();     return nil
            default:  return event
            }
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 AutoRecord",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "设置…",
                                      action: #selector(AppDelegate.showSettingsClicked),
                                      keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 AutoRecord",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "最小化",
                        action: #selector(NSWindow.performMiniaturize(_:)),
                        keyEquivalent: "m")
        winMenu.addItem(withTitle: "缩放",
                        action: #selector(NSWindow.performZoom(_:)),
                        keyEquivalent: "")
        winMenu.addItem(withTitle: "前置全部窗口",
                        action: #selector(NSApplication.arrangeInFront(_:)),
                        keyEquivalent: "")
        NSApp.mainMenu = mainMenu
    }

    @objc func showSettingsClicked() {
        if settingsWindow.isVisible {
            settingsWindow.orderOut(nil)
        } else {
            settingsWindow.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindow.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
