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
    "startLatLng": [48.2, 16.3]
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
let monthPayload = """
{"activities":[
  {"id":"last", "name":"Last month", "sportType":"Run", "startDateLocal":"2026-09-30T12:00:00", "distanceInMeter":20000},
  {"id":"first", "name":"First", "sportType":"Run", "startDateLocal":"2026-10-01T12:00:00", "distanceInMeter":5000},
  {"id":"latest", "name":"Latest", "sportType":"Run", "startDateLocal":"2026-10-31T10:00:00", "distanceInMeter":3000},
  {"id":"next", "name":"Next month", "sportType":"Run", "startDateLocal":"2026-11-01T12:00:00", "distanceInMeter":10000}
], "pagination":{"page":1,"size":100,"total":4,"totalPages":1}}
"""
let monthActivities = try JSONDecoder().decode(ActivityPage.self, from: Data(monthPayload.utf8)).activities
let october = CalendarMonthDistance(activities: monthActivities, now: ActivityDates.local.date(from: "2026-10-31T15:00:00")!)
precondition(october.daily.count == 31 && october.daily.first?.km == 5 && october.daily.last?.km == 3 && october.total == 8)
let firstDay = CalendarMonthDistance(activities: monthActivities, now: ActivityDates.local.date(from: "2026-10-01T15:00:00")!)
precondition(firstDay.daily.count == 1 && firstDay.total == 5)
let mixedPayload = """
{"activities":[
 {"id":"run","name":"Run","sportType":"Run","startDateLocal":"2026-10-30T08:00:00","distanceInMeter":6000},
 {"id":"virtual","name":"Treadmill","sportType":"VirtualRun","startDateLocal":"2026-10-31T08:00:00","distanceInMeter":5000},
 {"id":"swim","name":"Swim","sportType":"Swim","startDateLocal":"2026-10-31T09:00:00","distanceInMeter":2000},
 {"id":"open","name":"Open water","sportType":"OpenWaterSwim","startDateLocal":"2026-10-30T09:00:00","distanceInMeter":1000},
 {"id":"ride","name":"Ride","sportType":"Ride","startDateLocal":"2026-10-31T09:00:00","distanceInMeter":40000},
 {"id":"trail","name":"Trail","sportType":"TrailRun","startDateLocal":"2026-10-31T09:00:00","distanceInMeter":3000},
 {"id":"earlier","name":"Older","sportType":"Run","startDateLocal":"2026-10-01T09:00:00","distanceInMeter":4000},
 {"id":"future","name":"Future","sportType":"Run","startDateLocal":"2026-11-01T09:00:00","distanceInMeter":9000}
], "pagination":{"page":1,"size":100,"total":8,"totalPages":1}}
"""
let mixed = try JSONDecoder().decode(ActivityPage.self, from: Data(mixedPayload.utf8)).activities
let now = ActivityDates.local.date(from: "2026-10-31T12:00:00")!
let monthRun = CalendarMonthDistance(activities: mixed, sport: .running, now: now)
let monthSwim = CalendarMonthDistance(activities: mixed, sport: .swimming, now: now)
let weekRun = LastSevenDaysDistance(activities: mixed, sport: .running, now: now)
let weekSwim = LastSevenDaysDistance(activities: mixed, sport: .swimming, now: now)
precondition(monthRun.total == 15 && monthRun.daily.last?.km == 5 && monthSwim.total == 3)
precondition(weekRun.total == 11 && weekRun.daily.count == 7 && weekRun.daily.last?.km == 5)
precondition(weekSwim.total == 3 && weekSwim.daily.last?.km == 2)
precondition(ActivityInsights(activities: mixed, now: now).monthKm == 70)
let yearPayload = """
{"activities":[
 {"id":"prior","name":"Previous year","sportType":"Run","startDateLocal":"2025-12-31T10:00:00","distanceInMeter":9000},
 {"id":"january","name":"Run","sportType":"Run","startDateLocal":"2026-01-01T10:00:00","distanceInMeter":6000},
 {"id":"february","name":"Indoor","sportType":"VirtualRun","startDateLocal":"2026-02-28T10:00:00","distanceInMeter":5000},
 {"id":"swim","name":"Swim","sportType":"Swim","startDateLocal":"2026-02-02T10:00:00","distanceInMeter":2000},
 {"id":"sea","name":"Sea","sportType":"OpenWaterSwim","startDateLocal":"2026-03-01T10:00:00","distanceInMeter":1000},
 {"id":"future","name":"Future","sportType":"Run","startDateLocal":"2026-04-01T10:00:00","distanceInMeter":10000}
],"pagination":{"page":1,"size":100,"total":6,"totalPages":1}}
"""
let yearlyActivities = try JSONDecoder().decode(ActivityPage.self, from: Data(yearPayload.utf8)).activities
let march = ActivityDates.local.date(from: "2026-03-15T12:00:00")!
let annualRun = CalendarYearDistance(activities: yearlyActivities, sport: .running, now: march)
let annualSwim = CalendarYearDistance(activities: yearlyActivities, sport: .swimming, now: march)
precondition(annualRun.monthly.map(\.km) == [6, 5, 0] && annualRun.total == 11)
precondition(annualSwim.monthly.map(\.km) == [0, 2, 1] && annualSwim.total == 3)
let jan = CalendarYearDistance(activities: yearlyActivities, sport: .running, now: ActivityDates.local.date(from: "2026-01-01T12:00:00")!)
precondition(jan.monthly.count == 1 && jan.total == 6)
let december = CalendarYearDistance(activities: [], sport: .running, now: ActivityDates.local.date(from: "2028-12-31T12:00:00")!)
precondition(december.monthly.count == 12 && december.total == 0)
let february = CalendarMonthDistance(activities: [], now: ActivityDates.local.date(from: "2028-02-29T12:00:00")!)
precondition(february.daily.count == 29 && february.total == 0)
let gearRoot = FileManager.default.temporaryDirectory.appendingPathComponent("gear-inventory-test-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: gearRoot) }
let gearCache = GearInventoryCache(directory: gearRoot)
let scopeA = String(repeating: "a", count: 64), scopeB = String(repeating: "b", count: 64)
let inventory = try JSONDecoder().decode(GearPage.self, from: Data("""
{"gear":[{"id":"shoe-1","name":"My shoes","type":"shoe","isRetired":false,"distanceInMeter":1000}]}
""".utf8)).gear
try gearCache.save(inventory, instanceID: scopeA)
let restoredGear = try GearInventoryCache(directory: gearRoot).load(instanceID: scopeA)
precondition(restoredGear?.first?.name == "My shoes" && restoredGear?.first?.id == "shoe-1")
let otherGear = try gearCache.load(instanceID: scopeB)
precondition(otherGear == nil)
try gearCache.save([], instanceID: scopeA)
let emptiedGear = try gearCache.load(instanceID: scopeA)
precondition(emptiedGear?.isEmpty == true)
do { try gearCache.save(inventory, instanceID: "../bad"); preconditionFailure("Unsafe scope accepted") } catch {}
print("Dreeve model smoke test passed")
