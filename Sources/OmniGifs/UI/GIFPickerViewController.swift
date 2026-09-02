import AppKit
import Darwin
import OSLog

@MainActor
protocol GIFPickerViewControllerDelegate: AnyObject {
    func gifPicker(_ picker: GIFPickerViewController, didChoose favorite: GIFFavorite)
}

@MainActor
final class GIFPickerViewController: NSViewController {
    private static let refreshInterval: TimeInterval = 5 * 60
    private static var lastRefreshAt: Date?
    private static let logger = Logger(subsystem: "win.stkc.omnigifs", category: "Picker")

    weak var delegate: GIFPickerViewControllerDelegate?

    private let library: GIFLibrary
    private let session: DiscordSessionCoordinator
    private let search: SearchCoordinator

    private let collectionView = NSCollectionView()
    private let scrollView = NSScrollView()
    private let searchField = CommandSearchField()
    private let reloadButton = NSButton()
    private let reloadIcon = PassThroughImageView()
    private let activityIndicator = PassThroughProgressIndicator()
    private let countLabel = NSTextField(labelWithString: "")
    private let activityLabel = NSTextField(labelWithString: "")
    private let emptyStateArea = NSView()
    private let emptyLoginButton = NSButton()
    private let layout = WaterfallLayout()
    private let liveItems = NSHashTable<GIFCollectionItem>.weakObjects()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, String>!
    private var displayedFavorites: [String: GIFFavorite] = [:]
    private var displayedOrder: [GIFFavorite] = []
    private var displayedSearchResults: [String: GIFSearchResult] = [:]
    private var searchTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var indexProgressTask: Task<Void, Never>?
    private var playbackResumeTask: Task<Void, Never>?
    private var scrollPlaybackRecoveryTask: Task<Void, Never>?
    private var indexProgress: SearchIndexProgress?
    private var playbackEnabled = false
    private var isPresented = false
    private var lastCompletedSearchQuery: String?
    private var scrollToTopAfterReload = false
    private var refreshGeneration = 0

    init(library: GIFLibrary, session: DiscordSessionCoordinator, search: SearchCoordinator) {
        self.library = library
        self.session = session
        self.search = search
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        indexProgressTask?.cancel()
        presentationTask?.cancel()
        searchTask?.cancel()
        playbackResumeTask?.cancel()
        scrollPlaybackRecoveryTask?.cancel()
    }

    override func loadView() {
        // NSPopover already supplies the native glass background. A nested
        // behind-window visual effect can briefly redraw when its window reopens.
        let background = NSView()
        background.translatesAutoresizingMaskIntoConstraints = false
        view = background

        let title = NSTextField(labelWithString: "Favorites")
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.setContentHuggingPriority(.required, for: .horizontal)

        countLabel.font = .systemFont(ofSize: 13, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        activityLabel.font = .systemFont(ofSize: 13, weight: .medium)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [title, countLabel, activityLabel])
        titleStack.orientation = .horizontal
        titleStack.alignment = .firstBaseline
        titleStack.spacing = 7
        titleStack.setCustomSpacing(3, after: countLabel)

        searchField.placeholderString = "Search favorites"
        searchField.stringValue = library.query
        if SearchQueryPolicy.isSearchable(library.query) {
            lastCompletedSearchQuery = library.query
        }
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.controlSize = .large

        reloadButton.title = ""
        reloadButton.isBordered = false
        reloadButton.refusesFirstResponder = true
        reloadButton.toolTip = "Refresh favorites"
        reloadButton.setAccessibilityLabel("Refresh favorites")
        reloadButton.target = self
        reloadButton.action = #selector(statusButtonPressed)

        reloadIcon.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        reloadIcon.imageScaling = .scaleProportionallyDown
        reloadIcon.imageAlignment = .alignCenter
        reloadIcon.contentTintColor = .secondaryLabelColor

        activityIndicator.style = .spinning
        activityIndicator.controlSize = .small
        activityIndicator.isDisplayedWhenStopped = false
        activityIndicator.isHidden = true

        let reloadContainer = NSView()
        reloadContainer.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadIcon.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        reloadContainer.addSubview(reloadButton)
        reloadContainer.addSubview(reloadIcon)
        reloadContainer.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            reloadContainer.widthAnchor.constraint(equalToConstant: 36),
            reloadContainer.heightAnchor.constraint(equalToConstant: 36),
            reloadButton.leadingAnchor.constraint(equalTo: reloadContainer.leadingAnchor),
            reloadButton.trailingAnchor.constraint(equalTo: reloadContainer.trailingAnchor),
            reloadButton.topAnchor.constraint(equalTo: reloadContainer.topAnchor),
            reloadButton.bottomAnchor.constraint(equalTo: reloadContainer.bottomAnchor),
            reloadIcon.widthAnchor.constraint(equalToConstant: 16),
            reloadIcon.heightAnchor.constraint(equalToConstant: 16),
            reloadIcon.centerXAnchor.constraint(equalTo: reloadContainer.centerXAnchor),
            reloadIcon.centerYAnchor.constraint(
                equalTo: reloadContainer.centerYAnchor, constant: -2),
            activityIndicator.centerXAnchor.constraint(equalTo: reloadContainer.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(
                equalTo: reloadContainer.centerYAnchor, constant: -2),
        ])

