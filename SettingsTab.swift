// SettingsTab.swift
// 【界面-设置】设置页:ROI 设置 / 录制规则 / 保存位置 / 状态。
// 统一卡片风格,固定窗口,ROI 最多 3 行。

import AppKit

public final class SettingsTab: NSViewController {
    private var contentView: NSView!
    private var card1: NSBox!
    private var card1Title: NSTextField!
    private var newROIButton: NSButton!
    private var roiListContainer: NSView!
    private var emptyLabel: NSTextField!
    private var roiRows: [ROIListRow] = []
    private var card2: NSBox!
    private var card2Title: NSTextField!
    private var toleranceTextLabel: NSTextField!
    private var toleranceSlider: NSSlider!
    private var toleranceLabel: NSTextField!
    private var card3: NSBox!
    private var card3Title: NSTextField!
    private var saveTextLabel: NSTextField!
    private var pathField: NSTextField!
    private var browseBtn: NSButton!
    private var statusField: NSTextField!

    private let margin: CGFloat = 16
    private let gap:    CGFloat = 12
    private let cardW:  CGFloat = 408
    private let card2H: CGFloat = 64
    private let card3H: CGFloat = 132
    private let rowH:   CGFloat = 30
    private let maxROI: Int = 3

    public struct ROIListRow {
        public let nameField: NSTextField
        public let xField: NSTextField
        public let yField: NSTextField
        public let radiusField: NSTextField
        public let colorPop: NSPopUpButton
        public let deleteBtn: NSButton
        public init(nameField: NSTextField, xField: NSTextField,
                    yField: NSTextField, radiusField: NSTextField,
                    colorPop: NSPopUpButton, deleteBtn: NSButton) {
            self.nameField = nameField; self.xField = xField
            self.yField = yField; self.radiusField = radiusField
            self.colorPop = colorPop; self.deleteBtn = deleteBtn
        }
    }

