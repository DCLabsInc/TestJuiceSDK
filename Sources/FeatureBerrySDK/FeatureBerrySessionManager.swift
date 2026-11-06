#if canImport(UIKit) && canImport(ReplayKit)
import Combine
import Photos
import ReplayKit
import SwiftUI
import UIKit
import UserNotifications

enum RecordingStartFailureMessage {
    static func message(for error: Error) -> String {
        let recorderError = error as NSError
        if recorderError.domain == RPRecordingErrorDomain,
           recorderError.code == RPRecordingErrorCode.userDeclined.rawValue {
            return "You chose not to record the session. You can still submit feedback but may miss out on any associated rewards"
        }

        return "\(error.localizedDescription)\n\n(\(String(reflecting: error)))\n\nYou can still submit your feedback without a video."
    }
}

/// Entry point of the SDK.
@MainActor
public final class FeatureBerrySessionManager: ObservableObject {
    public static let shared = FeatureBerrySessionManager()

    /// Shows an orange dot under each touch in the recorded video.
    public var showsTouchIndicator = true
    /// How long a quick tap is held back so the dot reaches the video before the app reacts, in seconds. 0 disables.
    public var tapDelay: TimeInterval = 0.2

    private struct Configuration {
        let client: FeatureBerryClient
        let testType: FeatureBerryTestType
        let codeword: String
        let checklistItems: [String]
    }

    private var configuration: Configuration?
    private var currentTest: FeatureBerryTest?
    @Published private var checkedItems = Set<String>()
    private let recorder = ScreenRecorder()
    private let privacyMaskOverlay = PrivacyMaskOverlay()
    private var privacyMaskViews: [WeakPrivacyMaskView] = []
    private var overlay: FloatingOverlay?
    private var menuController: UIViewController?
    private var pendingVideoURL: URL?
    private var awaitingFeedback = false
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var isActive = false
    private var limitTask: Task<Void, Never>?
    private var crashRecovery: CrashRecovery?
    private var launchObserver: NSObjectProtocol?
    private var liveCheckObserver: NSObjectProtocol?
    private var isShowingLivePrompt = false
    public init() {}

    // MARK: Configuration

    public func configure(
        apiKey: String,
        testType: FeatureBerryTestType,
        codeword: String,
        checklistItems: [String]
    ) {
        configuration = Configuration(
            client: FeatureBerryClient(configuration: FeatureBerryConfiguration(apiKey: apiKey)),
            testType: testType,
            codeword: codeword,
            checklistItems: checklistItems)
        recoverFromCrashIfNeeded()
        startLiveVersionChecks()
    }

    // MARK: Live version check

