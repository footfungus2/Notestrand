import AuthenticationServices
import SwiftUI
import UIKit
import CryptoKit
import Foundation
import Network

/// "Sign in with ChatGPT" plan usage, following OpenAI's open-source flow
/// (developers.openai.com/siwc/token-sharing-open-source): OAuth + PKCE with a loopback callback,
/// tokens kept in the Keychain, access token refreshed before it expires.
@MainActor
final class ChatGPTAuth: ObservableObject {
    static let shared = ChatGPTAuth()

    struct Credentials: Codable {
        var email: String?
        var subject: String
        var clientID: String
        var idToken: String
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var scopes: [String]
    }

    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let planScope = "chatgpt.tokens.use.direct"

    @Published private(set) var credentials: Credentials?
    @Published var signingIn = false
    /// Signing in through Reynard: waiting for the learner to finish there and come back.
    @Published private(set) var waitingForReynard = false
    private var callback: LoopbackCallback?
    private var expectedState: String?

    enum Browser { case builtIn, reynard }
    private var refreshing: Task<Credentials, Error>?
    private var session: ASWebAuthenticationSession?
    private var anchor: AnchorProvider?

    init() {
        credentials = KeyStore.get(.chatgpt).flatMap { try? JSONDecoder().decode(Credentials.self, from: Data($0.utf8)) }
    }

    /// Stable per-install host id; the issued client is bound to it.
    private var hostID: String {
        if let id = UserDefaults.standard.string(forKey: "chatgptHostID") { return id }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(id, forKey: "chatgptHostID")
        return id
    }

    /// The issued client id survives sign-out so the next sign-in reuses the registration.
    private var savedClientID: String? {
        get { UserDefaults.standard.string(forKey: "chatgptClientID") }
        set { UserDefaults.standard.set(newValue, forKey: "chatgptClientID") }
    }

    private func save(_ c: Credentials?) {
        credentials = c
        KeyStore.set(.chatgpt, c.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    // MARK: sign in

    func signIn(with browser: Browser = .builtIn) async throws {
        signingIn = true
        defer { signingIn = false }
        let callback = try LoopbackCallback()
        defer { callback.stop() }
        let port = try await callback.start()
        let redirect = "http://127.0.0.1:\(port)/auth/callback"

        let state = Self.random(), nonce = Self.random(), verifier = Self.random(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let existingClient = savedClientID
        var params: [(String, String)] = [
            ("client_id", existingClient ?? "dynamic_agent_client"),
            ("ext_agent_host_id", hostID),
            ("response_type", "code"),
            ("redirect_uri", redirect),
            ("scope", "openid profile email offline_access resource.invoke \(Self.planScope)"),
            ("resource", Self.resource),
            ("state", state), ("nonce", nonce),
            ("code_challenge_method", "S256"), ("code_challenge", challenge),
        ]
        if existingClient == nil { params.append(("agent_name_hint", "Notestrand")) }
        if let c = credentials, c.clientID == existingClient {
            params.append(("id_token_hint", c.idToken))
            if let email = c.email { params.append(("login_hint", email)) }
        }
        var comps = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }

        self.callback = callback
        expectedState = state
        defer { self.callback = nil; expectedState = nil; waitingForReynard = false }
        var auth: ASWebAuthenticationSession?
        defer { auth?.cancel(); session = nil }
        var background = UIBackgroundTaskIdentifier.invalid
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }

        switch browser {
        case .builtIn:
            // The sign-in page redirects to our loopback listener; the sheet is closed once it has the code.
            let sheet = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: nil) { _, _ in callback.cancel() }
            let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }.first
            anchor = AnchorProvider(window: window ?? ASPresentationAnchor())
            sheet.presentationContextProvider = anchor
            sheet.prefersEphemeralWebBrowserSession = false // reuse an existing chatgpt.com login
            session = sheet
            auth = sheet
            sheet.start()
        case .reynard:
            // iOS 15's WebKit is too old for ChatGPT's login page; Reynard runs Firefox's engine and redirects to the same listener.
            guard await UIApplication.shared.open(Self.reynardURL(comps.url!)) else {
                throw AuthError("Reynard isn't installed. Get it from github.com/minh-ton/reynard-browser, or use Continue with ChatGPT.")
            }
            waitingForReynard = true
            // Keeps the listener alive briefly while Notestrand is in the background; after that, the pasted link still works.
            background = UIApplication.shared.beginBackgroundTask(withName: "ChatGPT sign-in") {
                UIApplication.shared.endBackgroundTask(background)
                background = .invalid
            }
        }
        // Anything on the iPad can hit the loopback port; ignore requests without our state instead of failing the sign-in.
        var query = try await callback.result()
        while query["state"] != state { query = try await callback.result() }

