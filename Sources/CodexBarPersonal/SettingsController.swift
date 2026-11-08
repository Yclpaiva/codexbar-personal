import AppKit
import PersonalCore

/// Provider visibility and order, plus what the menu bar shows. Every change applies immediately.
@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: ((PersonalSettings) -> Void)?
    var onClose: (() -> Void)?
    private var settings: PersonalSettings
    private let subtitle: (MenuProvider) -> (text: String, available: Bool)
    private let table = NSTableView()
    private let barProvider = NSPopUpButton()
    private let barWindow = NSPopUpButton()
    private let refresh = NSPopUpButton()
    private static let dragType = NSPasteboard.PasteboardType("dev.yuri.CodexBarPersonal.provider")

    init(settings: PersonalSettings, subtitle: @escaping (MenuProvider) -> (text: String, available: Bool)) {
        self.settings = settings
        self.subtitle = subtitle
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Configurações"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        self.build(in: window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func reloadSubtitles() { self.table.reloadData() }

    func windowWillClose(_ notification: Notification) { self.onClose?() }

    private func build(in window: NSWindow) {
        let column = NSTableColumn(identifier: .init("provider"))
        self.table.addTableColumn(column)
        self.table.headerView = nil
        self.table.rowHeight = 44
        self.table.style = .inset
        self.table.dataSource = self
        self.table.delegate = self
        self.table.registerForDraggedTypes([Self.dragType])
        self.table.draggingDestinationFeedbackStyle = .gap
        let scroll = NSScrollView()
        scroll.documentView = self.table
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        self.barProvider.addItems(withTitles: ["Aba selecionada", "Provedor com maior uso"]
            + MenuProvider.allCases.map(\.title))
        self.barWindow.addItems(withTitles: ["Semana", "5 horas"])
        self.refresh.addItems(withTitles: PersonalSettings.refreshChoices.map { "\($0) minutos" })
        for popup in [self.barProvider, self.barWindow, self.refresh] {
            popup.target = self
            popup.action = #selector(self.popupChanged)
        }
        self.syncPopups()

        let grid = NSGridView(views: [
            [Self.label("Mostrar"), self.barProvider],
            [Self.label("Janela"), self.barWindow],
            [Self.label("Atualizar a cada"), self.refresh],
        ])
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.rowAlignment = .firstBaseline

        let stack = NSStackView(views: [
            Self.caption("Mostrar no menu · arraste para reordenar"),
            scroll,
            Self.caption("Barra de menus"),
            grid,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: scroll)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        let rows = CGFloat(MenuProvider.allCases.count)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(equalToConstant: rows * 44 + 12),
            grid.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            content.widthAnchor.constraint(equalToConstant: 460),
        ])
        // Size the window to its content so the grid rows do not stretch.
        window.setContentSize(content.fittingSize)
    }

    private func syncPopups() {
        self.barProvider.selectItem(at: BarMode.choices.firstIndex(of: self.settings.barMode) ?? 0)
        self.barWindow.selectItem(at: self.settings.barWindow == .week ? 0 : 1)
        self.refresh.selectItem(at: PersonalSettings.refreshChoices.firstIndex(of: self.settings.refreshMinutes) ?? 0)
    }

    @objc private func popupChanged() {
        self.settings.barMode = BarMode.choices[max(0, self.barProvider.indexOfSelectedItem)]
        self.settings.barWindow = self.barWindow.indexOfSelectedItem == 0 ? .week : .fiveHours
        self.settings.refreshMinutes = PersonalSettings.refreshChoices[max(0, self.refresh.indexOfSelectedItem)]
        self.onChange?(self.settings)
    }

    @objc private func toggled(_ sender: NSSwitch) {
        let provider = self.settings.order[sender.tag]
        if sender.state == .on { self.settings.hidden.remove(provider) } else { self.settings.hidden.insert(provider) }
        self.onChange?(self.settings)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { self.settings.order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let provider = self.settings.order[row]
        let info = self.subtitle(provider)
        let cell = NSView()
        let icon = NSImageView(image: Icons.provider(provider, size: 18) ?? NSImage())
        icon.contentTintColor = .labelColor
        let name = NSTextField(labelWithString: provider.title)
        let detail = NSTextField(labelWithString: info.text)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = info.available ? .secondaryLabelColor : .systemRed
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = self.settings.hidden.contains(provider) || !info.available ? .off : .on
        toggle.isEnabled = info.available
        toggle.tag = row
        toggle.target = self
        toggle.action = #selector(self.toggled(_:))
        toggle.setAccessibilityLabel("Mostrar \(provider.title)")
        let row = NSStackView(views: [icon, text, NSView(), toggle])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation
    {
        dropOperation == .above ? .move : []
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation) -> Bool
    {
        guard let value = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let source = Int(value), self.settings.order.indices.contains(source) else { return false }
        let provider = self.settings.order.remove(at: source)
        self.settings.order.insert(provider, at: source < row ? row - 1 : row)
        tableView.reloadData()
        self.onChange?(self.settings)
        return true
    }

    private static func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11.5, weight: .medium)
        field.textColor = .secondaryLabelColor
        return field
    }
}
