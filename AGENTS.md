# Agent notes

Notestrand is a SwiftUI iPad app: an AI tutor (Teach, Practice, Exam, Chat) that uses the learner's own AI accounts and their Obsidian vault as memory. It is installed with **TrollStore on an iPad running iOS 15.3.1**: everything must work there. The teaching method and prompts come from LearnHarness (AGPL-3.0); keep those credits.

## The target: iOS 15.3.1 (read before writing any code)

The deployment target is iOS 15.0, so the compiler rejects newer **APIs**. It does not catch these, and each one breaks silently on the real iPad:

- **SF Symbols:** an icon newer than iOS 15 renders blank. Check every new symbol name:
  ```sh
  python3 -c "import plistlib;d=plistlib.load(open('/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist','rb'));n='SYMBOL';print(d['year_to_release'][d['symbols'][n]]['iOS'])"
  ```
  It must print 15.0 or lower.
- **The transcript page** (`Notestrand/Resources/web/`) runs in Safari 15.3 (WebKit 612). Avoid:
  - regex lookbehind literals `(?<=` / `(?<!`: a syntax error that stops the whole script;
  - `Object.hasOwn`, `structuredClone`, `Array.prototype.at` / `findLast` / `toSorted`;
  - CSS `:has()`, `dvh` / `svh`, `:focus-visible`, `@container`, `@layer`, `color-mix()`, `accent-color`.
- **Vendored libraries are pinned for Safari 15:** Mermaid 9.x, KaTeX 0.16.47, markdown-it 13.0.2, Chart.js 4.4.1 (inside `vendor/chart-src.js`). Don't upgrade one without scanning it for the features above.
- **Images:** use PNG (@2x/@3x) or PDF assets, not SVG. iOS 15's SVG renderer misreads valid SVGs, for example compact arc flags. Logo sources live in `design/logos/`; re-bake PNGs from them if a logo changes.
- **Linked libraries:** after adding a framework or a newer Swift feature, check the release binary. Every `LC_LOAD_DYLIB` (not `_WEAK_`) must exist on iOS 15, and anything like `libswift_StringProcessing` or `libswiftObservation` means a crash at launch:
  ```sh
  otool -l build/Payload/Notestrand.app/Notestrand | awk '/cmd LC_LOAD/{t=$2} /name /{print t, $2}'
  ```
- **iOS 16+ SwiftUI** (NavigationStack, presentationDetents, `TextField(axis:)`, `.scrollContentBackground`, Charts, PhotosPicker, alerts with text fields) needs `#available(iOS 16, *)` with an iOS 15 path. See `clearEditorBackground()` in `ChatView.swift`.
- There is no iOS 15 simulator. Behaviour is only proven on the iPad, so say what you couldn't verify.

## Simulator

Use the simulator the user already has open: **iPad (A16)**, iPadOS 26.5, UDID `BA443645-19B2-4683-8E4F-C13E0E434A10`.

- Build, test and install against it: `-destination 'platform=iOS Simulator,id=BA443645-19B2-4683-8E4F-C13E0E434A10'`.
- Never boot, create or switch to another simulator (no `simctl boot`, no `name=iPad Pro…` destinations), and never shut this one down.
- If it isn't booted, ask the user instead of booting one.

## Build and test

```sh
xcodegen generate                      # Notestrand.xcodeproj is generated from project.yml; edit project.yml, never the .xcodeproj
xcodebuild test -project Notestrand.xcodeproj -scheme Notestrand \
  -destination 'platform=iOS Simulator,id=BA443645-19B2-4683-8E4F-C13E0E434A10' -derivedDataPath build/sim
./build.sh                             # -> build/Notestrand.tipa: unsigned Release build, fake-signed with ldid
```

