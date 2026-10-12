# Dreeve iOS, native SwiftUI client

A starter iPhone app for a **self-hosted Dreeve** server, based on the public Dreeve HTTP API v1 at https://docs.dreeve.app/api/.

## Screenshots

Captured from the iPhone 17 simulator using demo activity data. Goals are saved locally in this build.

| Overview | Goals | Create a goal |
| --- | --- | --- |
| <img src="docs/screenshots/overview.png" alt="Overview with two favorite goals and weekly activity totals" width="250"> | <img src="docs/screenshots/goals.png" alt="Goals list with favorite selection and weekly and monthly progress" width="250"> | <img src="docs/screenshots/create-goal.png" alt="Goal editor with sport, metric, frequency and target fields" width="250"> |

## Features included

- Native dark-themed SwiftUI tab navigation: Overview, Activities, Goals, Health sync, Upload, Settings.
- Connect to a self-hosted Dreeve URL, validate `GET /api/v1/status`, save API token in iOS Keychain (not in source or UserDefaults).
- Browse activities with pagination and local search, see metrics and GPS routes with MapKit.
- Edit name, description, sport type, and assigned gear; delete an activity with confirmation.
- Display assigned gear name, imported/custom type, retirement status, lifetime distance, and activity count. Choose existing gear (including retired items) or remove the assignment. Loading errors offer a retry, and missing inventory entries preserve the current assignment.
- Add an image from the Photos library (when upload mode is supported).
- Download an existing GPX and share it from the device.
- Import `.fit`, `.tcx` and `.gpx` from Files using multipart upload, and view import job states. Import is asynchronous.
- Last-30-day dashboard derived locally from all pages within the date period, with last-7-day chart and sport breakdown.

## Open in Xcode

1. Use macOS with **Xcode 16 or newer** (SwiftUI / iOS 17 APIs).
2. Unzip and open `DreeveIOS.xcodeproj`.
3. Set a unique Bundle Identifier and your Apple development team under Target → Signing & Capabilities.
4. Select a simulator or iPhone and Run. iOS deployment target: **17.0**.
5. Enter the **HTTPS URL of your own Dreeve instance** and an API key generated in Dreeve Settings → Security → API access. The server must be configured with `DREEVE_API_KEY` and its containers recreated.
6. To upload workouts, Dreeve must use `IMPORT_MODE=files`; status reports `canUpload` accordingly.

**Privacy and networking:** The app requires HTTPS and does not configure insecure App Transport Security exceptions. It does not publish or expose your home server by itself. A VPN/tailnet and privately reachable HTTPS DNS name are suitable. The token is persisted with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. For stronger protections you may change this to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The URL is stored in UserDefaults, not a secret. Apple Maps tiles use Apple infrastructure.

## API coverage

| App action | Endpoint |
| --- | --- |
| Validate connection | `GET /api/v1/status` |
| List activities / dashboard queries | `GET /api/v1/activities` |
| Detail / GPS route | `GET /api/v1/activities/{activityId}` |
| Edit name/type/notes/gear | `PATCH /api/v1/activities/{activityId}` |
| Gear inventory | `GET /api/v1/gear` |
| Delete activity | `DELETE /api/v1/activities/{activityId}` |
| GPX export | `GET /api/v1/activities/{activityId}/gpx` |
| Add photo | `POST /api/v1/activities/{activityId}/images` |
| Upload FIT/TCX/GPX | `POST /api/v1/activity/upload` |
| Import history | `GET /api/v1/file-imports` |

### Important API boundaries

- There is **no documented manual JSON activity creation endpoint**. “Post” means upload an existing FIT / TCX / GPX file. Live GPS activity recording or HealthKit sync need client development and/or suitable import support.
- There is **no documented insights endpoint** in the reviewed HTTP API. Dashboard analytics are computed client-side from the previous 30 days. The list endpoint supports 100 items/page, so the dashboard requests each page in the period. This may be slow for large instances.
- No built-in social feed, follow relationships, kudos, or account-based login in the documented API. An API key gives server-level access and must **not** be hardcoded in a publicly distributed app. For multi-user App Store distribution, add per-user authentication and authorization server-side.
- No general offline activity database, background sync, or push notifications yet. Apple Health sync runs manually in the foreground.
- Photo viewing through static image URLs depends on whether the server permits those URLs to load without an authenticated cookie.
- The updated project builds for the generic iOS Simulator destination in Xcode. Interactive simulator operation and a live authenticated Dreeve integration test remain unverified.

