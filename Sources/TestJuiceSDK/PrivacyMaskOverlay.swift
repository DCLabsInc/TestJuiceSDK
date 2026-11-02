#if canImport(UIKit) && canImport(ReplayKit)
import UIKit

enum PrivacyMaskError: LocalizedError {
    case sceneUnavailable

    var errorDescription: String? {
        "Recording could not start because the privacy masks couldn't be displayed."
    }
}

@MainActor
final class PrivacyMaskOverlay {
    private final class Entry {
        weak var view: UIView?
        let mask: UIView

        init(view: UIView, mask: UIView) {
            self.view = view
            self.mask = mask
        }
    }

    private weak var scene: UIWindowScene?
    private var window: UIWindow?
    private var entries: [Entry] = []
    private var displayLink: CADisplayLink?

    func show(in scene: UIWindowScene, masking views: [UIView]) {
        guard !views.isEmpty else {
            stop()
            return
        }
        stop()

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        let root = UIViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root
        self.scene = scene
        self.window = window
        setViews(views)
        window.isHidden = false
        updateMasks()
        CATransaction.flush()

        let displayLink = CADisplayLink(target: self, selector: #selector(updateMasks))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func setViews(_ views: [UIView]) {
        guard !views.isEmpty else {
            stop()
            return
        }
        guard let root = window?.rootViewController?.view else { return }
        entries.forEach { $0.mask.removeFromSuperview() }
        entries = views.map { view in
            let mask = UIView()
            mask.backgroundColor = .black
            mask.isUserInteractionEnabled = false
            mask.isAccessibilityElement = false
            mask.accessibilityElementsHidden = true
            root.addSubview(mask)
            return Entry(view: view, mask: mask)
        }
        updateMasks()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        window?.isHidden = true
        window = nil
        scene = nil
        entries.removeAll()
    }

    static func visibleFrame(for view: UIView, in window: UIWindow) -> CGRect? {
        var frame = view.convert(view.bounds, to: window)
        var ancestor = view.superview
        while let current = ancestor {
            if current.clipsToBounds || current.layer.masksToBounds {
                frame = frame.intersection(current.convert(current.bounds, to: window))
            }
            ancestor = current.superview
        }
        frame = frame.intersection(window.bounds)
        return frame.isNull || frame.isEmpty ? nil : frame
    }

    @objc private func updateMasks() {
        guard let window, let scene else { return }
        entries.filter { $0.view == nil }.forEach { $0.mask.removeFromSuperview() }
        entries.removeAll { $0.view == nil }
        for entry in entries {
            guard let view = entry.view,
                  view.window?.windowScene === scene,
                  let frame = Self.visibleFrame(for: view, in: window)
            else {
                entry.mask.isHidden = true
                continue
            }

            var ancestor: UIView? = view
            var isVisible = true
            while let current = ancestor {
                if current.isHidden || current.alpha <= 0.01 {
                    isVisible = false
                    break
                }
                ancestor = current.superview
            }
            entry.mask.frame = frame
            entry.mask.isHidden = !isVisible
        }
    }
}

@MainActor
public extension TestJuiceSessionManager {
    /// Registers a view whose contents should be covered during session recording.
    /// The view is covered by a black mask on screen and in the recorded video.
    func registerPrivacyMask(for view: UIView) {
        addPrivacyMaskView(view)
    }

    /// Removes a previously registered recording mask.
    func unregisterPrivacyMask(for view: UIView) {
        removePrivacyMaskView(view)
    }
}
#endif
