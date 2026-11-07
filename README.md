# FeatureBerry SDK

FeatureBerrySDK provides a native Feature Board for your app. It can also collect
screen recordings, checklist status, and tester feedback for optional test sessions.

## Requirements

- iOS 18.0 or later
- Xcode with Swift Package Manager support

## Add the package

In Xcode, choose **File > Add Package Dependencies…** and enter:

```text
https://github.com/DCLabsInc/featureberry-ios-sdk
```

Select the `FeatureBerrySDK` library for your app target.

All integration examples below support iOS 18 or later. Shared SDK APIs are
main-actor isolated: call them from the main actor in either SwiftUI or UIKit.

> [!IMPORTANT]
> Enable the **Sign in with Apple** capability on your app target (and its App ID)
> if you enable voting, feature suggestions, or test sessions. Swift Package
> Manager libraries cannot add this entitlement for you.

> [!IMPORTANT]
> **Test-session recordings require camera roll access if you want to save them.**
> Add `NSPhotoLibraryAddUsageDescription` to your app's Info.plist (for example,
> "Save your feedback session recording to Photos"). The SDK asks for add-only
> Photos permission and saves the video to the camera roll after a successful
> submission.

Other Info.plist privacy keys depend on which features you enable:

| Key | When it is required |
| --- | --- |
| `NSPhotoLibraryAddUsageDescription` | Required if saving the captured video to Photos. |
| `NSMicrophoneUsageDescription` | Only if microphone recording is enabled (the SDK currently does not record the microphone). |
| `NSCameraUsageDescription` | Only if camera preview/capture is enabled (the SDK currently does not use the camera). |

## Show the Feature Board

The Feature Board is the primary use of this SDK. Add its button to any SwiftUI
view, including a list row or toolbar. Tapping it presents a native sheet with the
roadmap, voting, feature suggestions, and linked detail/profile pages:

```swift
import FeatureBerrySDK
import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("Feature Requests") {
                if let apiKey = FeatureBerryAppConfiguration.apiKey() {
                    FeatureBerryFeatureBoardButton(appShortName: "YOUR_APP_SHORT_NAME", apiKey: apiKey)
                    FeatureBerryTestingSettings {
                        FeatureBerry.userIsTesting = true
                    }
                }
            }
        }
    }
}
```

For UIKit apps, present it from a view controller (for example, in a table
selection handler):

```swift
FeatureBerryFeatureBoard.present(from: self, appShortName: "YOUR_APP_SHORT_NAME", apiKey: apiKey)
```

Here `self` is a `UIViewController`, and `apiKey` is your public SDK API key.
Provide the public SDK API key generated for your app. Never include a privileged
server secret in an iOS app. The board fetches roadmap features from the SDK API;
voting and suggestions prompt for Sign in with Apple when needed.
The backend's roadmap and suggestion endpoints must support `appShortName` and
the user-level SDK key, as used by the feature flags API. Older backend versions
that require an app ID and app-specific key are not compatible.

## Feature flags and testing mode

Configure feature flags once during startup with your SDK API key and the app's FeatureBerry short
name. Statuses are checked through the Horizon API and cached for seven minutes;
the app feature list is cached for twelve minutes. A flag check is synchronous,
so a feature whose status has not been loaded yet evaluates to `false` while the
SDK fetches it in the background.

**SwiftUI:** Configure from your app's initialization:

```swift
import FeatureBerrySDK
import SwiftUI

@main
struct MyApp: App {
    init() {
        guard let apiKey = FeatureBerryAppConfiguration.apiKey() else {
            fatalError("Missing SDKAPIKey in Info.plist")
        }
        FeatureBerry.configure(apiKey: apiKey, appShortName: "YOUR_APP_SHORT_NAME")
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

**UIKit:** Configure in your app delegate's launch method:

```swift
import FeatureBerrySDK
import UIKit

