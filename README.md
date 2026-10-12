# Dreeve iOS, native SwiftUI client

A starter iPhone app for a **self-hosted Dreeve** server, based on the public Dreeve HTTP API v1 at https://docs.dreeve.app/api/.

## Features included

- Native dark-themed SwiftUI tab navigation: Overview, Activities, Upload, Settings.
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
- No offline database, background sync, push notifications, or HealthKit integration yet.
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
