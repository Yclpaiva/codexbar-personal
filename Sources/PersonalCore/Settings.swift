import Foundation

/// Providers shown in the menu. Claude and Codex come from the proxy pool; Antigravity from the agy CLI.
public enum MenuProvider: String, CaseIterable, Codable, Sendable {
    case claude, codex, antigravity

    public var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    public var proxy: Provider? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .antigravity: nil
        }
    }
}

public enum BarWindow: String, CaseIterable, Sendable {
    case week = "7d", fiveHours = "5h"

    public var minutes: Int {
        self == .week ? 10080 : 300
    }
}

/// Percentages written next to the menu bar icon.
public enum BarPercent: String, CaseIterable, Sendable {
    case week, fiveHours = "5h", both, none

    public var title: String {
        switch self {
        case .week: L10n.tr("Weekly")
        case .fiveHours: L10n.tr("5 hours")
        case .both: L10n.tr("5 hours and weekly")
        case .none: L10n.tr("None")
        }
    }
}

/// Usage drawn in the menu bar item, following CodexBar: a 5h lane above a weekly lane. The 5h lane is
/// dropped when no visible account has a 5h window or when that pool is exhausted (the weekly-only
/// accounts still serve), leaving a single weekly meter. Percentages follow the same lanes.
public struct MenuBarContent: Equatable, Sendable {
    public let fiveHours: Double?
    public let week: Double?
    public let text: String?

    public init(fiveHours: Double?, week: Double?, percent: BarPercent) {
        let lane = fiveHours.flatMap { $0 >= 100 ? nil : $0 }
        self.fiveHours = lane
        self.week = week
        let values: [Double?] = switch percent {
        case .week: [week ?? lane]
        case .fiveHours: [lane ?? week]
        case .both: [lane, week]
        case .none: []
        }
        let text = values.compactMap(\.self).map { "\(Int($0.rounded()))%" }.joined(separator: " · ")
        self.text = text.isEmpty ? (percent == .none ? nil : "—") : text
    }
}

/// What the menu bar item shows.
public enum BarMode: Equatable, Sendable {
    /// The provider of the tab selected in the menu, as in CodexBar; the overview shows the highest.
    case selectedTab
    case highest
    case fixed(MenuProvider)

    /// Order of the settings popup.
    public static var choices: [Self] {
        [.selectedTab, .highest] + MenuProvider.allCases.map(fixed)
    }

    public init(stored: String?) {
        self = stored == "highest" ? .highest : stored.flatMap(MenuProvider.init(rawValue:))
            .map(Self.fixed) ?? .selectedTab
    }

    public var stored: String {
        switch self {
        case .selectedTab: "selected"
        case .highest: "highest"
        case let .fixed(provider): provider.rawValue
        }
    }
}

/// Menu preferences persisted in UserDefaults. Loading normalizes stored values, so providers added
/// in later versions appear (visible) at the end and unknown or duplicate entries are dropped.
public struct PersonalSettings: Equatable, Sendable {
    public static let refreshChoices = [5, 10, 15, 30]

    public var order: [MenuProvider]
    public var hidden: Set<MenuProvider>
    public var barMode: BarMode
    public var showIcon: Bool
    public var showBars: Bool
    public var barPercent: BarPercent
    public var refreshMinutes: Int
    /// Last selected tab; nil is the overview.
    public var lastTab: MenuProvider?

    public init(
        order: [MenuProvider] = MenuProvider.allCases,
        hidden: Set<MenuProvider> = [],
        barMode: BarMode = .selectedTab,
        showIcon: Bool = true,
        showBars: Bool = true,
        barPercent: BarPercent = .week,
        refreshMinutes: Int = 5,
        lastTab: MenuProvider? = nil)
    {
        var seen = Set<MenuProvider>()
        self.order = (order + MenuProvider.allCases).filter { seen.insert($0).inserted }
        self.hidden = hidden
        self.barMode = barMode
        self.showIcon = showIcon
        self.showBars = showBars
        self.barPercent = barPercent
        self.refreshMinutes = Self.refreshChoices.contains(refreshMinutes) ? refreshMinutes : 5
        self.lastTab = lastTab
    }