func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
) -> Bool {
    guard let apiKey = FeatureBerryAppConfiguration.apiKey() else {
        print("Missing SDKAPIKey in Info.plist")
        return false
    }
    FeatureBerry.configure(apiKey: apiKey, appShortName: "YOUR_APP_SHORT_NAME")
    return true
}
```

Add the UIKit method inside your `AppDelegate`. Both examples configure flags
before using flags or What's New; session configuration is separate.

`.Live` is true when a feature's Horizon status is `Shipped`; `.Testing` is true
when its status is `Testing`, regardless of the user's opt-in. `.LiveOrUserIsTesting`
is true for shipped features, or for testing features when the user has opted in.
The app controls `FeatureBerry.userIsTesting`; starting a configured test session
also enables it. Configuring the SDK, backgrounding, and finishing a session do
not change it. The value is not persisted across app launches. For example, the
provided settings button delegates the choice to the app:

```swift
FeatureBerryTestingSettings(tint: .pink) {
    FeatureBerry.userIsTesting = true
}
```

For UIKit, enable testing from a button action and refresh the view explicitly:

```swift
@IBAction private func enableTesting(_ sender: UIButton) {
    FeatureBerry.userIsTesting = true
    updateFeatureViews()
}

private func updateFeatureViews() {
    darkModeButton.isHidden = !FeatureBerry.Feature("dark-mode").Live
    checkoutButton.isHidden = !FeatureBerry.Feature("new-checkout").LiveOrUserIsTesting
}
```

The buttons are outlets in your view controller. Since an uncached status
initially evaluates to `false`, fetch statuses before updating the UI:

```swift
Task { @MainActor in
    do {
        try await FeatureBerry.refreshFeature(codeword: "dark-mode")
        try await FeatureBerry.refreshFeature(codeword: "new-checkout")
        updateFeatureViews()
    } catch {
        print("Unable to refresh features: \(error)")
    }
}
```

In SwiftUI, keep a local value for the UI and update it after loading the status
or changing testing mode:

```swift
struct CheckoutFeatureView: View {
    @State private var showCheckout = false

    var body: some View {
        VStack {
            if showCheckout {
                Text("New checkout is available")
            }
            FeatureBerryTestingSettings {
                FeatureBerry.userIsTesting = true
                updateFeature()
            }
        }
        .task {
            do {
                try await FeatureBerry.refreshFeature(codeword: "new-checkout")
                updateFeature()
            } catch {
                print("Unable to refresh feature: \(error)")
            }
        }
    }

    @MainActor private func updateFeature() {
        showCheckout = FeatureBerry.Feature("new-checkout").LiveOrUserIsTesting
    }
}
```

If testing mode can change elsewhere, use `FeatureBerry.onUserIsTestingChanged`
to refresh the appropriate UI. It is a single, app-wide callback on the main
actor; assigning the same value again does not call it. Clear or replace it
when no longer needed. Flag status changes themselves do not automatically
notify SwiftUI or UIKit; update the UI after an explicit refresh.

Call `FeatureBerry.refreshFeature(codeword:force:)` to explicitly refresh an
individual status, or `FeatureBerry.refreshFeatures(force:)` to fetch the app's
feature list.

### What's New

After configuring feature flags, call `FeatureBerry.CheckWhatsNew(releaseCodeword:)`
to check for shipped features and features in testing. It fetches feature statuses
only when the host app's `CFBundleShortVersionString` or `CFBundleVersion` differs
from the last successfully checked version. The returned `FeatureBerryWhatsNew` provides
`newFeatures`, `testFeatures`, and the release codeword's `releaseHorizon`; it
returns `nil` when the current app version was already checked.

**UIKit:** Check from a view controller after it is visible and ready to present:

```swift
override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)

    Task { @MainActor in
        do {
            guard let whatsNew = try await FeatureBerry.CheckWhatsNew(
                releaseCodeword: "YOUR_RELEASE_CODEWORD"
            ) else { return }

            showWhatsNew(newFeatures: whatsNew.newFeatures, testFeatures: whatsNew.testFeatures)
        } catch {
            print("Unable to check for new features: \(error)")
        }
    }
}

