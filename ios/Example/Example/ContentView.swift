import PlugchoiceSDK
import SwiftUI
import UIKit

/// Opens Link with an action. The client secret comes from a pasted
/// `cs_test_…`, or from a URL the app POSTs the action to (your server's
/// endpoint, which calls `POST /sdk/v1/client-sessions` scoped to it). The
/// host field points a Debug build at a hosted UI served from your computer.
struct ContentView: View {
    enum SecretSource: String, CaseIterable, Identifiable {
        case url
        case pasted
        var id: String { rawValue }
        var label: String { self == .url ? "From a URL" : "Pasted" }
    }

    enum ActionKind: String, CaseIterable, Identifiable {
        case add, setup, reconnect, custom
        var id: String { rawValue }
    }

    @AppStorage("secretSource") private var secretSource = SecretSource.url
    @AppStorage("secretURL") private var secretURL = ""
    @AppStorage("clientSecret") private var pastedSecret = ""
    @AppStorage("action") private var actionKind = ActionKind.add
    @AppStorage("customAction") private var customAction = ""
    @AppStorage("chargerId") private var chargerId = ""
    @AppStorage("siteId") private var siteId = ""
    @AppStorage("linkHost") private var hostText = ""
    @State private var lastResult = "None yet"
    @State private var inputError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Source", selection: $secretSource) {
                        ForEach(SecretSource.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch secretSource {
                    case .url:
                        TextField("http://192.168.1.20:3000/client-secret", text: $secretURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    case .pasted:
                        TextField("cs_test_…", text: $pastedSecret, axis: .vertical)
                            .lineLimit(1...3)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Client secret")
                } footer: {
                    Text(secretSource == .url
                        ? "Gets { action, charger_id, site_id } POSTed whenever the page needs a secret. The answer is JSON with client_secret (as from POST /sdk/v1/client-sessions) or the secret as plain text."
                        : "Used as is, every time the page asks. A secret expires after an hour.")
                }

                Section("Action") {
                    Picker("Action", selection: $actionKind) {
                        ForEach(ActionKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if actionKind == .custom {
                        TextField("Action name", text: $customAction)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if actionKind == .add {
                        TextField("Site id (optional)", text: $siteId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        TextField(actionKind == .custom ? "Charger id (optional)" : "Charger id", text: $chargerId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    TextField("http://192.168.1.20:4173", text: $hostText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Host (optional)")
                } footer: {
                    Text("Loads the page from this scheme://host[:port] instead of connect.plugchoice.com, for example from your computer. Debug builds only.")
                }

                Section {
                    if let inputError {
                        Text(inputError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button("Open", action: open)
                }

                Section("Last result") {
                    Text(lastResult)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }

                Section {
                    LabeledContent("SDK", value: Plugchoice.sdkVersion)
                    LabeledContent("Transports", value: Plugchoice.transports().joined(separator: ", "))
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                }
            }
            .navigationTitle("Plugchoice Example")
        }
        .task {
            // Testing aid: `-autoOpen YES` opens straight away with the
            // fields as they are; `-secretSource url|pasted`, `-secretURL`,
            // `-clientSecret`, `-action`, `-customAction`, `-chargerId`,
            // `-siteId` and `-linkHost` fill them.
            if UserDefaults.standard.bool(forKey: "autoOpen") {
                try? await Task.sleep(nanoseconds: 500_000_000)
                open()
            }
        }
    }

    private func open() {
        let host = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty, !Self.isOrigin(host) {
            inputError = "The host must be scheme://host[:port], e.g. http://192.168.1.20:4173."
            return
        }
        guard let fetch: Plugchoice.FetchClientSecret = secretFetcher() else { return }
        guard let action = linkAction() else { return }
        guard let presenter = Self.topViewController() else {
            inputError = "No window to present from."
            return
        }
        inputError = nil
        // An app makes one Plugchoice for its lifetime; the Example makes one
        // per open because its fields change.
        let plugchoice = Plugchoice(fetchClientSecret: fetch, options: .init(hostOverride: host.isEmpty ? nil : host))
        plugchoice.link.present(action, from: presenter) { result in
            lastResult = "at: \(Date().formatted(date: .omitted, time: .standard))\n\(result)"
            print("[Example] result\n\(lastResult)")
        }
    }

    private func secretFetcher() -> Plugchoice.FetchClientSecret? {
        switch secretSource {
        case .pasted:
            let secret = pastedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else {
                inputError = "Paste a client secret (cs_test_…)."
                return nil
            }
            return { _ in secret }
        case .url:
            guard let url = URL(string: secretURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil
            else {
                inputError = "Enter the http(s) URL of an endpoint that answers with a client secret."
                return nil
            }
            return { action in try await Self.fetchSecret(from: url, for: action) }
        }
    }

    private func linkAction() -> LinkAction? {
        let chargerId = chargerId.trimmingCharacters(in: .whitespacesAndNewlines)
        let siteId = siteId.trimmingCharacters(in: .whitespacesAndNewlines)
        switch actionKind {
        case .add:
            return .addCharger(siteId: siteId.isEmpty ? nil : siteId)
        case .custom:
            let name = customAction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                inputError = "Enter the action's name."
                return nil
            }
            return .custom(name, chargerId: chargerId.isEmpty ? nil : chargerId)
        case .setup, .reconnect:
            guard !chargerId.isEmpty else {
                inputError = "Enter the charger's id."
                return nil
            }
            return actionKind == .setup ? .setup(chargerId: chargerId) : .reconnect(chargerId: chargerId)
        }
    }

    /// POSTs the action to `url`, for a secret scoped to it; the answer is
    /// JSON with `client_secret` (or `clientSecret`), or the secret as plain
    /// text.
    private static func fetchSecret(from url: URL, for action: LinkAction) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["action": action.action]
        body["charger_id"] = action.chargerId
        body["site_id"] = action.siteId
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let secret = (object["client_secret"] ?? object["clientSecret"]) as? String {
            return secret
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isOrigin(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil
        else { return false }
        return true
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