        if query["error"] == "access_denied" { throw AuthError("ChatGPT plan use wasn't allowed. Try again and approve the permission.") }
        if let e = query["error"] { throw AuthError("ChatGPT sign-in failed: \(e)") }
        guard let code = query["code"] else { throw AuthError("ChatGPT didn't return a sign-in code.") }
        // New registrations return the issued client id; reauthorization must keep the one we sent.
        let clientID: String
        if let existingClient {
            if let returned = query["client_id"], returned != existingClient { throw AuthError("ChatGPT returned a different app registration. Please try again.") }
            clientID = existingClient
        } else {
            guard let issued = query["client_id"], issued != "dynamic_agent_client" else { throw AuthError("ChatGPT registration didn't complete. Please try again.") }
            clientID = issued
            savedClientID = issued
        }

        let token = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": Self.resource,
        ])
        let creds = try credentials(from: token, clientID: clientID, nonce: nonce, previous: nil)
        if let old = credentials, old.clientID == clientID, old.subject != creds.subject {
            throw AuthError("That's a different ChatGPT account than the one registered here.")
        }
        save(creds)
    }

    /// Reynard's address after signing in, pasted back in case Notestrand was paused and missed the redirect.
    func finish(withLink text: String) throws {
        let items = URLComponents(string: text.trimmed)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let callback, let expectedState, query["state"] == expectedState, query["code"] != nil || query["error"] != nil else {
            throw AuthError("That isn't the link from this sign-in. After signing in, copy the whole address from Reynard's address bar.")
        }
        callback.finish(.success(query))
    }

    func cancelSignIn() { callback?.cancel() }

    nonisolated static func reynardURL(_ page: URL) -> URL { appLink("reynard://open", carrying: page) }

    func signOut() async {
        if let c = credentials {
            // Best effort: revoke the renewable session, then forget the tokens either way.
            if let config = try? await URLSession.shared.data(from: URL(string: "\(Self.issuer)/.well-known/openid-configuration")!).0,
               let endpoint = ((try? JSONSerialization.jsonObject(with: config)) as? [String: Any])?["revocation_endpoint"] as? String,
               let url = URL(string: endpoint) {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = Self.form(["token": c.refreshToken, "token_type_hint": "refresh_token", "client_id": c.clientID])
                _ = try? await URLSession.shared.data(for: req)
            }
        }
        save(nil)
    }

    // MARK: tokens

    /// A valid access token, refreshed when it's within two minutes of expiry.
    func accessToken() async throws -> String {
        guard let c = credentials else { throw AuthError("Sign in with ChatGPT in Settings to use your ChatGPT plan.") }
        if c.expiresAt.timeIntervalSinceNow > 120 { return c.accessToken }
        return try await refresh().accessToken
    }

    /// One refresh at a time: refresh tokens rotate, so parallel refreshes would invalidate each other.
    func refresh() async throws -> Credentials {
        if let running = refreshing { return try await running.value }
        guard let c = credentials else { throw AuthError("Sign in with ChatGPT in Settings to use your ChatGPT plan.") }
        let task = Task { () throws -> Credentials in
            let token = try await tokenRequest([
                "grant_type": "refresh_token", "client_id": c.clientID,
                "refresh_token": c.refreshToken, "resource": Self.resource,
            ])
            return try credentials(from: token, clientID: c.clientID, nonce: nil, previous: c)
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            save(fresh)
            return fresh
        } catch let e as AuthError where e.signInAgain {
            save(nil)
            throw e
        }
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(fields)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let code = json["error"] as? String ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            // invalid_grant on refresh means the session ended (revoked, expired after 30 days, or disconnected in ChatGPT).
            throw AuthError(code == "invalid_grant" ? "Your ChatGPT sign-in has ended. Sign in again in Settings." : "ChatGPT sign-in failed: \(code)",
                            signInAgain: code == "invalid_grant")
        }
        return json
    }

    private func credentials(from json: [String: Any], clientID: String, nonce: String?, previous: Credentials?) throws -> Credentials {
        guard let access = json["access_token"] as? String else { throw AuthError("ChatGPT didn't return an access token.") }
        let scopes = (json["scope"] as? String)?.split(separator: " ").map(String.init) ?? previous?.scopes ?? []
        guard scopes.contains(Self.planScope) else {
            throw AuthError("ChatGPT plan use isn't enabled for this app. Sign in again and allow it, or check ChatGPT Settings → Apps.")
        }
        // shortcut: the ID token arrives straight from OpenAI's token endpoint over TLS, which OIDC Core §3.1.3.7 accepts
        // in place of a signature check; claims are still checked. Verify against the JWKS if tokens ever come from elsewhere.
        let idToken = json["id_token"] as? String ?? previous?.idToken ?? ""
        let claims = Self.claims(idToken)
        if nonce != nil || json["id_token"] != nil {
            guard claims["iss"] as? String == Self.issuer else { throw AuthError("ChatGPT returned an unexpected identity issuer.") }
            let aud = claims["aud"]
            guard (aud as? String) == clientID || (aud as? [String])?.contains(clientID) == true else { throw AuthError("ChatGPT identity was issued for a different app.") }
            if let exp = claims["exp"] as? Double, Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(-300) { throw AuthError("ChatGPT identity has expired. Please sign in again.") }
            if let nonce, claims["nonce"] as? String != nonce { throw AuthError("Sign-in was interrupted (nonce mismatch). Please try again.") }
        }
        guard let subject = claims["sub"] as? String ?? previous?.subject else { throw AuthError("ChatGPT didn't return a verifiable identity. Please sign in again.") }
        if let previous, previous.subject != subject { throw AuthError("The refreshed identity doesn't match this account. Please sign in again.", signInAgain: true) }
        return Credentials(
            email: claims["email"] as? String ?? previous?.email, subject: subject, clientID: clientID, idToken: idToken,
            accessToken: access, refreshToken: json["refresh_token"] as? String ?? previous?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600), scopes: scopes)
    }

    // MARK: helpers

    nonisolated static func claims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let data = Data(base64URL: String(parts[1])) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    nonisolated static func random(_ bytes: Int = 32) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).base64URL
    }

    nonisolated static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }
}

