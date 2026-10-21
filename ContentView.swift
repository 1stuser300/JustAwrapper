import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject private var store = TranscriptStore.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSaved = false
    @State private var historyText = ""

    @State private var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        let captureScript = """
        (function() {
            let t;
            const send = () => {
                const txt = document.body ? document.body.innerText : '';
                if (txt && txt.length > 0) {
                    window.webkit.messageHandlers.save.postMessage(txt);
                }
            };
            const schedule = () => { clearTimeout(t); t = setTimeout(send, 700); };
            const start = () => {
                if (!document.body) { setTimeout(start, 250); return; }
                new MutationObserver(schedule).observe(document.body, {
                    subtree: true, childList: true, characterData: true
                });
                schedule();
            };
            start();
            window.addEventListener('pagehide', send);
            document.addEventListener('visibilitychange', () => { if (document.hidden) send(); });
        })();
        """

        controller.addUserScript(WKUserScript(source: captureScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        config.userContentController = controller
        return WKWebView(frame: .zero, configuration: config)
    }()

    var body: some View {
        VStack(spacing: 0) {
            if showSaved {
                savedPane
            } else {
                WebViewWrapper(webView: webView) { text in
                    store.save(text)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button(showSaved ? "Back" : "View Saved") {
                    if !showSaved { historyText = store.loadHistory() }
                    showSaved.toggle()
                }
                .buttonStyle(.borderedProminent)

                Button("Refresh") {
                    historyText = store.loadHistory()
                }
                .buttonStyle(.bordered)
                .disabled(!showSaved)

                Button("Clear Cookies") { clearCookies() }
                    .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            statusBar
        }
        .onAppear {
            webView.load(URLRequest(url: URL(string: "https://lumo.proton.me")!))
        }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                if let s = value as? String { store.save(s) }
            }
        }
    }

    private var savedPane: some View {
        ScrollView {
            Text(historyText.isEmpty ? "(nothing saved yet)" : historyText)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Saves: \(store.saveCount)   Last: \(store.lastSaved)   Chars: \(store.latest.count)")
            if !store.lastError.isEmpty {
                Text("ERROR: \(store.lastError)").foregroundColor(.red)
            }
            Text(store.storagePath)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.system(size: 9))
        .foregroundColor(.gray)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func clearCookies() {
        let ds = webView.configuration.websiteDataStore
        let types: Set<String> = [WKWebsiteDataTypeCookies]
        ds.fetchDataRecords(ofTypes: types) { records in
            ds.removeData(ofTypes: types, for: records, completionHandler: {})
        }
    }
}

struct WebViewWrapper: UIViewRepresentable {
    let webView: WKWebView
    let onSave: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        webView.configuration.userContentController.add(context.coordinator, name: "save")
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "save")
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSave: onSave) }

    class Coordinator: NSObject, WKScriptMessageHandler {
        let onSave: (String) -> Void
        init(onSave: @escaping (String) -> Void) { self.onSave = onSave }

        func userContentController(_ ucc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "save", let body = message.body as? String {
                onSave(body)
            }
        }
    }
}