private func showWhatsNew(
    newFeatures: [FeatureBerryAppFeature],
    testFeatures: [FeatureBerryAppFeature]
) {
    let sections = [
        ("New features", newFeatures),
        ("Now testing", testFeatures)
    ].compactMap { section -> String? in
        let (title, features) = section
        guard !features.isEmpty else { return nil }
        return "\(title):\n" + features.map { "• \($0.title)" }.joined(separator: "\n")
    }
    guard !sections.isEmpty else { return }

    let alert = UIAlertController(
        title: "What's New",
        message: sections.joined(separator: "\n\n"),
        preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
}
```

**SwiftUI:** Check from a visible view and present the returned data in a sheet:

```swift
struct WhatsNewHost: View {
    @State private var whatsNew: FeatureBerryWhatsNew?
    @State private var showWhatsNew = false

    var body: some View {
        Text("Welcome")
            .task {
                do {
                    if let result = try await FeatureBerry.CheckWhatsNew(
                        releaseCodeword: "YOUR_RELEASE_CODEWORD"
                    ) {
                        whatsNew = result
                        showWhatsNew = !result.newFeatures.isEmpty || !result.testFeatures.isEmpty
                    }
                } catch {
                    print("Unable to check for new features: \(error)")
                }
            }
            .sheet(isPresented: $showWhatsNew) {
                if let result = whatsNew {
                    List {
                        Section("New features") {
                            ForEach(result.newFeatures) { feature in
                                Text(feature.title)
                            }
                        }
                        Section("Now testing") {
                            ForEach(result.testFeatures) { feature in
                                Text(feature.title)
                            }
                        }
                    }
                }
            }
    }
}
```

The presentation helper is app-specific; the SDK returns feature data but does
not present a What's New screen. A successful check is recorded immediately,
even if the app does not show the result, so check only when the UI is ready to
present it. `nil` also covers a missing bundle version or a check already in progress.

Using the Feature Board alone does **not** initialize a test session or start
screen recording. Do not call `FeatureBerrySessionManager.configure(...)` or
`startSession(presentingFrom:)` unless you also want to offer testing.

## Optional: configure and start a test session

Use the main actor to start a session. The SDK waits briefly (about 2.5 seconds
at most) for a foreground-active scene and a presenter attached to a window.
Start again after a session completes to run another test; shaking the device
does not start a session.

Configure the shared session manager before offering the session flow to users.
Use an API key appropriate for a client app (never embed a privileged server
secret), and provide the test type and codeword supplied by FeatureBerry,
along with the checklist items to show testers.
The test type is `.feature` or `.release`.

**UIKit:** Configure when your app is ready, then start from a visible view controller:

```swift
import FeatureBerrySDK
import UIKit

final class FeedbackViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        guard let apiKey = FeatureBerryAppConfiguration.apiKey() else {
            assertionFailure("Missing SDKAPIKey in Info.plist; see Config.template.xcconfig")
            return
        }

        FeatureBerrySessionManager.shared.configure(
            apiKey: apiKey,
            testType: .feature,
            codeword: "YOUR_CODEWORD",
            checklistItems: [
                "Sign in",
                "Add a dog walk",
                "Review walk history"
            ]
        )

    }

    @IBAction private func startTest(_ sender: UIButton) {
        FeatureBerrySessionManager.shared.startSession(presentingFrom: self)
    }
}
```

Connect the action to a button in your UI. **SwiftUI:** Configure the same
manager before offering the button, then add the SDK's presenter button to a
visible view:

```swift
import FeatureBerrySDK
import SwiftUI

struct FeedbackView: View {
    @State private var isConfigured = false

    var body: some View {
        FeatureBerrySessionButton(title: "Start a test")
            .disabled(!isConfigured)
            .task {
                guard let apiKey = FeatureBerryAppConfiguration.apiKey() else {
                    print("Missing SDKAPIKey in Info.plist")
                    return
                }
                FeatureBerrySessionManager.shared.configure(
                    apiKey: apiKey,
                    testType: .feature,
                    codeword: "YOUR_CODEWORD",
                    checklistItems: ["Sign in", "Add a dog walk", "Review walk history"]
                )
                isConfigured = true
            }
    }
}
```

Configure once in app setup when possible. The button uses a presenter attached
to its own view hierarchy, so place it in the scene that should show the session.
Do not offer it until configuration is complete.

### Masking private information in recordings

Register any views that display personal or otherwise sensitive information
before starting a session. The SDK covers each registered view with an opaque
black mask during recording; the mask is also visible on screen while recording.
Masks follow their views as the layout changes and are removed when recording
stops.

**UIKit:**

```swift
let sessionManager = FeatureBerrySessionManager.shared
sessionManager.registerPrivacyMask(for: emailTextField)
sessionManager.startSession(presentingFrom: self)
```

Call `unregisterPrivacyMask(for:)` when a view should no longer be masked.

**SwiftUI:** Apply the modifier to every sensitive region:

```swift
Text(userEmail)
    .featureBerryPrivacyMask()
