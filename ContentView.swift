import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject private var store = TranscriptStore.shared
    
    @State private var showTabs = false
    @State private var showSettings = false
    @State private var isPicking = false
    @State private var composerSelector: String = ""
    @State private var lastInjectResult: String = ""
    @State private var sessionToDelete: Session?
    @State private var showAlert = false
    @State private var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        
        controller.addUserScript(WKUserScript(source: captureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: pickerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = controller
        return WKWebView(frame: .zero, configuration: config)
    }()

    private let captureScript = """
    (function() {
        let t;
        const send = () => {
            const txt = document.body ? document.body.innerText : '';
            const url = window.location.href;
            if (txt && txt.length > 0) {
                window.webkit.messageHandlers.save.postMessage(JSON.stringify({ text: txt, url: url }));
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

    private let pickerScript = """
    (function() {
        function cssPath(el) {
            if (!el || el.nodeType !== 1) return null;
            let path = [];
            let cur = el;
            while (cur && cur.nodeType === 1 && cur !== document.documentElement) {
                let part = cur.tagName.toLowerCase();
                if (cur.id) {
                    path.unshift('#' + CSS.escape(cur.id));
                    break;
                }
                const cls = (typeof cur.className === 'string' && cur.className.trim())
                    ? cur.className.trim().split(/\\s+/).filter(Boolean).slice(0, 2).map(function(c) { return CSS.escape(c); }).join('.')
                    : '';
                if (cls) part += '.' + cls;
                const parent = cur.parentElement;
                if (parent) {
                    const sibs = Array.prototype.filter.call(parent.children, function(c) {
                        return c.tagName === cur.tagName;
                    });
                    if (sibs.length > 1) {
                        part += ':nth-of-type(' + (sibs.indexOf(cur) + 1) + ')';
                    }
                }
                path.unshift(part);
                cur = cur.parentElement;
            }
            return path.join(' > ');
        }

        function findBestEditable(el) {
            let target = el;
            while (target && !target.isContentEditable && target.tagName !== 'TEXTAREA' && target.tagName !== 'INPUT') {
                target = target.parentElement;
            }
            return target || el;
        }

        window.__lumoArmPicker = function(armed) { window.__lumoPickArmed = !!armed; };

        document.addEventListener('click', function(e) {
            if (!window.__lumoPickArmed) return;
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();
            window.__lumoPickArmed = false;

            const el = findBestEditable(e.target);
            const path = cssPath(el);
            const desc = el.tagName.toLowerCase() + (el.isContentEditable ? ' (contenteditable)' : '');
            window.webkit.messageHandlers.picked.postMessage({ selector: path || '', desc: desc });
        }, true);
    })();
    """

    var body: some View {
        ZStack {
            ZStack {
                VStack(spacing: 0) {
                    WebViewWrapper(webView: webView, onSave: { handleSave($0) }, onPicked: { sel, desc in
                        composerSelector = sel
                        isPicking = false
                        lastInjectResult = "Target: \(desc)"
                    })
                    
                    Divider()
                    controls
                    statusBar
                }
                
                // Fake lock screen
                if store.unlockRequired {
                    fakeLockOverlay
                }
            }
            
            // Privacy mode overlay (only active in app switcher)
            if store.privacyMode && !store.unlockRequired {
                Color.black
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        store.privacyMode = false
                    }
            }
            
            // Tabs sheet
            if showTabs {
                tabsSheet
            }
            
            // Settings sheet
            if showSettings {
                settingsSheet
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.privacyMode)
        .onAppear {
            loadWebViewIfNeeded()
            handleBackgroundEnter()
        }
        .onChange(of: store.captureEnabled) { enabled in
            if enabled {
                webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                    if let s = value as? String { store.save(s) }
                }
            }
        }
        .onChange(of: store.unlockRequired) { unlocked in
            if unlocked {
                store.startUnlock()
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(isPicking ? "Cancel Pick" : "Pick Target") {
                    isPicking ? cancelPick() : armPicker()
                }.buttonStyle(.bordered).font(.caption)
                
                Button("Insert Transcript") { injectTranscript() }
                    .buttonStyle(.borderedProminent).font(.caption)
                    .disabled(composerSelector.isEmpty || store.latest.isEmpty)
                
                Button("Turn Into Tab") { createSession() }
                    .buttonStyle(.bordered).font(.caption).disabled(store.latest.isEmpty)
                
                Button("Cookies") { clearCookies() }.buttonStyle(.bordered).font(.caption)
            }
            
            HStack(spacing: 8) {
                Button("Tabs") { showTabs = true }.buttonStyle(.bordered).font(.caption)
                
                Button("Settings") { showSettings = true }.buttonStyle(.bordered).font(.caption)
                
                Button(store.captureEnabled ? "Pause" : "Resume") {
                    store.captureEnabled.toggle()
                }.buttonStyle(.bordered).font(.caption)
                
                Button("Clear") {
                    store.captureEnabled = false
                    store.clear()
                }.buttonStyle(.bordered).font(.caption).tint(.red)
            }
        }.padding(.horizontal).padding(.top, 8)
    }

    // MARK: - Fake Lock Screen

    private var fakeLockOverlay: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(2.0)
                
                Text("Taps remaining: \(store.fakeLockTapCount)")
                    .foregroundColor(.white)
                    .font(.caption)
                
                Text("Tap anywhere to continue")
                    .foregroundColor(.gray)
                    .font(.caption)
            }
            .onTapGesture {
                if store.tapOnLock() {
                    // Unlocked
                }
            }
        }
    }

    // MARK: - Tabs Sheet

    private var tabsSheet: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture {
                showTabs = false
            }
            
            VStack(spacing: 0) {
                HStack {
                    Text("Saved Chats").font(.headline)
                    Spacer()
                    Button("Done") { showTabs = false }
                }.padding()
                
                if store.sessions.isEmpty {
                    Text("(no saved chats yet)\nTap 'Turn Into Tab' to save current chat")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(store.sessions) { session in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(session.title).fontWeight(.semibold)
                                        Text(formattedDate(session.lastActive)).font(.caption).foregroundColor(.secondary)
                                    }.spacer()
                                    
                                    Button("Load") {
                                        store.loadSession(session)
                                        store.selectedSessionId = session.id
                                        loadWebViewForSession(session)
                                        showTabs = false
                                    }.buttonStyle(.borderedProminent).font(.caption)
                                    
                                    Button("Delete") {
                                        sessionToDelete = session
                                        showAlert = true
                                    }.font(.caption).tint(.red)
                                }
                                .padding(.horizontal).padding(.vertical, 8)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(8)
                            }
                        }.padding()
                    }
                }
            }
            .frame(width: UIScreen.main.bounds.width * 0.85, height: UIScreen.main.bounds.height * 0.7)
            .background(Color.black.opacity(0.9))
            .cornerRadius(12)
        }
        .onAppear { store.loadSessions() }
        .alert("Delete Session?", isPresented: $showAlert) {
            Button("Cancel", role: .cancel) { sessionToDelete = nil }
            Button("Delete", role: .destructive) {
                if let session = sessionToDelete {
                    store.deleteSession(id: session.id)
                    sessionToDelete = nil
                }
            }
        } message: {
            if let session = sessionToDelete {
                Text("This permanently deletes '\(session.title)' and its transcript. This cannot be undone.")
            }
        }
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture {
                showSettings = false
            }
            
            VStack(spacing: 20) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    Button("Done") { showSettings = false }
                }.padding(.top, 20).padding()
                
                Toggle("Privacy Mode (App Switcher)", isOn: $store.privacyMode)
                    .toggleStyle(SwitchToggleStyle(tint: .primary))
                    .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("About"):
                        Text("- Captures conversation text")
                        Text("- Excludes from iCloud backups")
                        Text("- Privacy mode hides preview in app switcher")
                        Text("- Fake lock screen deters snooping")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                
                Spacer()
            }
            .frame(width: UIScreen.main.bounds.width * 0.85, height: UIScreen.main.bounds.height * 0.5)
            .background(Color.black.opacity(0.9))
            .cornerRadius(12)
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Capture: \(store.captureEnabled ? "ON" : "PAUSED")   Saves: \(store.saveCount)")
            if !composerSelector.isEmpty {
                Text("Target: \(composerSelector)").lineLimit(2).truncationMode(.middle)
            }
            if !lastInjectResult.isEmpty {
                Text(lastInjectResult)
            }
            if !store.lastError.isEmpty {
                Text("ERROR: \(store.lastError)").foregroundColor(.red)
            }
            Text(store.storagePath).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 9)).foregroundColor(.gray)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func handleBackgroundEnter() {
        store.startUnlock()
        _ = store.requestBackgroundTime()
    }

    private func handleSave(_ json: String) {
        guard let data = json.data(using: .utf8),
              let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = jsonDict["text"] as? String,
              let url = jsonDict["url"] as? String else {
            store.save(json)
            return
        }
        
        if let sessionId = store.selectedSessionId {
            store.recordWebViewURL(sessionId: sessionId, url: url)
        }
        store.save(text)
    }

    private func createSession() {
        store.turnIntoTab {
            showTabs = true
            store.captureEnabled = false
        }
    }

    private func loadWebViewIfNeeded() {
        let url = store.webViewURLs[store.selectedSessionId ?? "default"] ?? "https://lumo.proton.me"
        webView.load(URLRequest(url: URL(string: url)!))
    }

    private func loadWebViewForSession(_ session: Session) {
        let url = store.webViewURLs[session.id] ?? "https://lumo.proton.me"
        webView.load(URLRequest(url: URL(string: url)!))
        store.captureEnabled = true
    }

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

                let el = document.querySelector(\(selJSON));
                if (!el) return 'TARGET NOT FOUND - re-pick';

                let target = el;
                while (target && !target.isContentEditable && target.tagName !== 'TEXTAREA' && target.tagName !== 'INPUT') {
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

                const proto = target.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
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

        init(onSave: @escaping (String) -> Void, onPicked: @escaping (String, String) -> Void) {
            self.onSave = onSave
            self.onPicked = onPicked
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "save", let body = message.body as? String {
                onSave(body)
            } else if message.name == "picked", let dict = message.body as? [String: Any], let sel = dict["selector"] as? String {
                onPicked(sel, (dict["desc"] as? String) ?? sel)
            }
        }
    }
}