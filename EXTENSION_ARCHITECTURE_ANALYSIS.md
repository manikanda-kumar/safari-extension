# Safari Extension Architecture Analysis

## Scope interpreted
This analysis explains how the extension is structured end-to-end, and specifically how it routes runs through **Claude** or **Codex**.

---

## Overview
Navi is a hybrid architecture with three cooperating layers:

1. **Web extension layer (JavaScript, `ExtensionSource/`)**
   - Sidebar/popup UI, tab automation tools, run polling, and per-tab state.
2. **Native bridge layer (Swift, extension target + `NaviKit/Bridge`)**
   - Receives native messages from Safari extension JS and routes actions.
3. **Agent/runtime layer (Swift, `NaviKit/Agent`, `NaviKit/LLM`, `NaviKit/Auth`)**
   - Creates/executes agent runs, selects provider/model, streams LLM output, and coordinates tool calls back into the page.

The Safari extension itself does browser automation (`read_page`, `click`, `type`, `scroll`, `navigate`, `wait`), while the native app side handles authentication and LLM streaming.

---

## Key concepts

- **Per-tab state machine** (`ExtensionSource/background.js`)  
  Tracks `messages`, `runID`, `isRunning`, `pending tool calls`, errors, and update banners per tab.

- **Thread persistence key** (`ExtensionSource/content.js`)  
  A stable tab thread key is embedded in `window.name` (`__navi_thread_key__:*`) and used to persist/restore conversation snapshots.

- **Native message protocol** (`NaviKit/Bridge/NativeBridgeMessages.swift`)  
  Actions like `startRun`, `getRun`, `submitToolResult`, `loadThread`, etc. are typed and routed.

- **Run coordinator** (`NaviKit/Agent/BrowserAgentCoordinator.swift`)  
  Orchestrates run creation, provider selection, event/status updates, transcript logging, and tool bridging.

- **Single pending tool handshake** (`NaviKit/Agent/RunStore.swift`)  
  Native side exposes one pending tool call at a time; extension executes it in-page and posts result back.

- **Provider abstraction** (`NaviKit/LLM/LLMProvider.swift`)  
  Common streaming interface implemented by `ClaudeProvider` and `CodexProvider`.

---

## How it works

### 1) UI bootstrap (popup/sidebar)
- Popup (`popup.js`) or injected sidebar (`sidebar-inject.js` + `sidebar.js`) mounts React app (`app.jsx`).
- UI sends `app:init` to background script.
- Background hydrates tab state from native thread store and checks auth state via native bridge (`loadServiceState`).

### 2) User submits a prompt
- UI `onNew` -> background message `assistant:append`.
- `background.js` validates auth and prompt, appends user + placeholder assistant message, marks run as active.
- It starts `runAssistantLoop`.

### 3) Start run on native side
- `background.js` calls `createRun(prompt, conversation)` via `lib/native-bridge.js`.
- Safari native extension handler (`SafariWebExtensionHandler.swift`) forwards payload to `SafariExtensionMessageBridge` -> `NativeMessageRouter`.
- Router invokes `BrowserAgentCoordinator.startRun(...)`.

### 4) Provider/model selection (Claude vs Codex)
- `AssistantServiceStore.loadConfiguration()` reads selected provider + model from shared app-group defaults and credentials from secure storage.
- Provider choice is user-driven from iOS/macOS app Picker (`NaviProvider`: `anthropic` or `codex`):
  - `anthropic` display name: Claude, default model: `claude-sonnet-4-5`
  - `codex` display name: Codex, default model: `gpt-5.4-mini`
- Coordinator switches provider implementation:
  - `ClaudeProvider(apiKey: ...)`
  - `CodexProvider(apiKey: ..., accountID: ...)`

### 5) Agent loop and tool-use loop
- `LLMBrowserAgentSession.start(prompt:)` streams events from provider.
- For each turn:
  1. Send LLM request (system prompt + messages + tool schemas).
  2. Stream reasoning/text/tool-call deltas into `contentParts`.
  3. If stop reason is tool use:
     - Execute each tool via `BridgedBrowserToolExecutor`.
     - This enqueues a `pendingTool` in `RunStore` and waits.

### 6) Tool execution path (native -> extension -> page)
- Background loop polls `fetchRun` every ~400ms.
- When `pendingTool` appears, background executes it:
  - `read_page`: asks `content.js` to snapshot DOM text + interactive elements.
  - `click/type/scroll`: sends action to content script.
  - `navigate/wait`: performed directly from background (`tabs.update` / delay).
