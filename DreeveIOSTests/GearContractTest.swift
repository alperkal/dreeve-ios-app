import Foundation

// Standalone macOS contract test; no live server or credentials needed.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct GearContractTest {
    static func main() async throws {
        func check(_ condition: @autoclosure () throws -> Bool) throws {
            let result = try condition()
            precondition(result)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = DreeveAPIClient(baseURL: URL(string: "https://example.test/dreeve")!, token: "test-token", urlSession: URLSession(configuration: config))
        let decoder = JSONDecoder()
        let gearJSON = Data("""
        {"gear":[
          {"id":"gear-bike","name":"Canyon Grail","type":"imported","isRetired":false,"distanceInMeter":10500,"numberOfActivities":1},
          {"id":"gear-shoes","name":"Old shoes","type":"custom","isRetired":true,"distanceInMeter":0,"numberOfActivities":0}
        ]}
        """.utf8)
        MockURLProtocol.handler = { request in
            precondition(request.url!.path == "/dreeve/api/v1/gear")
            precondition(request.httpMethod == "GET")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return (200, gearJSON)
        }
        let inventory = try await client.gear()
        precondition(inventory.count == 2 && inventory[0].distanceInMeter == 10500)
        precondition(inventory[1].isRetired == true && inventory[1].numberOfActivities == 0)
        try check(decoder.decode(GearPage.self, from: Data("{\"gear\":[]}".utf8)).gear.isEmpty)
        // Documentation's example omits isRetired: remain compatible with it.
        try check(decoder.decode(GearPage.self, from: Data("{\"gear\":[{\"id\":\"gear-1\",\"name\":\"Bike\",\"type\":\"imported\"}]}".utf8)).gear[0].isRetired == nil)

        func patch(_ gear: GearChange) -> ActivityPatch {
            ActivityPatch(name: "Ride", sportType: "Ride", description: "", gear: gear)
        }
        func object(_ patch: ActivityPatch) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as! [String: Any]
        }
        try check(object(patch(.unchanged))["gearId"] == nil)
        try check(object(patch(.assign("gear-bike")))["gearId"] as? String == "gear-bike")
        try check(object(patch(.remove))["gearId"] is NSNull)
        try check(object(patch(.between(original: "gear-missing", selected: "gear-missing")))["gearId"] == nil)
        try check(object(patch(.between(original: "gear-bike", selected: nil)))["gearId"] is NSNull)

        try check(object(patch(.between(original: nil, selected: "gear-shoes")))["gearId"] as? String == "gear-shoes")
        try check(object(patch(.between(original: nil, selected: nil)))["gearId"] == nil)

        let activityJSON = Data("""
        {"id":"activity-1","name":"Ride","sportType":"Ride","startDateLocal":"2026-10-12T09:00:00","gearId":"gear-bike"}
        """.utf8)
        MockURLProtocol.handler = { request in
            precondition(request.url!.path == "/dreeve/api/v1/activities/activity-1")
            precondition(request.httpMethod == "PATCH")
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            precondition(body["gearId"] as? String == "gear-bike")
            return (200, activityJSON)
        }
        let updated = try await client.editActivity("activity-1", patch: patch(.assign("gear-bike")))
        precondition(updated.gearId == "gear-bike")
        try check(decoder.decode(DreeveActivity.self, from: Data("{\"id\":\"activity-1\",\"name\":\"Ride\",\"sportType\":\"Ride\",\"startDateLocal\":\"2026-10-12T09:00:00\",\"gearId\":null}".utf8)).gearId == nil)
        for code in [400, 401, 409] {
            MockURLProtocol.handler = { _ in (code, Data("{\"error\":\"bad_request\",\"message\":\"Server explanation\"}".utf8)) }
            do {
                _ = try await client.editActivity("activity-1", patch: patch(.remove))
                preconditionFailure("Expected an API error")
            } catch APIError.http(let received, let message) {
                precondition(received == code && message == "Server explanation")
            }
        }
        print("Gear contract tests passed: inventory, encoding, request, response, and errors.")
    }
}