- Rerun `xcodegen generate` after adding or removing files.
- Live API tests skip unless a key is passed: `TEST_RUNNER_OPENROUTER_API_KEY=… xcodebuild test … -only-testing:NotestrandTests/LiveTests`.
- **Visual checks without touching the user's app:** a throwaway XCTest that hosts a view in a `UIWindow` (from `UIApplication.shared.connectedScenes`), waits, and saves `window.drawHierarchy` as a PNG in the scratchpad. Delete the test afterwards. Off-screen `WKWebView`s don't run `requestAnimationFrame`, so drive animation states by time instead.
- zsh: a glob with no matches aborts the command (`rm build/x-*.png` fails when nothing matches).

## Releasing

1. Raise `MARKETING_VERSION` in `project.yml` (for example to `0.2.0`) and commit.
2. Tag that commit `v0.2.0` and push the tag. `.github/workflows/release.yml` builds `Notestrand.tipa` and `Notestrand.ipa` on GitHub and publishes them as a release.

The tag must equal `v` + `MARKETING_VERSION`: the in-app updater (`Updater.swift`) compares the release tag with the installed version, and the workflow fails if they differ. A CI build comes from GitHub's Xcode, not this Mac's, so install it on the iPad before telling people to update.

## Identity: never change these

- **Bundle IDs:** `dev.notestrand.ipad`, and `dev.notestrand.ipad.share` for the share extension. **Keychain service:** `dev.notestrand.ipad.keys`. **App Group:** `group.dev.notestrand.ipad`. Changing any of them makes TrollStore install a separate app, and the learner loses their keys, chats and flashcards. (Renamed from `dev.learnharness.ipad` on 2026-11-15; the old keychain group stays in the entitlements so `KeyStore` can copy keys saved before the rename.)
- The entitlements in `Notestrand/Notestrand.entitlements` and `ShareExtension/NotestrandShare.entitlements` are applied by `ldid` in `build.sh`, extension first. TrollStore needs `application-identifier` for the Keychain to work.

## Layout

| Path | What it is |
| --- | --- |
| `Notestrand/Agent.swift` | `AppState` (`@MainActor`): sessions, the turn loop, tool execution, regenerate/branch/edit, `/btw`, projects, share inbox routing |
| `Notestrand/LLMClient.swift` | Request bodies and stream parsers for the three wire formats: Anthropic Messages, OpenAI Chat Completions, OpenAI Responses (ChatGPT plan) |
| `Notestrand/Providers.swift` | Provider base URLs, `KeyStore` (Keychain), model catalog plus its disk cache |
| `Notestrand/ChatGPTAuth.swift` | Sign in with ChatGPT (OAuth + PKCE, loopback callback, token refresh) |
| `Notestrand/Tools.swift`, `Resources/tools.json` | Prompt assembly per `AgentRole`; tool schemas, where each tool's `agents` list decides which roles get it |
| `Notestrand/Resources/prompts/` | Upstream LearnHarness fragments (leave unchanged) plus ours: `shared/90-ipad.md` (app rules, visuals, fact-checking) and `examiner/` |
| `Notestrand/Vault.swift` | Obsidian vault: security-scoped bookmark, search/read, the one write path, knowledge notes |
| `Notestrand/ChatView.swift` | Chat screen, composer, attachments, export, and the `Transcript` web view bridge |
| `Notestrand/Resources/web/` | The transcript page: markdown, KaTeX, Mermaid (loaded on demand), ` ```chart `/` ```demo ` blocks in sandboxed iframes, action bars, thinking indicator |
| `Notestrand/WebTools.swift` | `web_search` (free DuckDuckGo, Tavily, Brave, Firecrawl) and `web_fetch` |
| `Notestrand/Onboarding*.swift`, `Launch.swift`, `Motion.swift` | First-run onboarding with demos, splash screen, shared motion helpers and haptics |
| `Notestrand/ShareInbox.swift`, `ShareExtension/` | "Share → Notestrand": App Group inbox with a tagged-clipboard fallback, opened via `notestrand://shared` |
| `Notestrand/Updater.swift` | Checks GitHub Releases (`footfungus2/Notestrand`) and hands the build to TrollStore (`apple-magnifier://install`) or SideStore (`sidestore://install`). Release tags must match `MARKETING_VERSION` in `project.yml` |
| `Notestrand/SettingsView.swift` | Settings, model picker, Memory editor, quick prompts, `AccentPicker` |
| `Notestrand/Flashcards.swift`, `HomeView.swift`, `LibraryViews.swift` | Spaced-repetition cards, dashboard, sidebar projects/rename |