## Code map

- `DreeveApp.swift`: launch and navigation
- `APIClient.swift`: bearer-auth HTTP client and uploads
- `Session.swift`: observable application state
- `Models.swift`: API DTOs and local activity insights
- `KeychainStore.swift`: secure token storage
- `DashboardView.swift`: summary and trends
- `ActivitiesView.swift`: paginated list
- `ActivityDetailView.swift`: detail, edit, photos, GPX, delete
- `RouteMapView.swift`: encoded polyline map
- `UploadView.swift`: file picker, upload queue/history
- `SettingsView.swift`: server URL, API key, server capabilities

Reference OpenAPI: https://docs.dreeve.app/api/openapi.yaml

## Gear API contract (checked October 12, 2026)

- Inventory: `GET /api/v1/gear` returns `{ "gear": [...] }`. The app joins an activity's nullable `gearId` to this inventory. `type` means `imported` or `custom`, not shoe/bike category. The documented example omits `isRetired`, so decoding tolerates missing metadata.
- Assignment: `PATCH /api/v1/activities/{activityId}` with `gearId` set to the complete prefixed identifier (for example `gear-b12659861`).
- Removal: explicitly send `"gearId": null`. Swift's default optional encoding would omit the key; the custom `ActivityPatch` encoder distinguishes omission, assignment, and removal.
- Unchanged: omit `gearId` when saving other fields. An unknown current ID is retained rather than silently cleared when inventory loading fails or the gear no longer appears.
- Save success: use the returned activity immediately in detail, activity list, and insights state; refresh the detail gear inventory to update totals. Failed saves stay in the editor and show the server explanation.
- Updates require `IMPORT_MODE=files`. Details refresh server capabilities before enabling editing. Other import modes keep gear visible but disable changes; the server's 409 explanation is also surfaced if mode changes during an edit.

