// Run independently with:
// cp DreeveIOSTests/ModelSmokeTest.swift /tmp/main.swift
// swiftc DreeveIOS/Models.swift /tmp/main.swift -o /tmp/dreeve-model-test && /tmp/dreeve-model-test
import Foundation

let payload = """
{
  "activities": [{
    "id": "activity-1", "name": "Evening Run", "description": "Training",
    "sportType": "Run", "startDateLocal": "2026-10-10T18:00:00",
    "distanceInMeter": 10000, "movingTimeInSeconds": 3000,
    "elevationInMeter": 123, "location": {"city": "Vienna", "state": null, "countryCode": "at"},
    "startLatLng": [48.2, 16.3], "hasGpx": true
  }],
  "pagination": {"page": 1, "size": 25, "total": 1, "totalPages": 1}
}
"""
let decoded = try JSONDecoder().decode(ActivityPage.self, from: Data(payload.utf8))
precondition(decoded.activities.count == 1)
precondition(decoded.activities[0].distanceKilometers == 10)
precondition(decoded.activities[0].movingMinutes == 50)
precondition(decoded.activities[0].locationLabel == "Vienna")
let summary = ActivityInsights(activities: decoded.activities, now: ActivityDates.local.date(from: "2026-10-12T09:00:00")!)
precondition(summary.weekKm == 10)
precondition(summary.monthKm == 10)
precondition(summary.sports.first?.id == "Run")
let sportOptions = ActivitySportTypes.options(including: "VirtualRun")
precondition(sportOptions.contains("Run") && sportOptions.contains("VirtualRun"))
precondition(sportOptions.contains("VirtualRide") && sportOptions.contains("VirtualRow"))
precondition(sportOptions.count == Set(sportOptions).count)
precondition(sportOptions == sportOptions.sorted())
precondition(ActivitySportTypes.options(including: "FutureServerSport").contains("FutureServerSport"))
precondition(!ActivitySportTypes.options(including: "").contains(""))
print("Dreeve model smoke test passed")
