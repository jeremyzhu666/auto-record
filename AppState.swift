// AppState.swift
// 【设置 / 状态 & 采集引擎】
// 包含:AppState(ROI/容差/保存目录/监控-录制状态机/tick 调度)
//      CaptureEngine(AVFoundation 采集+录制输出)
//      RecordingDelegate(录制完成后搬到最终目录,安全书签)
//      文件名生成(自动/manual_YYMMDD_HHMMSS_XY)
// 不包含任何 ViewController/NSView 代码(由 PreviewTab/SettingsTab 负责)。

import Foundation
import AppKit
import AVFoundation
import CoreVideo
import CoreImage
import ImageIO

// MARK: - 录制代理(含安全书签访问)
public final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    public var finalURL: URL?
    public static var secureBookmark: Data?

    public static func accessWithBookmark<T>(at url: URL, _ work: (URL) throws -> T) rethrows -> T? {
        var staled = false
        if let bookmark = secureBookmark {
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                       relativeTo: nil, bookmarkDataIsStale: &staled) {
                if resolved.startAccessingSecurityScopedResource() {
                    defer { resolved.stopAccessingSecurityScopedResource() }
                    return try work(url)
                }
            }
        }
        return try work(url)
    }

    public func fileOutput(_ output: AVCaptureFileOutput,
                           didFinishRecordingTo outputFileURL: URL,
                           from connections: [AVCaptureConnection],
                           error: Error?) {
        if let error = error {
            fputs("录制结束错误: \(error.localizedDescription)\n", stderr)
            if let nsErr = error as NSError? {
                fputs("  domain=\(nsErr.domain) code=\(nsErr.code)\n", stderr)
            }
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }
        if let final = finalURL, final != outputFileURL {
            let dir = final.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: final)

            var successFinal = false
            var moveErr = ""
            let result: Bool? = RecordingDelegate.accessWithBookmark(at: dir) { _ in
                do {
                    try FileManager.default.moveItem(at: outputFileURL, to: final)
                    return true
                } catch {
                    moveErr = error.localizedDescription
                    let task = Process()
                    task.launchPath = "/bin/cp"
                    task.arguments = [outputFileURL.path, final.path]
                    try? task.run(); task.waitUntilExit()
                    if task.terminationStatus == 0 {
                        try? FileManager.default.removeItem(at: outputFileURL)
                        return true
                    }
                    return false
                }
            }
            successFinal = result ?? false

            if successFinal {
                var size: UInt64 = 0
                if let attr = try? FileManager.default.attributesOfItem(atPath: final.path) {
                    size = (attr[.size] as? UInt64) ?? 0
                }
                fputs("录制完成(已存到最终目录): \(final.path) 大小: \(size)\n", stderr)
                AppState.shared.postStatus("监控中")
            } else {
                let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                                  ?? URL(fileURLWithPath: NSTemporaryDirectory())
                let fbDir = moviesDir.appendingPathComponent("AutoRecord")
                try? FileManager.default.createDirectory(at: fbDir, withIntermediateDirectories: true)
                let fbURL = fbDir.appendingPathComponent(outputFileURL.lastPathComponent)
                try? FileManager.default.removeItem(at: fbURL)
                var fbOK = false
                if (try? FileManager.default.copyItem(at: outputFileURL, to: fbURL)) != nil {
                    fbOK = true
                } else {
                    let task = Process(); task.launchPath = "/bin/cp"
                    task.arguments = [outputFileURL.path, fbURL.path]
                    try? task.run(); task.waitUntilExit()
                    fbOK = (task.terminationStatus == 0)
                }
                if fbOK {
                    try? FileManager.default.removeItem(at: outputFileURL)
                    AppState.shared.postStatus("目标目录权限不足(\(moveErr)),已转存: \(fbURL.path)")
                    fputs("fallback(转存Movies): \(fbURL.path)\n", stderr)
                } else {
                    var size: UInt64 = 0
                    if let attr = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path) {
                        size = (attr[.size] as? UInt64) ?? 0
                    }
                    AppState.shared.postStatus("保存失败,临时文件: \(outputFileURL.path)(\(size)B)")
                }
            }
        } else {
            var size: UInt64 = 0
            if let attr = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path) {
                size = (attr[.size] as? UInt64) ?? 0
            }
            fputs("录制完成(临时目录): \(outputFileURL.path) 大小: \(size)\n", stderr)
        }
    }
}

