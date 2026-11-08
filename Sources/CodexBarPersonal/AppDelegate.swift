import AppKit
import PersonalCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private let grid = ProviderGridView()
    private let gridItem = NSMenuItem()
    private var settings = PersonalSettings.load(from: .standard)
    private var menuOpen = false

    private var proxy: ProxyClient?
    private var snapshot: QuotaSnapshot?
    private var proxyError: String?
    private var refreshTask: Task<Void, Never>?
    private var antigravity: AntigravityClient?
    private var antigravityQuota: AntigravityQuota?
    private var antigravityTask: Task<Void, Never>?
    private var antigravityError: String?
    private var timer: Timer?
    private var lastAttempt: Date?

    private var dashboard: DashboardController?
    private var settingsWindow: SettingsController?
    private var benchmarkTimer: Timer?
    private var dashboardExerciseTimer: Timer?
    private var exerciseWindow: DashboardController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.menu.delegate = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.imagePosition = .imageLeading
        item.menu = self.menu
        self.statusItem = item
        self.gridItem.view = self.grid
        self.grid.onSelect = { [weak self] tab in self?.select(tab) }
        self.antigravity = AntigravityClient.locate().map { AntigravityClient(executable: $0) }
        do {
            self.proxy = try client()
        } catch {
            self.proxyError = error.localizedDescription
        }
        self.refresh(force: true)
        self.scheduleTimer()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(self.woke),
            name: NSWorkspace.didWakeNotification,
            object: nil)
        self.updateStatusItem()
        self.rebuildMenu()
        if CommandLine.arguments.contains("--dashboard") { self.openDashboard() }
        if CommandLine.arguments.contains("--settings") { self.openSettings() }
        // Exercises actual menu allocation/release without making additional quota API calls.
        if CommandLine.arguments.contains("--exercise-ui") {
            self.benchmarkTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.rebuildMenu() }
            }
        }
        if CommandLine.arguments.contains("--exercise-dashboard") {
            self.dashboardExerciseTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let exerciseWindow = self.exerciseWindow {
                        exerciseWindow.close()
                        self.exerciseWindow = nil
                    } else {
                        self.exerciseWindow = DashboardController()
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.refreshTask?.cancel()
        self.antigravityTask?.cancel()
        self.timer?.invalidate()
        self.benchmarkTimer?.invalidate()
        self.dashboardExerciseTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        self.menuOpen = true
        self.rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { self.menuOpen = false }
    }

    // MARK: Refresh

    @objc private func woke() { self.refresh(force: false) }

    @objc private func refreshNow() { self.refresh(force: false) }

    private func scheduleTimer() {
        self.timer?.invalidate()
        let interval = TimeInterval(self.settings.refreshMinutes * 60)
        self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: false) }
        }
        self.timer?.tolerance = 30
    }

    /// Hidden providers are not queried. Manual attempts are spaced by 15 seconds unless forced by a
    /// settings change that made a provider visible.
    private func refresh(force: Bool) {
        guard force || self.lastAttempt.map({ Date().timeIntervalSince($0) >= 15 }) ?? true else { return }
        self.lastAttempt = Date()
        let visible = self.settings.visible
        if visible.contains(.antigravity) { self.refreshAntigravity() }
        let providers = Set(visible.compactMap(\.proxy))
        guard !providers.isEmpty, self.refreshTask == nil, let proxy = self.proxy else { return }
        self.refreshTask = Task { [weak self] in
            defer { self?.refreshTask = nil }
            do {
                let snapshot = try await proxy.fetch(providers: providers)
                guard !Task.isCancelled, let self else { return }
                self.snapshot = snapshot
                self.proxyError = nil
                self.dashboard?.reload()
            } catch {
                self?.proxyError = "Não foi possível atualizar as cotas."
            }
            self?.dataChanged()
        }
    }

    /// Runs separately from the proxy so a slow or signed-out agy never delays Claude/Codex quotas.
    private func refreshAntigravity() {
        guard self.antigravityTask == nil, let antigravity = self.antigravity else { return }
        self.antigravityTask = Task { [weak self] in
            defer { self?.antigravityTask = nil }
            do {
                let quota = try await antigravity.fetch()
                guard !Task.isCancelled, let self else { return }
                self.antigravityQuota = quota
                self.antigravityError = nil
            } catch {
                self?.antigravityError = (error as? PersonalError)?.localizedDescription
                    ?? PersonalError.antigravityFailed.localizedDescription
            }
            self?.dataChanged()
        }
    }

    private func dataChanged() {
        self.updateStatusItem()
        if self.menuOpen { self.rebuildMenu() }
        self.settingsWindow?.reloadSubtitles()
    }

    // MARK: Status item

    private func usage(_ provider: MenuProvider, _ window: BarWindow) -> Double? {
        Usage.percent(provider, window: window, snapshot: self.snapshot, antigravity: self.antigravityQuota)
    }

    private func isStale(_ provider: MenuProvider) -> Bool {
        let limit = max(600, TimeInterval(self.settings.refreshMinutes * 120))
        let updated = provider.proxy == nil ? self.antigravityQuota?.updatedAt : self.snapshot?.updatedAt
        let failed = provider.proxy == nil ? self.antigravityError != nil : self.proxyError != nil
        return failed || updated.map { Date().timeIntervalSince($0) > limit } ?? true
    }

    private func updateStatusItem() {
        guard let button = self.statusItem?.button else { return }
        let window = self.settings.barWindow
        let headline = self.settings.headline { self.usage($0, window) }
        let stale = headline.map { self.isStale($0.provider) } ?? !self.settings.visible.isEmpty
        button.image = headline.map { Icons.provider($0.provider, size: 15) } ?? Icons.overview(size: 15)
        button.title = " \(percentText(headline?.usedPercent))\(stale ? " !" : "")"
        let windowName = window == .week ? "semanal" : "de 5 horas"
        button.toolTip = headline.map { "\($0.provider.title) · cota \(windowName) usada" } ?? "CodexBar Personal"
        button.toolTip? += stale ? " · atualização pendente" : ""
        button.setAccessibilityLabel(button.toolTip)
    }

    // MARK: Menu

    private func rebuildMenu() {
        self.menu.removeAllItems()
        if !self.settings.visible.isEmpty {
            self.updateGrid()
            self.menu.addItem(self.gridItem)
        }
        self.addContent()
    }

    private func updateGrid() {
        let tabs = [ProviderGridView.Tab(provider: nil, percent: nil)]
            + self.settings.visible.map { .init(provider: $0, percent: self.usage($0, .week)) }
        self.grid.update(tabs: tabs, selected: self.settings.tab)
        self.gridItem.view = self.grid
    }

    /// Changes the tab while the menu stays open; only the items below the grid are replaced.
    private func select(_ tab: MenuProvider?) {
        self.settings.lastTab = tab
        self.settings.save(to: .standard)
        self.updateStatusItem()
        self.updateGrid()
        while self.menu.items.count > 1 {
            self.menu.removeItem(at: 1)
        }
        self.addContent()
    }

    private func addContent() {
        if self.settings.visible.isEmpty {
            self.heading("Nenhum provedor visível. Ative um em Configurações.")
        } else {
            self.menu.addItem(.separator())
            switch self.settings.tab {
            case nil: self.addOverview()
            case .claude?: self.addProxy(.claude)
            case .codex?: self.addProxy(.codex)
            case .antigravity?: self.addAntigravity()
            }
        }
        self.menu.addItem(.separator())
        self.action("Atualizar cotas", #selector(self.refreshNow), key: "r")
        if self.settings.visible.contains(where: { $0.proxy != nil }) {
            self.action("Histórico do proxy…", #selector(self.openDashboard), key: "d")
        }
        self.action("Configurações…", #selector(self.openSettings), key: ",")
        self.menu.addItem(.separator())
        self.action("Sair", #selector(self.quit), key: "q")
    }

    private func addOverview() {
        for provider in self.settings.visible {
            let row = SummaryRow(
                provider: provider,
                percent: self.usage(provider, .week),
                detail: self.overviewDetail(provider))
            row.onPress = { [weak self] in self?.select(provider) }
            let item = NSMenuItem()
            item.view = row
            self.menu.addItem(item)
        }
    }

    private func overviewDetail(_ provider: MenuProvider) -> String {
        if self.isStale(provider), provider.proxy == nil ? self.antigravityError != nil : self.proxyError != nil {
            return "falha na última atualização"
        }
        if let proxy = provider.proxy {
            return self.snapshot?.pools.first { $0.provider == proxy && $0.key == "7d" }
                .map { Display.reset($0.resetsAt) } ?? "sem dados"
        }
        let weekly = self.antigravityQuota?.groups.flatMap(\.windows)
            .filter { ["gemini-weekly", "3p-weekly"].contains($0.key) }
            .max { $0.usedPercent < $1.usedPercent }
        return weekly.map { Display.reset($0.resetsAt) } ?? "sem dados"
    }

    private func addProxy(_ provider: Provider) {
        if let proxyError { self.heading(proxyError) }
        if self.proxy == nil { self.heading("Inicie pelo launcher para acessar o proxy.") }
        guard let snapshot else { return }
        for key in ["7d", "5h"] {
            guard let pool = snapshot.pools.first(where: { $0.provider == provider && $0.key == key }) else {
                continue
            }
            let used = String(format: "%.2f", locale: Locale(identifier: "pt_BR"), pool.usedCapacity)
            let accounts = pool.included == 1 ? "1 conta" : "\(pool.included) contas"
            let excluded = pool.excluded > 0 ? " · \(pool.excluded) fora do agregado" : ""
            self.meter(
                title: "\(key == "7d" ? "Semana" : "5 horas") · \(used)x de \(Int(pool.capacity))x",
                percent: pool.usedPercent,
                detail: "\(Display.reset(pool.resetsAt)) · \(accounts)\(excluded)")
        }
        self.menu.addItem(.separator())
        for account in snapshot.accounts where account.provider == provider {
            let item = NSMenuItem(
                title: "\(account.tier?.rawValue ?? "?") · \(account.label)",
                action: nil,
                keyEquivalent: "")
            let submenu = NSMenu()
            if let error = account.error { submenu.addItem(withTitle: error, action: nil, keyEquivalent: "") }
            for window in account.windows {
                submenu.addItem(
                    withTitle: "\(window.label): \(Int(window.usedPercent.rounded()))% usado · "
                        + Display.reset(window.resetsAt),
                    action: nil,
                    keyEquivalent: "")
            }
            if account.blocked { submenu.addItem(withTitle: "Limite atingido", action: nil, keyEquivalent: "") }
            if account.tier?.capacity == nil {
                submenu.addItem(withTitle: "Fora do agregado ponderado", action: nil, keyEquivalent: "")
            }
            item.submenu = submenu
            self.menu.addItem(item)
        }
        self.heading("Atualizado às \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
    }

    private func addAntigravity() {
        if self.antigravity == nil { self.heading(PersonalError.antigravityUnavailable.localizedDescription) }
        if let antigravityError { self.heading(antigravityError) }
        guard let quota = self.antigravityQuota else {
            if self.antigravityTask != nil { self.heading("Consultando o agy…") }
            return
        }
        for group in quota.groups {
            for window in group.windows.sorted(by: { ($0.minutes ?? 0) > ($1.minutes ?? 0) }) {
                let name = window.minutes == 10080 ? "semana" : window.minutes == 300 ? "5 horas" : window.label
                self.meter(
                    title: "\(group.name) · \(name)",
                    percent: window.usedPercent,
                    detail: Display.reset(window.resetsAt))
            }
        }
        self.heading("Atualizado às \(quota.updatedAt.formatted(date: .omitted, time: .shortened))")
    }

    private func meter(title: String, percent: Double, detail: String) {
        let item = NSMenuItem()
        item.view = MeterRow(title: title, percent: percent, detail: detail)
        self.menu.addItem(item)
    }

    private func heading(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        self.menu.addItem(item)
    }

    private func action(_ title: String, _ selector: Selector, key: String) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        self.menu.addItem(item)
    }

    // MARK: Windows

    @objc private func openDashboard() {
        if self.dashboard == nil {
            self.dashboard = DashboardController()
            self.dashboard?.onClose = { [weak self] in self?.dashboard = nil }
        }
        self.dashboard?.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        if self.settingsWindow == nil {
            let controller = SettingsController(settings: self.settings) { [weak self] provider in
                self?.subtitle(provider) ?? ("", true)
            }
            controller.onChange = { [weak self] settings in self?.apply(settings) }
            controller.onClose = { [weak self] in self?.settingsWindow = nil }
            self.settingsWindow = controller
        }
        self.settingsWindow?.showWindow(nil)
        // Accessory apps are not activated by the menu click; bring the window forward explicitly.
        self.settingsWindow?.window?.orderFrontRegardless()
        NSApplication.shared.activate()
    }

    private func subtitle(_ provider: MenuProvider) -> (text: String, available: Bool) {
        guard let proxy = provider.proxy else {
            return self.antigravity == nil
                ? (PersonalError.antigravityUnavailable.localizedDescription, false)
                : ("agy CLI · conta logada no agy", true)
        }
        let count = self.snapshot?.accounts.filter { $0.provider == proxy }.count ?? 0
        return (count > 0 ? "Taproot · \(count) contas" : "Taproot", true)
    }

    private func apply(_ changed: PersonalSettings) {
        var changed = changed
        // The tab is chosen in the menu; the settings window's copy may be older.
        changed.lastTab = self.settings.lastTab
        let previous = self.settings
        self.settings = changed
        changed.save(to: .standard)
        if previous.refreshMinutes != changed.refreshMinutes { self.scheduleTimer() }
        if !Set(changed.visible).subtracting(previous.visible).isEmpty { self.refresh(force: true) }
        self.updateStatusItem()
        if self.menuOpen { self.rebuildMenu() }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
