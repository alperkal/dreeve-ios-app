import Foundation

private final class PhotoProtocol: URLProtocol {
    static var status = 200
    static var contentType = "image/png"
    static var body = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP1sAAAAASUVORK5CYII=")!
    static var failure: URLError?
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "Accept") == "image/*")
        precondition(request.timeoutInterval == 20)
        if let failure = Self.failure {
            client!.urlProtocol(self, didFailWithError: failure)
            return
        }
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": Self.contentType])!, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: Self.body)
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ActivityPhotoContractTest {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhotoProtocol.self]
        let client = DreeveAPIClient(baseURL: URL(string: "https://example.test/dreeve")!, token: "must-not-leak", urlSession: URLSession(configuration: configuration))
        for value in ["http://old-host.invalid/files/activities/a%20b.jpg", "/files/activities/a%20b.jpg", "https://old-host.invalid/dreeve/files/activities/a%20b.jpg", "files/activities/a%20b.jpg"] {
            let url = try client.activityPhotoURL(value)
            precondition(url.absoluteString == "https://example.test/dreeve/files/activities/a%20b.jpg")
        }
        // Website links preserve the deployment path and prefixed activity ID.
        let page = try client.activityWebURL("activity-9756441741")
        precondition(page.absoluteString == "https://example.test/dreeve/activities/activity-9756441741")
        precondition(page.query == nil && page.fragment == nil)
        let encodedPage = try client.activityWebURL("activity-a b%?#")
        precondition(encodedPage.absoluteString == "https://example.test/dreeve/activities/activity-a%20b%25%3F%23")
        for id in ["", "9756441741", "activity-", "activity-../other", "activity-a\\b"] {
            do { _ = try client.activityWebURL(id); preconditionFailure("Invalid activity ID accepted") }
            catch APIError.invalidURL {}
        }
        let invalidWebsite = DreeveAPIClient(baseURL: URL(string: "http://example.test")!, token: "synthetic")
        do { _ = try invalidWebsite.activityWebURL("activity-1"); preconditionFailure("HTTP website accepted") }
        catch APIError.invalidURL {}
        let root = DreeveAPIClient(baseURL: URL(string: "https://example.test")!, token: "synthetic")
        let rootPage = try root.activityWebURL("activity-1")
        precondition(rootPage.absoluteString == "https://example.test/activities/activity-1")
        let rootURL = try root.activityPhotoURL("/files/activities/p.png")
        precondition(rootURL.absoluteString == "https://example.test/files/activities/p.png")
        let external = "https://cdn.example.test/photos/p.jpg?size=large"
        let externalURL = try client.activityPhotoURL(external)
        precondition(externalURL.absoluteString == external)
        for invalid in ["", "http://cdn.example.test/p.jpg", "file:///private/p.jpg", "https://user:secret@example.test/files/activities/p.jpg"] {
            do { _ = try client.activityPhotoURL(invalid); preconditionFailure("Invalid image URL accepted") }
            catch ActivityPhotoError.invalidURL {}
        }
        let photo = try await client.activityPhoto("/files/activities/p.png")
        precondition(photo == PhotoProtocol.body)
        for code in [401, 403] {
            PhotoProtocol.status = code
            do { _ = try await client.activityPhoto(external); preconditionFailure("Protected photo accepted") }
            catch ActivityPhotoError.websiteLogin {}
        }
        PhotoProtocol.status = 200
        PhotoProtocol.contentType = "text/html; charset=utf-8"
        do { _ = try await client.activityPhoto(external); preconditionFailure("Login HTML accepted as a photo") }
        catch ActivityPhotoError.websiteLogin {}
        PhotoProtocol.contentType = "image/png"
        PhotoProtocol.status = 404
        do { _ = try await client.activityPhoto(external); preconditionFailure("Missing photo accepted") }
        catch ActivityPhotoError.unavailable(let code) { precondition(code == 404) }
        PhotoProtocol.status = 200
        PhotoProtocol.failure = URLError(.timedOut)
        do { _ = try await client.activityPhoto(external); preconditionFailure("Timeout ignored") }
        catch let error as URLError { precondition(error.code == .timedOut) }
        PhotoProtocol.failure = nil
        let retried = try await client.activityPhoto(external)
        precondition(retried == photo && PhotoProtocol.requests == 7)
        print("Activity photo and website URL tests passed: prefixed IDs, encoding, configured HTTPS host/subpath, relative URLs, external images, token isolation, photo response, login, 404, timeout and retry.")
    }
}