    /// Window used to rank providers for "highest usage": five hours only when that is the sole percentage.
    public var rankingWindow: BarWindow {
        self.barPercent == .fiveHours ? .fiveHours : .week
    }

    public var visible: [MenuProvider] {
        self.order.filter { !self.hidden.contains($0) }
    }

    /// The selected tab, falling back to the overview when that provider was hidden.
    public var tab: MenuProvider? {
        self.lastTab.flatMap { self.hidden.contains($0) ? nil : $0 }
    }

    public static func load(from defaults: UserDefaults) -> Self {
        Self(
            order: (defaults.stringArray(forKey: "providerOrder") ?? []).compactMap(MenuProvider.init(rawValue:)),
            hidden: Set((defaults.stringArray(forKey: "hiddenProviders") ?? [])
                .compactMap(MenuProvider.init(rawValue:))),
            barMode: BarMode(stored: defaults.string(forKey: "barMode")),
            showIcon: defaults.object(forKey: "showIcon") as? Bool ?? true,
            showBars: defaults.object(forKey: "showBars") as? Bool ?? true,
            barPercent: defaults.string(forKey: "barPercent").flatMap(BarPercent.init(rawValue:)) ?? .week,
            refreshMinutes: defaults.object(forKey: "refreshMinutes") as? Int ?? 5,
            lastTab: defaults.string(forKey: "lastTab").flatMap(MenuProvider.init(rawValue:)))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(self.order.map(\.rawValue), forKey: "providerOrder")
        defaults.set(self.hidden.map(\.rawValue).sorted(), forKey: "hiddenProviders")
        defaults.set(self.barMode.stored, forKey: "barMode")
        defaults.set(self.showIcon, forKey: "showIcon")
        defaults.set(self.showBars, forKey: "showBars")
        defaults.set(self.barPercent.rawValue, forKey: "barPercent")
        defaults.set(self.refreshMinutes, forKey: "refreshMinutes")
        defaults.set(self.lastTab?.rawValue, forKey: "lastTab")
    }

    /// Provider and percentage for the menu bar. The selected tab or a fixed provider keeps its icon even
    /// before its data arrives; the overview tab, or a fixed provider that was hidden, falls back to the highest.
    public func headline(_ usage: (MenuProvider) -> Double?) -> (provider: MenuProvider, usedPercent: Double?)? {
        let target: MenuProvider? = switch self.barMode {
        case .selectedTab: self.tab
        case .highest: nil
        case let .fixed(provider): self.hidden.contains(provider) ? nil : provider
        }
        if let target { return (target, usage(target)) }
        return self.visible.compactMap { provider in usage(provider).map { (provider, $0) } }
            .max { $0.1 < $1.1 }
            .map { ($0.0, $0.1) }
    }
}

public enum Usage {
    /// Used percentage for a provider window: the weighted proxy pool, or Antigravity's shared groups.
    public static func percent(
        _ provider: MenuProvider,
        window: BarWindow,
        snapshot: QuotaSnapshot?,
        antigravity: AntigravityQuota?) -> Double?
    {
        guard let proxy = provider.proxy else { return antigravity?.usedPercent(minutes: window.minutes) }
        return snapshot?.pools.first { $0.provider == proxy && $0.key == window.rawValue }?.usedPercent
    }
}

extension MenuProvider {
    /// Monochrome SVG from the CodexBar resources; the app renders it as a template image.
    public var iconURL: URL? {
        let name = "ProviderIcon-\(self.rawValue)"
        let packaged = Bundle.main.resourceURL?
            .appendingPathComponent("CodexBarPersonal_PersonalCore.bundle/\(name).svg")
        return packaged.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: name, withExtension: "svg")
    }
}
