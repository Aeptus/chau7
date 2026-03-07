import SwiftUI
import AppKit

struct SplashView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.95)

            VStack(spacing: 20) {
                // App icon - uses shared AppIcon loader
                Image(nsImage: AppIcon.load())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .cornerRadius(24)
                    .shadow(color: .white.opacity(0.1), radius: 20)

                Text(L("Chau7", "Chau7"))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.8)
            }
        }
        .frame(width: 300, height: 280)
    }
}

final class SplashWindowController {
    private var window: NSWindow?

    func show() {
        let splashView = SplashView()
        let hostingView = NSHostingView(rootView: splashView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false // Prevent premature deallocation
        window.center()
        window.contentView = hostingView
        // Borderless windows can't become key — use orderFront to avoid
        // the AppKit warning about makeKeyWindow on an ineligible window.
        window.orderFront(nil)

        self.window = window
    }

    func dismiss(completion: @escaping () -> Void) {
        guard let window = window else {
            completion()
            return
        }

        // Capture window strongly to ensure it survives the animation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Order out instead of close to avoid deallocation issues
            window.orderOut(nil)
            self?.window = nil
            completion()
        }
    }

    /// Sets the window's appearance for theme consistency
    var windowAppearance: NSAppearance? {
        get { window?.appearance }
        set { window?.appearance = newValue }
    }
}