// MARK: - 文件名生成(EXT=自动/INT=手动 _YYMMDD_HHMMSS_XY)
private let randLetters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
public func randomLetters(_ n: Int = 2) -> String {
    var s = ""
    for _ in 0..<n { s.append(randLetters.randomElement() ?? "X") }
    return s
}
public func recordingFileName(prefix: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyMMdd_HHmmss"
    return "\(prefix)_\(f.string(from: Date()))_\(randomLetters(2)).mov"
}

// MARK: - 采集引擎(只做 AVFoundation:设备发现/预览+录制输出/pickColor 供 UI 用)
public final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "bmd.engine")
    public let lock = NSLock()
    public var currentBuffer: CVPixelBuffer?
    public private(set) var videoSize: CGSize = .zero
    public let recordingDelegate = RecordingDelegate()
    private(set) public var isRecording = false

    public func start() {
        let devices = AVCaptureDevice.devices(for: .video)
        fputs("==== 所有 video 设备 ====\n", stderr)
        for (i, d) in devices.enumerated() {
            fputs("[\(i)] \(d.localizedName) uniqueID=\(d.uniqueID) manufacturer=\(d.manufacturer) modelID=\(d.modelID)\n", stderr)
        }
        let bmd = devices.first(where: {
            let n = $0.localizedName.lowercased()
            return n.contains("blackmagic") || n.contains("ultrastudio") || n.contains("decklink")
        }) ?? devices.first
        guard let dev = bmd else { fputs("no video device\n", stderr); return }
        fputs("device: \(dev.localizedName)\n", stderr)

        session.beginConfiguration()
        session.sessionPreset = .high
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            if session.canAddInput(input) { session.addInput(input) }
        } catch { fputs("input error: \(error)\n", stderr) }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()
        session.startRunning()
        fputs("session.isRunning=\(session.isRunning)\n", stderr)
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { n in
            fputs("AVCaptureSessionRuntimeError: \(n.userInfo ?? [:])\n", stderr)
        }
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { n in
            fputs("AVCaptureSessionWasInterrupted: \(n.userInfo ?? [:])\n", stderr)
        }
        fputs("streaming...\n", stderr)
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        lock.lock()
        currentBuffer = pb
        videoSize = CGSize(width: w, height: h)
        lock.unlock()
    }

    /// 在视频缓冲里取指定像素点 RGB(用于 UI 吸色,非检测算法主路径)。
    public func pickColor(_ point: CGPoint) -> RGB? {
        lock.lock()
        let pb = currentBuffer
        lock.unlock()
        guard let buf = pb else { return nil }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let x = max(0, min(Int(point.x), w - 1))
        let y = max(0, min(Int(point.y), h - 1))
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let p = base.advanced(by: y * bpr + x * 4)
        let b = p.load(as: UInt8.self)
        let g = p.advanced(by: 1).load(as: UInt8.self)
        let r = p.advanced(by: 2).load(as: UInt8.self)
        return (Double(r), Double(g), Double(b))
    }

    public func startRecording(to url: URL) {
        guard !isRecording else { return }
        let dir = url.deletingLastPathComponent().path
        fputs("开始录制: 最终=\(url.path) dir=\(dir) 存在=\(FileManager.default.fileExists(atPath: dir) ? "Y" : "N")\n", stderr)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bmd_rec_\(UUID().uuidString).mov")
        recordingDelegate.finalURL = url
        movieOutput.startRecording(to: tmpURL, recordingDelegate: recordingDelegate)
        isRecording = true
        AppState.shared.currentRecordingFileName = url.lastPathComponent
        fputs("临时文件: \(tmpURL.path)\n", stderr)
    }

    public func stopRecording() {
        guard isRecording else { return }
        movieOutput.stopRecording()
        isRecording = false
        AppState.shared.currentRecordingFileName = nil
    }
}

// MARK: - 全局共享状态(设置 & 调度中枢)
public final class AppState {
    public static let shared = AppState()

    public let engine = CaptureEngine()

    // --- 设置项 ---
    public var rois: [ROI] = []
    public var selectedROIIndex: Int = 0
    public var triggerColorIndex: Int = 0    // 默认红
    public var tolerance: Double = 40         // 颜色匹配容差
    public var lastJumpSample: RGB?

