import Foundation

final class GearFeatureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data, headers) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct GearFeatureContractTest {
    static func main() async throws {
        let start = Date(timeIntervalSince1970: 100)
        var selection = GearPhotoSelection()
        precondition(selection.tap(now: start) == .unlock && selection.phase == .unlocked)
        precondition(selection.tap(now: start) == .search && selection.phase == .loading)
        precondition(selection.tap(now: start) == .none)
        selection.displayed(now: start)
        precondition(selection.secondsRemaining(now: start) == 10)
        precondition(selection.secondsRemaining(now: start.addingTimeInterval(9.1)) == 1)
        precondition(selection.tap(now: start.addingTimeInterval(9.9)) == .next)
        selection.displayed(now: start.addingTimeInterval(12))
        precondition(!selection.expire(now: start.addingTimeInterval(21.9)))
        precondition(selection.expire(now: start.addingTimeInterval(22)) && selection.phase == .locked)
        precondition(selection.tap(now: start.addingTimeInterval(22)) == .unlock)
        precondition(selection.tap(now: start.addingTimeInterval(22)) == .search)
        selection.failed(hasPreview: false, now: start)
        precondition(selection.phase == .unlocked && selection.tap(now: start) == .search)
        selection.failed(hasPreview: true, now: start)
        precondition(selection.phase == .choosing && selection.secondsRemaining(now: start) == 10)
        selection.reset()
        selection.displayed(now: start)
        // A tap at the deadline starts with unlock, never with the old next-result queue.
        precondition(selection.tap(now: start.addingTimeInterval(10)) == .unlock)

        let sample = Data("""
        {"results":[
          {"img_src":"https://images.test/first.png","thumbnail":"https://images.test/first-small.png","title":"First"},
          {"img_src":"https://images.test/second.jpg","title":"Second"},
          {"img_src":"data:image/png;base64,AA==","thumbnail_src":"https://images.test/third.jpg"},
          {"img_src":"http://insecure.test/x.png"},
          {"img_src":"javascript:alert(1)"}
        ]}
        """.utf8)
        let results = try GearImageSearchClient.decodeResults(sample)
        precondition(results.count == 3 && results[0].imageURL.absoluteString == "https://images.test/first.png")
        precondition(results[1].title == "Second" && results[2].imageURL.absoluteString == "https://images.test/third.jpg")
        precondition(results[0].thumbnailURL?.absoluteString == "https://images.test/first-small.png")
        do { _ = try GearImageSearchClient.decodeResults(Data("{\"results\":[]}".utf8)); preconditionFailure() }
        catch GearImageError.noResults {}
        do { _ = try GearImageSearchClient.decodeResults(Data("<html>Denied</html>".utf8)); preconditionFailure() }
        catch GearImageError.notJSON {}
        for address in ["http://example.test/search","https://user:pass@example.test/search","https://example.test/search?token=x"] {
            do { _ = try GearImageSearchClient.endpoint(address); preconditionFailure("Accepted invalid endpoint") }
            catch GearImageError.invalidEndpoint {}
        }
        let endpoint = try GearImageSearchClient.endpoint("https://search.test")
        precondition(endpoint.path == "/search")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GearFeatureProtocol.self]
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        let searchClient = GearImageSearchClient(urlSession: session)
        GearFeatureProtocol.handler = { request in
            precondition(request.url!.host == "search.test")
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            let query = Dictionary(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) }, uniquingKeysWith: { a, _ in a })
            precondition(query["q"] == "Brooks Ghost 16 running shoe product photo")
            precondition(query["categories"] == "images" && query["format"] == "json" && query["pageno"] == "1")
            return (200,sample,["Content-Type":"application/json"])
        }
        let fetched = try await searchClient.search(gearName: "Brooks Ghost 16", endpoint: "https://search.test/search")
        precondition(fetched == results)
        GearFeatureProtocol.handler = { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200,Data([1,2,3]),["Content-Type":"image/png"])
        }
        let image = try await searchClient.download(URL(string:"https://images.test/first.png")!)
        precondition(image == Data([1,2,3]))
        GearFeatureProtocol.handler = { _ in (403,Data("{}".utf8),[:]) }
        do { _ = try await searchClient.search(gearName:"Ghost",endpoint:"https://search.test/search"); preconditionFailure() }
        catch GearImageError.http(let code) { precondition(code == 403) }
        GearFeatureProtocol.handler = { _ in (200,Data([1]),["Content-Length":"12000001"]) }
        do { _ = try await searchClient.download(URL(string:"https://images.test/large.jpg")!); preconditionFailure() }
        catch GearImageError.imageTooLarge {}

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = GearImageCache(directory:root)
        defer { try? FileManager.default.removeItem(at:root) }
        let missing = try cache.load(instanceID:"server-a",gearID:"gear-1")
        precondition(missing == nil)
        try cache.replace(Data([1,2]), instanceID:"server-a",gearID:"gear-1")
        let originalURL = cache.fileURL(instanceID:"server-a",gearID:"gear-1")
        try cache.replace(Data([3,4]), instanceID:"server-a",gearID:"gear-1")
        let saved = try cache.load(instanceID:"server-a",gearID:"gear-1")
        precondition(saved == Data([3,4]))
        let files = try FileManager.default.contentsOfDirectory(atPath:root.path)
        precondition(files.count == 1)
        let reloaded = GearImageCache(directory:root)
        let afterRelaunch = try reloaded.load(instanceID:"server-a",gearID:"gear-1")
        precondition(afterRelaunch == saved)
        let otherServer = try reloaded.load(instanceID:"server-b",gearID:"gear-1")
        precondition(otherServer == nil)
        precondition(originalURL != cache.fileURL(instanceID:"server-b",gearID:"gear-1"))
        let unsafe = cache.fileURL(instanceID:"server-a",gearID:"../../some/path")
        precondition(unsafe.deletingLastPathComponent().path == root.path && unsafe.pathExtension == "png")

        let api = DreeveAPIClient(baseURL:URL(string:"https://api.test/dreeve")!,token:"test-token",urlSession:session)
        func row(_ id:String,_ gear:String,_ name:String) -> [String:Any] {
            ["id":id,"name":name,"sportType":"Run","startDateLocal":"2026-10-13T08:00:00","gearId":gear]
        }
        var calls = 0
        GearFeatureProtocol.handler = { request in
            calls += 1
            precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer test-token")
            precondition(request.url!.path == "/dreeve/api/v1/activities")
            let query = Dictionary(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.map { ($0.name,$0.value!) }, uniquingKeysWith:{a,_ in a})
            precondition(query["pagination[size]"] == "100" && query["filters[gearId]"] == nil)
            let page = Int(query["pagination[page]"]!)!
            let rows: [[String:Any]] = page == 1 ? [row("moved","gear-b","Moved"),row("other","gear-a2","Other")] :
                page == 2 ? [row("a","gear-a","Newest"),row("b","gear-a","Second")] :
                [row("a","gear-a","Duplicate"),row("moved","gear-a","Old assignment")]
            let data = try JSONSerialization.data(withJSONObject:["activities":rows,"pagination":["page":page,"size":100,"total":6,"totalPages":3]])
            return (200,data,[:])
        }
        let activities = try await api.activitiesForGear("gear-a")
        precondition(calls == 3 && activities.map(\.id) == ["a","b"] && activities[0].name == "Newest")
        GearFeatureProtocol.handler = { _ in (503,Data("{\"error\":\"bad_request\",\"message\":\"Offline\"}".utf8),[:]) }
        do { _ = try await api.activitiesForGear("gear-a");preconditionFailure() }
        catch APIError.http(let code,_) { precondition(code == 503) }
        print("Gear feature tests passed: unlock/search/next/10s reset, SearXNG requests/results/errors, bounded image downloads, cache replacement/relaunch/isolation, all-page gear filtering and duplicates.")
    }
}