- Background sends result back with `submitToolResult(runID, callID, result)`.
- Native `RunStore` resumes suspended continuation; agent continues next turn.

### 7) Completion and UI updates
- As run events arrive, coordinator updates run status/content in `RunStore`.
- Background keeps polling and transforms native content parts into UI message parts.
- On completion: run is marked complete; assistant message status becomes `complete`.

### 8) Persistence and recovery
- Background persists per-tab snapshots to native `BrowserThreadStore` (`app group/Application Support/.../BrowserAgent/Threads`).
- When a tab/app restarts, state is rehydrated by thread key.
- Run transcripts are also logged in JSONL (`TranscriptLogger`, temp directory).

---

## How Claude is used

**Auth & credentials**
- User signs in via Anthropic OAuth in app (`AuthController.performAnthropicLogin`, `AnthropicOAuthFlow`).
- Access/refresh tokens saved in shared secure storage (`CredentialStorage`, Valet).

**Inference transport**
- `ClaudeProvider` calls `https://api.anthropic.com/v1/messages` with SSE streaming.
- Maps streaming events to internal `LLMEvent`:
  - `thinking_delta` -> reasoning
  - `text_delta` -> assistant text
  - `tool_use` blocks -> tool calls
- Sends tool results back as Claude `tool_result` content blocks in subsequent turns.

**Prompting/tooling**
- Coordinator injects system prompt and browser tool definitions from `BrowserToolCatalog`.

---

## How Codex is used

**Auth & credentials**
- User signs in via OpenAI OAuth (`AuthController.performCodexLogin`, `CodexOAuthFlow`).
- Includes localhost callback server on port 1455 (`OAuthCallbackServer`) plus manual paste fallback.
- Stores access/refresh and extracted `chatgpt_account_id` for API headers.

**Inference transport**
- `CodexProvider` calls `https://chatgpt.com/backend-api/codex/responses` with SSE streaming.
- Adds headers like `chatgpt-account-id`, `OpenAI-Beta: responses=experimental`, and `originator: navi`.
- Maps response events:
  - `response.output_text.delta` -> text
  - `response.reasoning*.delta` -> thinking
  - `response.output_item.done` function_call -> tool call

**Request shape differences**
- Uses Responses-style `input` items (assistant/user messages, function calls, function outputs) instead of Anthropic Messages format.

---

## Where things live

- **Extension orchestration:** `ExtensionSource/background.js`
- **Page automation + snapshot:** `ExtensionSource/content.js`, `ExtensionSource/lib/page-bridge.js`
- **Native bridge from extension JS:** `ExtensionSource/lib/native-bridge.js`
- **Sidebar injection/UI boot:** `ExtensionSource/sidebar-inject.js`, `ExtensionSource/sidebar.js`, `ExtensionSource/app.jsx`
- **Safari native entrypoint:** `Navi macOS Extension/SafariWebExtensionHandler.swift`, `Navi iOS Extension/SafariWebExtensionHandler.swift`
- **Bridge routing/messages:** `Packages/NaviKit/Sources/NaviKit/Bridge/*`
- **Run coordination + tools:** `Packages/NaviKit/Sources/NaviKit/Agent/*`
- **Provider implementations:** `Packages/NaviKit/Sources/NaviKit/LLM/ClaudeProvider.swift`, `.../CodexProvider.swift`
- **Auth + credentials:** `Packages/NaviKit/Sources/NaviKit/Auth/*`
- **Shared storage/thread persistence:** `Packages/NaviKit/Sources/NaviKit/Storage/*`

---

## Gotchas / non-obvious behavior

1. **Tool execution is serialized**  
   RunStore only supports one pending tool invocation at a time.

2. **Polling-driven bridge**  
   Extension polls native state every 400ms; there is no push channel for pending tools.

3. **Thread identity tied to `window.name`**  
   Conversation continuity depends on preserved `window.name` token.

4. **Provider switch resets model to provider default**  
   `setSelectedProvider` updates both provider and model ID.

5. **Codex requires account ID header**  
   OAuth token parsing extracts account ID from JWT claims; missing/invalid value breaks calls.

6. **Sign-in happens in the app, not extension UI**  
   Extension checks `serviceState.isAuthenticated` and blocks runs until app login is done.

7. **Run safety relies heavily on prompt policy**  
   Guardrails for destructive actions are in the system prompt, not in hard-coded allow/deny logic.
