// BMD 采集卡原生 Mac 应用
// 主窗口:预览 + ROI 拖拽 + 录制红框;快捷键 R=手动录制开关,M=开始/停止监控
// 设置窗口:色卡 + 容差 + ROI + 保存路径 + 按钮 + 状态(⌘, 打开)
// 文件名:auto/manual_YYMMDD_HHMMSS_XY(XY=随机字母)

import AppKit
import AVFoundation
import CoreVideo
import CoreImage
import ImageIO
import ObjectiveC

// MARK: - 通知名
extension Notification.Name {
    static let monitoringChanged = Notification.Name("monitoringChanged")
    static let recordingChanged = Notification.Name("recordingChanged")
    static let statusChanged = Notification.Name("statusChanged")
    static let saveDirChanged = Notification.Name("saveDirChanged")
}

// MARK: - 录制代理
final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    var finalURL: URL?
    static var secureBookmark: Data?
    static func accessWithBookmark<T>(at url: URL, _ work: (URL) throws -> T) rethrows -> T? {
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
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
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
                    try? task.run()
                    task.waitUntilExit()
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
                AppState.shared.postStatus("已保存: \(final.path)")
            } else {
                let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
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
                    AppState.shared.postStatus("保存失败,临时文件: \(outputFileURL.path)(\(size)B),点打开临时文件夹")
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

typealias RGB = (r: Double, g: Double, b: Double)

func colorMatch(_ a: RGB, _ b: RGB, tolerance: Double) -> Bool {
    return abs(a.r - b.r) < tolerance && abs(a.g - b.g) < tolerance && abs(a.b - b.b) < tolerance
}

// MARK: - 文件名生成:auto/manual_YYMMDD_HHMMSS_XY
private let randLetters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
func randomLetters(_ n: Int = 2) -> String {
    var s = ""
    for _ in 0..<n { s.append(randLetters.randomElement() ?? "X") }
    return s
}
func recordingFileName(prefix: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyMMdd_HHmmss"
    return "\(prefix)_\(f.string(from: Date()))_\(randomLetters(2)).mov"
}

// MARK: - 采集引擎
final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "bmd.engine")
    private let lock = NSLock()
    private var currentBuffer: CVPixelBuffer?
    private(set) var videoSize: CGSize = .zero
    let recordingDelegate = RecordingDelegate()
    private(set) var isRecording = false

    func start() {
        let devices = AVCaptureDevice.devices(for: .video)
        fputs("==== 所有 video 设备 ====\n", stderr)
        for (i, d) in devices.enumerated() {
            fputs("[\(i)] \(d.localizedName) uniqueID=\(d.uniqueID) manufacturer=\(d.manufacturer) modelID=\(d.modelID ?? "-")\n", stderr)
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

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        lock.lock()
        currentBuffer = pb
        videoSize = CGSize(width: w, height: h)
        lock.unlock()
    }

    // 一次采样同时返回 (红色占比, 平均色),避免重复 lock/二次采样导致的崩溃
    // currentBuffer 未被 retain,这里取出后先强引用直到采样结束
    func sampleRedRatioAndAvg(_ rect: CGRect) -> (ratio: Double, avg: RGB)? {
        lock.lock()
        let pbOpt = currentBuffer
        let size = videoSize
        lock.unlock()
        guard let buf = pbOpt, size.width > 0 else { return nil }
        // 强引用缓冲区,防止采样期间被采集引擎回收
        _ = buf as CVPixelBuffer
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let bpp = 4
        let rx = max(0, min(Int(rect.origin.x), w - 1))
        let ry = max(0, min(Int(rect.origin.y), h - 1))
        let rw = min(Int(rect.width), w - rx)
        let rh = min(Int(rect.height), h - ry)
        guard rw > 0 && rh > 0 else { return nil }
        var redCount: UInt64 = 0, rSum: UInt64 = 0, gSum: UInt64 = 0, bSum: UInt64 = 0, n: UInt64 = 0
        let stepX = max(1, rw / 30), stepY = max(1, rh / 30)
        for y in stride(from: ry, to: ry + rh, by: stepY) {
            for x in stride(from: rx, to: rx + rw, by: stepX) {
                let p = base.advanced(by: y * bpr + x * bpp)
                let b = Double(p.load(as: UInt8.self))
                let g = Double(p.advanced(by: 1).load(as: UInt8.self))
                let r = Double(p.advanced(by: 2).load(as: UInt8.self))
                n += 1
                rSum += UInt64(r); gSum += UInt64(g); bSum += UInt64(b)
                if r > 120 && r - g > 50 && r - b > 50 {
                    redCount += 1
                }
            }
        }
        guard n > 0 else { return nil }
        let ratio = Double(redCount) / Double(n)
        let avg: RGB = (Double(rSum) / Double(n), Double(gSum) / Double(n), Double(bSum) / Double(n))
        return (ratio, avg)
    }

    // ROI 内整体平均色(保留供其他调用)
    func sampleAverageColor(_ rect: CGRect) -> RGB? {
        lock.lock()
        let pb = currentBuffer
        let size = videoSize
        lock.unlock()
        guard let buf = pb, size.width > 0 else { return nil }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let bpp = 4
        let rx = max(0, min(Int(rect.origin.x), w - 1))
        let ry = max(0, min(Int(rect.origin.y), h - 1))
        let rw = min(Int(rect.width), w - rx)
        let rh = min(Int(rect.height), h - ry)
        guard rw > 0 && rh > 0 else { return nil }
        var rSum: UInt64 = 0, gSum: UInt64 = 0, bSum: UInt64 = 0, n: UInt64 = 0
        let stepX = max(1, rw / 30), stepY = max(1, rh / 30)
        for y in stride(from: ry, to: ry + rh, by: stepY) {
            for x in stride(from: rx, to: rx + rw, by: stepX) {
                let p = base.advanced(by: y * bpr + x * bpp)
                bSum += UInt64(p.load(as: UInt8.self))
                gSum += UInt64(p.advanced(by: 1).load(as: UInt8.self))
                rSum += UInt64(p.advanced(by: 2).load(as: UInt8.self))
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return (Double(rSum) / Double(n), Double(gSum) / Double(n), Double(bSum) / Double(n))
    }

    func sampleTextColor(_ rect: CGRect, targets: [RGB], tolerance: Double) -> RGB? {
        lock.lock()
        let pb = currentBuffer
        let size = videoSize
        lock.unlock()
        guard let buf = pb, size.width > 0 else { return nil }

        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let bpp = 4  // BGRA

        let rx = max(0, min(Int(rect.origin.x), w - 1))
        let ry = max(0, min(Int(rect.origin.y), h - 1))
        let rw = min(Int(rect.width), w - rx)
        let rh = min(Int(rect.height), h - ry)
        guard rw > 0 && rh > 0 else { return nil }

        var rSum: UInt64 = 0, gSum: UInt64 = 0, bSum: UInt64 = 0, n: UInt64 = 0
        let stepX = max(1, rw / 30), stepY = max(1, rh / 30)
        let pickTol = tolerance * 1.5
        for y in stride(from: ry, to: ry + rh, by: stepY) {
            for x in stride(from: rx, to: rx + rw, by: stepX) {
                let p = base.advanced(by: y * bpr + x * bpp)
                let b = p.load(as: UInt8.self)
                let g = p.advanced(by: 1).load(as: UInt8.self)
                let r = p.advanced(by: 2).load(as: UInt8.self)
                let px: RGB = (Double(r), Double(g), Double(b))
                if targets.contains(where: { colorMatch(px, $0, tolerance: pickTol) }) {
                    bSum += UInt64(b); gSum += UInt64(g); rSum += UInt64(r); n += 1
                }
            }
        }
        guard n > 0 else { return nil }
        return (Double(rSum) / Double(n), Double(gSum) / Double(n), Double(bSum) / Double(n))
    }

    func pickColor(_ point: CGPoint) -> RGB? {
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

    func startRecording(to url: URL) {
        guard !isRecording else { return }
        let dir = url.deletingLastPathComponent().path
        fputs("开始录制: 最终=\(url.path) dir=\(dir) 存在=\(FileManager.default.fileExists(atPath: dir) ? "Y" : "N")\n", stderr)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bmd_rec_\(UUID().uuidString).mov")
        recordingDelegate.finalURL = url
        movieOutput.startRecording(to: tmpURL, recordingDelegate: recordingDelegate)
        isRecording = true
        fputs("临时文件: \(tmpURL.path)\n", stderr)
    }

    func stopRecording() {
        guard isRecording else { return }
        movieOutput.stopRecording()
        isRecording = false
    }
}

// MARK: - 共享状态
enum RecState: String { case standby = "待机", recording = "录制中" }

final class AppState {
    static let shared = AppState()
    let engine = CaptureEngine()
    struct ROI: Codable { var name: String; var rect: CGRect }
    var rois: [ROI] = []
    var selectedROIIndex: Int = 0
    var standbyColor: RGB?
    var recordColor: RGB?
    var tolerance: Double = 40            // 兼容设置滑块
    var redRatioThreshold: Double = 0.15  // ROI 内红色像素占比阈值,超过即开始录制
    var lastJumpSample: RGB?
    var saveDir: URL = {
        if let p = UserDefaults.standard.string(forKey: "saveDir") {
            return URL(fileURLWithPath: p)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }() {
        didSet { UserDefaults.standard.set(saveDir.path, forKey: "saveDir") }
    }
    var monitoring = false
    var recState: RecState = .standby
    var timer: Timer?
    var recordingCount = 0
    var lastSample: RGB?
    var lastStatus: String = "未开始"

    init() {
        if let bm = UserDefaults.standard.data(forKey: "outputSecureBookmark") {
            RecordingDelegate.secureBookmark = bm
        }
    }

    // 状态文本广播(主窗口标题 + 设置窗口状态行)
    func postStatus(_ text: String) {
        DispatchQueue.main.async {
            self.lastStatus = text
            NotificationCenter.default.post(name: .statusChanged, object: nil, userInfo: ["text": text])
        }
    }

    func startMonitoring() {
        guard !monitoring else { return }
        guard !rois.isEmpty else { postStatus("请先创建 ROI"); return }
        monitoring = true
        recState = .standby
        lastJumpSample = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in self.tick() }
        postStatus("监控中(待机) · 等待检测到红色")
    }

    func stopMonitoring() {
        monitoring = false
        timer?.invalidate(); timer = nil
        if engine.isRecording { engine.stopRecording() }
        recState = .standby
        postStatus("已停止")
    }

    // M 键 / 设置窗口按钮:切换监控
    func toggleMonitor() {
        if monitoring { stopMonitoring() }
        else { startMonitoring() }
        NotificationCenter.default.post(name: .monitoringChanged, object: nil, userInfo: ["on": monitoring])
    }

    // R 键 / 设置窗口按钮:切换手动录制
    func toggleManualRecord() {
        if engine.isRecording {
            engine.stopRecording()
            postStatus("手动停止录制")
        } else {
            if RecordingDelegate.secureBookmark == nil {
                guard chooseSaveDir() else { postStatus("必须先选保存目录才能录制"); return }
            }
            let url = saveDir.appendingPathComponent(recordingFileName(prefix: "manual"))
            engine.startRecording(to: url)
            postStatus("手动录制中 → \(url.path)")
        }
        NotificationCenter.default.post(name: .recordingChanged, object: nil, userInfo: ["on": engine.isRecording])
    }

    @discardableResult
    func chooseSaveDir() -> Bool {
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

    // 红色检测:ROI 内红色像素占比超过 redRatioThreshold → 开始录制;低于阈值 → 停止录制
    private func tick() {
        guard selectedROIIndex < rois.count else { return }
        let rect = rois[selectedROIIndex].rect
        // 一次采样同时拿到红色占比和平均色,避免重复 lock 导致崩溃
        guard let result = engine.sampleRedRatioAndAvg(rect) else {
            postStatus("ROI 内无法采样")
            return
        }
        let ratio = result.ratio
        let color = result.avg
        lastSample = color
        lastJumpSample = color

        let hasRed = ratio > redRatioThreshold
        let roiName = rois[selectedROIIndex].name
        fputs("tick: ROI \(roiName) 红色占比 \(Int(ratio*100))% 阈值 \(Int(redRatioThreshold*100))% 有红=\(hasRed ? "Y" : "N") 状态=\(recState.rawValue)\n", stderr)

        let redText = hasRed ? "🔴检测到红" : "⚪无红"
        let desc = "ROI \(roiName) 红色 \(Int(ratio*100))% | \(redText)"
        postStatus(desc)

        if hasRed && recState == .standby && !engine.isRecording {
            recordingCount += 1
            let url = saveDir.appendingPathComponent(recordingFileName(prefix: "auto"))
            engine.startRecording(to: url)
            recState = .recording
            postStatus("🔴检测到红色 → 开始录制: \(url.lastPathComponent)")
            NotificationCenter.default.post(name: .recordingChanged, object: nil, userInfo: ["on": true])
        } else if !hasRed && recState == .recording && engine.isRecording {
            engine.stopRecording()
            recState = .standby
            postStatus("⚪红色消失 → 停止录制")
            NotificationCenter.default.post(name: .recordingChanged, object: nil, userInfo: ["on": false])
        }
    }
}

// MARK: - 主窗口:预览 + ROI 拖拽 + 录制红框
final class PreviewTab: NSViewController {
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let roiLayer = CALayer()
    private let roiLabel = NSTextField(labelWithString: "")
    private let recordOverlay = CALayer()
    private let createLayer = CALayer()   // 拖拽新建预览框(独立,不干扰旧 ROI)
    private var refreshTimer: Timer?
    // 预览尺寸随窗口自适应,保持 16:9;ROI 拖拽/映射均基于此值
    private var previewSize = CGSize(width: 1280, height: 720)
    // ROI 交互状态机:idle=空闲 creating=拖拽新建 moving=移动 resizing=缩放
    private enum InteractionMode { case idle, creating, moving, resizing }
    private var interactionMode: InteractionMode = .idle
    private var interactionStart: CGPoint = .zero       // 交互起点(预览坐标)
    private var interactionOriginal: CGRect = .zero     // 交互开始时 roiLayer.frame(移动/缩放基准)
    private var resizeHandle: Int = 0                   // 缩放手柄索引 0..7
    private var moveLastPoint: CGPoint = .zero          // 移动时上一次鼠标位置
    // 8 个缩放手柄:0=左上 1=上 2=右上 3=右 4=右下 5=下 6=左下 7=左
    private lazy var handleLayers: [CALayer] = {
        (0..<8).map { _ in
            let l = CALayer()
            l.backgroundColor = NSColor.white.cgColor
            l.borderColor = NSColor.systemBlue.cgColor
            l.borderWidth = 1.5
            l.cornerRadius = 2
            l.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
            l.isHidden = true
            return l
        }
    }()

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1320, height: 780))
        v.wantsLayer = true
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        previewLayer = AVCaptureVideoPreviewLayer(session: AppState.shared.engine.session)
        previewLayer.videoGravity = .resizeAspect
        view.layer?.addSublayer(previewLayer)

        roiLayer.borderColor = NSColor.systemBlue.cgColor
        roiLayer.borderWidth = 2.0
        roiLayer.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.1).cgColor
        roiLayer.isHidden = true
        previewLayer.addSublayer(roiLayer)
        // 8 个缩放手柄加到预览层,位置由 updateHandles() 随 roiLayer.frame 更新
        handleLayers.forEach { previewLayer.addSublayer($0) }

        recordOverlay.borderColor = NSColor.systemRed.cgColor
        recordOverlay.borderWidth = 4.0
        recordOverlay.backgroundColor = NSColor.clear.cgColor
        recordOverlay.isHidden = true
        previewLayer.addSublayer(recordOverlay)

        createLayer.borderColor = NSColor.systemGreen.cgColor
        createLayer.borderWidth = 2.0
        createLayer.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.12).cgColor
        createLayer.isHidden = true
        previewLayer.addSublayer(createLayer)

        roiLabel.textColor = .white
        roiLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        roiLabel.wantsLayer = true
        roiLabel.layer?.backgroundColor = NSColor.systemBlue.cgColor
        roiLabel.layer?.cornerRadius = 4
        roiLabel.isHidden = true
        view.addSubview(roiLabel)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateROILayer()
                self?.updateRecordOverlay()
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged(_:)),
                                               name: .statusChanged, object: nil)
    }

    @objc private func statusChanged(_ n: Notification) {
        if let t = n.userInfo?["text"] as? String {
            view.window?.title = "AutoRecord — \(t)"
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 预览自适应窗口大小,保持 16:9(若已知视频尺寸则用视频比例),留 20pt 边距
        let bounds = view.bounds
        let pad: CGFloat = 20
        let availW = max(0, bounds.width - pad * 2)
        let availH = max(0, bounds.height - pad * 2)
        let vs = AppState.shared.engine.videoSize
        let aspect: CGFloat = (vs.width > 0 && vs.height > 0) ? vs.width / vs.height : 16.0 / 9.0
        var pw = availW
        var ph = availW / aspect
        if ph > availH {
            ph = availH
            pw = availH * aspect
        }
        previewSize = CGSize(width: pw, height: ph)
        let x = (bounds.width - pw) / 2
        let y = (bounds.height - ph) / 2
        previewLayer.frame = CGRect(origin: CGPoint(x: x, y: y), size: previewSize)
        recordOverlay.frame = previewLayer.bounds
        updateROILayer()
    }

    private func updateRecordOverlay() {
        recordOverlay.isHidden = !AppState.shared.engine.isRecording
    }

    private func updateROILayer() {
        let st = AppState.shared
        // 拖拽新建中:旧 ROI 保持原位,新建框由 createLayer 独立显示,这里直接跳过
        if interactionMode == .creating {
            return
        }
        guard !st.rois.isEmpty, st.selectedROIIndex < st.rois.count, st.engine.videoSize.width > 0 else {
            roiLayer.isHidden = true
            roiLabel.isHidden = true
            handleLayers.forEach { $0.isHidden = true }
            return
        }
        let roi = st.rois[st.selectedROIIndex]

        // 仅在非交互时按存储的 ROI 重算 frame;移动/缩放中由 mouseDragged 接管
        if interactionMode == .idle {
            let vs = st.engine.videoSize
            let sx = previewSize.width / vs.width
            let sy = previewSize.height / vs.height
            let frame = CGRect(x: roi.rect.origin.x * sx, y: previewSize.height - (roi.rect.origin.y + roi.rect.height) * sy,
                               width: roi.rect.width * sx, height: roi.rect.height * sy)
            roiLayer.frame = frame
        }
        roiLayer.isHidden = false

        let border: NSColor
        if let last = st.lastSample {
            if let standby = st.standbyColor, colorMatch(last, standby, tolerance: st.tolerance) {
                border = NSColor(srgbRed: CGFloat(standby.r/255), green: CGFloat(standby.g/255), blue: CGFloat(standby.b/255), alpha: 1)
            } else if let record = st.recordColor, colorMatch(last, record, tolerance: st.tolerance) {
                border = NSColor(srgbRed: CGFloat(record.r/255), green: CGFloat(record.g/255), blue: CGFloat(record.b/255), alpha: 1)
            } else {
                border = .systemBlue
            }
        } else {
            border = .systemBlue
        }
        roiLayer.borderColor = border.cgColor
        roiLayer.backgroundColor = border.withAlphaComponent(0.12).cgColor
        roiLabel.layer?.backgroundColor = border.cgColor

        updateHandles()
        updateROILabel()
    }

    // MARK: ROI 手柄与标签随 frame 更新
    private func updateHandles() {
        guard !roiLayer.isHidden else {
            handleLayers.forEach { $0.isHidden = true }
            return
        }
        let f = roiLayer.frame
        let s: CGFloat = 12
        let hs = s / 2
        // 索引顺序:0=左上 1=上 2=右上 3=右 4=右下 5=下 6=左下 7=左
        let rects: [CGRect] = [
            CGRect(x: f.minX - hs,    y: f.maxY - hs, width: s, height: s), // 左上
            CGRect(x: f.midX - hs,    y: f.maxY - hs, width: s, height: s), // 上
            CGRect(x: f.maxX - hs,    y: f.maxY - hs, width: s, height: s), // 右上
            CGRect(x: f.maxX - hs,    y: f.midY - hs, width: s, height: s), // 右
            CGRect(x: f.maxX - hs,    y: f.minY - hs, width: s, height: s), // 右下
            CGRect(x: f.midX - hs,    y: f.minY - hs, width: s, height: s), // 下
            CGRect(x: f.minX - hs,    y: f.minY - hs, width: s, height: s), // 左下
            CGRect(x: f.minX - hs,    y: f.midY - hs, width: s, height: s), // 左
        ]
        for (i, l) in handleLayers.enumerated() {
            l.frame = rects[i]
            l.isHidden = false
        }
    }

    private func updateROILabel() {
        let st = AppState.shared
        // 拖拽新建时隐藏标签,避免显示旧 ROI 名
        guard !roiLayer.isHidden, interactionMode != .creating, st.selectedROIIndex < st.rois.count else {
            roiLabel.isHidden = true
            return
        }
        roiLabel.stringValue = st.rois[st.selectedROIIndex].name
        roiLabel.sizeToFit()
        roiLabel.frame.origin = CGPoint(x: previewLayer.frame.origin.x + roiLayer.frame.minX + 4,
                                        y: previewLayer.frame.origin.y + roiLayer.frame.minY + 4)
        roiLabel.isHidden = false
    }

    // 预览坐标(左下原点,y 向上)→ 视频坐标(左上原点,y 向下)
    private func previewRectToVideo(_ f: CGRect) -> CGRect {
        let st = AppState.shared
        let sx = st.engine.videoSize.width / previewSize.width
        let sy = st.engine.videoSize.height / previewSize.height
        return CGRect(x: f.origin.x * sx,
                      y: (previewSize.height - f.origin.y - f.height) * sy,
                      width: f.width * sx,
                      height: f.height * sy)
    }

    // 命中手柄(返回 0..7),容差 5pt 方便抓取
    private func handle(at p: CGPoint) -> Int? {
        guard !roiLayer.isHidden else { return nil }
        let tol: CGFloat = 5
        for (i, l) in handleLayers.enumerated() where !l.isHidden {
            if l.frame.insetBy(dx: -tol, dy: -tol).contains(p) { return i }
        }
        return nil
    }

    // 根据手柄与拖拽量计算缩放后的 rect,防止翻转并保证最小尺寸
    private func resizedRect(original: CGRect, start: CGPoint, current: CGPoint, handle h: Int) -> CGRect {
        let dx = current.x - start.x
        let dy = current.y - start.y
        var left = original.minX, right = original.maxX
        var bottom = original.minY, top = original.maxY
        switch h {
        case 0: left += dx; top += dy      // 左上
        case 1: top += dy                  // 上
        case 2: right += dx; top += dy     // 右上
        case 3: right += dx                // 右
        case 4: right += dx; bottom += dy  // 右下
        case 5: bottom += dy               // 下
        case 6: left += dx; bottom += dy   // 左下
        case 7: left += dx                 // 左
        default: break
        }
        let minSize: CGFloat = 12
        if right - left < minSize {
            if h == 0 || h == 6 || h == 7 { left = right - minSize } else { right = left + minSize }
        }
        if top - bottom < minSize {
            if h == 0 || h == 1 || h == 2 { top = bottom + minSize } else { bottom = top - minSize }
        }
        return CGRect(x: min(left, right), y: min(bottom, top),
                      width: abs(right - left), height: abs(top - bottom))
    }

    private func toPreview(_ p: NSPoint) -> NSPoint {
        let o = previewLayer.frame.origin
        return NSPoint(x: p.x - o.x, y: p.y - o.y)
    }

    // MARK: ROI 交互:手柄缩放 > 内部移动 > 空白新建
    override func mouseDown(with event: NSEvent) {
        let p = toPreview(view.convert(event.locationInWindow, from: nil))
        // 1) 命中手柄 → 缩放
        if !roiLayer.isHidden, let h = handle(at: p) {
            interactionMode = .resizing
            resizeHandle = h
            interactionStart = p
            interactionOriginal = roiLayer.frame
            return
        }
        // 2) 点击在当前 ROI 内 → 移动
        if !roiLayer.isHidden && roiLayer.frame.contains(p) {
            interactionMode = .moving
            moveLastPoint = p
            interactionOriginal = roiLayer.frame
            return
        }
        // 3) 空白处 → 拖拽新建(用独立的 createLayer,不动旧 ROI)
        interactionMode = .creating
        interactionStart = p
        createLayer.frame = CGRect(origin: p, size: .zero)
        createLayer.isHidden = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toPreview(view.convert(event.locationInWindow, from: nil))
        switch interactionMode {
        case .creating:
            createLayer.frame = CGRect(x: min(interactionStart.x, p.x), y: min(interactionStart.y, p.y),
                                        width: abs(p.x - interactionStart.x), height: abs(p.y - interactionStart.y))
        case .moving:
            let dx = p.x - moveLastPoint.x
            let dy = p.y - moveLastPoint.y
            roiLayer.frame = roiLayer.frame.offsetBy(dx: dx, dy: dy)
            moveLastPoint = p
            updateHandles()
            updateROILabel()
        case .resizing:
            roiLayer.frame = resizedRect(original: interactionOriginal, start: interactionStart,
                                         current: p, handle: resizeHandle)
            updateHandles()
            updateROILabel()
        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let st = AppState.shared
        switch interactionMode {
        case .creating:
            let f = createLayer.frame
            createLayer.isHidden = true
            // 太小则取消(视为误点)
            if f.width < 10 || f.height < 10 {
                interactionMode = .idle
                updateROILayer()
                return
            }
            guard st.engine.videoSize.width > 0 else { interactionMode = .idle; updateROILayer(); return }
            let rect = previewRectToVideo(f)
            let name = "ROI \(st.rois.count + 1)"
            st.rois.append(AppState.ROI(name: name, rect: rect))
            st.selectedROIIndex = st.rois.count - 1
        case .moving, .resizing:
            // 提交修改到当前选中 ROI
            if st.selectedROIIndex < st.rois.count && st.engine.videoSize.width > 0 {
                st.rois[st.selectedROIIndex].rect = previewRectToVideo(roiLayer.frame)
            }
        case .idle:
            return
        }
        interactionMode = .idle
        updateROILayer()
    }
}

// MARK: - 设置窗口:色卡 + 容差 + ROI + 路径 + 按钮 + 状态
final class SettingsTab: NSViewController {
    private var standbyWell: NSColorWell!
    private var recordWell: NSColorWell!
    private var standbyWhiteDot: NSButton!  // 待机白色圆点(互斥切换)
    private var standbyGreenDot: NSButton!  // 待机绿色圆点(互斥切换)
    private var standbyCustomDot: NSColorWell!  // 待机自定义色点(进色板)
    private var toleranceSlider: NSSlider!
    private var toleranceLabel: NSTextField!
    private var roiPop: NSPopUpButton!
    private var pathField: NSTextField!
    private var statusField: NSTextField!
    private var toggleBtn: NSButton!
    private var openTmpBtn: NSButton!
    private var recordBtn: NSButton!
    private var card1: NSBox!
    private var card2: NSBox!
    private var card3: NSBox!
    private var browseBtn: NSButton!
    private var delROIButton: NSButton!
    // 卡片1/2 内的小标签(待机/录制/容差/监控ROI) 和卡片标题,需随卡片移动
    private var standbyLabel: NSTextField!
    private var recordTextLabel: NSTextField!
    private var toleranceTextLabel: NSTextField!
    private var roiTextLabel: NSTextField!
    private var saveTextLabel: NSTextField!
    private var card1Title: NSTextField!
    private var card2Title: NSTextField!
    private var card3Title: NSTextField!
    // 布局常量
    private let margin: CGFloat = 14
    private let gap: CGFloat = 12
    private let cardRow1H: CGFloat = 74
    private let cardRow2H: CGFloat = 66

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 190))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.97, alpha: 1.0).cgColor
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        func makeCard(_ f: NSRect) -> NSBox {
            let c = NSBox(frame: f)
            c.boxType = .custom
            c.cornerRadius = 14
            c.borderColor = NSColor(white: 0.88, alpha: 1.0)
            c.borderWidth = 1
            c.fillColor = NSColor(white: 0.96, alpha: 1.0)
            // 不使用 autoresizingMask,由 viewDidLayout 统一管理
            return c
        }
        func makePillBtn(title: String, color: NSColor = NSColor.labelColor, bg: NSColor = NSColor.white,
                       target: Any?, action: Selector) -> NSButton {
            let b = NSButton(title: title, target: target, action: action)
            b.wantsLayer = true
            b.layer?.backgroundColor = bg.cgColor
            b.layer?.cornerRadius = 9
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor(white: 0.82, alpha: 1.0).cgColor
            b.layer?.masksToBounds = true
            if #available(macOS 12, *) { b.hasDestructiveAction = false }
            return b
        }
        func makeCardTitle(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.frame = NSRect(x: 0, y: 0, width: 200, height: 18)
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            l.textColor = NSColor(white: 0.45, alpha: 1.0)
            view.addSubview(l)
            return l
        }
        func makeLabel(_ text: String, width: CGFloat = 36, height: CGFloat = 20) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 0, y: 0, width: width, height: height)
            l.font = .systemFont(ofSize: 12)
            view.addSubview(l)
            return l
        }
        // 圆形小色点:点击弹出系统色板(可进自定义/RGB 滑块)
        func makeColorDot(default c: NSColor, action: Selector) -> NSColorWell {
            let w = NSColorWell(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            w.color = c
            w.target = self
            w.action = action
            w.wantsLayer = true
            w.layer?.cornerRadius = 11
            w.layer?.borderWidth = 1
            w.layer?.borderColor = NSColor(white: 0.82, alpha: 1.0).cgColor
            w.layer?.masksToBounds = true
            return w
        }
        // 纯色圆形按钮(预设色,带选中边框)
        func makeDotButton(color c: NSColor, action: Selector) -> NSButton {
            let b = NSButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 11
            b.layer?.borderWidth = 0
            b.layer?.masksToBounds = true
            b.isBordered = false
            b.target = self
            b.action = action
            return b
        }

        // ===== 第一行:卡片1(待机色+录制色) 卡片2(容差+ROI) =====
        // 初始 frame 用占位值,真实布局由 viewDidLayout 统一计算
        card1 = makeCard(NSRect(x: margin, y: 86, width: 360, height: cardRow1H))
        view.addSubview(card1)
        card1Title = makeCardTitle("COLOR CONFIG")

        standbyLabel = makeLabel("待机", width: 36, height: 20)
        // 白/绿两个预设圆点(互斥切换),点击即应用该色
        standbyWhiteDot = makeDotButton(color: NSColor(red: 1, green: 1, blue: 1, alpha: 1),
                                        action: #selector(standbyPresetWhite))
        view.addSubview(standbyWhiteDot)
        standbyGreenDot = makeDotButton(color: NSColor(srgbRed: 0.2, green: 0.8, blue: 0.2, alpha: 1),
                                        action: #selector(standbyPresetGreen))
        view.addSubview(standbyGreenDot)
        // 自定义色点(点击进系统色板,选中后取消两个预设的选中态)
        standbyCustomDot = makeColorDot(default: NSColor(red: 1, green: 1, blue: 1, alpha: 1),
                                        action: #selector(standbyChanged))
        view.addSubview(standbyCustomDot)

        recordTextLabel = makeLabel("录制", width: 36, height: 20)
        recordWell = makeColorDot(default: NSColor(red: 1, green: 0, blue: 0, alpha: 1),
                                  action: #selector(recordChanged))
        view.addSubview(recordWell)

        card2 = makeCard(NSRect(x: 386, y: 86, width: 360, height: cardRow1H))
        view.addSubview(card2)
        card2Title = makeCardTitle("ROI & TOLERANCE")

        toleranceTextLabel = makeLabel("容差", width: 40, height: 20)
        toleranceSlider = NSSlider(value: 40, minValue: 5, maxValue: 100, target: self, action: #selector(toleranceChanged))
        view.addSubview(toleranceSlider)
        toleranceLabel = NSTextField(labelWithString: "40")
        toleranceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        toleranceLabel.textColor = .labelColor
        toleranceLabel.alignment = .right
        view.addSubview(toleranceLabel)

        roiTextLabel = makeLabel("监控ROI", width: 64, height: 20)
        roiPop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 196, height: 26))
        roiPop.target = self; roiPop.action = #selector(roiChanged)
        roiPop.wantsLayer = true
        roiPop.layer?.cornerRadius = 8
        view.addSubview(roiPop)
        delROIButton = makePillBtn(title: "删除ROI", color: .labelColor, bg: .white, target: self, action: #selector(deleteROI))
        view.addSubview(delROIButton)

        // ===== 第二行:卡片3(保存位置 + 操作按钮) =====
        card3 = makeCard(NSRect(x: margin, y: 14, width: 732, height: cardRow2H))
        view.addSubview(card3)
        card3Title = makeCardTitle("OUTPUT & CONTROLS")

        saveTextLabel = makeLabel("保存到", width: 50, height: 22)
        pathField = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        pathField.stringValue = AppState.shared.saveDir.path
        pathField.isEditable = false; pathField.drawsBackground = true
        pathField.backgroundColor = .white
        pathField.wantsLayer = true
        pathField.layer?.borderWidth = 1
        pathField.layer?.borderColor = NSColor(white: 0.82, alpha: 1.0).cgColor
        pathField.layer?.cornerRadius = 8
        pathField.font = .systemFont(ofSize: 12)
        view.addSubview(pathField)
        browseBtn = makePillBtn(title: "浏览…", color: .labelColor, bg: .white, target: self, action: #selector(chooseDir))
        view.addSubview(browseBtn)
        openTmpBtn = makePillBtn(title: "打开临时文件夹", color: .labelColor, bg: .white, target: self, action: #selector(openTmpFolder))
        view.addSubview(openTmpBtn)

        toggleBtn = makePillBtn(title: "开始监控", color: .white, bg: NSColor.systemBlue, target: self, action: #selector(toggleMonitorClicked))
        view.addSubview(toggleBtn)
        recordBtn = makePillBtn(title: "手动录制", color: .white, bg: NSColor.systemRed, target: self, action: #selector(recordManualClicked))
        view.addSubview(recordBtn)

        // 状态行
        statusField = NSTextField(labelWithString: AppState.shared.lastStatus)
        statusField.font = .systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor
        view.addSubview(statusField)

        // 默认色
        AppState.shared.standbyColor = (255, 255, 255)
        AppState.shared.recordColor = (255, 0, 0)
        refreshROIPop()

        // 监听通知同步 UI
        NotificationCenter.default.addObserver(self, selector: #selector(monitoringChanged(_:)),
                                               name: .monitoringChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recordingChanged(_:)),
                                               name: .recordingChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged(_:)),
                                               name: .statusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(saveDirChanged(_:)),
                                               name: .saveDirChanged, object: nil)
    }

    // MARK: 自适应布局:窗口缩放时重新计算所有控件 frame,确保控件随窗口移动/调整大小
    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return }

        // 布局尺寸(与原始设计保持一致)
        let innerPad: CGFloat = 14    // 卡片内左边距
        let btnGap: CGFloat = 6       // 按钮之间间距
        // 第一行卡片:两张卡左右平分,中间留 gap
        let cardW = max(360, (w - margin * 2 - gap) / 2)
        let card1X = margin
        let card2X = card1X + cardW + gap

        // 垂直布局(从底到顶):状态行 -> 卡片3 -> 间距 -> 卡片1/2
        let statusH: CGFloat = 18
        let statusY: CGFloat = 4
        let row2H = cardRow2H
        let row2Y = statusY + statusH + 4
        let row1H = cardRow1H
        let row1Y = row2Y + row2H + 8
        // 标题在卡片内部上方区域(卡片顶 - 20)
        let titleY = row1Y + row1H - 20

        // 卡片1(COLOR CONFIG)
        card1.frame = NSRect(x: card1X, y: row1Y, width: cardW, height: row1H)
        card1Title.frame = NSRect(x: card1X + innerPad, y: titleY, width: 200, height: 18)
        // 待机行:标签 + 白圆点 + 绿圆点 + 自定义色点
        let standbyLabelX = card1X + innerPad
        let dotX = standbyLabelX + 40
        let standbyRowY = row1Y + 30
        standbyLabel.frame = NSRect(x: standbyLabelX, y: standbyRowY, width: 36, height: 20)
        standbyWhiteDot.frame = NSRect(x: dotX, y: standbyRowY - 1, width: 22, height: 22)
        standbyGreenDot.frame = NSRect(x: dotX + 28, y: standbyRowY - 1, width: 22, height: 22)
        standbyCustomDot.frame = NSRect(x: dotX + 56, y: standbyRowY - 1, width: 22, height: 22)
        // 录制行
        let recordRowY = row1Y + 4
        recordTextLabel.frame = NSRect(x: standbyLabelX, y: recordRowY, width: 36, height: 20)
        recordWell.frame = NSRect(x: dotX, y: recordRowY - 1, width: 22, height: 22)

        // 卡片2(ROI & TOLERANCE)
        card2.frame = NSRect(x: card2X, y: row1Y, width: cardW, height: row1H)
        card2Title.frame = NSRect(x: card2X + innerPad, y: titleY, width: 200, height: 18)
        // 容差行
        let tolLabelX = card2X + innerPad
        let tolSliderX = tolLabelX + 44
        let tolSliderW = max(120, cardW - 44 - 50 - innerPad)
        let tolValX = tolSliderX + tolSliderW + 6
        let tolRowY = row1Y + 28
        toleranceTextLabel.frame = NSRect(x: tolLabelX, y: tolRowY, width: 40, height: 20)
        toleranceSlider.frame = NSRect(x: tolSliderX, y: tolRowY - 2, width: tolSliderW, height: 24)
        toleranceLabel.frame = NSRect(x: tolValX, y: tolRowY, width: 40, height: 20)
        // ROI 行
        let roiRowY = row1Y + 2
        let roiLabelX = card2X + innerPad
        let delBtnW: CGFloat = 70
        let roiPopW = max(120, cardW - 68 - delBtnW - 10 - innerPad)
        let roiPopX = roiLabelX + 68
        let delX = roiPopX + roiPopW + 10
        roiTextLabel.frame = NSRect(x: roiLabelX, y: roiRowY, width: 64, height: 20)
        roiPop.frame = NSRect(x: roiPopX, y: roiRowY - 4, width: roiPopW, height: 26)
        delROIButton.frame = NSRect(x: delX, y: roiRowY - 4, width: delBtnW, height: 26)

        // 卡片3(OUTPUT & CONTROLS,全宽)
        let card3W = w - margin * 2
        card3.frame = NSRect(x: margin, y: row2Y, width: card3W, height: row2H)
        let card3TitleY = row2Y + row2H - 20
        card3Title.frame = NSRect(x: margin + innerPad, y: card3TitleY, width: 200, height: 18)
        // 路径行
        let btnY = row2Y + 2
        let btnH: CGFloat = 28
        let saveLabelX = margin + innerPad
        let pathX = saveLabelX + 52
        let browseW: CGFloat = 70
        let openTmpW: CGFloat = 130
        let toggleW: CGFloat = 110
        let recordW: CGFloat = 100
        // 右侧两个动作按钮靠右
        let recordX = w - margin - innerPad - recordW
        let toggleX = recordX - btnGap - toggleW
        let openTmpX = toggleX - btnGap - openTmpW
        let browseX = openTmpX - btnGap - browseW
        let pathW = browseX - btnGap - pathX
        saveTextLabel.frame = NSRect(x: saveLabelX, y: btnY + 3, width: 50, height: 22)
        pathField.frame = NSRect(x: pathX, y: btnY, width: pathW, height: btnH)
        browseBtn.frame = NSRect(x: browseX, y: btnY, width: browseW, height: btnH)
        openTmpBtn.frame = NSRect(x: openTmpX, y: btnY, width: openTmpW, height: btnH)
        toggleBtn.frame = NSRect(x: toggleX, y: btnY, width: toggleW, height: btnH)
        recordBtn.frame = NSRect(x: recordX, y: btnY, width: recordW, height: btnH)

        // 状态行
        statusField.frame = NSRect(x: margin, y: statusY, width: w - margin * 2, height: statusH)
    }

    // MARK: 控件 action
    // 选中态:白圆点用蓝色加粗边框,绿圆点同;自定义色点选中时边框也加粗
    private func selectStandbyDot(_ which: Int) {  // 0=white 1=green 2=custom
        standbyWhiteDot.layer?.borderWidth = (which == 0) ? 3 : 0
        standbyWhiteDot.layer?.borderColor = NSColor.systemBlue.cgColor
        standbyGreenDot.layer?.borderWidth = (which == 1) ? 3 : 0
        standbyGreenDot.layer?.borderColor = NSColor.systemBlue.cgColor
        standbyCustomDot.layer?.borderWidth = (which == 2) ? 3 : 1
        standbyCustomDot.layer?.borderColor = (which == 2) ? NSColor.systemBlue.cgColor : NSColor(white: 0.82, alpha: 1.0).cgColor
    }

    @objc func standbyPresetWhite() {
        AppState.shared.standbyColor = (r: 255, g: 255, b: 255)
        selectStandbyDot(0)
    }
    @objc func standbyPresetGreen() {
        AppState.shared.standbyColor = (r: 51, g: 204, b: 51)
        selectStandbyDot(1)
    }
    @objc func standbyChanged(_ w: NSColorWell) {
        let c = w.color.usingColorSpace(.sRGB) ?? w.color
        AppState.shared.standbyColor = (r: Double(c.redComponent * 255), g: Double(c.greenComponent * 255), b: Double(c.blueComponent * 255))
        selectStandbyDot(2)
    }

    @objc func recordChanged(_ w: NSColorWell) {
        let c = w.color.usingColorSpace(.sRGB) ?? w.color
        AppState.shared.recordColor = (r: Double(c.redComponent * 255), g: Double(c.greenComponent * 255), b: Double(c.blueComponent * 255))
    }

    @objc func toleranceChanged(_ s: NSSlider) {
        AppState.shared.tolerance = s.doubleValue
        toleranceLabel.stringValue = "\(Int(s.doubleValue))"
    }

    @objc func roiChanged(_ s: NSPopUpButton) {
        if !AppState.shared.rois.isEmpty { AppState.shared.selectedROIIndex = s.indexOfSelectedItem }
    }

    @objc func deleteROI() {
        let st = AppState.shared
        guard !st.rois.isEmpty, st.selectedROIIndex < st.rois.count else { return }
        st.rois.remove(at: st.selectedROIIndex)
        if st.selectedROIIndex >= st.rois.count {
            st.selectedROIIndex = max(0, st.rois.count - 1)
        }
        refreshROIPop()
    }

    @objc func chooseDir() { AppState.shared.chooseSaveDir() }

    @objc func toggleMonitorClicked() { AppState.shared.toggleMonitor() }
    @objc func recordManualClicked() { AppState.shared.toggleManualRecord() }

    @objc func openTmpFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSTemporaryDirectory()))
    }

    // MARK: 通知回调
    @objc private func monitoringChanged(_ n: Notification) {
        let on = (n.userInfo?["on"] as? Bool) ?? false
        toggleBtn.title = on ? "停止监控" : "开始监控"
    }
    @objc private func recordingChanged(_ n: Notification) {
        let on = (n.userInfo?["on"] as? Bool) ?? false
        recordBtn.title = on ? "停止手动" : "手动录制"
    }
    @objc private func statusChanged(_ n: Notification) {
        if let t = n.userInfo?["text"] as? String { statusField.stringValue = t }
    }
    @objc private func saveDirChanged(_ n: Notification) {
        if let p = n.userInfo?["path"] as? String { pathField.stringValue = p }
    }

    private func refreshROIPop() {
        let st = AppState.shared
        roiPop.removeAllItems()
        if st.rois.isEmpty { roiPop.addItem(withTitle: "(无 ROI)") }
        else { for r in st.rois { roiPop.addItem(withTitle: r.name) } }
        let i = min(st.selectedROIIndex, st.rois.count - 1)
        if i >= 0 { roiPop.selectItem(at: i) }
    }
}

