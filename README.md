# Dreeve iOS, native SwiftUI client

A starter iPhone app for a **self-hosted Dreeve** server, based on the public Dreeve HTTP API v1 at https://docs.dreeve.app/api/.

## Features included

- Native dark-themed SwiftUI tab navigation: Overview, Activities, Health sync, Upload, Settings.
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
