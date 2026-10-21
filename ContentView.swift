import SwiftUI
import WebKit
import UIKit

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
    @State private var coverVisible = false
    @State private var didResignActive = false

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
                    WebViewWrapper(webView: webView,
                                   onSave: { handleSave($0) },
                                   onPicked: { props in
                                       pickedElementProps = props
                                       composerSelector = descriptorFor(props)
                                       isPicking = false
                                       lastInjectResult = "Target: \(descriptorFor(props))"
                                   })
                }

                Divider()
                controls
                statusBar
            }

            // Privacy cover — only while app is leaving the foreground
            if store.privacyMode && coverVisible {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView().tint(.white)
                }
                .transition(.opacity)
            }

            // Fake lock screen
            if store.unlockRequired {
                fakeLockOverlay
            }

            if showTabs {
                tabsSheet
            }

            if showSettings {
                settingsSheet
            }
        }
        .animation(.easeInOut(duration: 0.15), value: coverVisible)
        .animation(.easeInOut(duration: 0.15), value: store.unlockRequired)
        .onAppear {
            setupWebView()
            loadWebView()
            store.startUnlock()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            didResignActive = true
            if store.privacyMode {
                coverVisible = true
            }
            _ = store.requestBackgroundTime()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            coverVisible = false
            if didResignActive {
                store.startUnlock()
                didResignActive = false
            }
        }
        .onChange(of: store.captureEnabled) { enabled in
            if enabled, let webView = webView {
                webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                    if let s = value as? String { store.save(s) }
                }
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(isPicking ? "Cancel Pick" : "Pick Target") {
                    isPicking ? cancelPick() : armPicker()
                }
                .buttonStyle(.bordered)
                .font(.caption)

                Button("Insert Transcript") { injectTranscript() }
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
                    .disabled(pickedElementProps == nil || store.latest.isEmpty)

                Button("Turn Into Tab") { createSession() }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(store.latest.isEmpty)

                Button("Cookies") { clearCookies() }
                    .buttonStyle(.bordered)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                Button("Tabs") { showTabs = true }
                    .buttonStyle(.bordered)
                    .font(.caption)

                Button("Settings") { showSettings = true }
                    .buttonStyle(.bordered)
                    .font(.caption)

                Button(store.captureEnabled ? "Pause" : "Resume") {
                    store.captureEnabled.toggle()
                }
                .buttonStyle(.bordered)
                .font(.caption)

                Button("Clear") {
                    store.captureEnabled = false
                    store.clear()
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .tint(.red)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Fake lock

    private var fakeLockOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)

                Text("Loading… tap to continue")
                    .foregroundColor(.white)
                    .font(.headline)

                Text("\(store.fakeLockTapCount) tap\(store.fakeLockTapCount == 1 ? "" : "s") remaining")
                    .foregroundColor(.gray)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            _ = store.tapOnLock()
        }
    }

    // MARK: - Tabs sheet

    private var tabsSheet: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { showTabs = false }

            VStack(spacing: 0) {
                HStack {
                    Text("Saved Chats").font(.headline)
                    Spacer()
                    Button("Done") { showTabs = false }
                }
                .padding()

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
                                            showTabs = false
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .font(.caption)

                                        Button("Delete") {
                                            sessionToDelete = session
                                            showAlert = true
                                        }
                                        .font(.caption)
                                        .tint(.red)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 12)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(8)
                            }
                        }
                        .padding()
                    }
                }
            }
            .frame(width: min(UIScreen.main.bounds.width * 0.9, 420),
                   height: UIScreen.main.bounds.height * 0.7)
            .background(Color.black.opacity(0.95))
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

    // MARK: - Settings sheet

    private var settingsSheet: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { showSettings = false }

            VStack(spacing: 16) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    Button("Done") { showSettings = false }
                }
                .padding(.top, 16)
                .padding()

                Toggle("Privacy Cover (App Switcher)", isOn: $store.privacyMode)
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Features:").font(.caption).foregroundColor(.secondary)
                    Text("• Captures conversation text").font(.caption)
                    Text("• Excludes from iCloud backups").font(.caption)
                    Text("• Privacy cover hides preview when leaving app").font(.caption)
                    Text("• Fake lock deters snooping").font(.caption)
                }
                .padding(.horizontal)

                Spacer()
            }
            .frame(width: min(UIScreen.main.bounds.width * 0.9, 420),
                   height: UIScreen.main.bounds.height * 0.42)
            .background(Color.black.opacity(0.95))
            .cornerRadius(12)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Capture: \(store.captureEnabled ? "ON" : "PAUSED")   Saves: \(store.saveCount)")

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

    // MARK: - WebView setup

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
            const schedule = () => { clearTimeout(t); t = setTimeout(send, 1200); };
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
            function isEditable(el) {
                return el.isContentEditable || el.tagName === 'TEXTAREA' || el.tagName === 'INPUT';
            }

            function findEditor(el) {
                let target = el;
                let depth = 0;
                while (target && !isEditable(target) && depth < 12) {
                    target = target.parentElement;
                    depth++;
                }
                return target || el;
            }

            function candidatesFor(editor) {
                const all = Array.from(document.getElementsByTagName(editor.tagName));
                const editorIsEditable = isEditable(editor);
                return all.filter(function(el) {
                    if (editorIsEditable && !isEditable(el)) return false;
                    if (el.getAttribute('placeholder') !== editor.getAttribute('placeholder')) return false;
                    if (el.getAttribute('aria-label') !== editor.getAttribute('aria-label')) return false;
                    return true;
                });
            }

            window.__lumoArmPicker = function(armed) { window.__lumoPickArmed = !!armed; };

            document.addEventListener('click', function(e) {
                if (!window.__lumoPickArmed) return;
                e.preventDefault();
                e.stopPropagation();
                e.stopImmediatePropagation();
                window.__lumoPickArmed = false;

                const editor = findEditor(e.target);
                const list = candidatesFor(editor);
                const idx = list.indexOf(editor);

                window.webkit.messageHandlers.picked.postMessage({
                    tag: editor.tagName.toLowerCase(),
                    placeholder: editor.getAttribute('placeholder'),
                    ariaLabel: editor.getAttribute('aria-label'),
                    hasEditable: isEditable(editor),
                    indexAmongSimilar: idx < 0 ? 0 : idx
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

    private func descriptorFor(_ props: ElementProperties) -> String {
        var parts: [String] = [props.tag]
        if let pl = props.placeholder, !pl.isEmpty { parts.append("\"\(pl)\"") }
        if let al = props.ariaLabel, !al.isEmpty { parts.append("[\(al)]") }
        parts.append("#\(props.indexAmongSimilar)")
        return parts.joined(separator: " ")
    }

    private func handleSave(_ payload: String) {
        if let data = payload.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = obj["text"] as? String {
            store.save(text)
        } else {
            store.save(payload)
        }
    }

    private func createSession() {
        store.turnIntoTab {
            showTabs = true
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
        let placeholderJSON = props.placeholder.map { jsonString($0) } ?? "null"
        let ariaLabelJSON = props.ariaLabel.map { jsonString($0) } ?? "null"
        let indexJSON = String(props.indexAmongSimilar)
        let editableJSON = props.hasEditable ? "true" : "false"

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
                const requireEditable = \(editableJSON);

                function isEditable(el) {
                    return el.isContentEditable || el.tagName === 'TEXTAREA' || el.tagName === 'INPUT';
                }

                const all = Array.from(document.getElementsByTagName(tag.toUpperCase()));
                const matches = all.filter(function(el) {
                    if (requireEditable && !isEditable(el)) return false;
                    if (el.getAttribute('placeholder') !== placeholder) return false;
                    if (el.getAttribute('aria-label') !== ariaLabel) return false;
                    return true;
                });

                if (matches.length === 0) return 'No matching element - re-pick';
                if (targetIndex >= matches.length) return 'Target moved - re-pick';

                const target = matches[targetIndex];
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
                    const proto = target.tagName === 'TEXTAREA'
                        ? HTMLTextAreaElement.prototype
                        : HTMLInputElement.prototype;
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

    private func jsonString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let str = String(data: data, encoding: .utf8),
              str.count >= 2 else { return "\"\"" }
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

        init(onSave: @escaping (String) -> Void,
             onPicked: @escaping (ContentView.ElementProperties) -> Void) {
            self.onSave = onSave
            self.onPicked = onPicked
        }

        func userContentController(_ ucc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
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