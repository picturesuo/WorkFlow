import AppKit
import KeyboardShortcuts
import QuartzCore
import SwiftUI

/// Where the floating capsule sits once the user has moved it. Pure geometry
/// in global screen coordinates, so it is testable without a display.
enum IndicatorPlacement {
    /// Keeps the whole card inside `bounds`. A bounds smaller than the card
    /// centers it.
    static func clampedCenter(_ center: CGPoint, cardSize: CGSize, in bounds: CGRect) -> CGPoint {
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low > high ? (low + high) / 2 : min(max(value, low), high)
        }
        return CGPoint(
            x: clamp(center.x, bounds.minX + cardSize.width / 2, bounds.maxX - cardSize.width / 2),
            y: clamp(center.y, bounds.minY + cardSize.height / 2, bounds.maxY - cardSize.height / 2)
        )
    }

    /// The saved center, kept on the screen that holds it and fully visible
    /// there. When that screen is gone (a display was unplugged or rearranged),
    /// the card moves onto `fallback`, the screen the dictation is on.
    /// - Parameter screens: each screen's full frame and its visible frame
    ///   (without the menu bar and Dock).
    static func restoredCenter(
        _ saved: CGPoint, cardSize: CGSize,
        screens: [(frame: CGRect, visible: CGRect)], fallback: CGRect
    ) -> CGPoint {
        let bounds = screens.first { $0.frame.contains(saved) }?.visible ?? fallback
        return clampedCenter(saved, cardSize: cardSize, in: bounds)
    }

    /// The window origin that puts the card's center at `center`; the card is
    /// centered in the larger panel.
    static func windowOrigin(forCardCenter center: CGPoint, windowSize: CGSize) -> CGPoint {
        CGPoint(x: center.x - windowSize.width / 2, y: center.y - windowSize.height / 2)
    }

    static func decode(_ stored: [Double]?) -> CGPoint? {
        guard let stored, stored.count == 2, stored.allSatisfy(\.isFinite) else { return nil }
        return CGPoint(x: stored[0], y: stored[1])
    }
}

/// Hosts the capsule and lets the user drag it by the visible pill. The
/// panel never becomes key and never activates WorkFlow, so dragging leaves
/// the target app focused and the recording running. A double-click returns
/// the capsule to following the caret.
final class IndicatorHostingView: NSHostingView<IndicatorWindow> {
    var onDoubleClick: (() -> Void)?

    /// The drawn capsule in this view's coordinates: centered, inset by the
    /// panel padding, with fully rounded ends.
    var capsulePath: NSBezierPath {
        let card = bounds.insetBy(dx: IndicatorWindow.panelPadding, dy: IndicatorWindow.panelPadding)
        let radius = card.height / 2
        return NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
    }

    // Only the visible pill takes the click, and always as a drag: no inner
    // SwiftUI view ever receives it, and the shadow margin hits nothing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return capsulePath.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        window?.performDrag(with: event)
    }
}

@MainActor
class IndicatorWindowManager: IndicatorViewDelegate {
    static let shared = IndicatorWindowManager(defaults: .standard)
    
    var window: NSWindow?
    var viewModel: IndicatorViewModel?
    /// Holds the user's chosen position; tests pass their own suite.
    private let defaults: UserDefaults
    private static let centerKey = "indicatorCardCenter"
    /// True while this manager moves the panel itself, so only the user's
    /// moves are remembered.
    private var isPlacing = false
    private var observers: [NSObjectProtocol] = []
    