## Conventions that prevent real bugs

- **Saved data is decoded from old files.** New fields on `Session`, `Message` or other `Codable` stored types must be **optional**, or every existing chat fails to load. `NewFeatureTests.testOldSessionsStillDecode` guards this.
- **Saving:** call `app.persist(id)`. It writes in the background on `SessionStore.queue`, in order, and `flush()` runs when the app goes to the background. Don't write session files any other way.
- **Secrets** (API keys, tokens) only go through `KeyStore`: never UserDefaults, session files, logs or prompts. Settings key fields loop over `ProviderID.keyProviders`, never `allCases`, because the ChatGPT plan has no key field and saving it would erase the sign-in.
- **Vault writes** only go through `Vault.write`, which enforces the learner's read-only setting and confines writes to the vault's `Notestrand/` folder. Never write elsewhere in the vault.
- **Preferences:** keys live in `Prefs.swift`. Read them with `@AppStorage(Prefs.x)` in views.
- **The accent colour:** set both `.tint()` and `.accentColor()`. Fills read `Color.accentColor`, which `.tint` doesn't change.
- **Main thread:** stream callbacks into the UI are `@MainActor`. WebKit crashes when touched off the main thread.
- **Web views:** every chat screen owns its own `WKWebView`. Never move one between screens; that crashed UIKit mid-touch. The page is network-blocked by a content rule list (only `file:`, `about:` and `data:image/` are allowed). Keep it that way: model output and notes must never be able to make requests.
- **Untrusted output:** model replies, notes and web pages can all carry text written to misuse the app. Keep these in place:
  - every transcript `WKWebViewConfiguration` adds `TranscriptHost.noWebRTC` (content rules don't block WebRTC);
  - only a link tapped in the main frame opens a browser (`Transcript.Coordinator.decide`); demos can click their own links from script;
  - SwiftUI `Text` that shows model-written Markdown takes `.webLinksOnly()`, or its links can open any app's URL scheme;
  - the turn loop refuses tool calls the turn didn't offer (`AppState.refusal`), so gate a new tool in `Tools.specs`;
  - `Vault.write` passes content through `Vault.inert`, and `Vault.notes()` skips hidden folders and symlinks like `readNote` does.
- **Navigation:** in two columns, the right column is driven by `app.selected` (see `RootView.detail`) and sidebar rows are plain buttons. Opening a chat programmatically (Home, start cards, shares, branches) relies on that, because a `NavigationLink` won't activate when its row is off screen. Only compact width uses `NavigationLink(tag:selection:)` pushes. Never add a `List(selection:)` binding: it swallows taps in compact width.
- **Motion:** use `Motion.spring` / `Motion.springOrFade` and respect Reduce Motion (fade instead of slide, still frames instead of loops).
- **Accessibility:** touch targets at least 44pt, and `accessibilityLabel` on icon-only buttons.
- **Modes:** a session kind maps to an `AgentRole` (`AppState.role(_:)`). A new mode needs a case in `SessionKind`, its exhaustive switches (labels, icons, placeholder), a role, prompt fragments, and its role added to the relevant tools in `tools.json`.

## Working with the user

- Don't commit unless asked. `build/`, `build-codex-*` and the `.xcodeproj` are generated and ignored.
- The user may run Codex workers in parallel through Orca. Keep to the files your task names, and say when a build failure comes from someone else's half-finished edit.
- The install server, when running, is `python3 -m http.server 8080 --directory build/serve`, serving `build/serve/Notestrand.tipa` for TrollStore on the local Wi-Fi.
