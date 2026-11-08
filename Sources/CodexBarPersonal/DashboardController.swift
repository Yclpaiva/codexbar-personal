import AppKit
import PersonalCore

@MainActor
final class DashboardController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onClose: (() -> Void)?
    private let period = NSSegmentedControl(
        labels: [7, 30, 90].map { L10n.tr("%ld days", $0) },
        trackingMode: .selectOne,
        target: nil,
        action: nil)
    private let subtitle = NSTextField(labelWithString: L10n.tr("Loading history…"))
    private let cost = NSTextField(labelWithString: "—")
    private let tokens = NSTextField(labelWithString: "—")
    private let requests = NSTextField(labelWithString: "—")
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let chart = UsageChart()
    private let table = NSTableView()
    private var report: UsageReport?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var reloadPending = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar Personal · " + L10n.tr("Proxy history")
        window.minSize = NSSize(width: 690, height: 540)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        self.buildContent()
        self.reload()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        guard let content = self.window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        let title = NSTextField(labelWithString: L10n.tr("Proxy usage"))
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        self.period.selectedSegment = 1
        self.period.target = self
        self.period.action = #selector(self.periodChanged)
        let refresh = NSButton(title: L10n.tr("Refresh"), target: self, action: #selector(self.periodChanged))
        refresh.bezelStyle = .rounded
        let spacer = NSView()
        let header = NSStackView(views: [title, spacer, self.period, refresh])
        header.spacing = 12
        root.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        self.subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(self.subtitle)
        let metrics = NSStackView(views: [
            self.metric(L10n.tr("Estimated cost"), self.cost),
            self.metric("Tokens", self.tokens),
            self.metric(L10n.tr("Requests"), self.requests),
        ])
        metrics.distribution = .fillEqually
        metrics.spacing = 24
        root.addArrangedSubview(metrics)
        metrics.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(self.chart)
        self.chart.heightAnchor.constraint(equalToConstant: 150).isActive = true
        self.chart.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let section = NSTextField(labelWithString: L10n.tr("By model"))
        section.font = .systemFont(ofSize: 14, weight: .semibold)
        root.addArrangedSubview(section)
        for (identifier, title, width) in [
            ("model", L10n.tr("Model"), 300.0),
            ("provider", L10n.tr("Provider"), 100.0),
            ("tokens", "Tokens", 130.0),
            ("cost", L10n.tr("Estimated cost"), 150.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            self.table.addTableColumn(column)
        }
        self.table.delegate = self
        self.table.dataSource = self
        self.table.rowHeight = 27
        self.table.usesAlternatingRowBackgroundColors = true
        self.table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = self.table
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        self.footer.font = .systemFont(ofSize: 11)
        self.footer.textColor = .secondaryLabelColor
        root.addArrangedSubview(self.footer)
        self.footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func metric(_ title: String, _ value: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 25, weight: .medium)
        let stack = NSStackView(views: [label, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    @objc private func periodChanged() { self.reload() }

    func reload() {
        guard self.loadTask == nil else {
            self.reloadPending = true
            return
        }
        self.generation += 1
        let generation = self.generation
        let days = [7, 30, 90][self.period.selectedSegment]
        self.subtitle.stringValue = L10n.tr("Refreshing…")
        self.loadTask = Task { [weak self] in
            let result: Result<UsageReport, Error>
            do { result = try await .success(HistoryService.shared.load(days: days)) } catch { result = .failure(error)
            }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            defer {
                self.loadTask = nil
                if self.reloadPending {
                    self.reloadPending = false
                    self.reload()
                }
            }
            guard days == [7, 30, 90][self.period.selectedSegment] else { return }
            switch result {
            case let .success(report):
                self.report = report
                self.cost.stringValue = Self.money(report.totals.costUSD)
                self.tokens.stringValue = Display.compact(report.totals.tokens)
                self.requests.stringValue = String(report.totals.requests)
                let time = report.generatedAt.formatted(date: .omitted, time: .shortened)
                self.subtitle.stringValue = L10n.tr("%@ to %@ · updated at %@", report.since, report.until, time)
                self.chart.days = report.daily
                self.table.reloadData()
                self.footer.stringValue = [
                    "CLIProxyAPI · " + L10n.tr("%ld failed attempts included.", report.totals.failed),
                    report.totals.unpricedRequests > 0
                        ? L10n.tr(
                            "%ld requests without a price; cost shows the known subtotal.",
                            report.totals.unpricedRequests) : nil,
                    L10n.tr("History from other apps is kept separately."),
                ].compactMap(\.self).joined(separator: " ")
            case let .failure(error):
                self.subtitle.stringValue = L10n.tr("History unavailable")
                self.footer.stringValue = (error as? PersonalError)?.localizedDescription
                    ?? L10n.tr("Could not load the local data.")
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { self.report?.models.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let model = self.report?.models[row], let column = tableColumn else { return nil }
        let identifier = column.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let text: String = switch identifier.rawValue {
        case "model": model.model
        case "provider": model.provider.title
        case "tokens": Display.compact(model.totals.tokens)
        default: model.totals.unpricedRequests == model.totals.requests ? L10n.tr("No price") : Self
            .money(model.totals.costUSD)
        }
        cell.textField?.stringValue = text
        cell.toolTip = text
        return cell
    }

    func windowWillClose(_ notification: Notification) {
        self.generation += 1
        self.loadTask?.cancel()
        self.loadTask = nil
        self.report = nil
        self.chart.days = []
        self.table.reloadData()
        self.onClose?()
    }

    private static func money(_ value: Double) -> String { String(format: "US$ %.2f", value) }
}

@MainActor
private final class UsageChart: NSView {
    var days: [DailyUsage] = [] {
        didSet {
            self.toolTip = self.days.filter { $0.totals.tokens > 0 }
                .map { L10n.tr("%@: %@ tokens", $0.day, Display.compact($0.totals.tokens)) }.joined(separator: "\n")
            self.setAccessibilityLabel(L10n.tr("Tokens per day. %@", self.toolTip ?? L10n.tr("No data")))
            self.needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plot = self.bounds.insetBy(dx: 5, dy: 22)
        NSColor.separatorColor.setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: plot.minX, y: plot.minY))
        baseline.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        baseline.stroke()
        guard let maximum = self.days.map(\.totals.tokens).max(), maximum > 0 else { return }
        let width = plot.width / CGFloat(self.days.count)
        for (index, day) in self.days.enumerated() {
            let height = plot.height * CGFloat(day.totals.tokens) / CGFloat(maximum)
            let bar = NSRect(
                x: plot.minX + CGFloat(index) * width + 1,
                y: plot.minY,
                width: max(1, width - 3),
                height: height)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        NSString(string: self.days.first?.day ?? "").draw(at: NSPoint(x: plot.minX, y: 2), withAttributes: attributes)
        NSString(string: self.days.last?.day ?? "").draw(
            at: NSPoint(x: max(plot.minX, plot.maxX - 65), y: 2),
            withAttributes: attributes)
        NSString(string: L10n.tr("Tokens per day · max %@", Display.compact(maximum))).draw(
            at: NSPoint(x: plot.minX, y: self.bounds.maxY - 15),
            withAttributes: attributes)
    }
}