```

The modifier registers a transparent UIKit view covering its rectangular layout
bounds and unregisters it when removed from the hierarchy. Apply it after
padding or other layout modifiers whose area must also be covered. It does not
mask content outside those bounds, separate overlays, or other sensitive views.
Sensitive views must be present and registered before recording starts so masks
are in place before the first captured frame. Verify coverage on device for your
layout, especially animations, transforms, and overlapping content.

If a test session is interrupted by a crash, the SDK can include the crash log
when the developer submits feedback after relaunching the app.

### Keeping the API key out of source control

1. Copy `Config.template.xcconfig` to `Config.xcconfig` (git-ignored) in your
   app's project root and set `SDK_API_KEY = your_actual_key_here`.
2. Assign `Config.xcconfig` to your target's build configurations
   (Project > Info > Configurations).
3. Add `SDKAPIKey` = `$(SDK_API_KEY)` to your app's Info.plist.
4. Add `Config.xcconfig` to `.gitignore`. Commit only the template, and have
   teammates copy it.

After a user starts a session, the SDK asks for confirmation before recording the
app's screen with ReplayKit and displays a floating button for the session menu.

## Checklist items

Checklist items are provided statically through the `checklistItems` argument of
`FeatureBerrySessionManager.shared.configure(...)`. They are **not** pulled
dynamically from the FeatureBerry API. Each item is shown to the tester as a tick
box, and the item text is submitted as the checked item identifier.

To tick an item automatically when the corresponding action completes in your
app, call `tickChecklistItem(at:)` on the shared session manager. The index is
zero-based and matches the item's position in the `checklistItems` array passed
to `configure`:

```swift
// checklistItems: ["Sign in", "Add a dog walk", "Review walk history"]
func didAddDogWalk() {
    FeatureBerrySessionManager.shared.tickChecklistItem(at: 1)
}
```

Call this while a session is active. Invalid indices and calls outside an active
session are ignored. The tester can still manually untick an automatically
checked item in the session menu.

## Recording limits

The portal accepts videos up to 100 MB. The SDK records at a fixed 1 Mbps bitrate (downscaled to at most 1280 px on the long side) and
automatically stops recording after about 10 minutes 40 seconds, showing an
alert and then the session menu. If a finished recording is still over 100 MB,
the video is not uploaded; the feedback is still submitted, the video is saved
to Photos, and the tester is told to upload it manually from their library.

## Submission behavior

The session menu shows **Pass** and **Fail** buttons. Validation is enforced before submission:

- Pass requires all checklist items to be ticked.
- Fail requires feedback text.
- Feedback-only submissions omit `outcome`.
- Testers can sign in with Apple to fill in their email address.

Apps using the Apple sign-in button must enable the **Sign in with Apple**
capability for their app target in Xcode. Swift Package Manager libraries cannot
add this app entitlement. Apple may only provide the tester's email on the first
authorization. If authorization fails with error 1000, verify that the capability
is enabled for the host app's target and its App ID.

On submit, the SDK will post results to:

- `POST https://portal.featureberry.com/api/sdk/v1/tests/results`

Payload (JSON) includes test type, codeword, tester email, optional outcome,
optional feedback, and checked checklist keys. The response contains a
`testRecordId`. The session recording, when available, is then uploaded as
`multipart/form-data` in a field named `video` to:

- `POST https://portal.featureberry.com/api/sdk/v1/tests/{testRecordId}/video`

If submission or the video upload fails, the SDK shows an alert with the full
error text and a **Copy to clipboard** button. Note that a failed video upload
happens after the result was recorded.

### Device telemetry

The SDK includes available device telemetry with each test result: device model,
iOS version, network type, battery level, host app version, device language,
physical memory, and screen diagonal in points. These optional values are sent
as top-level fields with the result; values that are unavailable are omitted.
No location data is collected.

Never log or expose your API key in client-side diagnostics.
