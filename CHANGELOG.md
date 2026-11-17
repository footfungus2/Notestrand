# Changelog

What's new in each version of Notestrand. When a version is tagged, the release workflow copies its section into the GitHub release notes, which the app's **What's new** button opens.

## 0.2.1 (2026-11-17)

### New

- **Updates install inside the app.** Tapping **Update** no longer opens GitHub. If TrollStore's URL scheme is on, TrollStore opens and installs the update in one tap. If it's off, Notestrand downloads the update and opens the share sheet: choose TrollStore or SideStore there. Your chats, keys and settings are kept.
- **Choose your browser.** Settings → Appearance → Open links in: Safari, Google Chrome or Reynard. If you had "Open links in Reynard" switched on, you start on Reynard. If the browser you pick isn't installed, links open in Safari.
- The README now recommends the [Reynard](https://github.com/minh-ton/reynard-browser) browser for sites and login pages that iOS 15's Safari can't load.

### Getting this update from 0.2.0 or older

Older versions still send you to GitHub, so this one update needs a manual step. Either turn on **URL Scheme Enabled** in TrollStore's settings and then tap **Update** in Notestrand, or download `Notestrand.tipa` below and open it with TrollStore.

## 0.2.0 (2026-11-17)

### New

- **Needs work flashcards.** A quiz question you get wrong, answer with "I don't know", or get right at 50% sure or less becomes a flashcard in a **Needs work** deck, with the right answer and the explanation on the back. So do practice problems you give up on, move past, or need hints for. Home shows how many need work.
- **Draw your working.** Tap **+ → Draw your working** for a blank page you can draw on with the Pencil or a finger, then attach it to your message.
- **Your own AI server.** Connect Ollama, LM Studio or any OpenAI-compatible server on your Wi-Fi: Settings → API keys → Your own server. Enter the computer's address (not `localhost`); a key is optional. Small local models may struggle with Teach and Practice, which rely on tools.
- **Timed exam attempts.** In an Exam chat, tap the timer to start a 10 to 120 minute attempt. Until you finish or time runs out, the examiner only clarifies questions: no hints, answers or marking. You get a "Time's up" alert at the end.

### Fixes

- **Retry** only appears on the chat whose reply failed, and a streaming reply only shows in its own chat.
- An empty reply from the model now shows an error instead of being saved (empty replies broke later messages in that chat).
- Teach: the handover from the opening questions to the lesson plan is no longer missed.
- Lesson plans with step names that start with a Mermaid keyword (like `graph-basics`) now read correctly.
- Notes saved to your vault: code that Obsidian plugins would run is made harmless wherever it appears in a note.

## 0.1.0 (2026-11-16)

The first release: an AI tutor for iPads on iOS 15, installed with TrollStore.

- Four modes: **Teach** (checks what you know, plans a route and tests every step), **Practice** (problems with hints), **Exam** (photograph an answer and it's marked against the official mark scheme) and **Chat**.
- Use your own AI account: Anthropic, OpenAI, Google Gemini, OpenRouter, OpenCode Zen, or a ChatGPT Plus or Pro plan.
- Your Obsidian vault as memory: the tutor reads your notes and saves what you learn to a Notestrand folder.
- Flashcards made from any chat, with spaced review.
- Update checks against GitHub Releases, with an off switch in Settings.
- Safety: links written by the model only open web pages, the conversation view can't make network requests, and notes the app writes can't run code in Obsidian.
