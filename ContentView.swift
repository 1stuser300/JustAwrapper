import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject private var store = TranscriptStore.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSaved = false
    @State private var showClearConfirm = false
    @State private var isPicking = false
    @State private var composerSelector: String = ""
    @State private var lastInjectResult: String = ""

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
            const schedule = () => { clearTimeout(t); t = setTimeout(send, 900); };
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

        let pickerScript = """
        (function() {
            function cssPath(el) {
                if (!el || el.nodeType !== 1) return null;
                if (el.id) {
                    const s = '#' + CSS.escape(el.id);
                    if (document.querySelectorAll(s).length === 1) return s;
                }
                const parts = [];
                let cur = el;
                while (cur && cur.nodeType === 1 && cur !== document.documentElement) {
                    let part = cur.tagName.toLowerCase();
                    if (cur.id) {
                        parts.unshift('#' + CSS.escape(cur.id));
                        break;
                    }
                    const cls = (typeof cur.className === 'string' && cur.className.trim())
                        ? cur.className.trim().split(/\\s+/).filter(Boolean).slice(0, 2)
                        : [];
                    if (cls.length) {
                        part += '.' + cls.map(function(c){ return CSS.escape(c); }).join('.');
                    }
                    const parent = cur.parentElement;
                    if (parent) {
                        const sibs = Array.prototype.filter.call(parent.children, function(c){
                            return c.tagName === cur.tagName;
                        });
                        if (sibs.length > 1) {
                            part += ':nth-of-type(' + (sibs.indexOf(cur) + 1) + ')';
                        }
                    }
                    parts.unshift(part);
                    cur = cur.parentElement;
                }
                return parts.join(' > ');
            }

            window.__lumoArmPicker = function(armed) {
                window.__lumoPickArmed = !!armed;
            };

            document.addEventListener('click', function(e) {
                if (!window.__lumoPickArmed) return;
                e.preventDefault();
                e.stopPropagation();
                e.stopImmediatePropagation();
                window.__lumoPickArmed = false;

                const el = e.target;
                const path = cssPath(el);
                const editable = el.isContentEditable ||
                                 el.tagName === 'TEXTAREA' ||
                                 el.tagName === 'INPUT';
                const desc = el.tagName.toLowerCase() +
                             (el.id ? '#' + el.id : '') +
                             (editable ? ' (editable)' : ' (walks up to editable)');

                window.webkit.messageHandlers.picked.postMessage({
                    selector: path || '',
                    desc: desc
                });
            }, true);
        })();
        """

        controller.addUserScript(WKUserScript(source: captureScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: pickerScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        config.userContentController = controller
        return WKWebView(frame: .zero, configuration: config)
    }()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WebViewWrapper(webView: webView,
                               onSave: { store.save($0) },
                               onPicked: { sel, desc in
                                   composerSelector = sel
                                   isPicking = false
                                   lastInjectResult = "Target: \(desc)"
                               })

                if showSaved {
                    savedPane
                        .background(Color(UIColor.systemBackground))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Button(isPicking ? "Cancel Pick" : "1. Pick Target") {
                        isPicking ? cancelPick() : armPicker()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    Button("2. Insert Transcript") { injectTranscript() }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                        .disabled(composerSelector.isEmpty || store.latest.isEmpty)
                }

                HStack(spacing: 8) {
                    Button("Saved") { showSaved.toggle() }
                        .buttonStyle(.bordered)
                        .font(.caption)

                    Button(store.captureEnabled ? "Pause" : "Resume") {
                        store.captureEnabled.toggle()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    Button("Clear") { showClearConfirm = true }
                        .buttonStyle(.bordered)
                        .font(.caption)
                        .tint(.red)

                    Button("Cookies") { clearCookies() }
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
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
        .alert("Delete saved transcript?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.clear()
                lastInjectResult = ""
            }
        } message: {
            Text("This permanently deletes the transcript from the app's private storage and pauses capture so it doesn't come straight back. It cannot be undone.")
        }
    }

    // MARK: - Saved pane

    private var savedPane: some View {
        ScrollView {
            Text(store.latest.isEmpty ? "(nothing saved yet)" : store.latest)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Capture: \(store.captureEnabled ? "ON" : "PAUSED")   Saves: \(store.saveCount)   Last: \(store.lastSaved)   Chars: \(store.latest.count)")

            if !composerSelector.isEmpty {
                Text("Target: \(composerSelector)")
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            if !lastInjectResult.isEmpty {
                Text(lastInjectResult)
            }

            if !store.lastError.isEmpty {
                Text("ERROR: \(store.lastError)").foregroundColor(.red)
            }

            Text(store.storagePath)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 9))
        .foregroundColor(.gray)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Picker

    private func armPicker() {
        isPicking = true
        lastInjectResult = ""
        webView.evaluateJavaScript("window.__lumoArmPicker && window.__lumoArmPicker(true);") { _, error in
            if let error = error {
                lastInjectResult = "Arm failed: \(error.localizedDescription)"
                isPicking = false
            }
        }
    }

    private func cancelPick() {
        isPicking = false
        webView.evaluateJavaScript("window.__lumoArmPicker && window.__lumoArmPicker(false);") { _, _ in }
    }

    // MARK: - Injection

    private func injectTranscript() {
        let text = store.latest
        guard !text.isEmpty else { return }

        let b64 = Data(text.utf8).base64EncodedString()
        let selJSON = jsonString(composerSelector)

        let script = """
        (function() {
            try {
                const bin = atob("\(b64)");
                const bytes = new Uint8Array(bin.length);
                for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                const text = new TextDecoder('utf-8').decode(bytes);

                let el = null;
                try { el = document.querySelector(\(selJSON)); }
                catch (e) { return 'BAD SELECTOR: ' + e.message; }
                if (!el) return 'TARGET NOT FOUND - re-pick';

                let target = el;
                while (target &&
                       !target.isContentEditable &&
                       target.tagName !== 'TEXTAREA' &&
                       target.tagName !== 'INPUT') {
                    target = target.parentElement;
                }
                if (!target) target = el;

                target.focus();

                if (target.isContentEditable) {
                    const r = document.createRange();
                    r.selectNodeContents(target);
                    const s = window.getSelection();
                    s.removeAllRanges();
                    s.addRange(r);
                    document.execCommand('insertText', false, text);
                    return 'OK contenteditable (' + text.length + ' chars)';
                }

                const proto = target.tagName === 'TEXTAREA'
                    ? HTMLTextAreaElement.prototype
                    : HTMLInputElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                setter.call(target, text);
                target.dispatchEvent(new Event('input', { bubbles: true }));
                target.dispatchEvent(new Event('change', { bubbles: true }));
                return 'OK ' + target.tagName.toLowerCase() + ' (' + text.length + ' chars)';
            } catch (e) {
                return 'ERROR: ' + e.message;
            }
        })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                lastInjectResult = "Inject error: \(error.localizedDescription)"
            } else if let s = result as? String {
                lastInjectResult = s
            }
        }
    }

    private func jsonString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let str = String(data: data, encoding: .utf8),
              str.count >= 2 else { return "\"\"" }
        return String(str.dropFirst().dropLast())
    }

    // MARK: - Cookies

    private func clearCookies() {
        let ds = webView.configuration.websiteDataStore
        let types: Set<String> = [WKWebsiteDataTypeCookies]
        ds.fetchDataRecords(ofTypes: types) { records in
            ds.removeData(ofTypes: types, for: records, completionHandler: {})
        }
    }
}

// MARK: - WebView wrapper

struct WebViewWrapper: UIViewRepresentable {
    let webView: WKWebView
    let onSave: (String) -> Void
    let onPicked: (String, String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let cc = webView.configuration.userContentController
        cc.removeScriptMessageHandler(forName: "save")
        cc.removeScriptMessageHandler(forName: "picked")
        cc.add(context.coordinator, name: "save")
        cc.add(context.coordinator, name: "picked")
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        let cc = uiView.configuration.userContentController
        cc.removeScriptMessageHandler(forName: "save")
        cc.removeScriptMessageHandler(forName: "picked")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSave: onSave, onPicked: onPicked)
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        let onSave: (String) -> Void
        let onPicked: (String, String) -> Void

        init(onSave: @escaping (String) -> Void,
             onPicked: @escaping (String, String) -> Void) {
            self.onSave = onSave
            self.onPicked = onPicked
        }

        func userContentController(_ ucc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "save", let body = message.body as? String {
                onSave(body)
            } else if message.name == "picked",
                      let dict = message.body as? [String: Any],
                      let sel = dict["selector"] as? String {
                onPicked(sel, (dict["desc"] as? String) ?? sel)
            }
        }
    }
}