// MARK: - AppDelegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow!
    private var settingsWindow: NSWindow!
    private var previewTab: PreviewTab!
    private var settingsTab: SettingsTab!
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.engine.start()

        // 主窗口(预览)
        mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        mainWindow.title = "AutoRecord"
        mainWindow.minSize = NSSize(width: 640, height: 400)
        mainWindow.contentView = NSView()
        mainWindow.contentView?.wantsLayer = true
        previewTab = PreviewTab()
        previewTab.view.frame = mainWindow.contentView!.bounds
        previewTab.view.autoresizingMask = [.width, .height]
        mainWindow.contentView?.addSubview(previewTab.view)

        // 设置窗口
        settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 190),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        settingsWindow.title = "AutoRecord 设置"
        settingsWindow.minSize = NSSize(width: 820, height: 190)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentView = NSView()
        settingsTab = SettingsTab()
        settingsTab.view.frame = settingsWindow.contentView!.bounds
        settingsTab.view.autoresizingMask = [.width, .height]
        settingsWindow.contentView?.addSubview(settingsTab.view)

        // 布局:主窗口居中,设置窗口置于主窗口正上方
        mainWindow.center()
        settingsWindow.setFrameTopLeftPoint(NSPoint(x: mainWindow.frame.minX, y: mainWindow.frame.maxY + 12))
        mainWindow.makeKeyAndOrderFront(nil)
        // 设置窗口不自动打开,需要时用 ⌘, 调出
        NSApp.activate(ignoringOtherApps: true)

        installKeyMonitor()
        setupMenu()
    }

    // R / M 快捷键(文本输入中放行,Cmd 组合交给菜单)
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let fr = event.window?.firstResponder, fr is NSTextView { return event }
            guard let chars = event.charactersIgnoringModifiers else { return event }
            if event.modifierFlags.contains(.command) { return event }
            switch chars.lowercased() {
            case "r": AppState.shared.toggleManualRecord(); return nil
            case "m": AppState.shared.toggleMonitor(); return nil
            default: return event
            }
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 AutoRecord", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(AppDelegate.showSettingsClicked), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 AutoRecord", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // 窗口菜单
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.mainMenu = mainMenu
    }

    @objc func showSettingsClicked() {
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
