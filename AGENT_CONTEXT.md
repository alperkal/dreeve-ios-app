# Dreeve iOS — agent context

Read this before exploring the implementation. This is a repository-owned handoff, not a chat transcript. It explains current behavior and why the boundaries exist, so another agent can start with the relevant files instead of rediscovering the whole app.

Reviewed 2026-10-30. Baseline release: `v0.6.0` (`e0c23b2`); the Watch companion additions are documented alongside their implementation. Sources: the original “Create Dreeve iOS App” conversation, subsequent feature/fix discussions, README, current source, tests and workflows. Historical proposals are superseded by the implemented behavior below. Verify the current checkout before acting; update this document when architecture or product decisions change.

## Purpose and product boundaries

A native, personal iPhone companion for a self-hosted Dreeve activity server: browse activities, view routes/photos, manage gear, import workouts from Apple Health, track recurring goals, see widgets and a local training brief, and create shareable activity cards.

- SwiftUI, iOS 17 minimum, Swift 5 language mode; an Xcode project with an embedded iPhone WidgetKit extension plus a watchOS 10+ companion and complication extension. No third-party runtime dependency is currently required. FoundationModels is optional behind availability checks.
- Dreeve owns activities and gear. The app adds goal definitions and local derived features; it does not add a backend service or replace Dreeve’s import processor.
- The public API key is deployment-level access, not a multi-user authentication model. Deployment scoping must not be described as user-account isolation.
- Dark navy surfaces, lime accent, rounded cards; shared design primitives live in `Theme.swift`. User-facing flows should use plain language.
- Default goals are local. Private CloudKit sync is an opt-in, signing-dependent configuration, not a requirement to run the app.

## Start here / file arrangements

