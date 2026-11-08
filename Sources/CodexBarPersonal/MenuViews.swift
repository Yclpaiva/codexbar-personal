import AppKit
import PersonalCore

let menuWidth: CGFloat = 340

@MainActor
enum Icons {
    private static var cache: [MenuProvider: NSImage] = [:]

    /// Template image, so AppKit tints it for the menu bar, selection and dark mode.
    static func provider(_ provider: MenuProvider, size: CGFloat) -> NSImage? {
        let base = self.cache[provider] ?? provider.iconURL.flatMap(NSImage.init(contentsOf:))
        self.cache[provider] = base
        guard let image = base?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }

    static func overview(size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size - 3, weight: .regular))
    }
}

func usageColor(_ percent: Double) -> NSColor {
    percent >= 90 ? .systemRed : percent >= 70 ? .systemOrange : .systemGreen
}

func percentText(_ percent: Double?) -> String {
    percent.map { "\(Int($0.rounded()))%" } ?? "—"
}

/// Thin usage bar. A nil percentage draws only the track.
final class UsageBar: NSView {
    var percent: Double? {
        didSet { self.needsDisplay = true }
    }

    var trackColor = NSColor.labelColor.withAlphaComponent(0.12) {
        didSet { self.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = self.bounds.height / 2
        self.trackColor.setFill()
        NSBezierPath(roundedRect: self.bounds, xRadius: radius, yRadius: radius).fill()
        guard let percent, percent > 0 else { return }
        var fill = self.bounds
        fill.size.width = max(fill.height, fill.width * min(100, percent) / 100)
        usageColor(percent).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

/// Provider switcher at the top of the menu. Clicks change the tab without closing the menu.
@MainActor
final class ProviderGridView: NSView {
    struct Tab {
        let provider: MenuProvider?
        let percent: Double?
    }

    var onSelect: ((MenuProvider?) -> Void)?
    private var tabs: [Tab] = []
    private var selected: MenuProvider?

    init() { super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 64)) }

    required init?(coder: NSCoder) { nil }

    func update(tabs: [Tab], selected: MenuProvider?) {
        self.tabs = tabs
        self.selected = selected
        self.subviews.forEach { $0.removeFromSuperview() }
        let columns = min(4, max(1, tabs.count))
        let rows = (tabs.count + columns - 1) / columns
        let padding: CGFloat = 10, gap: CGFloat = 4, height: CGFloat = 54
        let width = (menuWidth - 2 * padding - CGFloat(columns - 1) * gap) / CGFloat(columns)
        self.setFrameSize(NSSize(width: menuWidth, height: CGFloat(rows) * (height + gap) + 6))
        for (index, tab) in tabs.enumerated() {
            let row = index / columns, column = index % columns
            let frame = NSRect(
                x: padding + CGFloat(column) * (width + gap),
                y: self.frame.height - 4 - CGFloat(row + 1) * height - CGFloat(row) * gap,
                width: width,
                height: height)
            let view = GridTabView(frame: frame, tab: tab, selected: tab.provider == selected)
            view.onPress = { [weak self] in self?.onSelect?(tab.provider) }
            self.addSubview(view)
        }
    }
}

@MainActor
private final class GridTabView: NSView {
    var onPress: (() -> Void)?
    private let isSelected: Bool
    private var pressed = false

    init(frame: NSRect, tab: ProviderGridView.Tab, selected: Bool) {
        self.isSelected = selected
        super.init(frame: frame)
        let title = tab.provider?.title ?? "Geral"
        let foreground: NSColor = selected ? .white : .labelColor
        let icon = NSImageView(frame: NSRect(x: (frame.width - 18) / 2, y: 30, width: 18, height: 18))
        icon.image = tab.provider.map { Icons.provider($0, size: 18) } ?? Icons.overview(size: 18)
        icon.contentTintColor = foreground
        self.addSubview(icon)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = foreground
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 2, y: 13, width: frame.width - 4, height: 14)
        self.addSubview(label)
        let bar = UsageBar(frame: NSRect(x: frame.width * 0.15, y: 6, width: frame.width * 0.7, height: 3))
        bar.percent = tab.percent
        bar.trackColor = selected ? NSColor.white.withAlphaComponent(0.35) : NSColor.labelColor.withAlphaComponent(0.12)
        self.addSubview(bar)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.button)
        self.setAccessibilityLabel(
            tab.provider == nil ? "Geral" : "\(title), \(percentText(tab.percent)) usado")
        self.setAccessibilitySelected(selected)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard self.isSelected else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: self.bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func mouseDown(with event: NSEvent) { self.pressed = true }

