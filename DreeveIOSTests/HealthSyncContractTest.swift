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

final class TCXInspector: NSObject, XMLParserDelegate {
    var element = ""
    var timestamps: [String] = []
    var latitudeCount = 0
    var heartRates: [String] = []
    var source = ""
    var sports: [String] = []
    var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        element = elementName
        text = ""
        if elementName == "LatitudeDegrees" { latitudeCount += 1 }
        if elementName == "Activity", let sport = attributes["Sport"] { sports.append(sport) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "Time" { timestamps.append(text) }
        if elementName == "Value" { heartRates.append(text) }
        if elementName == "Name" { source = text }
        text = ""
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
        let emptyRoute = try HealthTCXExporter.data(workout: workout, samples: [])
        let indoorParser = XMLParser(data: emptyRoute)
        let indoor = TCXInspector()
        indoorParser.delegate = indoor
        precondition(indoorParser.parse())
        precondition(indoor.timestamps.count == 61 && indoor.latitudeCount == 0 && indoor.heartRates.isEmpty)
        precondition(indoor.source == "Watch & <Trainer>" && indoor.sports == ["Running"])
        let indoorText = String(decoding: emptyRoute, as: UTF8.self)
        precondition(indoorText.contains("<TotalTimeSeconds>1700.000</TotalTimeSeconds>"))
        precondition(indoorText.contains("<DistanceMeters>5000.000</DistanceMeters>"))
        precondition(indoorText.contains("<Calories>300</Calories>"))
        precondition(workout.filename == "apple-health-11111111-2222-3333-4444-555555555555.tcx")
        let routeData = try HealthTCXExporter.data(workout: workout, samples: [
            HealthTrackpoint(date: start.addingTimeInterval(60), latitude: 48.2, longitude: 16.3, altitude: 200),
            HealthTrackpoint(date: start.addingTimeInterval(60), heartRate: 145),
            HealthTrackpoint(date: start.addingTimeInterval(-1), latitude: 1, longitude: 1),
            HealthTrackpoint(date: start.addingTimeInterval(90), latitude: .nan, longitude: 16)
        ])
        let routeParser = XMLParser(data: routeData)
        let route = TCXInspector()
        routeParser.delegate = route
        precondition(routeParser.parse())
        precondition(route.latitudeCount == 1 && route.heartRates == ["145"])
        precondition(!String(decoding: routeData, as: UTF8.self).contains("nan"))
        let invalid = HealthWorkoutSummary(id: UUID(), sportType:"Workout", start:start, end:start, duration:0, distance:nil, calories:nil, source:"Test", timeZoneIdentifier:"UTC")
        do { _ = try HealthTCXExporter.data(workout: invalid, samples: []); preconditionFailure("Invalid workout exported") }
        catch HealthSyncError.invalidWorkout {}

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.json")
        let ledger = try HealthSyncLedger(url: path)
        let pending = HealthSyncRecord(server:"https://one.test",workout:workout,state:.uncertain)
        try ledger.save(pending)
        let recovered = try HealthSyncLedger(url:path)
        precondition(recovered.records.count == 1 && recovered.records[0].state == .uncertain)
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
            precondition(text.contains(indoorText))
            return (202,Data("{\"status\":\"queued\",\"message\":\"File queued\"}".utf8))
        }
        let receipt = try await client.uploadActivity(data:emptyRoute,filename:workout.filename)
        precondition(receipt.status == "queued")
        try emptyRoute.write(to:URL(fileURLWithPath:"/private/tmp/dreeve-health-synthetic.tcx"))
        print("Health sync contract tests passed: TCX, routes/heart rate, durable history, duplicate candidates, import filters, multipart upload.")
    }
}
