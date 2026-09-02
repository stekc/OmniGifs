import AVFoundation
import AppKit

@MainActor
final class GIFCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GIFCollectionItem")

    private let imageViewControl = NSImageView()
    private let progress = NSProgressIndicator()
    private let matchOverlay = NSView()
    private let matchLabel = NSTextField(labelWithString: "")
    private let selectionOverlay = NSView()
    private var loadTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var representedID: String?
    private var representedFavorite: GIFFavorite?
    private var representedSearchResult: GIFSearchResult?
    private var thumbnailImage: NSImage?
    private var player: AVPlayer?
    private var playerEndObserver: NSObjectProtocol?
    private var playerLayer: AVPlayerLayer?
    private var webPPlayer: AnimatedWebPPlayer?
    private var animatedImageLayer: CALayer?
    private var playerLayerObservation: NSKeyValueObservation?
    private var replacesWebPOnVideoReveal = false
    private var hasActivePlayback = false
    private var playbackEnabled = false

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        imageViewControl.translatesAutoresizingMaskIntoConstraints = false
        // Keep the card's comfortable minimum height without distorting very
        // wide or very tall media. Any spare space uses the card background.
        imageViewControl.imageScaling = .scaleProportionallyUpOrDown
        imageViewControl.imageAlignment = .alignCenter
        imageViewControl.animates = false
        root.addSubview(imageViewControl)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        root.addSubview(progress)

        matchOverlay.translatesAutoresizingMaskIntoConstraints = false
        matchOverlay.isHidden = true
        root.addSubview(matchOverlay)

        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        matchLabel.textColor = .white
        matchLabel.lineBreakMode = .byTruncatingTail
        let labelShadow = NSShadow()
        labelShadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        labelShadow.shadowBlurRadius = 2
        labelShadow.shadowOffset = NSSize(width: 0, height: -1)
        matchLabel.shadow = labelShadow
        matchOverlay.addSubview(matchLabel)

        selectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        selectionOverlay.wantsLayer = true
        selectionOverlay.layer?.borderWidth = 3
        selectionOverlay.layer?.borderColor = NSColor.controlAccentColor.cgColor
        selectionOverlay.layer?.cornerRadius = 12
        selectionOverlay.layer?.cornerCurve = .continuous
        selectionOverlay.isHidden = true
        root.addSubview(selectionOverlay)

        NSLayoutConstraint.activate([
            imageViewControl.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            imageViewControl.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            imageViewControl.topAnchor.constraint(equalTo: root.topAnchor),
            imageViewControl.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            progress.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            matchOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            matchOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            matchOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            matchOverlay.heightAnchor.constraint(equalToConstant: 30),
            matchLabel.leadingAnchor.constraint(equalTo: matchOverlay.leadingAnchor, constant: 8),
            matchLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: matchOverlay.trailingAnchor, constant: -8),
            matchLabel.bottomAnchor.constraint(equalTo: matchOverlay.bottomAnchor, constant: -5),
            selectionOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            selectionOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            selectionOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            selectionOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(webPVideoReady(_:)),
            name: .omniGifsWebPVideoReady,
            object: nil
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        playerLayer?.frame = view.bounds
        animatedImageLayer?.frame = view.bounds
    }

    override var isSelected: Bool {
        didSet { selectionOverlay.isHidden = !isSelected }
    }

    var favoriteID: String? { representedID }

    func configure(with favorite: GIFFavorite, searchResult: GIFSearchResult?) {
        if representedFavorite == favorite {
            updateSearchResult(searchResult)
            return
        }
        loadTask?.cancel()
        stopPlayback()
        representedID = favorite.id
        representedFavorite = favorite
        updateSearchResult(searchResult)
        var cachedThumbnail = GIFVisualCache.shared.thumbnail(for: favorite.id)
        if cachedThumbnail == nil,
            let diskImage = ThumbnailPipeline.cachedThumbnailOnDisk(for: favorite.id)
        {
            let thumbnail = NSImage(
                cgImage: diskImage,
                size: NSSize(width: favorite.width, height: favorite.height)
            )
            GIFVisualCache.shared.storeThumbnail(thumbnail, for: favorite.id)
            cachedThumbnail = thumbnail
        }
        let cachedAnimation = GIFVisualCache.shared.animation(for: favorite.id)
        thumbnailImage = cachedThumbnail
        imageViewControl.image = cachedAnimation ?? cachedThumbnail
        imageViewControl.animates = playbackEnabled && cachedAnimation != nil
        imageViewControl.isHidden = false
        progress.isHidden = cachedAnimation != nil || cachedThumbnail != nil
        hasActivePlayback = cachedAnimation != nil
        if cachedThumbnail == nil {
            loadTask = Task { [weak self] in
                guard let image = await ThumbnailPipeline.shared.thumbnail(for: favorite),
                    !Task.isCancelled
                else { return }
                await MainActor.run {
                    guard self?.representedID == favorite.id else { return }
                    let thumbnail = NSImage(
                        cgImage: image,
                        size: NSSize(width: favorite.width, height: favorite.height)
                    )
                    self?.thumbnailImage = thumbnail
                    GIFVisualCache.shared.storeThumbnail(thumbnail, for: favorite.id)
                    if self?.hasActivePlayback != true {
                        self?.imageViewControl.image = thumbnail
                    }
                    self?.progress.isHidden = true
                }
            }
        }
        if playbackEnabled { startPlayback() }
    }

    func setPlaybackEnabled(_ enabled: Bool) {
        guard playbackEnabled != enabled else {
            // Visibility callbacks are also a health check. AVPlayer can be at
            // rate zero after a transient stall even though our logical flag
            // never changed, so reassert playback for a visible item.
            if enabled { resumePlayback() }
            return
        }
        playbackEnabled = enabled
        if enabled {
            resumePlayback()
        } else {
            pausePlayback()
        }
    }

    /// AppKit suppresses view-backed animation invalidations during live
    /// scrolling. Merely assigning `animates = true` again is a no-op because
    /// the property never changed, so explicitly restart the active renderer
    /// once the clip view has settled.
    func recoverPlaybackAfterScroll() {
        guard playbackEnabled, representedFavorite != nil else { return }
        guard hasActivePlayback else {
            startPlayback()
            return
        }

        if let webPPlayer {
            webPPlayer.restart()
        } else if let player {
            player.play()
            playerLayer?.setNeedsDisplay()
        } else {
            imageViewControl.animates = false
            imageViewControl.animates = true
            imageViewControl.needsDisplay = true
        }
        view.layer?.setNeedsDisplay()
    }

    /// Closing the popover is a hard lifecycle boundary. Pausing an AVPlayer
    /// leaves its decoder, display link, and buffered frames resident; release
    /// the playback graph completely while keeping the cheap poster thumbnail.
    func tearDownPlayback() {
        playbackEnabled = false
        stopPlayback()
    }

    /// AppKit retains collection items in its reuse pool. Drop their decoded
    /// surfaces while hidden; the poster remains in the bounded visual cache.
    func releaseVisualResources() {
        loadTask?.cancel()
        loadTask = nil
        tearDownPlayback()
        thumbnailImage = nil
        imageViewControl.image = nil
        imageViewControl.layer?.contents = nil
        progress.isHidden = true
    }

    func restorePosterIfNeeded() {
        guard imageViewControl.image == nil,
            let favorite = representedFavorite
        else { return }
        if let thumbnail = GIFVisualCache.shared.thumbnail(for: favorite.id) {
            thumbnailImage = thumbnail
            imageViewControl.image = thumbnail
            progress.isHidden = true
            return
        }

        // The bounded cache may have evicted a long-hidden item. Reconfigure
        // only that visible cell so its disk-backed poster is fetched again.
        let searchResult = representedSearchResult
        representedFavorite = nil
        configure(with: favorite, searchResult: searchResult)
    }

    func updateSearchResult(_ result: GIFSearchResult?) {
        representedSearchResult = result
        let description = result?.matchDescription ?? ""
        matchLabel.stringValue = description
        matchOverlay.isHidden = description.isEmpty
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        stopPlayback()
        representedID = nil
        representedFavorite = nil
        representedSearchResult = nil
        updateSearchResult(nil)
        playbackEnabled = false
        thumbnailImage = nil
        imageViewControl.image = nil
        imageViewControl.isHidden = false
        progress.isHidden = false
    }

    private func startPlayback() {
        guard let favorite = representedFavorite else { return }
        guard !hasActivePlayback else {
            resumePlayback()
            return
        }
        let expectedID = favorite.id
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            guard let asset = await ThumbnailPipeline.shared.playbackAsset(for: favorite),
                !Task.isCancelled
            else { return }
            await MainActor.run {
                guard let self, self.representedID == expectedID else { return }
                switch asset {
                case .animatedImage(let data):
                    guard let image = NSImage(data: data) else { return }
                    GIFVisualCache.shared.storeAnimation(image, for: expectedID)
                    self.hasActivePlayback = true
                    self.imageViewControl.image = image
                    self.imageViewControl.animates = self.playbackEnabled
                    self.progress.isHidden = true
                case .animatedWebP(let data):
                    let layer = CALayer()
                    layer.frame = self.view.bounds
                    layer.contentsGravity = .resizeAspectFill
                    layer.contentsScale =
                        self.view.window?.backingScaleFactor
                        ?? NSScreen.main?.backingScaleFactor
                        ?? 2
                    layer.actions = [
                        "bounds": NSNull(),
                        "position": NSNull(),
                        "contents": NSNull(),
                    ]
                    let maximumPixelSize = Int(
                        ceil(
                            max(self.view.bounds.width, self.view.bounds.height)
                                * layer.contentsScale
                        ))
                    guard
                        let webPPlayer = AnimatedWebPPlayer(
                            cacheKey: expectedID,
                            data: data,
                            layer: layer,
                            maximumPixelSize: maximumPixelSize
                        )
                    else { return }
                    self.view.layer?.insertSublayer(layer, above: self.imageViewControl.layer)
                    self.animatedImageLayer = layer
                    self.webPPlayer = webPPlayer
                    self.hasActivePlayback = true
                    self.imageViewControl.animates = false
                    self.progress.isHidden = true
                    if self.playbackEnabled { webPPlayer.play() }
                case .video(let url):
                    self.installVideo(url: url, replacingWebP: false)
                case .transcodedWebP(let url):
                    self.installVideo(url: url, replacingWebP: false)
                }
            }
        }
    }

    private func pausePlayback() {
        player?.pause()
        webPPlayer?.pause()
        imageViewControl.animates = false
    }

    private func resumePlayback() {
        guard representedFavorite != nil else { return }
        guard hasActivePlayback else {
            startPlayback()
            return
        }
        if let webPPlayer {
            webPPlayer.play()
        } else if let playerLayer {
            player?.play()
            if playerLayer.opacity < 1, playerLayerObservation == nil {
                observeVideoReveal(for: playerLayer)
            }
        } else {
            imageViewControl.animates = true
        }
    }

    private func observeVideoReveal(for layer: AVPlayerLayer) {
        playerLayerObservation?.invalidate()
        playerLayerObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
            [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self] in
                guard let self,
                    let layer = self.playerLayer,
                    layer.isReadyForDisplay
                else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = 1
                CATransaction.commit()
                self.imageViewControl.isHidden = true
                if self.replacesWebPOnVideoReveal {
                    self.webPPlayer?.stop()
                    self.webPPlayer = nil
                    self.animatedImageLayer?.removeFromSuperlayer()
                    self.animatedImageLayer = nil
                    self.replacesWebPOnVideoReveal = false
                }
                self.playerLayerObservation?.invalidate()
                self.playerLayerObservation = nil
            }
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        playerLayerObservation?.invalidate()
        playerLayerObservation = nil
        if let playerEndObserver {
            NotificationCenter.default.removeObserver(playerEndObserver)
            self.playerEndObserver = nil
        }
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil)
        playerLayer?.player = nil
        webPPlayer?.stop()
        webPPlayer = nil
        animatedImageLayer?.removeFromSuperlayer()
        animatedImageLayer = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        replacesWebPOnVideoReveal = false
        hasActivePlayback = false
        imageViewControl.animates = false
        imageViewControl.isHidden = false
        if let thumbnailImage { imageViewControl.image = thumbnailImage }
    }

    @objc private func webPVideoReady(_ notification: Notification) {
        guard let id = notification.object as? String,
            id == representedID,
            webPPlayer != nil,
            player == nil,
            let url = notification.userInfo?["url"] as? URL
        else { return }
        installVideo(url: url, replacingWebP: true)
    }

    private func installVideo(url: URL, replacingWebP: Bool) {
        let item = AVPlayerItem(url: url)
        let scale =
            view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        item.preferredMaximumResolution = CGSize(
            width: max(view.bounds.width * scale, 2),
            height: max(view.bounds.height * scale, 2)
        )
        item.preferredForwardBufferDuration = 0.5
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .none
        let layer = AVPlayerLayer(player: player)
        layer.frame = view.bounds
        // Match Discord Web's computed `object-fit: cover`. Normally the
        // intrinsic-ratio card means there is no crop; cover also handles
        // stale or rounded media metadata without revealing gutters.
        layer.videoGravity = .resizeAspectFill
        // Keep the previous frame visible until the decoder has produced the
        // first replacement frame, eliminating the black handoff flash.
        layer.opacity = 0.001
        view.layer?.insertSublayer(layer, above: animatedImageLayer ?? imageViewControl.layer)
        self.player = player
        playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                if self.playbackEnabled { player.play() }
            }
        }
        playerLayer = layer
        replacesWebPOnVideoReveal = replacingWebP
        observeVideoReveal(for: layer)
        hasActivePlayback = true
        progress.isHidden = true
        if playbackEnabled { player.play() }
    }
}