    /// Fires only for a press that started here and ends with the pointer still inside. The click
    /// that opens the menu delivers a stray mouseUp with another window's coordinates.
    override func mouseUp(with event: NSEvent) {
        defer { self.pressed = false }
        guard self.pressed, let window = self.window else { return }
        let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if self.bounds.contains(point) { self.onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        self.onPress?()
        return true
    }
}

/// Title, percentage, bar and detail line for one quota window.
@MainActor
final class MeterRow: NSView {
    init(title: String, percent: Double?, detail: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 46))
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 18, y: 26, width: menuWidth - 90, height: 16)
        self.addSubview(label)
        let value = NSTextField(labelWithString: percentText(percent))
        value.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        value.alignment = .right
        value.frame = NSRect(x: menuWidth - 72, y: 26, width: 54, height: 16)
        self.addSubview(value)
        let bar = UsageBar(frame: NSRect(x: 18, y: 18, width: menuWidth - 36, height: 5))
        bar.percent = percent
        self.addSubview(bar)
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: 18, y: 2, width: menuWidth - 36, height: 13)
        self.addSubview(sub)
        self.setAccessibilityElement(true)
        self.setAccessibilityLabel("\(title), \(percentText(percent)) usado, \(detail)")
    }

    required init?(coder: NSCoder) { nil }
}

/// One provider in the overview. Clicking opens its tab.
@MainActor
final class SummaryRow: NSView {
    var onPress: (() -> Void)?
    private let views: [NSView]
    private var pressed = false

    init(provider: MenuProvider, percent: Double?, detail: String) {
        let icon = NSImageView(frame: NSRect(x: 16, y: 11, width: 16, height: 16))
        icon.image = Icons.provider(provider, size: 16)
        let name = NSTextField(labelWithString: provider.title)
        name.font = .systemFont(ofSize: 13)
        name.frame = NSRect(x: 42, y: 18, width: 150, height: 16)
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: 42, y: 3, width: 160, height: 14)
        let bar = UsageBar(frame: NSRect(x: 206, y: 17, width: 74, height: 4))
        bar.percent = percent
        let value = NSTextField(labelWithString: percentText(percent))
        value.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        value.alignment = .right
        value.frame = NSRect(x: 282, y: 11, width: 44, height: 16)
        self.views = [icon, name, sub, value]
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 38))
        [icon, name, sub, bar, value].forEach(self.addSubview)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.button)
        self.setAccessibilityLabel("\(provider.title), \(percentText(percent)) usado, \(detail)")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = self.enclosingMenuItem?.isHighlighted == true
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: self.bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        for view in self.views {
            let color: NSColor? = highlighted ? .white : nil
            if let image = view as? NSImageView { image.contentTintColor = color ?? .labelColor }
            if let text = view as? NSTextField {
                text.textColor = color ?? (text.font?.pointSize == 10.5 ? .secondaryLabelColor : .labelColor)
            }
        }
    }

    override func mouseDown(with event: NSEvent) { self.pressed = true }

    /// Fires only for a press that started here and ends with the pointer still inside. The click
    /// that opens the menu delivers a stray mouseUp with another window's coordinates.
    override func mouseUp(with event: NSEvent) {
        defer { self.pressed = false }
        guard self.pressed, let window = self.window else { return }
        let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if self.bounds.contains(point) { self.onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        self.onPress?()
        return true
    }
}

/// Menu bar image: the provider icon and/or CodexBar-style meters, as one template image so AppKit
/// tints it for light and dark menu bars. Meters fill with used capacity, like the rest of the app.
@MainActor
func statusImage(icon: NSImage?, bars: MenuBarContent?, stale: Bool) -> NSImage? {
    guard icon != nil || bars != nil else { return nil }
    let iconWidth: CGFloat = icon == nil ? 0 : 15
    let barWidth: CGFloat = 15
    let gap: CGFloat = icon != nil && bars != nil ? 4 : 0
    let size = NSSize(width: iconWidth + gap + (bars == nil ? 0 : barWidth), height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        if let icon { icon.draw(in: NSRect(x: 0, y: 1.5, width: 15, height: 15)) }
        guard let bars else { return true }
        let x = iconWidth + gap
        func lane(_ y: CGFloat, _ height: CGFloat, _ used: Double?) {
            let rect = NSRect(x: x, y: y, width: barWidth, height: height)
            let radius = height / 2
            NSColor.black.withAlphaComponent(stale ? 0.18 : 0.28).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            let outline = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: radius - 0.5,
                yRadius: radius - 0.5)
            outline.lineWidth = 1
            NSColor.black.withAlphaComponent(stale ? 0.28 : 0.44).setStroke()
            outline.stroke()
            guard let used, used > 0 else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            NSColor.black.withAlphaComponent(stale ? 0.55 : 1).setFill()
            NSRect(x: x, y: y, width: barWidth * min(100, used) / 100, height: height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if let fiveHours = bars.fiveHours, let week = bars.week {
            lane(9.5, 6, fiveHours)
            lane(2.5, 4, week)
        } else {
            lane(5, 8, bars.week ?? bars.fiveHours)
        }
        return true
    }
    image.isTemplate = true
    return image
}
