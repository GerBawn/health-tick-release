import AppKit
import SwiftUI

/// Imperative AppKit window presenter (ported from PasteMemo). Unlike the
/// SwiftUI `Window` scene + `.onChange(Bool)` bridge, calling `show` always
/// presents the window — there is no "flag already true so nothing happens"
/// state-residue trap, and it works regardless of how the app was launched.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]
    private init() {}

    func show<Content: View>(
        id: String,
        title: String = "",
        size: NSSize,
        floating: Bool = false,
        styleMask: NSWindow.StyleMask = [.titled, .closable],
        autoResizesToContent: Bool = false,
        content: @escaping () -> Content,
        onClose: (() -> Void)? = nil
    ) {
        if let existing = windows[id], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = CallbackWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(id)

        if autoResizesToContent {
            // Do NOT use NSHostingController.sizingOptions = [.preferredContentSize]:
            // that option makes AppKit call back into SwiftUI synchronously during
            // the constraint-update pass, and SwiftUI marks the window dirty again
            // while computing the size — on macOS 26 (Tahoe) AppKit throws an
            // NSException → SIGTRAP for that re-entrancy (PasteMemo issue #70).
            // One-way data flow instead: SwiftUI measures its own ideal height,
            // reports via onChange, and the window frame is set on the next
            // runloop tick, outside any AppKit layout pass.
            let fixedWidth = size.width
            let rootView = AnyView(
                content().modifier(WindowContentHeightSizer { [weak window] height in
                    guard let window, height > 1 else { return }
                    DispatchQueue.main.async {
                        let current = window.contentRect(forFrameRect: window.frame).height
                        guard abs(current - height) > 0.5 else { return }
                        // Keep the top edge (title bar) anchored; grow downward.
                        let oldFrame = window.frame
                        let frameSize = window.frameRect(
                            forContentRect: NSRect(x: 0, y: 0, width: fixedWidth, height: height)
                        ).size
                        let origin = NSPoint(x: oldFrame.origin.x, y: oldFrame.maxY - frameSize.height)
                        window.setFrame(NSRect(origin: origin, size: frameSize), display: true, animate: false)
                    }
                })
            )
            window.contentViewController = NSHostingController(rootView: rootView)
            // Give the window a real initial size before center(): SwiftUI's first
            // layout is async, and centering a near-zero window makes it drift
            // off-position once the content size arrives.
            window.setContentSize(size)
        } else {
            window.contentView = NSHostingView(rootView: content())
        }

        window.isReleasedWhenClosed = false
        window.center()
        window.level = floating ? .floating : .normal

        window.onCloseCallback = { [weak self] in
            self?.windows.removeValue(forKey: id)
            onClose?()
        }

        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(id: String) {
        windows[id]?.close()
        windows.removeValue(forKey: id)
    }
}

/// Measures the wrapped content's ideal height and reports it via callback
/// (one-way data flow). Companion to WindowManager's autoResizesToContent —
/// replaces NSHostingController.sizingOptions = [.preferredContentSize], which
/// crashes on macOS 26 via constraint-update re-entrancy (PasteMemo issue #70).
private struct WindowContentHeightSizer: ViewModifier {
    let onHeight: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.height, initial: true) { _, newHeight in
                        onHeight(newHeight)
                    }
            }
        )
    }
}

private class CallbackWindow: NSWindow, NSWindowDelegate {
    var onCloseCallback: (() -> Void)?

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        onCloseCallback?()
    }
}
