// PreviewTab.swift
// 【界面-预览】主窗口预览 + ROI 选择 + 录制红框。
// ROI 参数在设置面板调整,预览窗口仅显示/选择 ROI。

import AppKit
import AVFoundation
import Quartz

public final class PreviewTab: NSViewController {
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let roiLayer = CALayer()
    private let roiLabel = NSTextField(labelWithString: "")
    private let recordOverlay = CALayer()
    private var showAllROIs: Bool = false
    private var roiBoxLayers: [CALayer] = []
    private var refreshTimer: Timer?

    private var previewSize = CGSize(width: 1280, height: 720)

    public override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 672, height: 378))
        v.wantsLayer = true
        view = v
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        previewLayer = AVCaptureVideoPreviewLayer(session: AppState.shared.engine.session)
        previewLayer.videoGravity = .resize
        previewLayer.anchorPoint = CGPoint(x: 0, y: 0)
        view.layer?.addSublayer(previewLayer)

        roiLayer.borderColor = NSColor.systemBlue.cgColor
        roiLayer.borderWidth = 2.0
        roiLayer.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.1).cgColor
        roiLayer.isHidden = true
        previewLayer.addSublayer(roiLayer)

        recordOverlay.borderColor = NSColor.systemRed.cgColor
        recordOverlay.borderWidth = 4.0
        recordOverlay.backgroundColor = NSColor.clear.cgColor
        recordOverlay.isHidden = true
        previewLayer.addSublayer(recordOverlay)

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
        NotificationCenter.default.addObserver(self, selector: #selector(roiDisplayChanged(_:)),
                                               name: .roiDisplayChanged, object: nil)
    }

    @objc private func statusChanged(_ n: Notification) {
        if let t = n.userInfo?["text"] as? String {
            view.window?.title = "AutoRecord — \(t)"
        }
    }
    @objc private func roiDisplayChanged(_ n: Notification) {
        showAllROIs = (n.userInfo?["show"] as? Bool) ?? false
        updateROILayer()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let pad: CGFloat = 20
        let availW = max(0, bounds.width - pad * 2)
        let availH = max(0, bounds.height - pad * 2)
        let vs = AppState.shared.engine.videoSize
        let aspect: CGFloat = (vs.width > 0 && vs.height > 0) ? vs.width / vs.height : 16.0 / 9.0
        var pw = availW
        var ph = availW / aspect
        if ph > availH { ph = availH; pw = availH * aspect }
        previewSize = CGSize(width: pw, height: ph)
        let x = (bounds.width - pw) / 2
        let y = (bounds.height - ph) / 2

        CATransaction.begin()
        if view.inLiveResize {
            CATransaction.setAnimationDuration(0)
        } else {
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        }
        previewLayer.frame = CGRect(origin: CGPoint(x: x, y: y), size: previewSize)
        previewLayer.bounds = CGRect(origin: .zero, size: previewSize)
        recordOverlay.frame = previewLayer.bounds
        updateROILayer()
        CATransaction.commit()
    }

    private func updateRecordOverlay() {
        recordOverlay.isHidden = !AppState.shared.engine.isRecording
    }

    private func updateROILayer() {
        let st = AppState.shared
        updateOtherROILayers()
        guard !st.rois.isEmpty, st.selectedROIIndex < st.rois.count,
              st.engine.videoSize.width > 0 else {
            roiLayer.isHidden = true
            roiLabel.isHidden = true
            return
        }
        let roi = st.rois[st.selectedROIIndex]
        let vs = st.engine.videoSize
        let sx = previewSize.width / vs.width
        let sy = previewSize.height / vs.height
        let cx = CGFloat(roi.centerX) * sx
        let cy = previewSize.height - CGFloat(roi.centerY) * sy
        let rad = CGFloat(roi.radius) * sx
        let frame = CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2)
        roiLayer.frame = frame
        roiLayer.cornerRadius = rad
        roiLayer.isHidden = false

        roiLayer.borderColor = NSColor.systemBlue.cgColor
        roiLayer.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        roiLabel.layer?.backgroundColor = NSColor.systemBlue.cgColor

        roiLabel.stringValue = roi.name
        roiLabel.sizeToFit()
        roiLabel.frame.origin = CGPoint(x: previewLayer.frame.origin.x + roiLayer.frame.minX + 4,
                                        y: previewLayer.frame.origin.y + roiLayer.frame.minY + 4)
        roiLabel.isHidden = false
    }

    private func updateOtherROILayers() {
        let st = AppState.shared
        guard st.engine.videoSize.width > 0, !st.rois.isEmpty else {
            roiBoxLayers.forEach { $0.removeFromSuperlayer() }
            roiBoxLayers.removeAll()
            return
        }
        let vs = st.engine.videoSize
        let sx = previewSize.width / vs.width
        let sy = previewSize.height / vs.height
        while roiBoxLayers.count < st.rois.count {
            let l = CALayer()
            l.borderWidth = 1.5
            l.cornerRadius = 2
            l.isHidden = true
            previewLayer.addSublayer(l)
            roiBoxLayers.append(l)
        }
        while roiBoxLayers.count > st.rois.count {
            roiBoxLayers.last?.removeFromSuperlayer()
            roiBoxLayers.removeLast()
        }
        for (i, l) in roiBoxLayers.enumerated() {
            let r = st.rois[i]
            let cx = CGFloat(r.centerX) * sx
            let cy = previewSize.height - CGFloat(r.centerY) * sy
            let rad = CGFloat(r.radius) * sx
            let f = CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2)
            l.frame = f
            l.cornerRadius = f.width / 2
            if i == st.selectedROIIndex {
                l.isHidden = true
            } else {
                l.isHidden = !showAllROIs
                l.borderColor = NSColor.systemGray.cgColor
                l.backgroundColor = NSColor.systemGray.withAlphaComponent(0.06).cgColor
            }
        }
    }

    private func toPreview(_ p: NSPoint) -> NSPoint {
        let o = previewLayer.frame.origin
        return NSPoint(x: p.x - o.x, y: p.y - o.y)
    }

    public override func mouseDown(with event: NSEvent) {
        let p = toPreview(view.convert(event.locationInWindow, from: nil))
        let st = AppState.shared
        guard st.engine.videoSize.width > 0 else { return }

        // 点击 ROI 切换选中
        for (i, r) in st.rois.enumerated() {
            let vs = st.engine.videoSize
            let sx = previewSize.width / vs.width
            let sy = previewSize.height / vs.height
            let cx = CGFloat(r.centerX) * sx
            let cy = previewSize.height - CGFloat(r.centerY) * sy
            let rad = CGFloat(r.radius) * sx
            let frame = CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2)
            if frame.contains(p) {
                st.selectedROIIndex = i
                NotificationCenter.default.post(name: .roisChanged, object: nil)
                return
            }
        }
    }
}