        let headerContent = NSView()
        headerContent.translatesAutoresizingMaskIntoConstraints = false
        for subview in [titleStack, searchField, reloadContainer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            headerContent.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: headerContent.leadingAnchor, constant: 14),
            titleStack.topAnchor.constraint(equalTo: headerContent.topAnchor, constant: 10),
            reloadContainer.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleStack.trailingAnchor, constant: 8),
            reloadContainer.trailingAnchor.constraint(
                equalTo: headerContent.trailingAnchor, constant: -4),
            reloadContainer.centerYAnchor.constraint(
                equalTo: titleStack.centerYAnchor, constant: -1),
            searchField.leadingAnchor.constraint(
                equalTo: headerContent.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(
                equalTo: headerContent.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 7),
            searchField.bottomAnchor.constraint(equalTo: headerContent.bottomAnchor, constant: -10),
            headerContent.heightAnchor.constraint(equalToConstant: 82),
        ])

        let glass = NSGlassEffectView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 20
        glass.style = .regular
        glass.contentView = headerContent

        emptyLoginButton.title = "Log In to Discord"
        emptyLoginButton.target = self
        emptyLoginButton.action = #selector(emptyLoginButtonPressed)
        emptyLoginButton.bezelStyle = .rounded
        emptyLoginButton.controlSize = .large
        emptyLoginButton.translatesAutoresizingMaskIntoConstraints = false
        emptyStateArea.translatesAutoresizingMaskIntoConstraints = false
        emptyStateArea.addSubview(emptyLoginButton)

        layout.delegate = self
        // Preserve the initial first-row position while allowing content to
        // continue underneath the floating glass header as the user scrolls.
        layout.sectionInsets.top = 106
        collectionView.frame = NSRect(x: 0, y: 0, width: 526, height: 530)
        collectionView.autoresizingMask = [.width]
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        dataSource = NSCollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id in
            guard let self,
                let favorite = displayedFavorites[id],
                let item = collectionView.makeItem(
                    withIdentifier: GIFCollectionItem.identifier,
                    for: indexPath
                ) as? GIFCollectionItem
            else { return nil }
            // A reused cell may still carry the previous presentation's state.
            // Disable it before configure(), since configure can start playback.
            item.setPlaybackEnabled(false)
            liveItems.add(item)
            item.configure(with: favorite, searchResult: displayedSearchResults[id])
            item.setPlaybackEnabled(isPresented && playbackEnabled)
            return item
        }
        collectionView.collectionViewLayout = layout
        // Assigning a collection layout can replace AppKit's internal collection
        // core, including its reuse registry. Register items after the layout.
        collectionView.register(
            GIFCollectionItem.self,
            forItemWithIdentifier: GIFCollectionItem.identifier
        )

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollDidEndLiveScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        background.addSubview(scrollView)
        background.addSubview(emptyStateArea, positioned: .above, relativeTo: scrollView)
        background.addSubview(glass, positioned: .above, relativeTo: emptyStateArea)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            glass.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            glass.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: background.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            emptyStateArea.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            emptyStateArea.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            emptyStateArea.topAnchor.constraint(equalTo: glass.bottomAnchor),
            emptyStateArea.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            emptyLoginButton.centerXAnchor.constraint(equalTo: emptyStateArea.centerXAnchor),
            emptyLoginButton.centerYAnchor.constraint(equalTo: emptyStateArea.centerYAnchor),
        ])

        library.onChange = { [weak self] in self?.reloadLibrary() }
        session.onStateChange = { [weak self] state in self?.updateSessionState(state) }
        indexProgressTask = Task { [weak self, search] in
            let updates = await search.progressUpdates()
            for await progress in updates {
                guard !Task.isCancelled else { break }
                self?.updateIndexProgress(progress)
            }
        }
        reloadLibrary()
        updateSessionState(session.state)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let viewport = scrollView.contentSize
        guard viewport.width > 0, viewport.height > 0 else { return }

        var frame = collectionView.frame
        let widthChanged = abs(frame.width - viewport.width) > 0.5
        if widthChanged {
            frame.size.width = viewport.width
            frame.size.height = max(frame.height, viewport.height)
            collectionView.frame = frame
            layout.invalidateLayout()
        }

        layout.prepare()
        let targetHeight = max(viewport.height, layout.collectionViewContentSize.height)
        if abs(collectionView.frame.height - targetHeight) > 0.5 {
            collectionView.setFrameSize(NSSize(width: viewport.width, height: targetHeight))
        }
    }

    func prepareForPresentation() {
        playbackResumeTask?.cancel()
        setPlaybackEnabled(false)
        for case let item as GIFCollectionItem in collectionView.visibleItems() {
            item.restorePosterIfNeeded()
        }
        refreshIfStale()
    }

    func startInitialRefresh() {
        _ = view
        refreshIfStale()
    }

    private func refreshIfStale() {
        guard presentationTask == nil else { return }
        let now = Date()
        if let lastRefreshAt = Self.lastRefreshAt,
            now.timeIntervalSince(lastRefreshAt) < Self.refreshInterval
        {
            return
        }
        refreshFavorites(forceReload: false)
    }

    func didPresent() {
        isPresented = true
        for case let item as GIFCollectionItem in collectionView.visibleItems() {
            item.restorePosterIfNeeded()
        }
        view.window?.makeFirstResponder(searchField)
        configureSearchEditor()
        let query = SearchQueryPolicy.normalized(searchField.stringValue)
        if SearchQueryPolicy.isSearchable(query), lastCompletedSearchQuery != query {
            searchTask?.cancel()
            searchTask = Task { [weak self] in
                guard let self else { return }
                await refreshCurrentSearch()
            }
        }
        playbackResumeTask?.cancel()
        playbackResumeTask = Task { [weak self] in
            await WebPVideoTranscoder.shared.activate()
            // Let the popover window commit its static thumbnail frame first.
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.setPlaybackEnabled(true)
        }
    }

    private func configureSearchEditor() {
        guard let editor = searchField.currentEditor() as? NSTextView else { return }
        // Search terms are identifiers and short phrases, not prose. Keeping
        // AppKit's writing assistance enabled here starts CoreNLP's language
        // model and leaves tens of megabytes resident after the popover closes.
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
    }

    func didDismiss() {
        isPresented = false
        searchTask?.cancel()
        searchTask = nil
        playbackResumeTask?.cancel()
        playbackResumeTask = nil
        scrollPlaybackRecoveryTask?.cancel()
        scrollPlaybackRecoveryTask = nil
        playbackEnabled = false
        for item in liveItems.allObjects {
            item.releaseVisualResources()
        }
        GIFVisualCache.shared.removeThumbnails()
        GIFVisualCache.shared.removeAnimations()
        Task {
            await ThumbnailPipeline.shared.releaseMemoryCache()
        }
        Task { [search] in
            await search.releaseRuntimeResources()
            // Core ML and media teardown leave large empty malloc regions.
            // Give framework releases one run-loop turn, then hand those pages
            // back to the OS rather than waiting for system memory pressure.
            try? await Task.sleep(for: .milliseconds(150))
            _ = await Task.detached(priority: .background) {
                malloc_zone_pressure_relief(nil, 0)
            }.value
        }
        Task {
            await WebPVideoTranscoder.shared.cancelAll()
        }
    }

    private func setPlaybackEnabled(_ enabled: Bool) {
        guard playbackEnabled != enabled else { return }
        playbackEnabled = enabled
        for case let item as GIFCollectionItem in collectionView.visibleItems() {
            item.setPlaybackEnabled(enabled)
        }
    }

    @objc private func scrollBoundsChanged(_ notification: Notification) {
        guard isPresented, playbackEnabled else { return }
        scrollPlaybackRecoveryTask?.cancel()
        scrollPlaybackRecoveryTask = Task { [weak self] in
            // Coalesce momentum-scroll notifications, then ask AppKit for the
            // settled visible set. setPlaybackEnabled(true) deliberately
            // reasserts play even when the logical flag was already true.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let self else { return }
            recoverVisiblePlaybackAfterScroll()
        }
    }

    @objc private func scrollDidEndLiveScroll(_ notification: Notification) {
        guard isPresented, playbackEnabled else { return }
        scrollPlaybackRecoveryTask?.cancel()
        scrollPlaybackRecoveryTask = nil
        recoverVisiblePlaybackAfterScroll()
    }

    private func recoverVisiblePlaybackAfterScroll() {
        collectionView.layoutSubtreeIfNeeded()
        collectionView.setNeedsDisplay(collectionView.visibleRect)
        for case let item as GIFCollectionItem in collectionView.visibleItems() {
            item.recoverPlaybackAfterScroll()
        }
    }

    private func refreshFavorites(forceReload: Bool) {
        if forceReload {
            presentationTask?.cancel()
        } else if presentationTask != nil {
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        let reportsProgress = forceReload
        if reportsProgress { updateIndexProgress(.refreshingFavorites) }
        presentationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if refreshGeneration == generation {
                    presentationTask = nil
                }
            }
            let previousFavorites = library.favorites
            library.setHiddenIDs(await search.unavailableIDs())
            if let data = await session.refreshFavorites(
                forceReload: forceReload,
                reportConnecting: reportsProgress
            ) {
                do {
                    let changed = try library.replace(with: data)
                    if changed {
                        let currentIDs = Set(library.favorites.map(\.id))
                        let removedIDs = Set(previousFavorites.map(\.id)).subtracting(currentIDs)
                        if !removedIDs.isEmpty {
                            try await ThumbnailPipeline.shared.removeCachedData(for: removedIDs)
                            try await WebPVideoTranscoder.shared.removeCachedVideos(
                                for: removedIDs
                            )
                        }
                    }
                } catch {
                    Self.logger.error(
                        "Unable to update favorites: \(error.localizedDescription, privacy: .public)"
                    )
                    updateIndexProgress(.unavailable)
                }
            }
            let favorites = library.favorites
            let favoritesChanged = favorites != previousFavorites
            let indexChanged = await search.index(favorites)
            library.setHiddenIDs(await search.unavailableIDs())
            if favoritesChanged || indexChanged {
                await refreshCurrentSearch()
            }
        }
    }

    private func refreshCurrentSearch(shouldScrollToTop: Bool = false) async {
        let query = SearchQueryPolicy.normalized(searchField.stringValue)
        guard SearchQueryPolicy.isSearchable(query) else {
            library.setQuery("")
            return
        }
        if library.query != query {
            library.setQuery(query, preservingVisibleResults: true)
        }
        let results = await search.search(query, among: library.favorites)
        guard !Task.isCancelled,
            isPresented,
            query == SearchQueryPolicy.normalized(searchField.stringValue)
        else { return }
        if shouldScrollToTop { scrollToTopAfterReload = true }
        lastCompletedSearchQuery = query
        library.applySearchResults(results)
        // An identical ranking does not notify the library, so consume the pending
        // scroll here when there was no snapshot to apply.
        if scrollToTopAfterReload {
            scrollToTopAfterReload = false
            scrollToTop()
        }
    }

    private func reloadLibrary() {
        let shouldScrollToTop = scrollToTopAfterReload
        scrollToTopAfterReload = false
        updateCountLabel()
        updateEmptyState()
        let favorites = library.filteredFavorites
        let nextSearchResults = Dictionary(
            uniqueKeysWithValues: favorites.compactMap { favorite in
                library.searchResult(for: favorite.id).map { (favorite.id, $0) }
            })
        if favorites == displayedOrder {
            guard nextSearchResults != displayedSearchResults else {
                if shouldScrollToTop { scrollToTop() }
                return
            }
            displayedSearchResults = nextSearchResults
            for case let item as GIFCollectionItem in collectionView.visibleItems() {
                item.updateSearchResult(displayedSearchResults[item.favoriteID ?? ""])
            }
            if shouldScrollToTop { scrollToTop() }
            return
        }

        let previousByID = displayedFavorites
        let previousIDs = displayedOrder.map(\.id)
        let nextIDs = favorites.map(\.id)
        let layoutChanged =
            previousIDs != nextIDs
            || zip(displayedOrder, favorites).contains { pair in
                pair.0.width != pair.1.width || pair.0.height != pair.1.height
            }
        displayedOrder = favorites
        displayedFavorites = Dictionary(uniqueKeysWithValues: favorites.map { ($0.id, $0) })
        displayedSearchResults = nextSearchResults
        for case let item as GIFCollectionItem in collectionView.visibleItems() {
            item.updateSearchResult(displayedSearchResults[item.favoriteID ?? ""])
        }

        var snapshot: NSDiffableDataSourceSnapshot<Int, String>
        if previousIDs == nextIDs, !dataSource.snapshot().sectionIdentifiers.isEmpty {
            snapshot = dataSource.snapshot()
            let changedIDs = favorites.compactMap { favorite in
                previousByID[favorite.id] == favorite ? nil : favorite.id
            }
            if !changedIDs.isEmpty { snapshot.reloadItems(changedIDs) }
        } else {
            snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(nextIDs, toSection: 0)
        }
        // Waterfall positions depend on the complete ordered result set. AppKit's
        // animated diff can otherwise move a reused item using its old height while
        // the layout is still describing the previous snapshot, briefly overlapping
        // the item below it. Install the snapshot atomically, then rebuild geometry.
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            if layoutChanged {
                self.layout.invalidateLayout()
            }
            self.collectionView.needsLayout = true
            self.view.needsLayout = true
            self.collectionView.layoutSubtreeIfNeeded()
            if shouldScrollToTop { self.scrollToTop() }
        }
    }

    private func scrollToTop() {
        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: 0))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func updateIndexProgress(_ progress: SearchIndexProgress) {
        indexProgress = progress
        updateCountLabel()
    }

    private func updateCountLabel() {
        let count = library.filteredFavorites.count
        countLabel.stringValue = "(\(count) GIFs)"
        let status: String?
        let isBusy: Bool
        switch indexProgress {
        case .refreshingFavorites:
            status = "Refreshing…"
            isBusy = true
        case .checking:
            status = "Checking index…"
            isBusy = true
        case .indexing(let completed, let total, let semantic):
            let mode = semantic ? "AI + OCR" : "OCR"
            status = "Indexing \(mode) \(completed)/\(total)"
            isBusy = true
        case .ready:
            status = sessionStatusText
            isBusy = session.state == .connecting
        case .unavailable:
            status = "Search unavailable"
            isBusy = false
        case nil:
            status = sessionStatusText
            isBusy = session.state == .connecting
        }
        activityLabel.stringValue = status.map { "— \($0)" } ?? ""
        activityLabel.isHidden = status == nil
        reloadButton.isHidden = isBusy
        reloadIcon.isHidden = isBusy
        activityIndicator.isHidden = !isBusy
        if isBusy {
            activityIndicator.startAnimation(nil)
        } else {
            activityIndicator.stopAnimation(nil)
        }
    }

    private var sessionStatusText: String? {
        switch session.state {
        case .connected: nil
        case .connecting: "Connecting…"
        case .expired: "Session expired"
        // Before the first silent refresh, this means "not checked yet."
        case .notConnected: nil
        case .offline: "Offline"
        }
    }

    private func updateSessionState(_ state: DiscordSessionCoordinator.State) {
        let shouldRefreshAfterLogin =
            state == .connected && library.favorites.isEmpty && presentationTask == nil
        switch state {
        case .connected:
            Self.lastRefreshAt = Date()
            reloadButton.toolTip = "Refresh favorites"
        case .connecting:
            reloadButton.toolTip = "Connecting"
        case .expired:
            reloadButton.toolTip = "Log in again"
        case .notConnected:
            Self.lastRefreshAt = nil
            reloadButton.toolTip = "Log in"
        case .offline:
            reloadButton.toolTip = "Retry"
        }
        updateCountLabel()
        updateEmptyState()
        if shouldRefreshAfterLogin {
            refreshFavorites(forceReload: true)
        }
    }

    private func updateEmptyState() {
        emptyLoginButton.isHidden =
            !library.favorites.isEmpty || session.state == .connected
    }

    @objc private func emptyLoginButtonPressed() {
        session.showLoginWindow()
    }

    @objc private func statusButtonPressed() {
        switch session.state {
        case .notConnected, .expired:
            session.showLoginWindow()
        default:
            refreshFavorites(forceReload: true)
        }
    }
}

