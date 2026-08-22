// TriggerLogic.swift
// 【算法】ROI 内目标色匹配 + 触发判定。
import Foundation
import CoreVideo

public extension CaptureEngine {
    /// 圆形 ROI 步进扫描,任意 1 个像素匹配目标色即返回 true。
    func sampleHasColor(centerX: Double, centerY: Double, radius: Double,
                        target: RGB, tolerance: Double) -> Bool {
        lock.lock()
        let pb   = currentBuffer
        let size = videoSize
        lock.unlock()
        guard let buf = pb, size.width > 0 else { return false }
        _ = buf as CVPixelBuffer

        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return false }

        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let bpp = 4  // BGRA
        let cx = Int(centerX), cy = Int(centerY), rad = Int(radius)
        guard rad > 0 else { return false }

        let x0 = max(0, cx - rad), x1 = min(w - 1, cx + rad)
        let y0 = max(0, cy - rad), y1 = min(h - 1, cy + rad)
        let rad2 = Double(rad) * Double(rad)
        let step = max(1, rad / 20)

        for y in stride(from: y0, through: y1, by: step) {
            let dy = Double(y - cy)
            for x in stride(from: x0, through: x1, by: step) {
                let dx = Double(x - cx)
                if dx * dx + dy * dy > rad2 { continue }
                let p = base.advanced(by: y * bpr + x * bpp)
                let b = Double(p.load(as: UInt8.self))
                let g = Double(p.advanced(by: 1).load(as: UInt8.self))
                let r = Double(p.advanced(by: 2).load(as: UInt8.self))
                if abs(r - target.r) < tolerance
                    && abs(g - target.g) < tolerance
                    && abs(b - target.b) < tolerance {
                    return true
                }
            }
        }
        return false
    }
}

public enum TriggerLogic {
    public static func evaluate(
        engine: CaptureEngine,
        centerX: Double, centerY: Double, radius: Double,
        targetColor: RGB,
        tolerance: Double
    ) -> Bool {
        return engine.sampleHasColor(centerX: centerX, centerY: centerY, radius: radius,
                                     target: targetColor, tolerance: tolerance)
    }
}