| Location | Responsibility |
| --- | --- |
| `DreeveIOS.xcodeproj/` | Targets, explicit source membership, signing settings and shared scheme. Add new Swift files to the correct build sources; a file on disk alone is insufficient. |
| `DreeveIOS/DreeveApp.swift` | Composition root, injected stores, tab navigation, foreground loops, widget deep links and Health prompt presentation. |
| `DreeveIOS/APIClient.swift` | HTTPS validation, API requests, bearer authentication, multipart uploads, filtered pagination helpers, photo URL handling and activity website URLs. |
| `DreeveIOS/Models.swift` | API DTOs, tri-state gear patch encoding, sport-family mapping and Overview aggregates. |
| `DreeveIOS/Session.swift` | Main-actor application/connection state; coordinates shared index sync, cached Overview/Goals, network activity pages, write-through mutations and import completion. |
| `DreeveIOS/ActivityIndexStore.swift` | Separate local SwiftData activity-summary database, instance cursor, mutation revisions, queries and streak-history aggregation. |
| `DreeveIOS/ActivitySyncEngine.swift` | Actor coordinating full backfill, date-based deltas, reconciliation, pagination and concurrent callers. |
| `DreeveIOS/GoalEngine.swift` | Pure calendar/progress/streak logic; also `ActivitySportFilter` for Overview drill-down. |
| `DreeveIOS/GoalStore.swift` | `TrainingGoal`, `GoalPersistence` and `GoalProgressStore`; local/optional CloudKit definitions and cached derived progress. |
| `DreeveIOS/DashboardView.swift`, `ActivitiesView.swift`, `GoalsView.swift` | Overview, general/gear/sport-filtered activity lists, goal management and favorite cards. |
| `DreeveIOS/ActivityDetailView.swift`, `RouteMapView.swift`, `ActivityWebView.swift` | Detail/edit/delete, attached photos/full-screen viewer, routes and embedded website viewer. Photo viewer code is in the detail file. The activity editor uses a sport-type dropdown from the supported API catalog in `Models.swift`, preserving unknown current types for forward compatibility. |
| `DreeveIOS/AppleHealthReader.swift` | Read-only HealthKit workout, route and sensor queries; foreground workout observer. |
| `DreeveIOS/HealthSyncCore.swift` | Workout DTOs, metric resampling, import journal/recovery/matching; discovery policy, decisions journal and server verifier. |
| `DreeveIOS/HealthSyncStore.swift` | Manual and approved FIT upload orchestration, duplicate preflight, durable upload intent and server reconciliation. |
| `DreeveIOS/HealthImportDiscovery.swift` | Automatic foreground discovery, saved approvals/snoozes/dismissals, custom `HealthImportPrompt`. |
| `DreeveIOS/HealthFITExporter.swift`, `HealthSyncView.swift` | Native FIT writer, manual Health selection/recovery and import-status tracking. The standalone Upload/Files screen was removed; do not recreate it as a tab. |
| `DreeveIOS/GearView.swift`, `GearImageCore.swift`, `GearImageStore.swift` | Gear list and thumbnail view; two-tap/timeout state machine, image-search client, disk cache and image processing. |
| `DreeveIOS/CoachContextBuilder.swift`, `CoachEngine.swift`, `CoachCardView.swift` | Verified local context, deterministic brief/optional model curation/cache and UI. |
| `DreeveIOS/RoutesView.swift`, `RoutesCore.swift` | Explicit location/map-area searches for mapped OSM running, walking and hiking route relations, Apple Map overlays, partial geometry and distance. Uses a separate configurable Overpass session with provider-scoped optional credentials, never Dreeve credentials; no route generation. |
| `DreeveIOS/RouteGeometryProjector.swift`, `ShareCardRenderer.swift`, `ShareCardSheetView.swift` | Route projection, native compositing/export, photo/background selection and share/save actions. |
| `DreeveIOS/GoalWidgetPublisher.swift` | Publishes safe derived snapshots from the main app to the App Group. |
| `Shared/GoalWidgetData.swift` | Credential-free snapshot types, widget selection/period rules, shared atomic storage; used by both targets. |
| `Shared/GoalWatchData.swift`, `DreeveIOS/PhoneGoalWatchBridge.swift` | Ordered/versioned credential-free Watch envelopes, atomic storage, scoped selection/deep links and iPhone Watch Connectivity sender. |
| `DreeveWatch/`, `DreeveWatchWidgets/` | Watch companion/receiver/details and configurable corner/circular complications; no direct Dreeve API or HealthKit access. |
| `DreeveWidgets/` | WidgetKit views, goal-selection App Intent, timelines and extension configuration. No authenticated networking or SwiftData store here. |
| `DreeveIOS/Theme.swift` | Shared design tokens: navy/lime palette, corner radius, card/button styles used across all UI targets. Never hardcode palette or radius values in view files. |
| `DreeveIOS/KeychainStore.swift`, `SettingsView.swift` | Secure API-token persistence, connection/capability settings and user-configured image-search endpoint. |
| `DreeveIOSTests/`, `run_tests.sh` | Portable standalone Swift contract executables, not an XCTest target. |
| `scripts/`, `.github/workflows/` | Local/CI tests, unsigned simulator/device builds, packaging and tag-triggered releases. |
| `create_project.py` | Historical project-generator script used during initial app creation. Not part of the build or CI pipeline; do not run or modify it. |
| `docs/screenshots/`, `docs/social-preview.png`, `Branding/` | Documentation screenshots, social preview and icon source assets. Screenshots use synthetic data. |

## Authorities, persistence and privacy

| Data | Authority / storage | Important boundary |
| --- | --- | --- |
| Activities, gear, import-job outcomes | Dreeve server; local activity index is a saved replica | No network response is not evidence of deletion. |
| Health workouts / available sensor readings | Apple Health | Read only; Dreeve changes never modify Health. |
| Goal definitions, favorites, archive state | App SwiftData; optional private CloudKit | Never synchronize raw activities, Health samples, tokens or instance addresses through goal records. |
| Goal progress and streaks | Derived from complete indexed activities | Cached values are not an independent counter to increment on import. Recompute after edits/deletions. |
| Widget content | Last main-app-published App Group JSON | Widget cannot independently discover server changes; keep the last valid snapshot on transient failures. |
| Import attempts and links | Protected `Application Support/HealthSync/history.json` | Persist intent before upload. A timeout can leave a real accepted upload. |
| Import approvals/reminders | Protected `Application Support/HealthSync/discovery.json` | Approval is permission to try after verification, not proof an upload succeeded. |
| Gear pictures | `Application Support/GearImages/`, hashed instance + gear filenames | One current image per gear; local only, excluded from backup. |
| Gear inventory | `Application Support/GearInventory/`, hashed instance filename | Protected, backup-excluded local inventory, atomically replaced only after a successful fetch; saved names are usable offline. |
| Activity index | `Application Support/DreeveActivityIndex/ActivityIndex.store` | Separate schema/container with CloudKit disabled; excluded from backup. |
| Derived goal/coach caches | Local Caches directories | Rebuildable and instance-scoped; preserve available values during transient failures. |
| API token | Keychain | Never source code, URL query strings, UserDefaults, CloudKit, widgets, logs or docs. |