    public var saveDir: URL = {
        if let p = UserDefaults.standard.string(forKey: "saveDir") {
            return URL(fileURLWithPath: p)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
               ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }() {
        didSet { UserDefaults.standard.set(saveDir.path, forKey: "saveDir") }
    }

    // --- 运行时 ---
    public private(set) var monitoring = false
    public private(set) var recState: RecState = .standby
    public var timer: Timer?
    public private(set) var recordingCount = 0
    public var isManualRecording = false
    public var currentRecordingFileName: String?
    public var lastSample: RGB?
    public private(set) var lastStatus: String = "未开始"

    public init() {
        if let bm = UserDefaults.standard.data(forKey: "outputSecureBookmark") {
            RecordingDelegate.secureBookmark = bm
        }
    }

    /// 启动时检查书签有效性,无效则立即弹窗让用户授权保存目录(外置硬盘提前授权)
    public func ensureSaveDirAccess() {
        if let bm = RecordingDelegate.secureBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bm, options: .withSecurityScope,
                                       relativeTo: nil, bookmarkDataIsStale: &stale) {
                if resolved.startAccessingSecurityScopedResource() {
                    resolved.stopAccessingSecurityScopedResource()
                    if !stale { return }   // 书签有效,无需重新授权
                }
            }
        }
        // 无书签 / 书签失效:启动后立即提示选择保存目录
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = self.chooseSaveDir()
        }
    }

    // MARK: - 广播
    public func postStatus(_ text: String) {
        DispatchQueue.main.async {
            if self.lastStatus == text { return }
            self.lastStatus = text
            NotificationCenter.default.post(name: .statusChanged, object: nil, userInfo: ["text": text])
        }
    }

    // MARK: - 监控
    public func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        recState = .standby
        lastJumpSample = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
        postStatus("监控中")
    }

    public func stopMonitoring() {
        monitoring = false
        timer?.invalidate(); timer = nil
        if engine.isRecording { engine.stopRecording() }
        recState = .standby
        postStatus("已停止")
    }

    // M 键 / 设置窗口按钮
    public func toggleMonitor() {
        if monitoring { stopMonitoring() } else { startMonitoring() }
        NotificationCenter.default.post(name: .monitoringChanged, object: nil, userInfo: ["on": monitoring])
    }

    // R 键 / 设置窗口按钮:手动录制
    public func toggleManualRecord() {
        if engine.isRecording {
            engine.stopRecording()
            postStatus("监控中")
        } else {
            if RecordingDelegate.secureBookmark == nil {
                guard chooseSaveDir() else { postStatus("必须先选保存目录才能录制"); return }
            }
            let url = saveDir.appendingPathComponent(recordingFileName(prefix: "INT"))
            isManualRecording = true
            engine.startRecording(to: url)
            postStatus("录制（INT）：\(currentRecordingFileName ?? "")")
        }
        NotificationCenter.default.post(name: .recordingChanged, object: nil, userInfo: ["on": engine.isRecording])
    }

    @discardableResult
    public func chooseSaveDir() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "选保存目录(授权一次,之后自动保存)"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDir
        panel.message = "请选择视频保存文件夹。授权后每次录制会自动在此目录生成 mov 文件。"
        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil, relativeTo: nil) {
                RecordingDelegate.secureBookmark = bookmark
                UserDefaults.standard.set(bookmark, forKey: "outputSecureBookmark")
            }
            saveDir = url
            NotificationCenter.default.post(name: .saveDirChanged, object: nil, userInfo: ["path": url.path])
            return true
        }
        return false
    }

    // MARK: - tick(检测调度 + 录制状态机)
    private func tick() {
        guard selectedROIIndex < rois.count else { return }
        let roi = rois[selectedROIIndex]
        let targetColor = ColorPreset.from(index: triggerColorIndex)
        let triggered = TriggerLogic.evaluate(
            engine: engine,
            centerX: roi.centerX, centerY: roi.centerY, radius: roi.radius,
            targetColor: targetColor, tolerance: tolerance
        )
        fputs("tick: 状态=\(recState.rawValue) 触发=\(triggered ? "Y" : "N")\n", stderr)

        if engine.isRecording {
            postStatus("录制（\(isManualRecording ? "INT" : "EXT")）：\(currentRecordingFileName ?? "")")
        } else {
            postStatus("监控中")
        }

        if triggered && recState == .standby && !engine.isRecording {
            recordingCount += 1
            let url = saveDir.appendingPathComponent(recordingFileName(prefix: "EXT"))
            isManualRecording = false
            engine.startRecording(to: url)
            recState = .recording
            NotificationCenter.default.post(name: .recordingChanged, object: nil, userInfo: ["on": true])
        } else if !triggered && recState == .recording && engine.isRecording {
            engine.stopRecording()
            recState = .standby
            NotificationCenter.default.post(name: .recordingChanged, object: nil, userInfo: ["on": false])
        }
    }
}
