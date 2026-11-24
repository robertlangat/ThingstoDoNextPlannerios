# Things to Do Next Planner (iOS)

This is the native iPhone, iPad and Apple Watch version of **Things to Do Next Planner**. It uses
SwiftUI, needs iOS 17+ and watchOS 10+, and works fully offline. It has the same features as the
[Android app](https://github.com/robertlangat/To-Do-List-Schedule-Planner) and the same Google
Drive sync format, so the two apps can share one Drive copy if you use the same Google Cloud
project.

| Folder | What it is |
|---|---|
| `Packages/PlannerCore` | Pure Swift logic, unit-tested with `swift test`: recurrence, reminder planning, offline planner, AI-response validation, sync merge (HLC + tombstones), task operations, view queries, progress stats. It's a port of the Android `core` module with the same rules and file formats. |
| `App` | The SwiftUI iPhone/iPad app: Tasks, Calendar and Mine tabs, editor, planner, settings, notifications, Drive sync, AdMob. |
| `Shared` | Code shared by the app and the widget: the App Group JSON store and the interactive "complete" intent. |
| `Widget` | WidgetKit home-screen widget (small, medium and large) with tappable checkboxes and quick add. |
| `Watch` | watchOS app: today's tasks, upcoming deadlines, one-tap complete, and when it was last updated. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated, not committed. |

## Get a build without a Mac

Every push to `main` builds on GitHub's macOS machines and publishes the
[**ios-latest** release](../../releases/tag/ios-latest):

- `ThingsToDoNext-unsigned.ipa` is an unsigned iPhone build (Debug, Google **test** ads). iPhones
  only run signed apps, so install it with **Sideloadly** or **AltStore** using your free Apple
  ID (they re-sign it for 7 days), or sign it with your Apple Developer account.
- `ThingsToDoNext-simulator.app.zip` runs in the Xcode iOS Simulator (unzip it and drag it onto a
  simulator).

For TestFlight or the App Store you need an Apple Developer account ($99/year); see "Signing"
below.

## Publishing to the App Store

Everything for the listing is generated automatically:

- **[`store-assets` branch](../../tree/store-assets)** and the **app-store-assets** release contain
  the 1024×1024 icon, captioned and plain screenshots for iPhone 6.9" (1320×2868), iPad 13"
  (2064×2752) and Apple Watch (416×496). They're captured from the real app by
  `.github/workflows/store-assets.yml`, using screenshot mode with demo data and no ads.
- **[`marketing/AppStore/listing.md`](marketing/AppStore/listing.md)** holds the name, subtitle,
  description, keywords, privacy-label answers, age rating and review notes.
- **Privacy policy and support pages** are in `docs/`, served by GitHub Pages.

Checklist:

1. **GitHub Pages**: go to repo **Settings → Pages**, set Source to "Deploy from a branch", choose
   `main` / `/docs`, and save. The privacy policy then lives at
   `https://robertlangat.github.io/ThingstoDoNextPlannerios/privacy-policy`.
2. **Apple Developer Program**: enrol at developer.apple.com ($99/year).
3. **App Store Connect → Apps → +**: create a New App. Platform iOS, name
   "Things to Do Next Planner", bundle ID `com.robertlangat.thingstodonext` (register it first
   under Certificates, Identifiers & Profiles if it isn't listed), and SKU `thingstodonext-ios-001`.
4. **App Group**: under Identifiers → App Groups, create `group.com.robertlangat.thingstodonext`.
   Enable it on the app ID and on `com.robertlangat.thingstodonext.todaywidget`. Also register
   `com.robertlangat.thingstodonext.watchkitapp`.
5. **API key for CI uploads**: in App Store Connect → Users and Access → Integrations → App Store
   Connect API, create a key with the **Admin** role and download the `.p8` file. In GitHub, go to
   **Settings → Secrets and variables → Actions** and add `APPLE_TEAM_ID`, `ASC_KEY_ID`,
   `ASC_ISSUER_ID` and `ASC_KEY_P8` (paste the whole `.p8` file).
6. **Upload**: go to **Actions → Upload to App Store Connect → Run workflow** and enter a version
   (e.g. `1.0.0`). It archives the Release build (real ad units), signs it automatically and
   uploads it. After 10–30 minutes of processing, it shows up in TestFlight.
7. **Listing**: fill in the version page from `listing.md` and upload the screenshots from
   `framed/`. Pick the build, answer the privacy, age-rating and IDFA questions as `listing.md`
   describes, and **Submit for Review**.
8. **AdMob**: link the app in AdMob once it's live, publish the GDPR and IDFA messages under
   Privacy & messaging, and host `app-ads.txt` on your developer website.

## Build on a Mac

```bash
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # optional: Google client ID, AI URL, team ID
xcodegen generate
open ThingsToDoNext.xcodeproj                                # run the "ThingsToDoNext" scheme
swift test --package-path Packages/PlannerCore               # core tests
xcodebuild -project ThingsToDoNext.xcodeproj -scheme ThingsToDoNext \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Requires Xcode 16+.

### Signing (device, TestFlight, App Store)

1. Put your team ID in `Config/Secrets.xcconfig` (`DEVELOPMENT_TEAM = …`) and regenerate the project.
2. In the Apple Developer portal, create the App Group `group.com.robertlangat.thingstodonext`.
   Enable it for `com.robertlangat.thingstodonext` and `com.robertlangat.thingstodonext.todaywidget`.
   The app and widget share data through it.
3. Archive the **Release** configuration in Xcode (it uses the real ad units) and upload it to
   App Store Connect.

## AdMob

| | ID |
|---|---|
| App ID | `ca-app-pub-8306955081407788~6611207934` (`GADApplicationIdentifier` in Info.plist) |
| Banner | `ca-app-pub-8306955081407788/6084594329` (Release) |
| Interstitial | `ca-app-pub-8306955081407788/8783356966` (Release) |

- **Debug builds** (including the CI .ipa) use Google's test units, so testing never counts as
  invalid traffic. **Release builds** use the real units.
- **Placement**: an adaptive banner above the tab bar on Tasks, Calendar and Mine. Interstitials
  show only after you save a task or a plan: every 3rd save, at most once every 3 minutes, and
  never in the first minute. There are no ads at launch, when ticking tasks, in the widget or on
  the watch.
- **Consent**: Google's User Messaging Platform shows the GDPR / US-state form where required.
  Create the message in **AdMob → Privacy & messaging**, and add the IDFA explainer message too.
  After consent, iOS's App Tracking Transparency prompt appears once. Ads still work if the user
  declines. Settings shows **Ad privacy options** when required.
- **Before release**: add Google's full SKAdNetwork list to `SKAdNetworkItems` in `project.yml`
  (copy it from Google's iOS quick-start; only Google's own ID is included now), host `app-ads.txt`
  on your website, and answer the App Store privacy questions for advertising data.

## Google Drive sync

The app uses the GoogleSignIn SDK with the `drive.appdata` scope only. The sync file is
`todoplanner-sync-v1.json` in the hidden app-data folder, which is the same file the Android app
uses.

1. In Google Cloud Console, use the **same project** as the Android app. Drive's app-data folder
   is shared between clients of one project, so both apps see the same tasks.
2. Go to **Credentials → Create credentials → OAuth client ID → iOS**, with bundle ID
   `com.robertlangat.thingstodonext`.
3. Put the client ID and its reversed form in `Config/Secrets.xcconfig` (`GOOGLE_IOS_CLIENT_ID`,
   `GOOGLE_REVERSED_CLIENT_ID`). Then run `xcodegen generate`.
4. Make sure the consent screen lists the `drive.appdata` scope and your account is a test user.

Builds without a client ID still work: the sign-in button explains that sync isn't set up yet.

## AI planner backend

The app uses the same backend as the Android app (`backend/` in the Android repo). Set
`AI_BACKEND_URL` in `Config/Secrets.xcconfig` (write it as `https:/$()/your-host`, because `//`
starts a comment in xcconfig), or enter it at runtime in Settings → AI planner. Each time, you
approve the exact payload before it's sent. The offline planner always works.

## Platform notes

- **Reminders**: these are local notifications with **Complete** and **Snooze** actions. iOS
  allows 64 pending notifications per app, so the soonest 60 are scheduled and topped up on
  launch, on background refresh and at midnight. Request IDs are the deterministic keys
  `taskId@date#offset`, so edits, snoozes, restores and syncs replace reminders instead of
  duplicating them. Triggers are floating wall-clock times, and the schedule is rebuilt on
  time-zone or clock changes. iOS keeps scheduled notifications across reboots. iOS has no
  "approximate alarms", but Focus modes can hold notifications back, and Settings says so.
- **Permissions**: notifications are requested only when you turn on reminders or add one. There
  are no microphone, calendar or photo permissions. Dictation uses the keyboard's mic.
  "Add to device calendar" uses the system event editor, which needs no calendar access on iOS 17.
  Backups use the Files picker.
- **Widget completion**: the widget writes to the shared store and cancels that occurrence's
  pending notifications. The app reconciles everything else the next time it runs.
- **Watch**: the phone sends the latest state as application context. Completions on the watch
  use `transferUserInfo`, which iOS queues and delivers when the phone is reachable. The watch
  shows "N waiting to sync" until the phone confirms.
- **Recurrence and sync rules** are the same as the Android app. See its `docs/RECURRENCE.md`
  and `docs/SYNC.md`.

## Tests

`swift test --package-path Packages/PlannerCore` runs about 30 tests. They cover:
- monthly-31st and Feb-29 rules, weekday and custom-weekly rules, COUNT/UNTIL/EXDATE and splits
- DST gap and overlap, time-zone change, reminder dedupe, snooze and the 60-reminder cap
- sync union, deletion staying deleted, undo restore, last-writer-wins tie-breaks, idempotence,
  purging, HLC skew, and **reading a snapshot written by the Android app**
- the offline planner, rough-text parser and AI validator
- Today, Inbox, Starred, Completed, search, filter and focus views, and progress stats
- task operations: complete/undo, per-occurrence completion, recurring edits without duplicate
  reminders, synced deletes and lists

CI runs these, then builds the app, widget and watch app for the simulator and for devices.

## Secrets

Nothing secret is committed. `Config/Secrets.xcconfig` and `GoogleService-Info.plist` are
git-ignored, and the placeholders are in `Config/Secrets.example.xcconfig`.