Sources: [List gear](https://docs.dreeve.app/api/operations/listgear/) and [Update activity](https://docs.dreeve.app/api/operations/updateactivity/).

## Verification

Completed for this update:

- Full Debug build with Xcode for the generic iOS Simulator destination, code signing disabled: **passed** (arm64 and x86_64).
- Standalone gear contract tests using URLProtocol mocks: **passed**. Cover inventory metadata, empty inventory, omitted retirement metadata, nullable activity gear, assignment/removal/unchanged encoding, preserving missing current gear, authenticated GET/PATCH paths (including deployment subpath), response decoding, and 400/401/409 server errors.
- Original model smoke test: **passed**.
- Xcode project syntax validation and ZIP integrity: **passed**.

Run the portable tests on macOS with Xcode installed:

```sh
./run_tests.sh
```

Test sources are standalone executables rather than an Xcode XCTest target. Run a simulator build from the project folder with:

```sh
xcodebuild -project DreeveIOS.xcodeproj -scheme DreeveIOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dreeve-build CODE_SIGNING_ALLOWED=NO build
```

Live instance checks still needed: open an activity with assigned gear, select another item and save, reopen the activity to confirm persistence, then choose No gear and confirm removal. Check an activity with no gear, a retired item, and an empty inventory. In Strava import mode, verify gear remains visible and editing is disabled. Test server/network errors and retry. No real server records were modified during this update.

## Application icons

The configured `AppIcon` asset uses the official Dreeve mark with its orange color preserved, a navy (`#09101c`) background, and navy negative space. This dark design is the default on iOS 17 and later and is also explicitly registered for the iOS dark appearance. The icon is opaque and square; iOS supplies corner masking. Xcode derives device icon sizes from the 1024 × 1024 source.

`Branding/` contains the unchanged official SVG plus editable SVG and opaque PNG versions for both white and navy backgrounds. The white version is available as an alternative; the navy version is assigned to the app. Source: [official Dreeve logo](https://raw.githubusercontent.com/dreeveapp/dreeve/master/public/assets/images/logo.svg).

## Manual Apple Health synchronization

Use the **Health sync** tab, choose a starting date, choose whether to include routes and heart rate, and tap **Load Apple Health workouts**. Grant read access through Apple's permission sheet. Select individual workouts, then tap **Sync selected** and confirm the destination server. The app requests no HealthKit write permission and does not modify or delete your original Health records.

Each chosen workout becomes an in-memory TCX upload to the existing Dreeve API. Workouts without GPS also export. Available distance and calorie totals are included; enabled routes and heart-rate samples are included when readable. Names of recording sources are preserved as device names. Garmin's standard Running/Biking/Other sport values are used in the TCX, then the original mapped sport is restored through Dreeve's activity PATCH endpoint after import succeeds. Refresh status to complete this step and link the returned activity ID. Imported or manually linked activities show their Apple Health source and original duration in activity details.

**Duplicates and recovery:** Filenames contain the original HealthKit workout UUID. A device-local journal, scoped to the server URL, records upload intent before sending. Queued and unconfirmed requests are not blindly repeated after restart. The app checks server history by exact filename and reviews existing activities near the original start time. Possible matches require explicit confirmation; selecting **Link this activity** creates a local association with no upload. If these are different workouts, explicitly allow a new upload. This is a heuristic check, not a global uniqueness guarantee: old exports may have different times/time zones, and different HealthKit records may describe the same workout. For unconfirmed network outcomes, refresh first; an explicit retry remains available with a duplicate warning. Failed imports can be selected again. Server-reported duplicate skips are shown separately from imported workouts.

The journal contains HealthKit IDs, workout summaries, destination URLs, and activity links, never API tokens or raw GPS/heart-rate samples. It is stored in Application Support, excluded from backups, and protected with complete file protection on iOS. If the journal cannot be read or saved, uploads stop rather than lose duplicate tracking. Links are local to this installation; Dreeve has no HealthKit-ID field in its current public API. Deleting an activity in Dreeve does not delete it from Health or automatically upload it again.

**Current limits:** Synchronization is one way (Health → Dreeve), manual, and runs while the app is open. A 202 response means queued, not imported. The server needs `IMPORT_MODE=files` and its normal file-processing job. Refresh status after that job runs. No automatic background delivery, propagation of later workout edits/deletions, lap splits, cadence, or power export is implemented. TCX stores active duration; Dreeve currently also interprets this value as elapsed duration, so paused workouts lose the distinction on the server. Time-only export markers bridge sparse recordings without inventing GPS or sensor readings, but speed and elevation metrics may differ from Apple's original metrics. Apple's HealthKit read privacy means an empty result can mean no workouts, limited history, or denied permission.

**Verification for this update:** Xcode simulator build passed. Portable contract tests cover indoor and route/heart-rate TCX output, XML escaping, invalid workouts, UUID filenames, durable journal recovery and server separation, corrupt-journal detection, timezone-aware duplicate candidates, paginated filename-filter requests, and authenticated multipart uploads returning 202. The generated indoor fixture was also accepted by the official Dreeve XML reader and active-duration calculation. These are synthetic/mock tests; no real Health data was read and no live Dreeve records were modified.

**Real-device checks required:** Enable HealthKit for your signing team's App ID/provisioning profile. Build and run on an iPhone with readable workouts, grant permission, sync a single indoor workout and a single outdoor workout, let Dreeve process them, refresh status, and inspect the summary, route, heart rate, sport, and local link. Repeat refresh/relaunch to confirm no second upload. Confirm or reject a match from the old importer, test optional data permissions, and test denied Health access and a server/network error. Successful compilation does not verify device HealthKit permissions or live import processing.

Implementation: `AppleHealthReader.swift` (read-only HealthKit queries), `HealthSyncCore.swift` (TCX and journal), `HealthSyncStore.swift` (uploads/reconciliation), and `HealthSyncView.swift` (manual selection and review). Tests: `DreeveIOSTests/HealthSyncContractTest.swift`, included in `./run_tests.sh`.

References: [Apple HealthKit authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data), [Dreeve file upload](https://docs.dreeve.app/api/operations/uploadactivityfile/), and [file import status](https://docs.dreeve.app/api/operations/listfileimports/).



## Weekly and monthly Goals (October 12, 2026)

Create any number of independent recurring goals in the Goals tab. Each goal chooses an exact Dreeve sport type, activity count or distance, weekly or monthly frequency, and a positive target. Counts must be whole numbers. Distance is entered/displayed in kilometres and stored in metres. Tap a goal to edit it, swipe left to archive, or restore archived goals. Delete is available in the editor. Select Favorite 1 and Favorite 2 at the top of Goals; Overview shows only those selected slots. Concurrent favorite-slot conflicts are resolved deterministically in the UI.

### Personal Team: local goals by default

The default Debug/Release builds use `DreeveIOS.entitlements` without iCloud or Push Notifications and `Info.plist` with an empty `GoalCloudContainer`. Goals are persisted locally with SwiftData and keep working offline; they do not sync between devices. This removes the Personal Team provisioning failure introduced by the Goals update. Existing HealthKit support, signing team and bundle ID are preserved. Select your Personal Team, then build/run again. If Xcode still shows the old capability error, close/reopen the project and use Product → Clean Build Folder.

Apple limits iCloud and Push Notifications provisioning to eligible developer-program teams. See [Apple's developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account).

### Optional iCloud sync with an eligible paid team

1. Select an Apple Developer Program team and a unique bundle ID.
2. In the target's Build Settings, set **Code Signing Entitlements** (`CODE_SIGN_ENTITLEMENTS`) to `DreeveIOS/DreeveIOS-iCloud.entitlements` and **Info.plist File** (`INFOPLIST_FILE`) to `DreeveIOS/Info-iCloud.plist` for both Debug and Release. The separate default local files remain available when switching back to a Personal Team.
3. In Signing & Capabilities, enable **iCloud → CloudKit**, **Push Notifications**, and **Background Modes → Remote notifications**. Create/select `iCloud.<your bundle ID>` in your developer account. If using another container, update the identifier in both optional iCloud files. These capabilities synchronize goal definitions; Dreeve activity progress still requires API refresh.
4. Run signed builds on two devices using the same iCloud account and container. Verify goal creation/edit/archive and favorites on both. Sync is asynchronous; Goals displays account/sync status.
5. Before TestFlight/App Store distribution, initialize the development CloudKit schema with a signed development run and deploy it to production in CloudKit Console. Keep the bundle/container identity stable.

To return to local mode, restore the two default build-setting paths and remove the iCloud, Push Notifications and remote-notification Background Mode capabilities. Both modes use the same on-device goal database; changing mode does not clear goals.

The simulator uses local SwiftData storage by default, because unsigned simulator builds can crash inside CloudKit when no entitlement is present. To test iCloud on a **properly signed and entitled simulator**, add `DREEVE_SIMULATOR_CLOUDKIT` to Swift Active Compilation Conditions. Do not add it to an unsigned build. Local device storage is already the default. Enabling the optional cloud files requires eligible signing even on a simulator. A recoverable container-opening failure attempts the same on-disk store without CloudKit; it never silently substitutes an empty memory database.

Only goal definitions, archive state and favorite ranks enter the private CloudKit database. Instance scope is a SHA-256 hash of the normalized HTTPS deployment URL (host casing/default HTTPS port/trailing slashes normalized; subpaths preserved). The URL itself and API credentials are not stored in goal records. Tokens remain in Keychain. Reconnecting to the same deployment restores its goals; another deployment has a separate set. Dreeve's documented API key is instance-level, so this is deployment scoping, not user-account scoping.

### Progress and calendar rules

- Creation time is metadata, never an activity cutoff. A Thursday goal includes Monday–Thursday activity; editing sport/metric/frequency/target immediately recomputes against the whole current period.
- Gregorian weeks run Monday 00:00 through the next Monday exclusively; months run from day 1 to the next month's day 1 exclusively. The device's current timezone determines **today** and therefore the active week/month. Activity membership uses the date portion of `startDateLocal`, preserving its recorded wall-clock date without converting timezone suffixes. Date arithmetic uses floating calendar components to avoid daylight-saving shifts.
- The [activity search API](https://docs.dreeve.app/api/operations/listactivities/) documents inclusive `filters[from]`/`filters[to]` date filters, page numbers starting at 1, maximum page size 100, and `pagination.totalPages`. It does not explicitly specify the filter timezone. The app fetches one extra day at each end and applies the exact local-date period itself.
- Fetch every page for the combined current week/month window. Deduplicate by activity ID. Replace the saved activity snapshot only when all pages and local-date parsing succeed; a failed later page cannot publish partial totals. Fresh snapshots remove remotely deleted activities and apply changed sport/date/distance. Snapshot APIs are not available, so simultaneous server changes across pagination are reconciled on subsequent refreshes.
- Current-period values are computed on device. Distance sums nonnegative distances, and each matching activity counts once. One activity can contribute independently to several goals. Over-target values remain visible.
- Refresh on app open/foreground, every 60 seconds while active, after edits/deletions/uploads, when import status is read, and with pull-to-refresh or Overview's refresh button. Upload acceptance is not completion: active polling picks up the eventual imported activity. In-flight results cannot overwrite local activity changes or cross instance switches.
- Local derived activity snapshots are stored in the app's Caches directory, outside CloudKit and iCloud backup. Failed refreshes retain cached values and show the error plus last refresh time. Values become stale after five minutes or a period change. If the cache does not cover a new period, progress is shown as unavailable rather than a misleading zero. iOS may evict caches, requiring a network fetch; goal definitions remain in persistent SwiftData storage.
- There is no Dreeve activity push integration or closed-app activity refresh. Foreground refresh reconciles imports/edits/deletions made elsewhere. Historical goal achievements are outside this version's scope.

### Goal verification

- Xcode 27 Debug simulator build: passed for arm64 and x86_64; unsigned simulator startup checked. Generic iPhone arm64 build also passed with signing disabled.
- Standalone regression tests: original model and gear tests passed. New tests cover Monday/month/year boundaries, leap years, DST and travel, local timestamp suffixes, invalid dates, retroactive counting/distance, edits/deletions, duplicate IDs, all-page queries and later-page failures, 121 persistent goals, favorite-slot conflicts, archive exclusion, instance normalization/isolation, local offline snapshots, in-flight mutation/switch races, and cancelled foreground callers with a resumed refresh.
- SwiftUI Overview, Goals list and goal editor rendered on an iPhone simulator using an isolated temporary fake-data build. The fixture is not included in the delivered app. An inherited card layout issue was corrected so metric labels and values stay together.
- Live authenticated Dreeve operations and signed two-device CloudKit synchronization remain unverified; no real server records were changed. Follow the iCloud setup steps and verify a real activity edit/delete/import before relying on the app.

New sources: `GoalEngine.swift` (calendar, scope, calculations), `GoalStore.swift` (SwiftData/CloudKit and local progress cache), `GoalsView.swift` (list/editor/favorites/status), `DreeveIOS.entitlements`, `Info.plist`. Goal tests run with `./run_tests.sh` on macOS 14+ and Xcode. They are standalone executables, not an XCTest target.

Apple reference: [Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices).

The Goals feature was merged into the canonical repository with Apple Health sync, its HealthKit entitlement, API helpers and app icons preserved. Health import reconciliation also triggers goal refresh. On iPhone, the additional tab may place some screens in the system More menu.

## GitHub Actions: builds and releases

`Build and test` runs on pull requests, pushes to `main`, and manually from Actions. It runs all standalone model/gear/Health/Goals tests, builds the shared `DreeveIOS` scheme for iPhone and Simulator, and uploads downloadable packages plus test/build logs. It uses GitHub's `macos-26` runner and its default Xcode; toolchain versions are recorded in the log. Builds are unsigned and use the existing local-goal configuration, with no Apple signing secrets required.

`Release` runs when a version tag is pushed, for example:

```sh
git tag v1.0.0
git push origin v1.0.0
```

Commit and push the workflow files first. Tags must have the form `v1.2.3` or `v1.2.3-beta.1`. The release workflow calls the same verified build in Release configuration, sets the app version from the tag and build number from the workflow run, then publishes a GitHub release after checking package checksums. Prerelease tags produce prereleases. Existing releases are not overwritten; re-running a publish job for an already published tag will fail rather than replacing its assets.

Release assets:

- `DreeveIOS-project.zip`: tracked Xcode project/source at the exact tagged commit, ready to open and sign in Xcode.
- `DreeveIOS-simulator.zip`: compiled `.app` for the runner's iOS Simulator SDK/architecture; install in a compatible simulator using `xcrun simctl install booted DreeveIOS.app`.
- `DreeveIOS-unsigned.ipa`: compiled iPhone Release app in a Payload ZIP. It requires your own signing/provisioning before installation. It cannot be installed directly and is not a TestFlight/App Store distribution.
- `SHA256SUMS.txt`: checksums for the three packages.

Only the publish job has `contents: write`; pull-request and build jobs have read-only access. Official GitHub Actions are pinned to verified commit IDs. The repository must allow GitHub Actions and the workflow's release job token to write releases. No API keys, Apple certificates, personal provisioning profiles or iCloud credentials are included.

To reproduce a build locally, run `bash scripts/ci_build.sh Debug /tmp/dreeve-ci` (or `Release`). This runs tests and both builds, records logs, and packages the currently committed source. GitHub execution has to be verified after these files are pushed; local validation cannot establish the hosted runner's result.
