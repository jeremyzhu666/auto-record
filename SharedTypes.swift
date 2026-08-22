// SharedTypes.swift
// 【共享契约】所有模块共用的数据类型、通知名、颜色协议。
import Foundation
import AppKit

public extension Notification.Name {
    static let monitoringChanged  = Notification.Name("monitoringChanged")
    static let recordingChanged   = Notification.Name("recordingChanged")
    static let statusChanged      = Notification.Name("statusChanged")
    static let saveDirChanged     = Notification.Name("saveDirChanged")
    static let roiDisplayChanged  = Notification.Name("roiDisplayChanged")
    static let roisChanged        = Notification.Name("roisChanged")
}

public typealias RGB = (r: Double, g: Double, b: Double)

@inlinable
public func colorMatch(_ a: RGB, _ b: RGB, tolerance: Double) -> Bool {
    return abs(a.r - b.r) < tolerance
        && abs(a.g - b.g) < tolerance
        && abs(a.b - b.b) < tolerance
}

public enum ColorPreset {
    public static let red:   RGB = (255,   0,   0)
    public static let white: RGB = (255, 255, 255)
    public static let green: RGB = (  0, 200,   0)
    public static let all: [RGB]       = [red, white, green]
    public static let names: [String]  = ["红", "白", "绿"]

    public static func from(index: Int) -> RGB {
        guard index >= 0 && index < all.count else { return red }
        return all[index]
    }

    public static func nsColor(for rgb: RGB) -> NSColor {
        NSColor(red:   CGFloat(rgb.r) / 255.0,
                green: CGFloat(rgb.g) / 255.0,
                blue:  CGFloat(rgb.b) / 255.0,
                alpha: 1.0)
    }
}

public enum RecState: String {
    case standby   = "待机"
    case recording = "录制中"
}

public struct ROI: Codable, Equatable {
    public var name: String
    public var centerX: Double
    public var centerY: Double
    public var radius: Double

    public init(name: String, centerX: Double, centerY: Double, radius: Double) {
        self.name    = name
        self.centerX = centerX
        self.centerY = centerY
        self.radius  = radius
    }
}
