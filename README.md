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
                    FeatureBerryTestingSettings()
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

Provide the public SDK API key generated for your app. Never include a privileged
server secret in an iOS app. The board fetches roadmap features from the SDK API;
voting and suggestions prompt for Sign in with Apple when needed.
The backend's roadmap and suggestion endpoints must support `appShortName` and
the user-level SDK key, as used by the feature flags API. Older backend versions
that require an app ID and app-specific key are not compatible.

## Feature flags and testing mode

Configure feature flags with your SDK API key and the app's FeatureBerry short
name. Statuses are checked through the Horizon API and cached for seven minutes;
the app feature list is cached for twelve minutes. A flag check is synchronous,
so a feature whose status has not been loaded yet evaluates to `false` while the
SDK fetches it in the background.

```swift
FeatureBerry.configure(apiKey: apiKey, appShortName: "YOUR_APP_SHORT_NAME")

if FeatureBerry.Feature("dark-mode").Live {
    showDarkMode()
}

if FeatureBerry.Feature("new-checkout").Testing && FeatureBerry.userIsTesting {
    showNewCheckout()
}
```

`.Live` is true when a feature's Horizon status is `Shipped`; `.Testing` is true
when its status is `Testing`, regardless of the user's opt-in. Combine `.Testing`
with `FeatureBerry.userIsTesting` to show testing features only to opted-in users.
Add the provided button under Feature Requests in your settings to let users opt
in, or set `FeatureBerry.userIsTesting` from your own button. Starting a configured
test session also enables testing mode; successfully submitting the session
disables it. Testing mode resets when the app enters the background and is not
persisted across app launches.
The provided button's tint is customizable:

```swift
FeatureBerryTestingSettings(tint: .orange)
```

Set `FeatureBerry.onUserIsTestingChanged` to refresh your app's current view when
the user opts in or testing mode resets. The callback runs on the main actor and
receives the new value; assigning the same value again does not call it.
For example, in a view controller:

```swift
FeatureBerry.onUserIsTestingChanged = { [weak self] _ in
    self?.updateFeatureViews()
}
```

Clear the callback when it is no longer needed. Configure feature flags before
the user opts in, because `configure` also resets testing mode.

Call `FeatureBerry.refreshFeature(codeword:force:)` to explicitly refresh an
individual status, or `FeatureBerry.refreshFeatures(force:)` to fetch the app's
feature list.

Using the Feature Board alone does **not** initialize a test session or start
screen recording. Do not call `FeatureBerrySessionManager.configure(...)` or
`startSession(presentingFrom:)` unless you also want to offer testing.

## Optional: configure and start a test session

Call `startSession(presentingFrom:)` on the main thread. If called from an early
lifecycle hook such as SwiftUI `onAppear`, the SDK waits briefly (about 2.5
seconds at most) for a foreground-active scene and a presenter attached to a
window before presenting. Call it again after a session completes to run another
test; shaking the device does not start a session.

Configure the shared session manager before offering the session flow to users.
Use an API key appropriate for a client app (never embed a privileged server
secret), and provide the test type and codeword supplied by FeatureBerry,
along with the checklist items to show testers.
The test type is `.feature` or `.release`.

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

        FeatureBerrySessionManager.shared.startSession(presentingFrom: self)
    }
}
```

### Masking private information in recordings

Register any views that display personal or otherwise sensitive information
before starting a session. The SDK covers each registered view with an opaque
black mask during recording; the mask is also visible on screen while recording.
Masks follow their views as the layout changes and are removed when recording
stops.

```swift
let sessionManager = FeatureBerrySessionManager.shared
sessionManager.registerPrivacyMask(for: emailTextField)
sessionManager.startSession(presentingFrom: self)
```

Call `unregisterPrivacyMask(for:)` when a view should no longer be masked.
Sensitive views must be registered before recording starts so the masks are in
place before the first captured frame.

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

Add this to the first view controller your app opens, so the session starts from
`viewDidLoad`. The SDK asks the user to confirm, then starts recording the app's screen
and audio with ReplayKit. It also displays a floating button for opening the
session menu.

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
