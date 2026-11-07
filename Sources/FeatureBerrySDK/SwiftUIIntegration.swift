#if canImport(SwiftUI) && canImport(UIKit) && canImport(ReplayKit)
import SwiftUI
import UIKit
import os

@MainActor
private final class SessionPresenterReference {
    weak var controller: UIViewController?
}

@MainActor
private struct SessionPresenterAnchor: UIViewControllerRepresentable {
    let reference: SessionPresenterReference

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        reference.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

/// A SwiftUI button that starts a previously configured test session.
@MainActor
public struct FeatureBerrySessionButton: View {
    private let title: String
    @State private var presenter = SessionPresenterReference()

    public init(title: String = "Start test session") {
        self.title = title
    }

    public var body: some View {
        Button(title) {
            guard let controller = presenter.controller else {
                Logger(subsystem: "com.featureberry.sdk", category: "Session")
                    .error("Cannot start a session before the SwiftUI presenter is ready.")
                return
            }
            FeatureBerrySessionManager.shared.startSession(presentingFrom: controller)
        }
        .background(SessionPresenterAnchor(reference: presenter).frame(width: 0, height: 0))
    }
}

@MainActor
final class SwiftUIPrivacyMaskView: UIView {
    private let manager: FeatureBerrySessionManager

    init(manager: FeatureBerrySessionManager) {
        self.manager = manager
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        manager.registerPrivacyMask(for: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func unregister() {
        manager.unregisterPrivacyMask(for: self)
    }
}

@MainActor
private struct PrivacyMaskAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> SwiftUIPrivacyMaskView {
        SwiftUIPrivacyMaskView(manager: .shared)
    }

    func updateUIView(_ view: SwiftUIPrivacyMaskView, context: Context) {}

    static func dismantleUIView(_ view: SwiftUIPrivacyMaskView, coordinator: ()) {
        view.unregister()
    }
}

public extension View {
    /// Masks this view's rectangular bounds during FeatureBerry session recordings.
    @MainActor
    func featureBerryPrivacyMask() -> some View {
        background(PrivacyMaskAnchor().allowsHitTesting(false))
    }
}
#endif