    public override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 430))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.95, alpha: 1.0).cgColor
        contentView = NSView(frame: v.bounds)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(white: 0.95, alpha: 1.0).cgColor
        v.addSubview(contentView)
        view = v
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        @inline(__always) func makeCard(_ f: NSRect) -> NSBox {
            let c = NSBox(frame: f); c.boxType = .custom; c.cornerRadius = 10
            c.borderColor = NSColor(white: 0.86, alpha: 1.0); c.borderWidth = 1
            c.fillColor = NSColor.white; return c
        }
        @inline(__always) func makeBtn(title: String, bg: NSColor, fg: NSColor, target: Any?, action: Selector) -> NSButton {
            let b = NSButton(title: title, target: target, action: action)
            b.wantsLayer = true; b.layer?.backgroundColor = bg.cgColor
            b.layer?.cornerRadius = 6; b.layer?.borderWidth = 0
            b.layer?.masksToBounds = true
            b.contentTintColor = fg
            b.font = .systemFont(ofSize: 12, weight: .medium)
            return b
        }
        @inline(__always) func makeCardTitle(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            l.textColor = NSColor(white: 0.4, alpha: 1.0)
            contentView.addSubview(l); return l
        }
        @inline(__always) func makeLabel(_ text: String, w: CGFloat = 36) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 12)
            l.textColor = NSColor(white: 0.3, alpha: 1.0)
            contentView.addSubview(l); return l
        }

        card1 = makeCard(NSRect(x: margin, y: 0, width: cardW, height: 200))
        contentView.addSubview(card1)
        card1Title = makeCardTitle("ROI 设置")
        newROIButton = makeBtn(title: "+ 新建", bg: NSColor.systemBlue, fg: .white,
                               target: self, action: #selector(newROI))
        contentView.addSubview(newROIButton)
        emptyLabel = NSTextField(labelWithString: "点击「新建」创建 ROI")
        emptyLabel.font = .systemFont(ofSize: 11); emptyLabel.textColor = .tertiaryLabelColor
        contentView.addSubview(emptyLabel)
        roiListContainer = NSView(frame: .zero)
        roiListContainer.wantsLayer = true
        contentView.addSubview(roiListContainer)

        card2 = makeCard(NSRect(x: margin, y: 0, width: cardW, height: card2H))
        contentView.addSubview(card2)
        card2Title = makeCardTitle("录制规则")
        toleranceTextLabel = makeLabel("容差", w: 32)
        toleranceSlider = NSSlider(value: Double(AppState.shared.tolerance),
                                   minValue: 5, maxValue: 100,
                                   target: self, action: #selector(toleranceChanged))
        contentView.addSubview(toleranceSlider)
        toleranceLabel = NSTextField(labelWithString: "\(Int(AppState.shared.tolerance))")
        toleranceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        toleranceLabel.alignment = .center
        contentView.addSubview(toleranceLabel)

        card3 = makeCard(NSRect(x: margin, y: 0, width: cardW, height: card3H))
        contentView.addSubview(card3)
        card3Title = makeCardTitle("保存位置")
        saveTextLabel = makeLabel("路径", w: 32)
        pathField = NSTextField(frame: .zero)
        pathField.stringValue = AppState.shared.saveDir.path
        pathField.isEditable = false; pathField.drawsBackground = true
        pathField.backgroundColor = NSColor(white: 0.98, alpha: 1.0)
        pathField.wantsLayer = true; pathField.layer?.borderWidth = 1
        pathField.layer?.borderColor = NSColor(white: 0.86, alpha: 1.0).cgColor
        pathField.layer?.cornerRadius = 4; pathField.font = .systemFont(ofSize: 11)
        contentView.addSubview(pathField)
        browseBtn = makeBtn(title: "浏览…", bg: NSColor(white: 0.92, alpha: 1.0), fg: .labelColor,
                            target: self, action: #selector(chooseDir))
        contentView.addSubview(browseBtn)
        statusField = NSTextField(labelWithString: AppState.shared.lastStatus)
        statusField.font = .systemFont(ofSize: 11); statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail
        contentView.addSubview(statusField)

        rebuildROIList()

        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged(_:)),
                                               name: .statusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(saveDirChanged(_:)),
                                               name: .saveDirChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(roisChanged(_:)),
                                               name: .roisChanged, object: nil)
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width
        guard w > 0 else { return }
        let cw = w - margin * 2
        let pad: CGFloat = 14
        let card1H: CGFloat = CGFloat(maxROI) * rowH + 72

        let card3Y = margin
        let card2Y = card3Y + card3H + gap
        let card1Y = card2Y + card2H + gap

        card3.frame = NSRect(x: margin, y: card3Y, width: cw, height: card3H)
        card3Title.frame = NSRect(x: margin + pad, y: card3Y + card3H - 22, width: 200, height: 18)
        let pathY = card3Y + card3H - 52
        saveTextLabel.frame = NSRect(x: margin + pad, y: pathY + 4, width: 32, height: 20)
        let browseW: CGFloat = 64
        let pathX = margin + pad + 38
        let browseX = margin + cw - pad - browseW
        let pathW = browseX - 6 - pathX
        pathField.frame = NSRect(x: pathX, y: pathY, width: pathW, height: 24)
        browseBtn.frame = NSRect(x: browseX, y: pathY, width: browseW, height: 24)
        statusField.frame = NSRect(x: margin + pad, y: card3Y + 6, width: cw - pad * 2, height: 18)

        card2.frame = NSRect(x: margin, y: card2Y, width: cw, height: card2H)
        card2Title.frame = NSRect(x: margin + pad, y: card2Y + card2H - 22, width: 200, height: 18)
        let tolY = card2Y + 14
        let tolLabX = margin + pad
        let tolValW: CGFloat = 36
        let tolValX = margin + cw - pad - tolValW
        let tolSlidX = tolLabX + 38
        let tolSlidW = max(60, tolValX - tolSlidX - 6)
        toleranceTextLabel.frame = NSRect(x: tolLabX, y: tolY, width: 32, height: 20)
        toleranceSlider.frame = NSRect(x: tolSlidX, y: tolY - 2, width: tolSlidW, height: 24)
        toleranceLabel.frame = NSRect(x: tolValX, y: tolY, width: tolValW, height: 20)

        card1.frame = NSRect(x: margin, y: card1Y, width: cw, height: card1H)
        card1Title.frame = NSRect(x: margin + pad, y: card1Y + card1H - 22, width: 200, height: 18)
        let btnY = card1Y + card1H - 48
        newROIButton.frame = NSRect(x: margin + pad, y: btnY, width: 72, height: 24)
        let listTop = btnY - 8
        let listBottom = card1Y + 10
        let listH = listTop - listBottom
        let listX = margin + pad
        let listW = cw - pad * 2
        roiListContainer.frame = NSRect(x: listX, y: listBottom, width: listW, height: listH)
        emptyLabel.frame = NSRect(x: 0, y: (listH - 16) / 2, width: listW, height: 16)
        for (i, r) in roiRows.enumerated() {
            let y = listH - CGFloat(i + 1) * rowH
            r.nameField.frame   = NSRect(x: 0,             y: y + 4, width: listW * 0.2, height: 20)
            r.xField.frame      = NSRect(x: listW * 0.22,  y: y + 2, width: 42,          height: 22)
            r.yField.frame      = NSRect(x: listW * 0.22 + 46, y: y + 2, width: 42,      height: 22)
            r.radiusField.frame = NSRect(x: listW * 0.22 + 92, y: y + 2, width: 42,      height: 22)
            r.colorPop.frame    = NSRect(x: listW * 0.22 + 140, y: y,   width: 60,      height: 26)
            r.deleteBtn.frame   = NSRect(x: listW - 44,   y: y + 1, width: 44,          height: 24)
        }

        let needH = card1Y + card1H + margin
        if abs(contentView.bounds.height - needH) > 1 {
            contentView.frame = NSRect(x: 0, y: 0, width: w, height: needH)
        }
    }

    private func rebuildROIList() {
        let st = AppState.shared
        for r in roiRows {
            r.nameField.removeFromSuperview()
            r.xField.removeFromSuperview()
            r.yField.removeFromSuperview()
            r.radiusField.removeFromSuperview()
            r.colorPop.removeFromSuperview()
            r.deleteBtn.removeFromSuperview()
        }
        roiRows.removeAll()

        for (i, roi) in st.rois.enumerated() {
            let nf = NSTextField(labelWithString: roi.name)
            nf.font = .systemFont(ofSize: 12, weight: .medium); nf.textColor = .labelColor
            roiListContainer.addSubview(nf)

            @inline(__always) func makeTF(_ val: Int, _ tag: Int) -> NSTextField {
                let f = NSTextField(frame: .zero)
                f.stringValue = String(val); f.tag = tag
                f.target = self; f.action = #selector(roiParamChanged(_:))
                f.isEditable = true; f.drawsBackground = true; f.backgroundColor = .white
                f.wantsLayer = true; f.layer?.borderWidth = 1
                f.layer?.borderColor = NSColor(white: 0.86, alpha: 1.0).cgColor
                f.layer?.cornerRadius = 4
                f.font = .systemFont(ofSize: 11); f.alignment = .center
                roiListContainer.addSubview(f)
                return f
            }
            let xf = makeTF(Int(roi.centerX), i * 3)
            let yf = makeTF(Int(roi.centerY), i * 3 + 1)
            let rf = makeTF(Int(roi.radius), i * 3 + 2)

            let cp = NSPopUpButton(frame: .zero)
            cp.addItems(withTitles: ColorPreset.names)
            cp.selectItem(at: st.triggerColorIndex)
            cp.tag = i; cp.target = self; cp.action = #selector(rowColorChanged(_:))
            cp.wantsLayer = true; cp.layer?.cornerRadius = 4
            roiListContainer.addSubview(cp)

            let db = NSButton(title: "删除", target: self, action: #selector(deleteRowAt(_:)))
            db.tag = i; db.wantsLayer = true
            db.layer?.backgroundColor = NSColor(white: 0.95, alpha: 1.0).cgColor
            db.layer?.cornerRadius = 4
            db.layer?.borderWidth = 1
            db.layer?.borderColor = NSColor(white: 0.86, alpha: 1.0).cgColor
            db.layer?.masksToBounds = true
            db.font = .systemFont(ofSize: 11)
            roiListContainer.addSubview(db)

            roiRows.append(ROIListRow(nameField: nf, xField: xf, yField: yf,
                                      radiusField: rf, colorPop: cp, deleteBtn: db))
        }
        emptyLabel.isHidden = !st.rois.isEmpty
        view.needsLayout = true
    }

    @objc public func newROI() {
        let st = AppState.shared
        guard st.engine.videoSize.width > 0 else { return }
        guard st.rois.count < maxROI else { return }
        let vs = st.engine.videoSize
        let name = "ROI \(st.rois.count + 1)"
        st.rois.append(ROI(name: name,
                           centerX: Double(vs.width / 2),
                           centerY: Double(vs.height / 2),
                           radius: 25))
        st.selectedROIIndex = st.rois.count - 1
        NotificationCenter.default.post(name: .roisChanged, object: nil)
        if !st.monitoring { st.startMonitoring() }
    }

    @objc public func roiParamChanged(_ f: NSTextField) {
        let st = AppState.shared
        let idx = f.tag / 3; let which = f.tag % 3
        guard idx < st.rois.count, let v = Double(f.stringValue), v > 0 else { return }
        switch which {
        case 0: st.rois[idx].centerX = v
        case 1: st.rois[idx].centerY = v
        default: st.rois[idx].radius = v
        }
        NotificationCenter.default.post(name: .roisChanged, object: nil)
    }

    @objc public func rowColorChanged(_ p: NSPopUpButton) {
        AppState.shared.triggerColorIndex = p.indexOfSelectedItem
        for r in roiRows { r.colorPop.selectItem(at: p.indexOfSelectedItem) }
    }

    @objc public func deleteRowAt(_ b: NSButton) {
        let i = b.tag; let st = AppState.shared
        guard i < st.rois.count else { return }
        st.rois.remove(at: i)
        if st.selectedROIIndex >= st.rois.count {
            st.selectedROIIndex = max(0, st.rois.count - 1)
        }
        NotificationCenter.default.post(name: .roisChanged, object: nil)
    }

    @objc public func toleranceChanged(_ sl: NSSlider) {
        AppState.shared.tolerance = sl.doubleValue
        toleranceLabel.stringValue = "\(Int(sl.doubleValue))"
    }

    @objc public func chooseDir() { AppState.shared.chooseSaveDir() }

    @objc private func statusChanged(_ n: Notification) {
        if let t = n.userInfo?["text"] as? String { statusField.stringValue = t }
    }
    @objc private func saveDirChanged(_ n: Notification) {
        if let p = n.userInfo?["path"] as? String { pathField.stringValue = p }
    }
    @objc private func roisChanged(_ n: Notification) {
        rebuildROIList()
        view.needsLayout = true
    }
}
