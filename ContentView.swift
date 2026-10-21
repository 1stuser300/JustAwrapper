import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject private var store = TranscriptStore.shared
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var showTabs = false
    @State private var showSettings = false
    @State private var isPicking = false
    @State private var pickedElementProps: ElementProperties?
    @State private var composerSelector: String = ""
    @State private var lastInjectResult: String = ""
    @State private var sessionToDelete: Session?
    @State private var showAlert = false
    @State private var webView: WKWebView?

    struct ElementProperties {
        var tag: String
        var placeholder: String?
        var ariaLabel: String?
        var hasEditable: Bool
        var indexAmongSimilar: Int
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let webView = webView {
                    WebViewWrapper(webView: webView, onSave: { handleSave($0) }, onPicked: { props in
                        pickedElementProps = props
                        composerSelector = descriptorFor(props)
                        isPicking = false
                        lastInjectResult = "Target: \(props.tag)"
                    })
                }
                
                Divider()
                controls
                statusBar
            }
            
            if store.unlockRequired {
                fakeLockOverlay
            }
            
            if store.privacyMode && !store.unlockRequired {
                Color.black
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation {
                            store.privacyMode = false
                        }
                    }
            }
            
            if showTabs {
                tabsSheet
            }
            
            if showSettings {
                settingsSheet
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.privacyMode)
        .animation(.easeInOut(duration: 0.2), value: store.unlockRequired)
        .onAppear {
            setupWebView()
            loadWebView()
            handleBackgroundEnter()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                if store.privacyMode {
                    // Already covered by blur overlay when inactive
                }
            case .active:
                loadWebView()
            case .inactive:
                // App entering transition state — blur will appear
                break
            @unknown default:
                break
            }
        }
        .onChange(of: store.captureEnabled) { enabled in
            if enabled, let webView = webView {
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
                    .disabled(pickedElementProps == nil || store.latest.isEmpty)
                
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
            Color.black.opacity(0.95).ignoresSafeArea()
            
            VStack(spacing: 24) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                
                Text("Loading... Tap to continue")
                    .foregroundColor(.white)
                    .font(.headline)
                
                Text("\(store.fakeLockTapCount) tap\(store.fakeLockTapCount == 1 ? "" : "s") remaining")
                    .foregroundColor(.gray)
                    .font(.caption)
            }
            .onTapGesture {
                _ = store.tapOnLock()
            }
        }
    }

    // MARK: - Tabs Sheet

    private var tabsSheet: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { showTabs = false }
            
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
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(session.title).fontWeight(.semibold)
                                        Spacer()
                                        Text(formattedDate(session.lastActive))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    HStack(spacing: 8) {
                                        Button("Load") {
                                            store.loadSession(session)
                                            store.selectedSessionId = session.id
                                            loadWebView()
                                            showTabs = false
                                        }.buttonStyle(.borderedProminent).font(.caption)
                                        
                                        Button("Delete") {
                                            sessionToDelete = session
                                            showAlert = true
                                        }.font(.caption).tint(.red)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 12)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(8)
                            }
                        }.padding()
                    }
                }
            }
            .frame(width: min(UIScreen.main.bounds.width * 0.9, 400), height: UIScreen.main.bounds.height * 0.7)
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
                Text("Permanently delete '\(session.title)'? This cannot be undone.")
            }
        }
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { showSettings = false }
            
            VStack(spacing: 16) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    Button("Done") { showSettings = false }
                }.padding(.top, 16).padding()
                
                Toggle("Privacy Mode (App Switcher)", isOn: $store.privacyMode)
                    .toggleStyle(SwitchToggleStyle(tint: .primary))
                    .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Features:").font(.caption).foregroundColor(.secondary)
                    Text("• Captures conversation text").font(.caption)
                    Text("• Excludes from iCloud backups").font(.caption)
                    Text("• Privacy hides preview in app switcher").font(.caption)
                    Text("• Fake lock deters snooping").font(.caption)
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .frame(width: min(UIScreen.main.bounds.width * 0.9, 400), height: UIScreen.main.bounds.height * 0.4)
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

    // MARK: - WebView Setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        
        let captureScript = """
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

        let pickerScript = """
        (function() {
            function findEditor(el) {
                let target = el;
                let depth = 0;
                while (target && !target.isContentEditable && target.tagName !== 'TEXTAREA' && target.tagName !== 'INPUT' && depth < 10) {
                    target = target.parentElement;
                    depth++;
                }
                return target || el;
            }

            function getElementProps(el) {
                const editor = findEditor(el);
                const siblings = Array.from((editor.parentElement || document.body).children)
                    .filter(c => c === editor || c.tagName === editor.tagName);
                const index = siblings.indexOf(editor);
                
                return {
                    tag: editor.tagName.toLowerCase(),
                    placeholder: editor.getAttribute('placeholder') || null,
                    ariaLabel: editor.getAttribute('aria-label') || null,
                    hasEditable: editor.isContentEditable || editor.tagName === 'TEXTAREA' || editor.tagName === 'INPUT',
                    indexAmongSimilar: index
                };
            }

            window.__lumoArmPicker = function(armed) { window.__lumoPickArmed = !!armed; };

            document.addEventListener('click', function(e) {
                if (!window.__lumoPickArmed) return;
                e.preventDefault();
                e.stopPropagation();
                e.stopImmediatePropagation();
                window.__lumoPickArmed = false;
                
                const props = getElementProps(e.target);
                window.webkit.messageHandlers.picked.postMessage(props);
            }, true);
        })();
        """

        controller.addUserScript(WKUserScript(source: captureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: pickerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = controller
        
        webView = WKWebView(frame: .zero, configuration: config)
    }

    private func loadWebView() {
        guard let webView = webView else { return }
        webView.load(URLRequest(url: URL(string: "https://lumo.proton.me")!))
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

    private func descriptorFor(_ props: ElementProperties) -> String {
        var parts: [String] = []
        parts.append(props.tag)
        if let pl = props.placeholder { parts.append(pl) }
        if let al = props.ariaLabel { parts.append("[\(al)]") }
        if props.hasEditable { parts.append("(editable)") }
        return parts.joined(separator: " ")
    }

    private func createSession() {
        store.turnIntoTab {
            showTabs = true
            store.captureEnabled = false
        }
    }

    private func armPicker() {
        isPicking = true
        lastInjectResult = ""
        pickedElementProps = nil
        webView?.evaluateJavaScript("window.__lumoArmPicker(true);") { _, error in
            if let error = error {
                lastInjectResult = "Arm failed: \(error.localizedDescription)"
                isPicking = false
            }
        }
    }

    private func cancelPick() {
        isPicking = false
        webView?.evaluateJavaScript("window.__lumoArmPicker(false);") { _, _ in }
    }

    private func injectTranscript() {
        guard let props = pickedElementProps else { return }
        let text = store.latest
        guard !text.isEmpty else { return }

        let b64 = Data(text.utf8).base64EncodedString()
        let tagJSON = jsonString(props.tag)
        let placeholderJSON = props.placeholder.flatMap(jsonString) ?? "null"
        let ariaLabelJSON = props.ariaLabel.flatMap(jsonString) ?? "null"
        let indexJSON = props.indexAmongSimilar

        let script = """
        (function() {
            try {
                const bin = atob("\(b64)");
                const bytes = new Uint8Array(bin.length);
                for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                const text = new TextDecoder('utf-8').decode(bytes);

                const tag = \(tagJSON);
                const placeholder = \(placeholderJSON);
                const ariaLabel = \(ariaLabelJSON);
                const targetIndex = \(indexJSON);

                const candidates = Array.from(document.getElementsByTagName(tag.toUpperCase()));
                const filtered = candidates.filter(el => {
                    const p = el.getAttribute('placeholder');
                    const a = el.getAttribute('aria-label');
                    if (placeholder && p !== placeholder) return false;
                    if (ariaLabel && a !== ariaLabel) return false;
                    return true;
                });

                if (filtered.length === 0) return 'No element found - re-pick';
                if (targetIndex >= filtered.length) return 'Target gone - re-pick';
                
                const target = filtered[targetIndex];
                if (!target) return 'Target not found';

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

                if (target.tagName === 'TEXTAREA' || target.tagName === 'INPUT') {
                    const proto = target.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                    const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                    setter.call(target, text);
                    target.dispatchEvent(new Event('input', { bubbles: true }));
                    target.dispatchEvent(new Event('change', { bubbles: true }));
                    return 'OK ' + target.tagName.toLowerCase() + ' (' + text.length + ' chars)';
                }

                return 'Cannot inject into ' + target.tagName.toLowerCase();
            } catch (e) {
                return 'ERROR: ' + e.message;
            }
        })();
        """

        webView?.evaluateJavaScript(script) { result, error in
            if let error = error {
                lastInjectResult = "Inject error: \(error.localizedDescription)"
            } else if let s = result as? String {
                lastInjectResult = s
            }
        }
    }

    private func jsonString(_ s: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let str = String(data: data, encoding: .utf8),
              str.count >= 2 else { return nil }
        return String(str.dropFirst().dropLast())
    }

    private func clearCookies() {
        guard let webView = webView else { return }
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
    let onPicked: (ContentView.ElementProperties) -> Void

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
        let onPicked: (ContentView.ElementProperties) -> Void

        init(onSave: @escaping (String) -> Void, onPicked: @escaping (ContentView.ElementProperties) -> Void) {
            self.onSave = onSave
            self.onPicked = onPicked
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "save", let body = message.body as? String {
                onSave(body)
            } else if message.name == "picked", let dict = message.body as? [String: Any] {
                let props = ContentView.ElementProperties(
                    tag: dict["tag"] as? String ?? "unknown",
                    placeholder: dict["placeholder"] as? String,
                    ariaLabel: dict["ariaLabel"] as? String,
                    hasEditable: dict["hasEditable"] as? Bool ?? false,
                    indexAmongSimilar: dict["indexAmongSimilar"] as? Int ?? 0
                )
                onPicked(props)
            }
        }
    }
}