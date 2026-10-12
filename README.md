# Dreeve iOS, native SwiftUI client

A starter iPhone app for a **self-hosted Dreeve** server, based on the public Dreeve HTTP API v1 at https://docs.dreeve.app/api/.

## Features included

- Native dark-themed SwiftUI tab navigation: Overview, Activities, Upload, Settings.
- Connect to a self-hosted Dreeve URL, validate `GET /api/v1/status`, save API token in iOS Keychain (not in source or UserDefaults).
- Browse activities with pagination and local search, see metrics and GPS routes with MapKit.
- Edit name, description, and sport type; delete an activity with confirmation.
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
| Edit name/type/notes | `PATCH /api/v1/activities/{activityId}` |
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
- This project has not been built or run on an iOS Simulator here, because Xcode and the iOS SDK are not available in this environment. Build and API integration testing are required before production use.

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

## Checks run in this environment

- Parsed all Swift source with the Swift compiler frontend.
- Typechecked the Foundation model and the portable networking implementation (using Linux shims for iOS-only file permissions).
- Executed `DreeveIOSTests/ModelSmokeTest.swift` with synthetic API JSON, passed.
- Validated the Xcode project structure syntax with `plutil -lint`.

None of these checks replace an actual build in Xcode or a live authenticated integration test against a Dreeve instance.
