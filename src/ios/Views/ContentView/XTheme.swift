//
//  XTheme.swift
//  Minis - Xov design tokens
//
//  照搬 xosvi 的视觉规范（DeepSeek 风：浅色纯白 / 深色近黑的中性底，
//  强调色统一一支蓝，行内信息只用「标题 + 摘要 + 相对时间」三层）。
//  抽屉的会话行先用这套；聊天页、设置二级页后续也走这里，别在页面里另写字号花色。
//

import SwiftUI

enum XTheme {

    // MARK: - 底色

    /// 页面底：浅色纯白、深色近黑
    static let bg = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.09, alpha: 1)
        : .white })

    /// 卡片 / 输入框底：浅色白（靠描边区分）、深色略亮一档
    static let card = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.15, alpha: 1)
        : .white })

    /// 选中行底
    static let rowSelected = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.18, alpha: 1)
        : UIColor(white: 0.96, alpha: 1) })

    /// 分隔线：压到几乎看不见
    static let hairline = Color.primary.opacity(0.06)

    static let subText = Color.secondary

    /// DeepSeek 蓝
    static let accent = Color(red: 0.30, green: 0.42, blue: 0.96)

    // MARK: - 尺寸

    static let rowRadius: CGFloat = 10
    static let avatarDiameter: CGFloat = 34
    static let rowHPadding: CGFloat = 16
    static let rowVPadding: CGFloat = 12

    // MARK: - 字号（未乘 App Base 缩放，调用方用 fontSettings.scaledApp(_:) 包一层）

    static let rowTitleSize: CGFloat = 15
    static let rowSubtitleSize: CGFloat = 13
    static let rowTimeSize: CGFloat = 12
    static let avatarGlyphSize: CGFloat = 15
    static let avatarInitialSize: CGFloat = 14

    // MARK: - 头像外圈取色

    /// 按标题哈希取稳定色相，饱和度压低——同一个会话每次进来都是同一支颜色。
    /// 会话自带类别色时优先用类别色（抽屉里已有语义：终端/写作/检索…）。
    static func ringColor(for key: String) -> Color {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Color(hue: Double(h % 360) / 360.0, saturation: 0.45, brightness: 0.72)
    }
}