    init(defaults: UserDefaults) {
        self.defaults = defaults
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.keepOnScreen()
            }
        })
    }

    /// The capsule as drawn now: it hugs its content, so its width follows
    /// the state while its height is fixed.
    private(set) var cardSize = CGSize(width: 120, height: IndicatorWindow.cardSize.height)

    /// The capsule reports its width when its content changes; a wider
    /// message near a screen edge is pulled back fully on screen.
    func cardWidthDidChange(_ width: CGFloat) {
        let width = min(width, IndicatorWindow.cardSize.width)
        guard width > 0, width != cardSize.width else { return }
        cardSize.width = width
        guard let window else { return }
        // Resize the panel around the same center so it stays the pill's size.
        let size = IndicatorWindow.windowSize(forCardWidth: width)
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        isPlacing = true
        window.setFrame(NSRect(origin: IndicatorPlacement.windowOrigin(forCardCenter: center, windowSize: size), size: size),
                        display: window.isVisible)
        isPlacing = false
        if window.isVisible { keepOnScreen() }
    }

    /// The capsule center the user chose by dragging, if any.
    var savedCardCenter: CGPoint? {
        IndicatorPlacement.decode(defaults.array(forKey: Self.centerKey) as? [Double])
    }

    /// Remembers where the user dropped the capsule. Moves made by the manager
    /// itself (appearing beside the caret, keeping it on screen) are ignored.
    func windowDidMove(byUser: Bool) {
        guard byUser, !isPlacing, let frame = window?.frame else { return }
        defaults.set([Double(frame.midX), Double(frame.midY)], forKey: Self.centerKey)
    }

    /// Forgets the dragged position: the next dictation appears beside the caret.
    func resetPosition() {
        defaults.removeObject(forKey: Self.centerKey)
    }

    private func place(at origin: NSPoint) {
        isPlacing = true
        window?.setFrameOrigin(origin)
        isPlacing = false
    }

    private static func screenFrames() -> [(frame: CGRect, visible: CGRect)] {
        NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
    }

    /// Pulls the capsule back fully onto a screen, after displays change or
    /// when it grows near an edge. The user's saved position is untouched, so
    /// it returns there once that screen is back.
    func keepOnScreen(screens: [(frame: CGRect, visible: CGRect)]? = nil) {
        guard let window else { return }
        let screens = screens ?? Self.screenFrames()
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let fallback = screens.first?.visible else { return }
        let clamped = IndicatorPlacement.restoredCenter(
            center, cardSize: cardSize, screens: screens, fallback: fallback
        )
        guard clamped != center else { return }
        place(at: IndicatorPlacement.windowOrigin(forCardCenter: clamped, windowSize: window.frame.size))
    }
    
    /// Creates the view model without presenting the window, so recording can
    /// start immediately while the caret position is being resolved.
    func prepare(pasteTarget: PasteTarget? = nil) -> IndicatorViewModel {
        NotificationCenter.default.post(name: .indicatorWindowWillShow, object: nil)
        KeyboardShortcuts.enable(.escape)
        
        let newViewModel = IndicatorViewModel(pasteTarget: pasteTarget)
        newViewModel.delegate = self
        viewModel = newViewModel
        
        // Build the panel and the SwiftUI hierarchy now, while the caret
        // position is being resolved in the background: materializing the
        // backing store, blur material and first layout during the appear
        // animation drops its first frames.
        ensureWindowContent(for: newViewModel)
        return newViewModel
    }
    
    func presentWindow(for presentedViewModel: IndicatorViewModel, nearPoint point: NSPoint?) {
        // The recording may already be cancelled/hidden by the time the caret
        // position is resolved.
        guard viewModel === presentedViewModel else { return }
        
        // Prefer the screen containing the point, then the screen of the window
        // with input focus (NSScreen.main is useless for a background app — it
        // degenerates to the primary screen). A point outside every screen
        // cannot be trusted for positioning and is ignored.
        let pointScreen = point.flatMap { FocusUtils.screenContaining(point: $0) }
        let targetScreen = pointScreen ?? FocusUtils.getFocusedWindowScreen() ?? NSScreen.screens.first
        let anchorPoint = pointScreen != nil ? point : nil
        
        // Never show the window without positioning it: an unpositioned panel
        // appears at its default origin (0,0) — the bottom-left corner.
        guard let screen = targetScreen else { return }
        
        // Normally prepared in prepare(); recreate only if hide() tore it down.
        if window?.contentView == nil {
            ensureWindowContent(for: presentedViewModel)
        }
        guard let window = window else { return }
        
        let windowFrame = window.frame
        let screenFrame = screen.frame
        
        // A position the user dragged the capsule to wins over the caret,
        // kept fully on a screen that still exists.
        if let saved = savedCardCenter {
            let center = IndicatorPlacement.restoredCenter(
                saved, cardSize: cardSize, screens: Self.screenFrames(), fallback: screen.visibleFrame
            )
            place(at: IndicatorPlacement.windowOrigin(forCardCenter: center, windowSize: windowFrame.size))
            orderFrontAndAppear(window, for: presentedViewModel)
            return
        }

        // The card is centered inside a larger panel (margins for the appear
        // offset and shadow), so position the visible card, not the window.
        let cardBottomInset = (windowFrame.height - IndicatorWindow.cardSize.height) / 2
        
        var x: CGFloat
        var y: CGFloat
        
        if let point = anchorPoint {
            // Card bottom 20 points above cursor
            x = point.x - windowFrame.width / 2
            y = point.y + 20 - cardBottomInset
        } else {
            // Default: card top 100 points from the top center of screen
            x = screenFrame.midX - windowFrame.width / 2
            y = screenFrame.maxY - 100 - windowFrame.height + cardBottomInset
        }
        
        // Adjust if out of screen bounds
        x = max(screenFrame.minX, min(x, screenFrame.maxX - windowFrame.width))
        y = max(screenFrame.minY, min(y, screenFrame.maxY - windowFrame.height))
        
        place(at: NSPoint(x: x, y: y))
        orderFrontAndAppear(window, for: presentedViewModel)
    }

    private func orderFrontAndAppear(_ window: NSWindow, for presentedViewModel: IndicatorViewModel) {
        // The first committed frame must be fully transparent, otherwise the
        // card flashes at full size before the appear animation starts.
        if let layer = window.contentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAllAnimations()
            layer.opacity = 0
            CATransaction.commit()
        }
        
        window.orderFront(nil)
        
        // Start the appear animation one runloop turn after the first
        // (fully transparent) frame is committed: springing a layer tree
        // that is still being built drops the opening frames.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.viewModel === presentedViewModel else { return }
            self.animateAppear()
        }
    }
    
    // MARK: - Layer animations
    
    // The appear/hide springs run on the hosting view's layer via Core
    // Animation, not via SwiftUI value animation: SwiftUI re-rasterizes the
    // card (material + gradients + shadow) on the CPU for every frame of an
    // animated scaleEffect and blocks the main thread in
    // CABackingStoreUpdate/wait_for_synchronize. A CASpringAnimation on the
    // layer transform scales the already-drawn texture in the render server.
    
    /// Matches SwiftUI .spring(response: 0.3, dampingFraction: 0.9): a calm
    /// settle with almost no overshoot.
    private static func springAnimation(keyPath: String, from: Any?, to: Any?) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / 0.3, 2)
        spring.damping = 0.9 * 2 * sqrt(spring.stiffness)
        spring.duration = spring.settlingDuration
        spring.fromValue = from
        spring.toValue = to
        return spring
    }
    
    /// Scaled down around the card center and pushed down towards the caret,
    /// so the appear animation rises bottom-up — the same start/end state the
    /// SwiftUI animation used. The layer transform works in Core Animation
    /// coordinates, which on macOS have +y pointing up regardless of the
    /// view's flippedness, so "down" is a negative y translation.
    static func hiddenTransform(for view: NSView) -> CATransform3D {
        let bounds = view.bounds
        let scale = IndicatorWindow.appearInitialScale
        var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
        return CATransform3DConcat(
            transform,
            CATransform3DMakeTranslation(0, -IndicatorWindow.appearOffset, 0)
        )
    }
    
    private func animateAppear() {
        guard let view = window?.contentView, let layer = view.layer else { return }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        layer.add(
            Self.springAnimation(keyPath: "transform", from: Self.hiddenTransform(for: view), to: CATransform3DIdentity),
            forKey: "transform"
        )
        layer.add(Self.springAnimation(keyPath: "opacity", from: 0, to: 1), forKey: "opacity")
        CATransaction.commit()
    }
    
    private func animateHide() async {
        guard let view = window?.contentView, let layer = view.layer, layer.opacity > 0 else { return }
        
        let hidden = Self.hiddenTransform(for: view)
        // Start from the interrupted mid-flight state if the appear spring is
        // still running.
        let currentTransform = layer.presentation()?.transform ?? layer.transform
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { continuation.resume() }
            layer.removeAllAnimations()
            layer.transform = hidden
            layer.opacity = 0
            layer.add(
                Self.springAnimation(keyPath: "transform", from: currentTransform, to: hidden),
                forKey: "transform"
            )
            layer.add(Self.springAnimation(keyPath: "opacity", from: currentOpacity, to: 0), forKey: "opacity")
            CATransaction.commit()
        }
    }
    
    /// Pre-creates the panel and orders it on screen once (fully transparent),
    /// so the first real appearance doesn't pay ~40 ms for window, backing
    /// store and blur material creation in the middle of the animation.
    func warmUp() {
        guard window == nil else { return }
        ensureWindowContent(for: IndicatorViewModel())
        // Ordering the panel in, even transparent, puts windows from the test
        // host on the user's screen; tests only need the panel built.
        guard !OpenSuperWhisperApp.isRunningTests, let window = window else { return }
        
        window.alphaValue = 0
        window.orderFront(nil)
        DispatchQueue.main.async {
            window.orderOut(nil)
            window.alphaValue = 1
        }
    }
    
    /// Builds the panel and its SwiftUI hierarchy without showing anything,
    /// so the expensive first layout is done before the appear animation.
    private func ensureWindowContent(for presentedViewModel: IndicatorViewModel) {
        if window == nil {
            // Using NSPanel for full-screen compatibility
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: IndicatorWindow.windowSize(forCardWidth: cardSize.width)),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            // The capsule takes clicks only to be dragged; it never becomes
            // key (borderless panel) and never activates the app
            // (nonactivating), so the target app keeps focus and shortcuts.
            panel.ignoresMouseEvents = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isMovable = true
            panel.hidesOnDeactivate = false
            
            self.window = panel
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: panel, queue: .main
            ) { [weak self] _ in
                // Only a drag moves the panel while a mouse button is down.
                let byUser = NSEvent.pressedMouseButtons & 1 != 0
                MainActor.assumeIsolated { self?.windowDidMove(byUser: byUser) }
            })
        }
        
        guard let window = window else { return }
        // Reuse the hosting view across sessions: rebuilding the SwiftUI
        // hierarchy (with its blur material) on every recording is wasted work.
        let rootView = IndicatorWindow(viewModel: presentedViewModel) { [weak self] width in
            self?.cardWidthDidChange(width)
        }
        if let hostingView = window.contentView as? IndicatorHostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = IndicatorHostingView(rootView: rootView)
            hostingView.onDoubleClick = { [weak self] in self?.resetPosition() }
            // Never let SwiftUI's ideal size drive the window frame: with the
            // default sizingOptions the hosting view shrinks the panel down to
            // the card size, and the window bounds then clip the animation —
            // the downward offset, the spring bounce overshoot and the shadow.
            hostingView.sizingOptions = []
            // The appear/hide springs animate this view's layer directly.
            hostingView.wantsLayer = true
            window.contentView = hostingView
        }
        window.setContentSize(IndicatorWindow.windowSize(forCardWidth: cardSize.width))
        window.contentView?.layoutSubtreeIfNeeded()
    }
    
    func stopRecording() {
        viewModel?.startDecoding()
    }
    
    func stopForce() {
        viewModel?.cancelRecording()
        viewModel?.cleanup()
        hide()
    }
    
    @discardableResult
    func requestCancel() -> Bool {
        guard let viewModel else { return false }
        guard viewModel.handleCancelRequest() else { return false }
        stopForce()
        return true
    }

    func hide() {
        // Capture the session being hidden: a new recording may start while
        // the hide animation runs, and tearing the window down then would
        // kill the fresh session's indicator.
        let hidingViewModel = viewModel
        
        Task {
            guard let viewModel = hidingViewModel, viewModel === self.viewModel else { return }
            
            await animateHide()
            viewModel.cleanup()
            
            guard self.viewModel === viewModel else { return }
            
            // Disabling the hotkey does synchronous WindowServer calls (up to
            // ~100 ms of SLSRemoveHotKey/SLSGetSymbolicHotKeyValue in traces),
            // so it must not run while the hide animation frames are drawn.
            // If a new session started during the animation, the guard above
            // already returned and the shortcut stays enabled for it.
            KeyboardShortcuts.disable(.escape)
            
            // The content view is kept alive and reused by the next session.
            self.window?.orderOut(nil)
            self.viewModel = nil
            
            NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
        }
    }
    
    func didFinishDecoding(_ completedViewModel: IndicatorViewModel) {
        Self.finishDecoding(from: completedViewModel, current: viewModel, hide: hide)
    }

    /// Completion can arrive after another indicator has taken over the window.
    /// Keep the routing independent of AppKit so delayed callbacks are testable.
    static func finishDecoding(from completed: AnyObject, current: AnyObject?, hide: () -> Void) {
        guard completed === current else { return }
        hide()
    }
}