Instance identity: `GoalEngine.instanceID` hashes the normalized HTTPS deployment URL, normalizing host casing, default 443 and trailing slashes while preserving deployment subpaths. Goals/index/widgets/gear/coach and discovery use hashed scoping. The older Health import ledger uses the destination server address plus Health UUID; discovery approvals use the canonical hash plus UUID. Do not accidentally merge journals across destinations.

No private infrastructure hostname should be hardcoded or copied into examples. Gear image search has **no default endpoint**; configure it in Settings. Use neutral example domains in documentation and fixtures. Keep Dreeve bearer credentials out of image-search requests, website requests, model inputs and share artifacts.

## Runtime data flow and concurrency

```text
Dreeve API -> ActivitySyncEngine -> local ActivityIndexStore
                                      |-> Session.insightsActivities -> Overview / training brief
                                      |-> current-period data + history -> GoalProgressStore
                                      |                                    -> GoalWidgetPublisher
                                      |                                       -> App Group JSON -> widgets
                                      `-> gear-filtered Activities

Main Activities tab -> paginated API list (separate from the index)
Overview sport row -> fully paginated date + sport-family API query
PATCH / DELETE -> server -> write-through index + visible state -> derived refresh
Approved Health upload -> server queue -> poll final import result -> index reconciliation
```

- First activity sync exhausts all history before publishing a complete Overview/Goal snapshot. Partial cold history may be visible to Gear with an incomplete-history indicator.
- Normal deltas start from the newest indexed local day minus 14 days. Follow every page; prune only after the whole response succeeds. Retain the oldest delta boundary day for timezone safety.
- A full reconciliation runs when due (seven days), on manual full refresh, or after tracked import completion. This catches older edits, deletions and backdated imports outside the delta window. There is no server change-token feed.
- Screens share/coalesce sync work. Session reuses successful refreshes for 15 seconds; the root refresh loop runs every 60 seconds while active. View-task cancellation must not cancel an owned shared sync or become “Request failed: cancelled.”
- Connection generations reject responses from an old connection. Mutation revisions prevent a scan from resurrecting an activity edited/deleted while that scan was in flight; retry the invalidated scan as implemented.
- Failed refreshes preserve saved values. Incomplete pagination must not replace a complete snapshot or prove records were deleted.
- Ordinary opens and both new/legacy goal widget links open Overview. Returning from background resets the selected tab to Overview; widget links must not select Goals.
- The main Activities feed loads paged local index summaries before its first network page, keeps visible rows on refresh failure, and paginates cached history offline. It flags incomplete cache and connection errors; only a successful server response replaces saved results. Do not use an unsuccessful request as evidence of an empty activity list.
- Overview’s distance trend is a swipeable chart: last seven days by default and current calendar month through today on the second page, and current calendar year by month on the third page. All three charts filter by the Settings distance-trend choice (running by default or swimming); Run and VirtualRun count together; swimming combines Swim and OpenWaterSwim. Other Overview totals remain all-sport. `calendarMonthActivities` includes the first day on 31-day months separately from the last-30-days insights; the separate year-to-date query also comes from the local activity index without extending the goal snapshot range.
- Overview shows its connection warning once at the top. Favorite rows suppress repeated stale warnings, and their section warning is hidden when the top status is present. Standalone Goals retains its warnings and the neutral progress timestamp remains visible.

## Goals, dates and streaks: preserve these semantics

- Unlimited recurring goals: sport, activity count/distance, weekly/monthly frequency, positive target. Counts are whole numbers; distance is stored in metres and entered/displayed in kilometres.
- `SportFamily.canonical/types` is the shared mapping: `Run + VirtualRun -> Run`, `Ride + VirtualRide -> Ride`, `Rowing + VirtualRow -> Rowing`. Preserve the raw sport on activity DTOs. Do not merge TrailRun or every sport with a similar name.
- Current progress includes the **whole current period**, even before goal creation. Editing sport/metric/frequency/target recomputes the whole period. `createdAt` is not a progress cutoff.
- Monday-based Gregorian weeks; calendar months; exclusive next-period boundary. The device timezone chooses today/current period. Activity membership uses validated `startDateLocal` wall-clock dates, without converting suffixes to UTC/device time. `GoalCalendar` uses UTC only as a DST-free arithmetic container.
- Overview’s “last 30 days” is today plus 29 earlier calendar days. Health discovery’s “last month” is a rolling calendar month; these are intentionally different windows.
- Overview shows the two explicitly selected favorite slots, not arbitrary replacement goals. CloudKit-friendly goal models have defaults and no uniqueness constraints; visible UUID/favorite conflicts are resolved deterministically.
- Streaks count consecutive completed periods from the goal’s **creation period**, including earlier activities within that period. Unlike current progress, they do not award periods before creation. An unfinished current period gives grace time; a missed ended period breaks the chain. Editing rules recalculates history. Insufficient offline history coverage means unknown, not zero/broken.

## Health import lifecycle and duplicate safety

1. Automatic discovery runs on launch/foreground, a foreground `HKObserverQuery`, and 30-second bounded rescans. It reads completed workouts from **only the rolling last calendar month**, including the first review. It uses bounded rescans, not a persisted HealthKit anchor; late arrivals with recent workout dates are still found.
2. Discovery does not require a successful Dreeve connection. Automatic prompts require verified-ready workouts. Offline unknowns remain “Import status not verified” and can be reviewed manually in Health Sync.
3. Server verification exhausts activity pages and exact import-filename matches. Check both `apple-health-<uuid>.fit` and legacy `.tcx`. Server filename filtering is substring-based, so compare exact filenames locally.
4. Nearby start-time matches (currently ±120 seconds, interpreted in the workout’s timezone) are heuristic. Require explicit review/link or a deliberate “different workout” override; never silently auto-link.
5. The custom sheet groups workouts and uses existing theme. Import stores approval and route/heart-rate choices first; Later snoozes 24 hours; Don’t Ask dismisses those IDs. Pending approvals can be cancelled. Do not interrupt another sheet/editor/viewer or ongoing import. A badge/review action remains in Health Sync.
6. Approved offline work is checked again against Dreeve while active before export/upload. It uses the existing `HealthSyncStore` path; no second independent uploader. Connection/lifecycle guards prevent new approved uploads after switching server, disabling discovery or leaving foreground.
7. Write durable **uncertain** upload intent before the network request. A `202`/queued receipt is not import success. Poll `file-imports`; finish linking and, when needed, reconcile the original sport via PATCH.
8. Queued/uncertain uploads never automatically retry. Known local import states, including failed/deleted records, stay out of automatic discovery prompts; manual recovery handles them. Only a confirmed linked-activity HTTP 404 proves deletion, never timeout/401/403/server failure. Do not recreate deleted Dreeve activities automatically.
9. Health permissions are read only. Empty results cannot distinguish denial from no readable data. Apple’s authorization UI is unavoidable; the workout decision sheet itself is custom. No closed-app notification delivery or background upload scheduler is implemented.

The device-local journal cannot guarantee global uniqueness after reinstall/on a second device. Deterministic filenames are lookup keys, not server-enforced idempotency. Exactly-once behavior across devices would need a server contract. Health edits/deletions do not propagate to Dreeve; do not introduce replacement/deletion sync implicitly.

The activity feed merges server activities with instance-scoped durable Health import records in workout-date order. Queued, unconfirmed and finishing imports have read-only local detail pages (stats and an optional bounded route preview captured during the authorized FIT export); new failed imports remain visible for review. Suppress placeholders by confirmed activity ID, never heuristic time matches. Pending entries never enter the activity index, goals, widgets or coach context. The main app checks outstanding journal entries every 10 seconds while foregrounded, even outside Health Sync and after relaunch; it never resends files automatically. Completion refreshes the activity feed and goals. New imports retain a durable read-only handoff row until the confirmed activity ID is present in the feed/index, so an offline or failed list refresh cannot make the workout disappear. Route previews live only in the protected, backup-excluded import journal; legacy entries without a preview remain decodable. Editing, gear, photo uploads and website actions require a real Dreeve activity.

FIT is the active Health export format because GPX loses telemetry. `HealthFITExporter` writes the protocol directly; do not add a GPX-to-FIT conversion that invents missing readings. Export available GPS, heart rate, cadence, power, pause events and separate active/elapsed durations. Running cadence is FIT cycles/min (steps/min divided by two); cycling cadence is rpm; power is watts. Preserve gaps, zeros and source identity, avoid double-counting phone + Watch samples. Legacy TCX journals/filenames remain supported. Later data never silently rewrites old imports.

## API, gear, photos and sharing contracts

- Require HTTPS; preserve configured deployment subpaths. API root is `/api/v1`. Use full prefixed activity/gear IDs. `canUpload` comes from server status and gates file-mode writes; do not assume uploads/editing are always enabled.
- List responses are paginated (`pagination.totalPages`, page 1+, size up to 100). Date filters are `filters[from]` / `filters[to]`; multi-sport is comma-separated `filters[sportType]`, e.g. `Run,VirtualRun`. Overview drill-down fetches all pages, deduplicates IDs, rechecks local-date membership, and keeps its filters independent of the main Activities tab.
- Public gear filtering is absent in the reviewed v1 contract. Gear lists query the local index by exact full `gearId`. Preserve this offline/full-history behavior rather than replacing it with a shallow loaded-page search.
- Gear PATCH has three states: omit to preserve, full ID to assign, explicit JSON null to remove. Missing inventory must never silently clear an existing assignment. Gear `type` is imported/custom, not shoe/bike.
- Gear picture selection: first tap unlocks, second searches; show loading, select first usable image, each tap within 10 seconds chooses the next result, each replacement restarts the countdown. Expiry accepts; next session requires unlock again and a fresh search. Retain the existing picture on failure. Downsample/center in a rounded thumbnail; detail shows the same selected gear picture.
- Search/image downloads have their own credential-isolating session, size limits, HTTPS checks and atomic cache replacement. Do not pass the Dreeve API token to third-party image hosts.
- Local activity-photo URLs resolve against the configured server/subpath; external HTTPS images retain their host. Website authentication is separate from API authentication. Failure needs explanation/Retry, not an endless spinner.
- Photo uploads immediately display preparation, upload and refresh progress beside the picker; JPEG encoding runs away from the main thread and upload failures remain visible. Activity-photo tap opens the loaded image full screen, with pinch/double-tap zoom and pan. Swipe down dismisses only when zoomed out, preserving zoomed panning.
- “Open in Dreeve” uses `WKWebView` inside the app at `/activities/{activityId}`. Target-blank links stay in the same viewer. Do not add external Safari navigation or inject API bearer credentials into website requests.
- Share card styles: Sticker = Copy Sticker only; Dark Map/Photo = Copy Sticker + Share Image with explicit Save to Photos. Add-only Photos permission suffices for saving. Shared overlays have no Dreeve wordmark.
- Photo style defaults to the first attached activity image, supports switching among attachments, and still allows the system picker. With no attachment, require choosing a photo. Reject superseded/cancelled image loads. Subject segmentation is on-device; preserve map attribution, transparent PNGs, export dimensions and temporary-file cleanup. Generated cards are not uploaded to Dreeve/CloudKit.

## Widgets and training brief

Widgets consume safe JSON, not API credentials or a shared SwiftData database. Small ring selects one goal; medium shows two; large up to four, favorites first. Reached goals get the themed check badge. A specifically selected missing goal must not silently become another goal. There is no update-time label.

Snapshot storage is atomic, backup-excluded and protected until first unlock after reboot so later locked-screen reads work. Distinguish unreadable storage from a successfully saved empty inventory. Preserve valid current-period values only for unchanged goals/targets and the same instance. Explicit logout, instance switches, deletion and archiving clear obsolete data; period rollover must not reuse an old completion check. The extension requests timelines around 15 minutes and midnight; WidgetKit controls actual timing. External activity changes need an app refresh.

The training brief uses Swift-computed facts from complete cached history. It is fingerprint-cached across opens, invalidated by relevant activity/goal/day changes, and can be force-refreshed. On supported iOS 26+ devices, FoundationModels only curates the order/emphasis of verified categories; Swift controls sentences and numbers. Model unavailability, refusal, failure or timeout falls back to deterministic rules. No hosted AI or secret service key is required. Never send names, routes, coordinates or instance/token data into the model prompt. Workload descriptions are not medical/injury predictions. Coach comparisons keep exact sport and matching indoor/outdoor/route category; virtual merging for goals is not permission to compare indoor vs outdoor performance.

### Watch companion boundary

The iPhone publisher sends the existing safe goal snapshot through `PhoneGoalWatchBridge`; the Watch receives and atomically saves a versioned envelope using `GoalWatchStorage`. iPhone and Watch App Groups are separate device-local containers, not a cross-device file share. Never add API credentials or duplicate goal calculation to Watch code. The Watch app and extension use only `GoalWidgetData`/`GoalWatchData`, not the iOS SwiftData models or API client.

Each complication’s App Intent selection contains both instance and goal identity. The default is the first favorite; explicit missing selections never fall back. Corner uses the system curved widget-label gauge; circular uses a ring; completion is a lime check. Taps deep-link to that exact goal’s Watch detail. Saved amounts persist offline only for their valid week/month; rollover is unknown until a fresh phone snapshot arrives, shown with a neutral refresh indicator rather than a green gauge. The corner gauge colors only the completed portion green. No update-time labels. **Sync from iPhone** requests cached phone state, not a Dreeve server refresh.

Application context carries the latest small snapshot; large inventories use immutable file transfers. Sequence numbers reject delayed duplicate/out-of-order packets; sender IDs/timestamps distinguish phone reinstall generations. Phone-side logout/instance changes explicitly publish an ordered empty snapshot. Priority complication transfers are budgeted and reserved for visible goal changes, not timestamps alone. A separate durable priority-send checkpoint keeps unsent changes pending through session activation, foreground retries and phone restarts; failed transfers re-arm the checkpoint. A duplicate current-revision priority arrival still reloads the complication after a preceding context delivery. Watch background tasks must wait for session activation/pending data handling; do not complete them before persisting incoming data. Foreground Watch sync retries after activation and reachability changes and every 15 seconds while visible, with a 30-second in-flight timeout and request identities that ignore late callbacks. Unchanged polls and timestamp-only updates persist their metadata without requesting another complication redraw; priority duplicates and explicit Watch refreshes can force a reload. The phone also sends live messages to the running Watch app; it marks confirmation only after the Watch has persisted the exact revision. Settings shows Watch transfer/save status; the Watch distinguishes storage failures and rejected older packets from successful receipt. A Watch pull may recover a newer same-instance snapshot from the iPhone widget cache, never crossing logout or instance changes. Actual Watch delivery timing is system-managed, and a disconnected Watch cannot learn a logout instantly.

The main scheme embeds Watch app + Watch complication extension; `DreeveWatch.xcscheme` supports watch-only builds. All four targets need consistent signing/App Groups; no Watch CloudKit/HealthKit capability is used. `scripts/package_build.py` checks Watch embedding/identifiers/versions/platforms as well as iPhone widgets. The Watch simulator runtime is not installed on this development host: SDK builds and portable transport tests do not prove actual Infograph rendering or paired-device/background delivery. See the README’s signed-device checklist before claiming end-to-end validation.

## Build, verification, release and maintenance

From the repository root on macOS:

```sh
./run_tests.sh
xcodebuild -project DreeveIOS.xcodeproj -scheme DreeveIOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dreeve-build CODE_SIGNING_ALLOWED=NO build
# Full local CI equivalent: tests, simulator + iPhone builds, packages.
bash scripts/ci_build.sh Debug /tmp/dreeve-ci
```

Change-to-test routing:

| Area | Contract tests to read first |
| --- | --- |
| DTO/API/gear patches | `ModelSmokeTest.swift`, `GearContractTest.swift` |
| Calendar/goal progress/streaks | `GoalsContractTest.swift`, `GoalSportMatchingTest.swift`, `GoalStreakContractTest.swift` |
| Index, sync races, cancellation | `ActivityIndexContractTest.swift`, `SessionRefreshContractTest.swift` |
| Overview sport drill-down | `OverviewSportsContractTest.swift` |
| Health/FIT/re-import/discovery | `HealthSyncContractTest.swift`, `HealthDiscoveryContractTest.swift` |
| Gear search/cache/state machine | `GearFeatureContractTest.swift` |
| Widget/Watch snapshot, selection, rollover/offline | `GoalWidgetContractTest.swift`, `GoalWatchContractTest.swift` |
| Photo URLs/auth/error handling | `ActivityPhotoContractTest.swift` |
| Geometry/share export | `ShareCardContractTest.swift` |
| Training brief/privacy/fallback | `CoachContractTest.swift` |
| Nearby routes/Overpass search, geometry | `RoutesContractTest.swift` |

All test names above are relative to `DreeveIOSTests/`.

Use `run_tests.sh` to see the exact portable source sets. Add a meaningful regression case to the relevant contract executable for behavioral changes; new executables must be registered there. Model, gear, Health/FIT/discovery, goal/calendar/streak, index/session/cancellation, widget, photo, sport drill-down, share and coach tests are separate. Do not substitute `xcodebuild test` and assume these standalone tests ran.

Default signing uses the local Info/entitlements files. Optional `Info-iCloud.plist` / `DreeveIOS-iCloud.entitlements` configure private CloudKit with eligible signing; unsigned simulator CloudKit must stay off unless explicitly entitled (`DREEVE_SIMULATOR_CLOUDKIT`). Goals and activity index remain separate stores. Never “recover” a persistent-store error by silently showing an empty in-memory database.

Widgets require matching App Groups in app + extension. IDs derive from `DREEVE_APP_BUNDLE_IDENTIFIER` and `DREEVE_APP_GROUP_IDENTIFIER`. Personal Team limitations caused earlier provisioning failures: turning off iCloud/Push does not remove the widgets’ App Group requirement. Unsigned builds do not prove eligible device signing.

- `.github/workflows/build.yml`: main pushes, PRs, manual dispatch and reusable workflow; macOS runner calls `scripts/ci_build.sh`.
- `.github/workflows/release.yml`: a **pushed `v*` tag**, not an ordinary commit, triggers verification/build then GitHub release publication. The build script requires semver-like tags (`v0.4.0`, optional prerelease suffix). Do not create/push a release tag without user authorization.
- `scripts/package_build.py`: source ZIP from **tracked committed content**, simulator ZIP, unsigned iPhone IPA and checksums. Uncommitted edits are not in the source archive. The IPA needs signing; it is not directly installable or TestFlight/App Store distribution. All four app/extension products must be signed/embedded correctly.
- CI uses no Apple credentials and does not prove live HealthKit/CloudKit/Home Screen integration. Keep hosted-run results distinct from local results.

Prior work has passed standalone suites and simulator builds; some features also received unsigned device builds and isolated synthetic simulator checks. These are historical results, not guarantees for a new change. Real-iPhone Health authorization/Watch arrivals/sensor availability, actual Dreeve processing, signed CloudKit/App Group access, widget lock/unlock/timelines and receiving-app sharing need device/live checks. No real Health data or live server mutations are necessary for portable tests. Known unreachable-CloudKit-branch compiler warnings in local simulator configurations are separate from runtime failures.

For any change: inspect current Git status, read this guide and only the relevant implementation/tests, preserve existing work, validate proportionately, and report exactly what was checked. The original working checkout is `~/Documents/workspace/dreeve-ios-app`; when the repository is relocated, work in the actual supplied checkout rather than creating the historical path. Never edit an extracted starter ZIP or synced ChatGPT reference mirror instead of the working repo. Commit only when requested; pushing and releasing are separate actions. Update this document and README when behavior changes, and keep `AGENTS.md` as the short entry point.

Portable-cache note: iOS file-protection write options are guarded by platform in goal/gear caches. On macOS, portable tests use atomic writes without iOS protection flags; otherwise the OS may deny reopening fixtures. Device data protection remains enabled.
Offline activity details use the instance-scoped activity index and display saved fields immediately; a successful server fetch replaces them. The index contains activity-list payloads, so it may not contain every detail, photo, or map tile. Server-dependent actions are disabled while showing saved data.

## Nearby routes

Routes occupies the fourth main tab; Gear is available from More. Preserve their existing selection tags and the Routes navigation container.

Routes uses a configurable Overpass-compatible HTTPS endpoint (public Overpass by default) only on user request, with an ephemeral session, blocked redirects, bounded response, a configurable 15–180 second request and query timeout (60 by default), short rate limit and five-minute per-provider local in-memory cache. Optional Bearer or X-API-Key credentials are stored separately in Keychain scoped to the validated endpoint; never put keys in URLs, app preferences, logs, CloudKit or requests to another provider. Existing foreground Core Location permission centers the full-screen map on entry (about 8 km across) without an automatic provider search; Near me requests permission if needed and searches within 4 km. Search this area uses the chosen map center and the same radius. Both send the selected coordinates to Overpass without Dreeve credentials. Running, foot and hiking relations are selectable on the map and all three are selected by default. The cache is scoped to the selection, and changing filters invalidates prior results and in-flight UI updates. These are mapped data, not generated loops, and may be missing or incomplete. Preserve separate original way geometries; distance sums only available segments and labels incomplete results. Merge only connected consecutive ways and simplify display geometry separately; never use simplified points for distance. Group display segments into one MKMultiPolyline for all routes and a second for the selected route; do not rebuild overlays on map-center updates. Apple Maps displays the geometry with visible OSM attribution. No background location, route history upload or automatic server writes.

Route search is explicit: checkbox changes clear existing results and the user taps Near me or Search this area. Do not automatically transmit location on screen open. With no route types selected, search is disabled. Search controls sit at the bottom of the map; selectable route annotations and the expandable list remain available. A larger timeout does not guarantee a response: during Bologna testing the default provider returned ten combined-type relations in roughly 28 seconds, while a different provider timed out even for a small query. Running-only can legitimately return no results even when foot or hiking routes exist.

On a physical iPhone, the user observed MapKit's Metal resource threshold warning while panning routes; they later reported it disappeared after the grouped-overlay change. This is a device observation, not a guarantee for all maps or iOS versions. An additional Apple telemetry sandbox message was reported while debugging; it alone did not establish a Dreeve permission or route-search failure. Preserve original coordinates for distance and group map overlays to avoid reintroducing per-segment renderers. RoutesContractTest covers query selections/cache separation, provider configuration, geometry simplification and grouping; device map responsiveness and live providers remain real-device checks.

Gear inventory names and metadata are cached separately from pictures, scoped by the Dreeve instance hash. Refresh in the foreground and on existing inventory requests; a failed fetch must retain the last saved inventory. Activity details, Gear and filter choices use saved inventory offline and must not expose another instance’s data or treat a failed request as an empty inventory.

Appearance is configured in Settings using `appearance.theme`: Dark (default), Light or System. `DreeveTheme` colors adapt to the selected SwiftUI color scheme; keep light text/background and accent contrast readable. The selected preference is stored separately in the iPhone App Group and propagated in ordered Watch envelopes, with missing legacy data defaulting to dark. Widget timeline reloads and Watch visible-change/priority delivery include appearance changes without changing goal data. Watch face rendering may override complication colors; share-card exports remain dark.
