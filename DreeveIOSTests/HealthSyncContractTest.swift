import Foundation

final class HealthMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}


/// Test-only raw FIT inspector, independent of the exporter's message builder.
/// Schema/scaling assertions below use Garmin's published profile field numbers.
struct FITInspector {
    struct Message {
        let number: UInt16
        let values: [UInt8: [UInt8]]
        func unsigned(_ field: UInt8) -> UInt64? {
            guard let bytes = values[field] else { return nil }
            return bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
        }
        func signed(_ field: UInt8) -> Int32? { unsigned(field).map { Int32(bitPattern: UInt32($0)) } }
        func string(_ field: UInt8) -> String? { values[field].map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
    }
    let messages: [Message]
    init(_ data: Data) throws {
        let bytes = Array(data)
        precondition(bytes.count >= 16 && bytes[0] == 14 && String(decoding: bytes[8..<12], as: UTF8.self) == ".FIT")
        let size = bytes[4..<8].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        precondition(size + 16 == bytes.count)
        // Nibble lookup CRC is independent of the writer's bit-by-bit update.
        let table: [UInt16] = [0,0xCC01,0xD801,0x1400,0xF001,0x3C00,0x2800,0xE401,0xA001,0x6C00,0x7800,0xB401,0x5000,0x9C01,0x8801,0x4400]
        func crc(_ bytes: ArraySlice<UInt8>) -> UInt16 {
            var value: UInt16 = 0
            for byte in bytes {
                value = (value >> 4) ^ table[Int(value & 15)] ^ table[Int(byte & 15)]
                value = (value >> 4) ^ table[Int(value & 15)] ^ table[Int(byte >> 4)]
            }
            return value
        }
        precondition(crc(bytes[0..<14]) == 0 && crc(bytes[0..<bytes.count]) == 0)
        var position = 14
        var definitions: [UInt8: (UInt16, [(UInt8, Int)])] = [:]
        var result: [Message] = []
        while position < 14 + size {
            let header = bytes[position]; position += 1
            precondition(header & 0x80 == 0)
            let local = header & 15
            if header & 0x40 != 0 {
                precondition(bytes[position + 1] == 0) // little-endian
                let number = UInt16(bytes[position + 2]) | UInt16(bytes[position + 3]) << 8
                let count = Int(bytes[position + 4]); position += 5
                var fields: [(UInt8, Int)] = []
                for _ in 0..<count {
                    fields.append((bytes[position], Int(bytes[position + 1]))); position += 3
                }
                definitions[local] = (number, fields)
            } else {
                let definition = definitions[local]!
                var values: [UInt8: [UInt8]] = [:]
                for (number, count) in definition.1 {
                    values[number] = Array(bytes[position..<position + count]); position += count
                }
                result.append(Message(number: definition.0, values: values))
            }
        }
        precondition(position == 14 + size)
        messages = result
    }
}

@main
struct HealthSyncContractTest {
    static func main() async throws {
        func check(_ value: @autoclosure () throws -> Bool) throws {
            let result = try value()
            precondition(result)
        }
        let start = ISO8601DateFormatter().date(from: "2026-10-12T08:00:00Z")!
        let uuid = UUID(uuidString:"11111111-2222-3333-4444-555555555555")!
        let workout = HealthWorkoutSummary(id: uuid, sportType: "Run", start: start, end: start.addingTimeInterval(1800),
            duration: 1700, distance: 5000, calories: 300, source: "Watch & <Trainer>", timeZoneIdentifier: "Europe/Vienna")
        let emptyRoute = try HealthFITExporter.data(workout: workout, samples: [])
        let indoor = try FITInspector(emptyRoute)
        let session = indoor.messages.first { $0.number == 18 }!
        precondition(session.unsigned(7) == 1800000 && session.unsigned(8) == 1700000)
        precondition(session.unsigned(9) == 500000 && session.unsigned(11) == 300)
        precondition(session.unsigned(5) == 1 && session.string(110) == "Run")
        precondition(indoor.messages.filter { $0.number == 19 }.count == 1)
        precondition(indoor.messages.filter { $0.number == 34 }.count == 1)
        precondition(indoor.messages.first { $0.number == 23 }?.string(27) == "Watch & <Trainer>")
        let indoorRecords = indoor.messages.filter { $0.number == 20 }
        precondition(indoorRecords.count == 2 && indoorRecords.allSatisfy { $0.signed(0) == Int32.max && $0.unsigned(3) == 255 })
        let activity = indoor.messages.first { $0.number == 34 }!
        precondition(activity.unsigned(5)! - activity.unsigned(253)! == 7200)
        precondition(workout.filename == "apple-health-11111111-2222-3333-4444-555555555555.fit")
        precondition(workout.importFilenames == [workout.filename, workout.legacyFilename])
        let routeData = try HealthFITExporter.data(workout: workout, samples: [
            HealthTrackpoint(date: start.addingTimeInterval(60), latitude: 48.21234567, longitude: 16.31234567, altitude: 200.2, speed: 3.456),
            HealthTrackpoint(date: start.addingTimeInterval(60.5), heartRate: 145),
            HealthTrackpoint(date: start.addingTimeInterval(-1), latitude: 1, longitude: 1),
            HealthTrackpoint(date: start.addingTimeInterval(90), latitude: .nan, longitude: 16, heartRate: 999),
            HealthTrackpoint(date: start.addingTimeInterval(100), latitude: -48.2, longitude: 180, altitude: 15000, speed: 70),
            HealthTrackpoint(date: start.addingTimeInterval(120), latitude: 48.2, longitude: 179.999999999)
        ], events: [HealthTimerEvent(date: start.addingTimeInterval(100), isPaused: true),
                    HealthTimerEvent(date: start.addingTimeInterval(200), isPaused: false)])
        let route = try FITInspector(routeData)
        let records = route.messages.filter { $0.number == 20 }
        let measured = records.first { $0.unsigned(3) == 145 }!
        precondition(abs(Double(measured.signed(0)!) * 180 / 2147483648 - 48.21234567) < 0.0000001)
        precondition(abs(Double(measured.signed(1)!) * 180 / 2147483648 - 16.31234567) < 0.0000001)
        precondition(measured.unsigned(78) == 3501 && measured.unsigned(73) == 3456)
        precondition(records.filter { $0.signed(0) != Int32.max }.count == 3)
        let high = records.first { $0.signed(1) == Int32.min }!
        precondition(high.unsigned(78) == 77500 && high.unsigned(2) == 65535 && high.unsigned(73) == 70000)
        let timers = route.messages.filter { $0.number == 21 }
        precondition(timers.map { $0.unsigned(1)! } == [0,1,0,4])
        for sport in ["VirtualRun", "VirtualRide", "Swim", "Yoga", "Hike", "Workout"] {
            let summary = HealthWorkoutSummary(id: uuid, sportType: sport, start: start, end: workout.end,
                duration: 1700, distance: nil, calories: nil, source: "Test", timeZoneIdentifier: "UTC")
            let decoded = try FITInspector(HealthFITExporter.data(workout: summary, samples: []))
            let summaryMessage = decoded.messages.first { $0.number == 18 }!
            let expected: [String: (UInt64,UInt64)] = ["VirtualRun":(1,1), "VirtualRide":(2,6), "Swim":(5,17), "Yoga":(10,43), "Hike":(17,0), "Workout":(0,0)]
            precondition(summaryMessage.unsigned(5) == expected[sport]!.0 && summaryMessage.unsigned(6) == expected[sport]!.1)
            precondition(summaryMessage.unsigned(9) == UInt64(UInt32.max) && summaryMessage.unsigned(11) == UInt64(UInt16.max))
        }
        let invalid = HealthWorkoutSummary(id: UUID(), sportType:"Workout", start:start, end:start, duration:0, distance:nil, calories:nil, source:"Test", timeZoneIdentifier:"UTC")
        do { _ = try HealthFITExporter.data(workout: invalid, samples: []); preconditionFailure("Invalid workout exported") }
        catch HealthSyncError.invalidWorkout {}
        try routeData.write(to: URL(fileURLWithPath:"/private/tmp/dreeve-health-synthetic-route.fit"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.json")
        let ledger = try HealthSyncLedger(url: path)
        let pending = HealthSyncRecord(server:"https://one.test",workout:workout,state:.uncertain,uploadFilename:workout.filename)
        try ledger.save(pending)
        let recovered = try HealthSyncLedger(url:path)
        precondition(recovered.records.count == 1 && recovered.records[0].state == .uncertain && recovered.records[0].filename == workout.filename)
        // Backward-compatible decoding of pre-FIT journals: absent filename means TCX.
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as! [String: Any]
        legacyJSON.removeValue(forKey: "uploadFilename")
        let legacy = try JSONDecoder().decode(HealthSyncRecord.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        precondition(legacy.filename == workout.legacyFilename && legacy.state == .uncertain)
        var accepted = pending
        accepted.state = .queued
        try recovered.save(accepted)
        precondition(recovered.records.count == 1)
        var imported = accepted
        imported.state = .imported
        imported.activityID = "activity-1"
        try recovered.save(imported)
        let secondServer = HealthSyncRecord(server:"https://two.test",workout:workout,state:.queued)
        try recovered.save(secondServer)
        precondition(recovered.records.count == 2 && recovered.records[0].activityID == "activity-1")
        try Data("broken-json".utf8).write(to:path)
        do { _ = try HealthSyncLedger(url:path); preconditionFailure("Corrupt ledger was silently reset") }
        catch is DecodingError {}

        let activities = try JSONDecoder().decode(ActivityPage.self, from: Data("""
        {"activities":[
          {"id":"activity-1","name":"Previously imported","sportType":"Workout","startDateLocal":"2026-10-12T10:00:00"},
          {"id":"activity-2","name":"Different workout","sportType":"Run","startDateLocal":"2026-10-12T10:10:00"}
        ],"pagination":{"page":1,"size":100,"total":2,"totalPages":1}}
        """.utf8)).activities
        precondition(HealthWorkoutMatcher.candidates(for:workout,activities:activities).map(\.id) == ["activity-1"])

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HealthMockURLProtocol.self]
        let client = DreeveAPIClient(baseURL:URL(string:"https://example.test/subpath")!,token:"test-token",urlSession:URLSession(configuration:config))
        HealthMockURLProtocol.handler = { request in
            precondition(request.httpMethod == "GET" && request.url!.path == "/subpath/api/v1/file-imports")
            let query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
            precondition(query.contains(URLQueryItem(name:"filters[filename]",value:workout.filename)))
            precondition(query.contains(URLQueryItem(name:"pagination[page]",value:"2")))
            return (200, Data("{\"fileImports\":[],\"pagination\":{\"page\":2,\"size\":100,\"total\":0,\"totalPages\":2}}".utf8))
        }
        let imports = try await client.fileImports(page:2,size:100,filename:workout.filename)
        precondition(imports.fileImports.isEmpty)
        var historyCalls: [String] = []
        HealthMockURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let name = query.first { $0.name == "filters[filename]" }!.value!
            let page = Int(query.first { $0.name == "pagination[page]" }!.value!)!
            historyCalls.append(name + "|" + String(page))
            let row: [String: Any] = ["filename": page == 1 ? name + ".other" : name,
                "source": "file", "status": name == workout.filename ? "failed" : "queued"]
            return (200, try JSONSerialization.data(withJSONObject: ["fileImports": [row],
                "pagination": ["page": page, "size": 100, "total": 2, "totalPages": 2]]))
        }
        let legacyQueued = try await HealthImportHistory.find(client: client, filenames: workout.importFilenames)
        precondition(legacyQueued?.filename == workout.legacyFilename && legacyQueued?.status == "queued")
        precondition(historyCalls == [workout.filename + "|1", workout.filename + "|2", workout.legacyFilename + "|1", workout.legacyFilename + "|2"])
        HealthMockURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/activities/existing-fit") {
                return (200, Data("{\"id\":\"existing-fit\",\"name\":\"Existing workout\",\"sportType\":\"Run\",\"startDateLocal\":\"2026-10-12T10:00:00\"}".utf8))
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let page = Int(query.first { $0.name == "pagination[page]" }!.value!)!
            return (200, try JSONSerialization.data(withJSONObject: ["fileImports": [["filename": workout.filename,
                "source": "file", "status": page == 1 ? "failed" : "success", "activityId": "existing-fit"]],
                "pagination": ["page": page, "size": 100, "total": 2, "totalPages": 2]]))
        }
        let acceptedFIT = try await HealthImportHistory.find(client: client, filenames: workout.importFilenames)
        precondition(acceptedFIT?.status == "success" && acceptedFIT?.activityId == "existing-fit")
        HealthMockURLProtocol.handler = { _ in
            (200, Data("{\"fileImports\":[],\"pagination\":{\"page\":1,\"size\":100,\"total\":2,\"totalPages\":2}}".utf8))
        }
        do { _ = try await HealthImportHistory.find(client: client, filenames: workout.importFilenames); preconditionFailure("Incomplete import history accepted") }
        catch APIError.decoding {}
        let linked = HealthSyncRecord(server: "https://one.test", workout: workout, state: .imported,
            activityID: "deleted-fit", uploadFilename: workout.filename)
        HealthMockURLProtocol.handler = { request in
            precondition(request.url!.path.hasSuffix("/activities/deleted-fit"))
            return (404, Data("{\"error\":\"not_found\",\"message\":\"Activity deleted\"}".utf8))
        }
        for state in [HealthSyncState.imported, .skipped, .needsDetails] {
            var stored = linked; stored.state = state
            let recovered = try await HealthSyncRecovery.verify(stored, client: client)
            precondition(recovered.state == .deleted && recovered.activityID == nil && recovered.filename == workout.filename)
            try ledger.save(recovered)
            let reopened = try HealthSyncLedger(url: path)
            precondition(reopened.records.first { $0.id == recovered.id }?.state == .deleted)
        }
        for status in [401, 503] {
            HealthMockURLProtocol.handler = { _ in (status, Data("{\"error\":\"bad_request\",\"message\":\"Unavailable\"}".utf8)) }
            do { _ = try await HealthSyncRecovery.verify(linked, client: client); preconditionFailure("Server error treated as deletion") }
            catch APIError.http(let code, _) { precondition(code == status && linked.state == .imported) }
        }
        HealthMockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await HealthSyncRecovery.verify(linked, client: client); preconditionFailure("Timeout treated as deletion") }
        catch is URLError {}
        HealthMockURLProtocol.handler = { _ in (200, Data("{\"id\":\"deleted-fit\",\"name\":\"Still present\",\"sportType\":\"Run\",\"startDateLocal\":\"2026-10-12T10:00:00\"}".utf8)) }
        let stillPresent = try await HealthSyncRecovery.verify(linked, client: client)
        precondition(stillPresent.state == .imported && stillPresent.activityID == linked.activityID)
        var pendingLink = linked; pendingLink.state = .queued
        HealthMockURLProtocol.handler = { _ in preconditionFailure("Pending upload must not be unlocked by a missing activity") }
        let unchanged = try await HealthSyncRecovery.verify(pendingLink, client: client)
        precondition(unchanged.state == .queued)
        // Historical success records can remain on older servers after deletion.
        // Ignore only a linked activity's confirmed 404, then continue across pages.
        var historyPages: [Int] = []
        HealthMockURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/activities/deleted-fit") {
                return (404, Data("{\"error\":\"not_found\",\"message\":\"Deleted\"}".utf8))
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let page = Int(query.first { $0.name == "pagination[page]" }!.value!)!
            historyPages.append(page)
            var row: [String: Any] = ["filename": workout.filename, "source": "file", "status": page == 1 ? "success" : "queued"]
            if page == 1 { row["activityId"] = "deleted-fit" }
            return (200, try JSONSerialization.data(withJSONObject: ["fileImports": [row], "pagination": ["page": page, "size": 100, "total": 2, "totalPages": 2]]))
        }
        let queuedReplacement = try await HealthImportHistory.find(client: client, filenames: [workout.filename])
        precondition(queuedReplacement?.status == "queued" && historyPages == [1,2])
        HealthMockURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/activities/deleted-fit") {
                return (404, Data("{\"error\":\"not_found\",\"message\":\"Deleted\"}".utf8))
            }
            return (200, try JSONSerialization.data(withJSONObject: ["fileImports": [["filename": workout.filename, "source": "file", "status": "success", "activityId": "deleted-fit"]], "pagination": ["page": 1, "size": 100, "total": 1, "totalPages": 1]]))
        }
        let deletedHistory = try await HealthImportHistory.find(client: client, filenames: [workout.filename])
        precondition(deletedHistory == nil)
        HealthMockURLProtocol.handler = { request in
            precondition(request.httpMethod == "POST" && request.url!.path == "/subpath/api/v1/activity/upload")
            precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer test-token")
            precondition(request.value(forHTTPHeaderField:"Content-Type")!.hasPrefix("multipart/form-data; boundary="))
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream, body.isEmpty {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer,maxLength:buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf:buffer.prefix(count))
                }
            }
            let text = String(decoding:body,as:UTF8.self)
            precondition(text.contains("name=\"file\"; filename=\"\(workout.filename)\""))
            precondition(body.range(of: emptyRoute) != nil)
            return (202,Data("{\"status\":\"queued\",\"message\":\"File queued\"}".utf8))
        }
        let receipt = try await client.uploadActivity(data:emptyRoute,filename:workout.filename)
        precondition(receipt.status == "queued")
        try emptyRoute.write(to:URL(fileURLWithPath:"/private/tmp/dreeve-health-synthetic.fit"))
        print("Health sync contract tests passed: FIT CRC/profile, precision/speed/heart rate/pauses, indoor summaries, active/elapsed duration, legacy TCX journal migration, durable history, duplicate candidates, confirmed deletion/re-import recovery, pending/offline protection, import filters and binary multipart upload.")
    }
}
