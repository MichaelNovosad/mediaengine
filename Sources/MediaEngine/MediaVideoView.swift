import AVFoundation
import SwiftUI

#if canImport(UIKit)
import UIKit
/// The plain view that shows the picture of a ``PlaybackController``, for UIKit (iPhone, iPad, visionOS) apps. It
/// draws no controls: build them yourself or use `AVPlayerViewController` with ``AVPlayerController/player``.
@MainActor
public final class MediaVideoLayerHost: UIView {
    private var hosted: CALayer?

    public init(controller: any PlaybackController) {
        super.init(frame: .zero)
        backgroundColor = .black
        show(controller)
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("use init(controller:)") }

    /// Shows another controller's picture.
    public func show(_ controller: any PlaybackController) {
        let layer = MediaVideoLayerHost.layer(for: controller)
        guard hosted !== layer else { return }
        hosted?.removeFromSuperlayer()
        self.layer.addSublayer(layer)
        hosted = layer
        setNeedsLayout()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        hosted?.frame = bounds
    }
}

/// SwiftUI view with the picture of a ``PlaybackController`` (software or AVPlayer), scaled to fit, on black.
///
/// ```swift
/// MediaVideoView(controller: controller).ignoresSafeArea()
/// ```
public struct MediaVideoView: UIViewRepresentable {
    public let controller: any PlaybackController
    public init(controller: any PlaybackController) { self.controller = controller }
    public func makeUIView(context: Context) -> MediaVideoLayerHost { MediaVideoLayerHost(controller: controller) }
    public func updateUIView(_ view: MediaVideoLayerHost, context: Context) { view.show(controller) }
}
#elseif canImport(AppKit)
import AppKit
/// The plain view that shows the picture of a ``PlaybackController``, for AppKit (Mac) apps. It draws no controls.
@MainActor
public final class MediaVideoLayerHost: NSView {
    private var hosted: CALayer?

    public init(controller: any PlaybackController) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        show(controller)
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("use init(controller:)") }

    /// Shows another controller's picture.
    public func show(_ controller: any PlaybackController) {
        let picture = MediaVideoLayerHost.layer(for: controller)
        guard hosted !== picture else { return }
        hosted?.removeFromSuperlayer()
        layer?.addSublayer(picture)
        hosted = picture
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        hosted?.frame = bounds
    }
}

/// SwiftUI view with the picture of a ``PlaybackController`` (software or AVPlayer), scaled to fit, on black.
public struct MediaVideoView: NSViewRepresentable {
    public let controller: any PlaybackController
    public init(controller: any PlaybackController) { self.controller = controller }
    public func makeNSView(context: Context) -> MediaVideoLayerHost { MediaVideoLayerHost(controller: controller) }
    public func updateNSView(_ view: MediaVideoLayerHost, context: Context) { view.show(controller) }
}
#endif

extension MediaVideoLayerHost {
    /// The layer that shows a controller's picture: the display layer of the software path, a player layer for AVPlayer.
    @MainActor
    static func layer(for controller: any PlaybackController) -> CALayer {
        switch controller {
        case let software as SoftwareController: return software.displayLayer
        case let player as AVPlayerController: return player.videoLayer
        default: return CALayer()
        }
    }
}
