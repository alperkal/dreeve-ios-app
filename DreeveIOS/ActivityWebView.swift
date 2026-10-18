import SwiftUI
import WebKit

struct ActivityWebPage: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ActivityWebView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: ActivityBrowser

    init(url: URL) {
        _browser = StateObject(wrappedValue: ActivityBrowser(url: url))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                EmbeddedActivityBrowser(browser: browser)
                if let error = browser.errorMessage {
                    ContentUnavailableView {
                        Label("Page couldn’t load", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { browser.retry() }
                            .buttonStyle(.borderedProminent)
                    }
                    .background(DreeveTheme.background)
                } else if browser.isLoading {
                    ProgressView("Loading Dreeve…")
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("Dreeve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onDisappear { browser.webView.stopLoading() }
    }
}

@MainActor
private final class ActivityBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    // Website cookies stay in WebKit; the API bearer token is never supplied here.
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private var retryURL: URL
    @Published var isLoading = true
    @Published var errorMessage: String?

    init(url: URL) {
        retryURL = url
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
    }

    func retry() {
        errorMessage = nil
        isLoading = true
        webView.load(URLRequest(url: retryURL))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorMessage = nil
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        errorMessage = "The page stopped responding. Please try again."
    }

    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        isLoading = false
        errorMessage = error.localizedDescription
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else {
            if action.targetFrame?.isMainFrame != false && isLoading {
                isLoading = false
                errorMessage = "This page requires a secure HTTPS address."
            }
            decisionHandler(.cancel)
            return
        }
        if action.targetFrame?.isMainFrame != false { retryURL = url }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse,
           http.statusCode >= 400 {
            isLoading = false
            errorMessage = "Dreeve returned an error (\(http.statusCode)). Please try again."
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // Keep target=_blank and window.open links inside this same viewer.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url,
           url.scheme?.lowercased() == "https", url.host != nil,
           url.user == nil, url.password == nil {
            retryURL = url
            webView.load(action.request)
        }
        return nil
    }
}

private struct EmbeddedActivityBrowser: UIViewRepresentable {
    let browser: ActivityBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
