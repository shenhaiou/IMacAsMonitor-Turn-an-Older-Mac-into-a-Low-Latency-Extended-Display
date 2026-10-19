import AppKit
import CoreImage
import MetalKit

final class MetalVideoView: MTKView, MTKViewDelegate {
    private let renderLock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private var ciContext: CIContext!
    private let renderColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        guard let device else { return }
        ciContext = CIContext(mtlDevice: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = true
        delegate = self
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(_ pixelBuffer: CVPixelBuffer) {
        renderLock.lock()
        latestFrame = pixelBuffer
        renderLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.draw()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        renderLock.lock()
        let frame = latestFrame
        renderLock.unlock()
        guard
            let frame,
            let drawable = currentDrawable,
            let commandQueue = device?.makeCommandQueue(),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let source = CIImage(cvPixelBuffer: frame)
        let sourceExtent = source.extent
        let destination = CGRect(origin: .zero, size: drawableSize)
        let scale = min(destination.width / sourceExtent.width, destination.height / sourceExtent.height)
        let scaledSize = CGSize(width: sourceExtent.width * scale, height: sourceExtent.height * scale)
        let origin = CGPoint(
            x: (destination.width - scaledSize.width) / 2,
            y: (destination.height - scaledSize.height) / 2
        )
        let transformed = source
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))

        ciContext.render(
            transformed,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: destination,
            colorSpace: renderColorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

final class VideoWindowController: NSWindowController, NSWindowDelegate {
    private let videoView: MetalVideoView
    private var cursorHidden = false
    private var previousPresentationOptions: NSApplication.PresentationOptions?

    init() {
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        videoView = MetalVideoView(frame: frame)
        let window = EscapeWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.contentView = videoView
        window.level = .normal
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        window.delegate = self
        window.escapePressed = { [weak self] in self?.closePresentation() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPresentation() {
        guard let window else { return }
        if previousPresentationOptions == nil {
            previousPresentationOptions = NSApp.presentationOptions
            NSApp.presentationOptions = NSApp.presentationOptions.union([
                .autoHideMenuBar,
                .autoHideDock,
            ])
        }
        if let screen = NSScreen.main {
            window.setFrame(screen.frame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
    }

    func present(_ pixelBuffer: CVPixelBuffer) {
        videoView.present(pixelBuffer)
    }

    func closePresentation() {
        window?.orderOut(nil)
        restoreCursor()
        restorePresentationOptions()
    }

    func windowWillClose(_ notification: Notification) {
        restoreCursor()
        restorePresentationOptions()
    }

    private func restoreCursor() {
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    private func restorePresentationOptions() {
        guard let previousPresentationOptions else { return }
        NSApp.presentationOptions = previousPresentationOptions
        self.previousPresentationOptions = nil
    }
}

private final class EscapeWindow: NSWindow {
    var escapePressed: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            escapePressed?()
        } else {
            super.keyDown(with: event)
        }
    }
}