    private func startLiveVersionChecks() {
        checkLiveVersion()
        guard liveCheckObserver == nil else { return }
        liveCheckObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkLiveVersion() }
        }
    }

    private func checkLiveVersion() {
        guard let configuration, !isShowingLivePrompt else { return }
        Task { @MainActor in
            guard let url = await configuration.client.fetchLiveAppURL(codeword: configuration.codeword) else { return }
            self.presentLiveVersionAlert(url: url)
        }
    }

    private func presentLiveVersionAlert(url: URL) {
        guard !isShowingLivePrompt, !isActive else { return }
        Task { @MainActor in
            guard !self.isShowingLivePrompt, !self.isActive,
                  let scene = await Self.readyScene(preferred: nil),
                  let root = scene.windows.first(where: { !($0 is PassthroughWindow) && $0.isKeyWindow })?.rootViewController
                    ?? scene.windows.first(where: { !($0 is PassthroughWindow) })?.rootViewController
            else { return }
            let presenter = Self.topMost(from: root)
            if presenter is UIAlertController { return }
            self.isShowingLivePrompt = true
            let alert = UIAlertController(
                title: "Version now live",
                message: "This test has now gone live. Sync back to the live version now or wait for further upcoming test version",
                preferredStyle: .alert)
            Self.stylePopup(alert)
            alert.addAction(UIAlertAction(title: "Wait", style: .cancel) { [weak self] _ in
                self?.isShowingLivePrompt = false
            })
            alert.addAction(UIAlertAction(title: "Live version", style: .default) { [weak self] _ in
                self?.isShowingLivePrompt = false
                UIApplication.shared.open(url)
            })
            presenter.present(alert, animated: true)
        }
    }

    func addPrivacyMaskView(_ view: UIView) {
        privacyMaskViews.removeAll { $0.view == nil }
        guard !privacyMaskViews.contains(where: { $0.view === view }) else { return }
        privacyMaskViews.append(WeakPrivacyMaskView(view))
        privacyMaskOverlay.setViews(privacyMaskViews.compactMap(\.view))
    }

    func removePrivacyMaskView(_ view: UIView) {
        privacyMaskViews.removeAll { $0.view == nil || $0.view === view }
        privacyMaskOverlay.setViews(privacyMaskViews.compactMap(\.view))
    }

    // MARK: Crash recovery

    private func recoverFromCrashIfNeeded() {
        guard crashRecovery == nil, !isActive, let recovery = CrashReporter.recoverCrashedSession() else { return }
        if let video = recovery.videoURL, !recovery.savedToPhotos {
            Task { @MainActor in
                if await self.saveToCameraRoll(video) {
                    CrashReporter.markSavedToPhotos()
                    self.crashRecovery?.savedToPhotos = true
                }
            }
        }
        crashRecovery = recovery
        presentCrashFeedbackWhenReady()
    }

    private func presentCrashFeedbackWhenReady() {
        if let scene = Self.activeScene() {
            // Let the host app finish its own launch UI first.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                await self.beginCrashFeedback(in: Self.activeScene() ?? scene)
            }
            return
        }
        launchObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let observer = self.launchObserver else { return }
                NotificationCenter.default.removeObserver(observer)
                self.launchObserver = nil
                self.presentCrashFeedbackWhenReady()
            }
        }
    }

    private static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
    }

    private static let readinessRetryLimit = 10
    private static let readinessRetryDelay: Duration = .milliseconds(250)

    /// Waits briefly for a foreground-active scene and a presenter attached to a window.
    /// Returns nil if they are still not ready after a bounded number of retries.
    private static func readyPresenter(for viewController: UIViewController) async -> UIViewController? {
        for attempt in 0...readinessRetryLimit {
            if let window = viewController.viewIfLoaded?.window,
               window.windowScene?.activationState == .foregroundActive {
                return viewController
            }
            if attempt < readinessRetryLimit { try? await Task.sleep(for: readinessRetryDelay) }
        }
        return nil
    }

    /// Waits briefly for a foreground-active scene; returns nil after a bounded number of retries.
    private static func readyScene(preferred: UIWindowScene?) async -> UIWindowScene? {
        for attempt in 0...readinessRetryLimit {
            if let preferred, preferred.activationState == .foregroundActive { return preferred }
            if let scene = activeScene() { return scene }
            if attempt < readinessRetryLimit { try? await Task.sleep(for: readinessRetryDelay) }
        }
        return nil
    }

    private func beginCrashFeedback(in scene: UIWindowScene) async {
        guard let configuration, let recovery = crashRecovery, !isActive else { return }
        let definition = try? await configuration.client.fetchTestDefinition(
            testType: configuration.testType, codeword: configuration.codeword)
        guard !isActive else { return }
        checkedItems.removeAll()
        currentTest = FeatureBerryTest(
            title: "Test session",
            instructions: "The app crashed. Your recording and crash log will be sent when you submit.",
            checklist: configuration.checklistItems.map {
                FeatureBerryTest.ChecklistItem(key: $0, label: $0, kind: "task")
            },
            showPassFailButtons: definition?.showPassFailButtons ?? false,
            reward: definition?.reward)
        isActive = true
        awaitingFeedback = true
        pendingVideoURL = recovery.videoURL
        let overlay = FloatingOverlay { [weak self] in self?.presentMenu() }
        overlay.show(in: scene)
        self.overlay = overlay
        presentMenu(initialFeedback: "Crashed - logs attached")
    }

    /// Automatically ticks a configured checklist item during an active session.
    /// The index is zero-based and refers to the order of `checklistItems` passed to `configure`.
    public func tickChecklistItem(at index: Int) {
        guard isActive,
              let configuration,
              configuration.checklistItems.indices.contains(index)
        else { return }
        checkedItems.insert(configuration.checklistItems[index])
    }

    var checkedChecklistItemKeys: Set<String> { checkedItems }

    func toggleChecklistItem(key: String) {
        if checkedItems.contains(key) {
            checkedItems.remove(key)
        } else {
            checkedItems.insert(key)
        }
    }

    // MARK: Session start

    @MainActor
    public func startSession(presentingFrom viewController: UIViewController) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        guard let configuration, !isActive else { return }
        FeatureBerry.userIsTesting = true
        checkedItems.removeAll()
        Task { @MainActor in
            // If the definition can't be fetched, fall back to the feedback-only flow.
            let definition = try? await configuration.client.fetchTestDefinition(
                testType: configuration.testType, codeword: configuration.codeword)
            guard !self.isActive else { return }
            self.currentTest = FeatureBerryTest(
                title: "Test session",
                instructions: "Tick each item as you complete it, then submit your result.",
                checklist: configuration.checklistItems.map {
                    FeatureBerryTest.ChecklistItem(key: $0, label: $0, kind: "task")
                },
                showPassFailButtons: definition?.showPassFailButtons ?? false,
                reward: definition?.reward)
            // SwiftUI hosts may call this from onAppear before the scene/presenter is ready.
            guard let presenter = await Self.readyPresenter(for: viewController), !self.isActive else {
                self.currentTest = nil
                return
            }
            self.presentConfirmation(from: presenter)
        }
    }

    private func presentConfirmation(from viewController: UIViewController) {
        let reward = currentTest?.reward
        let host = UIHostingController(rootView: SessionConfirmationView(reward: reward) { [weak self, weak viewController] record in
            guard let self, let viewController else { return }
            Task { @MainActor in await self.beginRecording(from: viewController, record: record) }
        })
        host.modalPresentationStyle = .overFullScreen
        host.view.backgroundColor = .clear
        viewController.present(host, animated: true)
    }

    private func beginRecording(from viewController: UIViewController, record: Bool) async {
        var recording = record
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        if record {
            let hint = RecordingHintOverlay()
            if let scene = viewController.viewIfLoaded?.window?.windowScene ?? Self.activeScene() {
                hint.show(in: scene, hasReward: currentTest?.reward != nil)
            }
            defer { hint.hide() }
            do {
                let maskViews = privacyMaskViews.compactMap(\.view)
                if !maskViews.isEmpty {
                    guard let scene = viewController.viewIfLoaded?.window?.windowScene ?? Self.activeScene() else {
                        throw PrivacyMaskError.sceneUnavailable
                    }
                    privacyMaskOverlay.show(in: scene, masking: maskViews)
                }
                try await recorder.start()
            } catch {
                privacyMaskOverlay.stop()
                // The session continues without video so testers can still submit feedback.
                recording = false
                let alert = UIAlertController(
                    title: "Couldn't start recording",
                    message: RecordingStartFailureMessage.message(for: error),
                    preferredStyle: .alert)
                Self.stylePopup(alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                Self.topMost(from: viewController).present(alert, animated: true)
            }
        }
        isActive = true
        awaitingFeedback = false
        pendingVideoURL = nil
        CrashReporter.beginSession(videoFileName: recording ? recorder.currentVideoFileName : nil)
        recorder.onStreamError = { [weak self] _ in
            Task { @MainActor in await self?.handleInterruption() }
        }
        if let scene = await Self.readyScene(preferred: viewController.viewIfLoaded?.window?.windowScene) {
            let overlay = FloatingOverlay { [weak self] in self?.presentMenu() }
            overlay.show(in: scene)
            self.overlay = overlay
            if recording, showsTouchIndicator, let host = overlay.presenter?.view {
                TouchIndicator.shared.start(in: host, ignoring: overlay.overlayWindow, minimumVisibleTime: tapDelay)
            }
        }
        observeLifecycle()
        if recording { scheduleRecordingLimit() }
    }

    private func scheduleRecordingLimit() {
        limitTask?.cancel()
        limitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RecordingLimits.maxDuration))
            guard !Task.isCancelled else { return }
            await self?.handleRecordingLimitReached()
        }
    }

    private func handleRecordingLimitReached() async {
        guard isActive, !awaitingFeedback else { return }
        awaitingFeedback = true
        TouchIndicator.shared.stop()
        pendingVideoURL = await stopRecording()

        let minutes = Int((RecordingLimits.maxDuration / 60).rounded(.down))
        let alert = UIAlertController(
            title: "Recording stopped",
            message: "Recording stopped automatically after about \(minutes) minutes to keep the video under 100 MB. Please submit your feedback now.",
            preferredStyle: .alert)
        Self.stylePopup(alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            Task { @MainActor in self?.presentMenu() }
        })
        if let presenter = overlay?.presenter {
            Self.topMost(from: presenter).present(alert, animated: true)
        }
    }

    private static func topMost(from controller: UIViewController) -> UIViewController {
        var top = controller
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    private func presentOversizeAlert(in scene: UIWindowScene?, savedToPhotos: Bool, bytes: Int64) {
        guard let window = scene?.windows.first(where: { !($0 is PassthroughWindow) && $0.isKeyWindow })
            ?? scene?.windows.first(where: { !($0 is PassthroughWindow) }),
              let root = window.rootViewController
        else { return }
        let megabytes = Int((Double(bytes) / 1_000_000).rounded())
        let location = savedToPhotos
            ? "It has been saved to your Photos library. Please upload it manually from there."
            : "It could not be saved to your Photos library."
        let alert = UIAlertController(
            title: "Video too large to upload",
            message: "Your recording is \(megabytes) MB, which is over the 100 MB upload limit, so it was not uploaded. Your feedback was submitted. \(location)",
            preferredStyle: .alert)
        Self.stylePopup(alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        Self.topMost(from: root).present(alert, animated: true)
    }

    private static func stylePopup(_ alert: UIAlertController) {
        alert.overrideUserInterfaceStyle = .dark
        alert.view.tintColor = .systemOrange
    }

    // MARK: Menu

    private func presentMenu(initialFeedback: String = "") {
        // A swipe-dismissed sheet leaves a stale reference behind.
        if let menu = menuController, menu.presentingViewController == nil {
            menuController = nil
            overlay?.restoreKey()
        }
        guard menuController == nil, let presenter = overlay?.presenter else { return }
        guard let test = currentTest else { return }
        let view = ChecklistMenuView(test: test, sessionManager: self, initialFeedback: initialFeedback) { [weak self] outcome, email, feedback, checkedItems in
            guard let self, let configuration = self.configuration else { return }
            let result = FeatureBerryTestResult(
                testType: configuration.testType,
                codeword: configuration.codeword,
                testerEmail: email,
                outcome: outcome,
                feedback: feedback,
                checkedItems: checkedItems)
            try await self.submit(result)
        }
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        menuController = host
        overlay?.makeKey()
        presenter.present(host, animated: true)
    }

    private func dismissMenu() async {
        guard let menu = menuController else { return }
        menuController = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            menu.dismiss(animated: true) { continuation.resume() }
        }
        overlay?.restoreKey()
    }

    // MARK: Lifecycle

    private func observeLifecycle() {
        let center = NotificationCenter.default
        backgroundObserver = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handleInterruption() }
        }
        foregroundObserver = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleForeground() }
        }
    }

    private func stopObserving() {
        [backgroundObserver, foregroundObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
        backgroundObserver = nil
        foregroundObserver = nil
    }

    private func handleInterruption() async {
        guard isActive else { return }
        if !awaitingFeedback {
            awaitingFeedback = true
            TouchIndicator.shared.stop()
            let taskID = UIApplication.shared.beginBackgroundTask(withName: "FeatureBerry.finalize")
            pendingVideoURL = await stopRecording()
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
        }

        let content = UNMutableNotificationContent()
        content.title = "Feedback needed"
        content.body = "Tap here to return to the app and submit your test feedback."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "com.featureberry.sdk.paused", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func handleForeground() {
        guard isActive, awaitingFeedback else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["com.featureberry.sdk.paused"])
        presentMenu()
    }

    // MARK: Completion

    private func submit(_ result: FeatureBerryTestResult) async throws {
        guard isActive, let configuration else { return }
        if !awaitingFeedback && pendingVideoURL == nil {
            pendingVideoURL = await stopRecording()
        }
        let videoSize = pendingVideoURL.map(RecordingLimits.fileSize(at:)) ?? 0
        let tooLarge = RecordingLimits.exceedsUploadLimit(fileSize: videoSize)
        let recovery = crashRecovery
        let telemetry = await FeatureBerryDeviceTelemetry.collect()
        try await configuration.client.submitTestResult(
            result,
            telemetry: telemetry,
            videoURL: tooLarge ? nil : pendingVideoURL,
            crashLogURL: recovery?.crashLogURL)
        var savedToPhotos = recovery?.savedToPhotos ?? false
        if recovery == nil, let videoURL = pendingVideoURL { savedToPhotos = await saveToCameraRoll(videoURL) }
        let scene = overlay?.presenter?.view.window?.windowScene
        await dismissMenu()
        await finishSession()
        if tooLarge { presentOversizeAlert(in: scene, savedToPhotos: savedToPhotos, bytes: videoSize) }
    }

    @discardableResult
    private func saveToCameraRoll(_ url: URL) async -> Bool {
        await Self.saveVideoToPhotoLibrary(url)
    }

    // Nonisolated so Photos' callbacks, which run on its own queues, are not main-actor isolated.
    private nonisolated static func saveVideoToPhotoLibrary(_ url: URL) async -> Bool {
        // Requesting access without this Info.plist key terminates the app.
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else { return false }
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { return false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges({
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { success, _ in
                continuation.resume(returning: success)
            })
        }
    }

    private func finishSession() async {
        guard isActive else { return }
        isActive = false
        limitTask?.cancel()
        limitTask = nil
        stopObserving()
        TouchIndicator.shared.stop()
        overlay?.hide()
        overlay = nil
        var videoURL = pendingVideoURL
        if videoURL == nil && !awaitingFeedback {
            videoURL = await stopRecording()
        }
        privacyMaskOverlay.stop()
        pendingVideoURL = nil
        awaitingFeedback = false
        checkedItems.removeAll()
        if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
        crashRecovery = nil
        CrashReporter.endSession()
        currentTest = nil
        FeatureBerry.userIsTesting = false
    }

    private func stopRecording() async -> URL? {
        let videoURL = await recorder.stop()
        privacyMaskOverlay.stop()
        return videoURL
    }
}

@MainActor
private final class WeakPrivacyMaskView {
    weak var view: UIView?

    init(_ view: UIView) {
        self.view = view
    }
}
#endif
