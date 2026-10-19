import AppKit

/// Timeline colours (our own palette). Dynamic: each resolves for the current
/// drawing appearance, so dark and light mode both work.
@MainActor
enum Palette {
    static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        }
    }

    static let background = dynamic(light: 0xECEDF0, dark: 0x1B1C1F)
    static let rowEven = dynamic(light: 0xF6F7F9, dark: 0x232428)
    static let rowOdd = dynamic(light: 0xF1F2F5, dark: 0x202125)
    static let rowLocked = dynamic(light: 0xE4E5E9, dark: 0x2A2B30)
    static let header = dynamic(light: 0xE3E5EA, dark: 0x2A2B30)
    static let headerSelected = dynamic(light: 0xD6DAE3, dark: 0x33353B)
    static let ruler = dynamic(light: 0xDDDFE4, dark: 0x2D2E33)
    static let separator = dynamic(light: 0xC9CCD3, dark: 0x3A3B41)
    static let tick = dynamic(light: 0x7B7F88, dark: 0x8A8E97)
    static let text = dynamic(light: 0x1E2025, dark: 0xE8E9ED)
    static let secondaryText = dynamic(light: 0x60646D, dark: 0x9A9EA7)
    static let playhead = NSColor(hex: 0xFF453A)
    static let selection = dynamic(light: 0xFFB800, dark: 0xFFC83D)
    static let snapGuide = NSColor(hex: 0xFFD60A)
    static let marqueeFill = dynamic(light: 0x0A84FF, dark: 0x0A84FF, alpha: 0.12)
    static let marqueeStroke = NSColor(hex: 0x0A84FF)
    static let invalid = NSColor(hex: 0xFF453A)
    static let buttonOn = dynamic(light: 0x0A6CFF, dark: 0x4C9DFF)
    static let buttonWarn = dynamic(light: 0xD9480F, dark: 0xFF8A4C)
    static let buttonOff = dynamic(light: 0x8C9099, dark: 0x7D818A)

    /// Base colour of a clip style.
    static func clip(_ style: TimelineClipStyle) -> NSColor {
        switch style {
        case .video: NSColor(hex: 0x3B82F6)
        case .screen: NSColor(hex: 0x6366F1)
        case .audio: NSColor(hex: 0x22A06B)
        case .image: NSColor(hex: 0xA855F7)
        case .unified: NSColor(hex: 0x2F7FD8)
        case .stitched: NSColor(hex: 0x0E9F9E)
        case .group: NSColor(hex: 0xE08A1E)
        case .callout: NSColor(hex: 0xE5487D)
        case .shader: NSColor(hex: 0x64748B)
        case .other: NSColor(hex: 0x7C8089)
        }
    }

    static let banner = dynamic(light: 0xFCE9C8, dark: 0x3A2E1A)
    static let bannerText = dynamic(light: 0x7A4A00, dark: 0xFFC46B)
    static let outsideGroup = dynamic(light: 0x000000, dark: 0x000000, alpha: 0.28)
    static let marker = dynamic(light: 0x0F9F8F, dark: 0x3DD6C3)
    static let waveform = NSColor(white: 1, alpha: 0.85)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
