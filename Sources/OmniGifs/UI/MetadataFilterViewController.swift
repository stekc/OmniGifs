import AppKit

@MainActor
final class MetadataFilterViewController: NSViewController {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class OptionButton: NSButton {
        var representedID: UUID?
    }

    private final class DeleteCommand: NSObject {
        let id: UUID
        let name: String

        init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    var onFilterChange: (() -> Void)?

    private let library: GIFLibrary
    private let folderStack = NSStackView()
    private let tagStack = NSStackView()
    private let clearTagsButton = NSButton()

    init(library: GIFLibrary) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
        let rowCount = max(library.folders.count + 1, max(library.tags.count, 1))
        let height = CGFloat(min(230, max(100, 48 + rowCount * 24)))
        preferredContentSize = NSSize(width: 330, height: height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        view = content

        let foldersPane = makePane(
            title: "Folders",
            stack: folderStack,
            trailingControl: nil
        )
        let tagsPane = makePane(
            title: "Tags",
            stack: tagStack,
            trailingControl: clearTagsButton
        )
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        clearTagsButton.title = "Clear"
        clearTagsButton.bezelStyle = .inline
        clearTagsButton.controlSize = .small
        clearTagsButton.target = self
        clearTagsButton.action = #selector(clearTagFilters)

        for pane in [foldersPane, tagsPane] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(pane)
        }
        content.addSubview(separator)

        NSLayoutConstraint.activate([
            foldersPane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            foldersPane.topAnchor.constraint(equalTo: content.topAnchor),
            foldersPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            foldersPane.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.5),
            separator.leadingAnchor.constraint(equalTo: foldersPane.trailingAnchor),
            separator.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            separator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            tagsPane.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            tagsPane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tagsPane.topAnchor.constraint(equalTo: content.topAnchor),
            tagsPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        reloadOptions()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadOptions()
    }

    private func makePane(
        title: String,
        stack: NSStackView,
        trailingControl: NSView?
    ) -> NSView {
        let pane = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(titleLabel)
        pane.addSubview(scrollView)
        if let trailingControl {
            trailingControl.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(trailingControl)
        }

        var constraints = [
            titleLabel.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: pane.topAnchor, constant: 9),
            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -5),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ]
        if let trailingControl {
            constraints.append(contentsOf: [
                trailingControl.trailingAnchor.constraint(
                    equalTo: pane.trailingAnchor,
                    constant: -10
                ),
                trailingControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                titleLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingControl.leadingAnchor,
                    constant: -8
                ),
            ])
        } else {
            constraints.append(
                titleLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: pane.trailingAnchor,
                    constant: -12
                )
            )
        }
        NSLayoutConstraint.activate(constraints)
        return pane
    }

    private func reloadOptions() {
        guard isViewLoaded else { return }
        removeArrangedSubviews(from: folderStack)
        removeArrangedSubviews(from: tagStack)

        let all = OptionButton(
            radioButtonWithTitle: "All",
            target: self,
            action: #selector(folderSelected(_:))
        )
        all.state = library.selectedFolderID == nil ? .on : .off
        configureOption(all)
        addOption(all, to: folderStack)
        for folder in library.folders {
            let button = OptionButton(
                radioButtonWithTitle: folder.name,
                target: self,
                action: #selector(folderSelected(_:))
            )
            button.representedID = folder.id
            button.state = library.selectedFolderID == folder.id ? .on : .off
            button.menu = deletionMenu(
                title: "Delete Folder",
                action: #selector(deleteFolder(_:)),
                id: folder.id,
                name: folder.name
            )
            configureOption(button)
            addOption(button, to: folderStack)
        }

        if library.tags.isEmpty {
            let empty = NSTextField(labelWithString: "No tags yet")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            tagStack.addArrangedSubview(empty)
        } else {
            for tag in library.tags {
                let button = OptionButton(
                    checkboxWithTitle: tag.name,
                    target: self,
                    action: #selector(tagToggled(_:))
                )
                button.representedID = tag.id
                button.state = library.selectedTagIDs.contains(tag.id) ? .on : .off
                button.menu = deletionMenu(
                    title: "Delete Tag",
                    action: #selector(deleteTag(_:)),
                    id: tag.id,
                    name: tag.name
                )
                configureOption(button)
                addOption(button, to: tagStack)
            }
        }
        clearTagsButton.isHidden = library.selectedTagIDs.isEmpty
    }

    private func configureOption(_ button: NSButton) {
        button.controlSize = .small
        button.lineBreakMode = .byTruncatingTail
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func addOption(_ button: NSButton, to stack: NSStackView) {
        stack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func deletionMenu(
        title: String,
        action: Selector,
        id: UUID,
        name: String
    ) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = DeleteCommand(id: id, name: name)
        menu.addItem(item)
        return menu
    }

    private func removeArrangedSubviews(from stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    @objc private func folderSelected(_ sender: OptionButton) {
        performChange { try library.selectFolderFilter(sender.representedID) }
    }

    @objc private func tagToggled(_ sender: OptionButton) {
        guard let tagID = sender.representedID else { return }
        performChange { try library.toggleTagFilter(tagID) }
    }

    @objc private func clearTagFilters() {
        performChange { try library.clearTagFilters() }
    }

    @objc private func deleteFolder(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DeleteCommand,
            confirmDeletion(
                name: command.name,
                detail: "GIFs in this folder won’t be deleted."
            )
        else { return }
        performChange { try library.deleteFolder(command.id) }
    }

    @objc private func deleteTag(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DeleteCommand,
            confirmDeletion(
                name: command.name,
                detail: "This tag will be removed from every GIF."
            )
        else { return }
        performChange { try library.deleteTag(command.id) }
    }

    private func confirmDeletion(name: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(name)”?"
        alert.informativeText = detail
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func performChange(_ change: () throws -> Void) {
        do {
            try change()
            reloadOptions()
            onFilterChange?()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t Update Filters"
            alert.runModal()
            reloadOptions()
        }
    }
}