final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: ASPresentationAnchor
    init(window: ASPresentationAnchor) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}

struct AuthError: LocalizedError {
    let message: String
    var signInAgain = false
    init(_ m: String, signInAgain: Bool = false) { message = m; self.signInAgain = signInAgain }
    var errorDescription: String? { message }
}

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect's query string.
/// Unchecked Sendable: its mutable state is only touched on `queue` (startWaiter is set before the listener starts).
final class LoopbackCallback: @unchecked Sendable {
    private let listener: NWListener
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private let queue = DispatchQueue(label: "chatgpt.loopback")

    init() throws {
        let params = NWParameters.tcp
        // Loopback only: nothing else on the network can reach the callback.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    private var startWaiter: CheckedContinuation<UInt16, Error>?

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            startWaiter = cont
            listener.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    /// Runs on `queue`; resumes the start continuation exactly once.
    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue { startWaiter?.resume(returning: port); startWaiter = nil }
        case .failed(let e):
            startWaiter?.resume(throwing: e); startWaiter = nil
        default: break
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // "GET /auth/callback?code=...&state=... HTTP/1.1"
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let ok = target.hasPrefix("/auth/callback")
            let body = ok ? "<html><body style=\"font-family:-apple-system;text-align:center;padding:40px\"><h2>Signed in</h2><p><a href=\"notestrand://\">Return to Notestrand</a></p></body></html>" : "Not found"
            let response = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            guard ok else { return }
            let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            self?.finish(.success(Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })))
        }
    }

    func finish(_ r: Result<[String: String], Error>) {
        queue.async {
            if let w = self.waiter { self.waiter = nil; w.resume(with: r) } else if self.pending == nil { self.pending = r }
        }
    }

    /// Called when the browser sheet closes; ignored if the redirect already arrived.
    func cancel() { finish(.failure(AuthError("Sign-in was cancelled."))) }

    func result() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let p = self.pending { self.pending = nil; cont.resume(with: p) } else { self.waiter = cont }
            }
        }
    }

    func stop() { listener.cancel() }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        self.init(base64Encoded: b)
    }
}

/// A second way to sign in, for when the built-in sheet's WebKit is too old for ChatGPT's login page.
struct ReynardSignIn: View {
    @ObservedObject var chatgpt: ChatGPTAuth
    var onError: (String?) -> Void

    var body: some View {
        if chatgpt.waitingForReynard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in in Reynard, then come back here. If nothing happens, copy the whole address from Reynard's address bar and tap Paste sign-in link.")
                    .font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Paste sign-in link") {
                        do { try chatgpt.finish(withLink: UIPasteboard.general.string ?? ""); onError(nil) } catch { onError(error.localizedDescription) }
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { chatgpt.cancelSignIn() }
                }
                .buttonStyle(.borderless) // two buttons in one list row
                .frame(minHeight: 44)
            }
        } else {
            Button("Sign in with Reynard instead") {
                Task {
                    do { try await chatgpt.signIn(with: .reynard); onError(nil) } catch { onError(error.localizedDescription) }
                }
            }
            .disabled(chatgpt.signingIn)
            .frame(minHeight: 44)
        }
    }
}

/// `base?url=<url>`, the form Reynard, TrollStore and SideStore read.
func appLink(_ base: String, carrying url: URL) -> URL {
    var c = URLComponents(string: base)!
    // Escape everything but unreserved characters, or the inner URL's own & and ? would split it.
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    c.percentEncodedQuery = "url=" + (url.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    return c.url!
}

/// Opens a web link in Reynard when the learner chose it in Settings, else (or if Reynard is missing) in Safari.
@MainActor func openLink(_ url: URL) {
    guard Prefs.d.bool(forKey: Prefs.reynardLinks) else { UIApplication.shared.open(url); return }
    UIApplication.shared.open(ChatGPTAuth.reynardURL(url)) { opened in
        if !opened { UIApplication.shared.open(url) }
    }
}