extension GIFPickerViewController: NSSearchFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) {
        configureSearchEditor()
    }

    func controlTextDidChange(_ notification: Notification) {
        let query = searchField.stringValue
        searchTask?.cancel()
        scrollToTop()
        guard SearchQueryPolicy.isSearchable(query) else {
            lastCompletedSearchQuery = nil
            scrollToTopAfterReload = true
            library.setQuery("")
            if scrollToTopAfterReload {
                scrollToTopAfterReload = false
                scrollToTop()
            }
            return
        }
        library.setQuery(query, preservingVisibleResults: true)
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            await refreshCurrentSearch(shouldScrollToTop: true)
        }
    }
}

extension GIFPickerViewController: NSCollectionViewDelegate {
    func collectionView(
        _ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let indexPath = indexPaths.first,
            indexPath.item < library.filteredFavorites.count
        else { return }
        delegate?.gifPicker(self, didChoose: library.filteredFavorites[indexPath.item])
    }
}

extension GIFPickerViewController: WaterfallLayoutDelegate {
    func collectionView(_ collectionView: NSCollectionView, aspectRatioAt indexPath: IndexPath)
        -> CGFloat
    {
        guard indexPath.item < library.filteredFavorites.count else { return 1 }
        return library.filteredFavorites[indexPath.item].aspectRatio
    }
}
