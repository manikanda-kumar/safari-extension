import {
    cancelRun,
    clearThread,
    createRun,
    fetchRun,
    loadServiceState,
    loadThread,
    saveThread,
    submitToolResult
} from "./lib/native-bridge.js";
import { getPageSnapshot, getTabThreadKey, performPageAction } from "./lib/page-bridge.js";

const POLL_INTERVAL_MS = 400;
const SIDEBAR_WIDTH = 420;
const APPCAST_URL = "https://raw.githubusercontent.com/finnvoor/Navi/main/appcast.xml";
const TAB_SESSION_PREFIX = "__navi_thread_key__:";

const tabState = new Map();
const sidebarTabs = new Set();
const hydratedTabs = new Set();
const activeRunLoops = new Set();

let cachedUpdateAvailable = false;

const IS_IPHONE = /iPhone|iPod/.test(navigator.userAgent);

if (IS_IPHONE) {
    browser.action.setPopup({ popup: "popup.html" });
}

browser.action.onClicked.addListener(async (tab) => {
    if (tab?.id) {
        await injectSidebar(tab.id);
    }
});

browser.commands.onCommand.addListener(async (command) => {
    if (command === "toggle-sidebar") {
        const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
        if (tab?.id) {
            await injectSidebar(tab.id);
        }
    }
});

browser.tabs.onRemoved.addListener((tabId) => {
    sidebarTabs.delete(tabId);
    const state = tabState.get(tabId);
    tabState.delete(tabId);
    hydratedTabs.delete(tabId);
    activeRunLoops.delete(tabId);
    if (state?.threadKey) {
        void clearThread(state.threadKey);
    }
});

browser.tabs.onUpdated.addListener(async (tabId, changeInfo) => {
    if (changeInfo.status === "complete" && sidebarTabs.has(tabId)) {
        try {
            await openSidebar(tabId, { animate: false });
        } catch {}
    }
});

browser.runtime.onMessage.addListener((message, sender) => {
    if (message?.type === "sidebar:close") {
        const tabId = message.tabId || sender.tab?.id;
        if (tabId) {
            closeSidebar(tabId).catch(() => {});
        }
        return;
    }

    switch (message?.type) {
        case "app:init":
            return initializeApp(message.tabId);
        case "assistant:newThread":
            return startNewThread(message.tabId);
        case "assistant:append":
            return appendAndRun(message.tabId, message.message);
        case "assistant:stop":
            return stopRun(message.tabId);
        default:
            return undefined;
    }
});

async function initializeApp(tabId) {
    if (!tabId) {
        return { ok: false, error: "No active tab is available." };
    }

    await hydrateState(tabId);
    const state = ensureState(tabId);
    await refreshServiceState(state);
    ensureRunLoop(tabId);
    checkForAppUpdate();
    return { ok: true, state: await commitState(tabId) };
}

async function startNewThread(tabId) {
    if (!tabId) {
        return { ok: false, error: "No active tab is available." };
    }

    await hydrateState(tabId);
    const state = ensureState(tabId);
    if (state.isRunning) {
        return { ok: false, error: "Wait for Navi to finish before starting a new thread." };
    }

    resetThreadState(state);
    activeRunLoops.delete(tabId);
    return { ok: true, state: await commitState(tabId) };
}

async function appendAndRun(tabId, appendMessage) {
    const resolvedTabId = tabId ?? (await getActiveTabID());
    if (!resolvedTabId) {
        return { ok: false, error: "No active tab is available." };
    }

    await hydrateState(resolvedTabId);
    const state = ensureState(resolvedTabId);
    if (state.isRunning) {
        return { ok: false, error: "Navi is already working." };
    }

    await refreshServiceState(state);
    if (!state.serviceState.isAuthenticated) {
        return {
            ok: false,
            error: "Open the Navi app and sign in before starting Navi.",
            state: await commitState(resolvedTabId)
        };
    }

    const userMessage = normalizeUserAppendMessage(appendMessage);
    const promptText = flattenThreadMessageText(userMessage);
    if (!promptText) {
        return { ok: false, error: "Navi needs a prompt." };
    }

    const assistantMessage = createAssistantMessage({
        id: makeID("assistant"),
        content: [],
        status: { type: "running" }
    });

    state.messages = [...state.messages, userMessage, assistantMessage];
    state.isRunning = true;
    state.runID = null;
    state.toolCallsInFlight.clear();
    state.error = null;

    ensureRunLoop(resolvedTabId, { startNew: true });
    return { ok: true, state: await commitState(resolvedTabId) };
}

async function stopRun(tabId) {
    if (!tabId) {
        return { ok: false, error: "No active tab is available." };
    }

    await hydrateState(tabId);
    const state = ensureState(tabId);
    if (!state.isRunning || !state.runID) {
        return { ok: true, state: await commitState(tabId) };
    }

    updateAssistantMessage(state, (message) => ({
        ...message,
        status: { type: "incomplete", reason: "cancelled" }
    }));

    try {
        await cancelRun(state.runID);
    } catch (error) {
        state.error = error.message;
    } finally {
        state.isRunning = false;
        state.runID = null;
        state.toolCallsInFlight.clear();
    }

    return { ok: true, state: await commitState(tabId) };
}

async function runAssistantLoop(tabId) {
    await hydrateState(tabId);
    const state = ensureState(tabId);

    try {
        if (!state.runID) {
            const request = buildRunRequest(state.messages);
            if (!request) {
                throw new Error("Navi could not find a user message to send.");
            }

            const response = await createRun(request.prompt, request.conversation);
            applyRunSnapshot(state, response.run);
            state.service = { ok: true, message: "Connected." };
            await commitState(tabId);
        }

        while (state.isRunning && state.runID) {
            const response = await fetchRun(state.runID);
            const runState = response.run;
            applyRunSnapshot(state, runState);

            if (runState.pendingTool && !state.toolCallsInFlight.has(runState.pendingTool.callID)) {
                state.toolCallsInFlight.add(runState.pendingTool.callID);
                void handleToolCall(tabId, runState.pendingTool);
            }

            if (runState.error) {
                throw new Error(runState.error);
            }

            if (runState.isComplete) {
                state.isRunning = false;
                state.runID = null;
                updateAssistantMessage(state, (message) => ({
                    ...message,
                    status: { type: "complete", reason: "stop" }
                }));
                await commitState(tabId);
                return;
            }

            await commitState(tabId);
            await delay(POLL_INTERVAL_MS);
        }
    } catch (error) {
        state.error = error.message;
        state.isRunning = false;
        state.runID = null;
        updateAssistantMessage(state, (message) => ({
            ...message,
            content: ensureErrorContent(message.content, error.message),
            status: { type: "incomplete", reason: "error", error: error.message }
        }));
        await commitState(tabId);
    } finally {
        activeRunLoops.delete(tabId);
        state.isRunning = false;
        state.runID = null;
        state.toolCallsInFlight.clear();
        await commitState(tabId);
    }
}

function ensureRunLoop(tabId, { startNew = false } = {}) {
    if (activeRunLoops.has(tabId)) {
        return;
    }

    const state = ensureState(tabId);
    if (startNew) {
        state.runID = null;
    }

    if (!state.isRunning) {
        return;
    }

    activeRunLoops.add(tabId);
    void runAssistantLoop(tabId);
}

async function handleToolCall(tabId, pendingTool) {
    const state = ensureState(tabId);

    try {
        let result;

        switch (pendingTool.name) {
            case "read_page":
                {
                    const snapshot = await getPageSnapshot(tabId);
                    result = {
                        ok: true,
                        snapshot,
                        summary: `Read ${snapshot.title || "the current page"}.`
                    };
                }
                break;
            case "click":
                result = await performPageAction(tabId, {
                    kind: "click",
                    targetID: pendingTool.input.targetID
                });
                break;
            case "type":
                result = await performPageAction(tabId, {
                    kind: "type",
                    targetID: pendingTool.input.targetID,
                    text: pendingTool.input.text,
                    submit: Boolean(pendingTool.input.submit)
                });
                break;
            case "scroll":
                result = await performPageAction(tabId, {
                    kind: "scroll",
                    targetID: pendingTool.input.targetID
                });
                break;
            case "navigate":
                result = await performPageAction(tabId, {
                    kind: "navigate",
                    url: pendingTool.input.url
                });
                break;
            case "wait":
                result = await performPageAction(tabId, {
                    kind: "wait",
                    durationMs: pendingTool.input.durationMs
                });
                break;
            default:
                result = { ok: false, error: `Unsupported tool: ${pendingTool.name}` };
                break;
        }

        if (state.runID) {
            await submitToolResult(state.runID, pendingTool.callID, result);
        }
    } catch (error) {
        if (state.runID) {
            await submitToolResult(state.runID, pendingTool.callID, {
                ok: false,
                error: error.message
            }).catch(() => {});
        }
    } finally {
        state.toolCallsInFlight.delete(pendingTool.callID);
        await commitState(tabId);
    }
}

async function refreshServiceState(state) {
    const serviceState = await loadServiceState();
    state.serviceState = serviceState;
    state.service = {
        ok: true,
        message: serviceState.isAuthenticated ? "Connected." : "Open the Navi app and sign in first."
    };
}

function applyRunSnapshot(state, runState) {
    state.isRunning = !runState.isComplete;
    state.runID = runState.isComplete ? null : runState.runID;
    state.error = runState.error || null;

    updateAssistantMessage(state, (message) => ({
        ...message,
        content: convertRunParts(runState.contentParts),
        status: runState.isComplete ? { type: "complete", reason: "stop" } : { type: "running" }
    }));
}

function buildRunRequest(messages) {
    const conversation = messages
        .filter((message) => message?.role === "user" || message?.role === "assistant")
        .map((message) => ({
            role: message.role,
            content: flattenThreadMessageText(message)
        }))
        .filter((message) => message.content.length > 0);

    const promptIndex = findLastUserIndex(conversation);
    if (promptIndex < 0) {
        return null;
    }

    return {
        prompt: conversation[promptIndex].content,
        conversation: conversation.slice(0, promptIndex)
    };
}

function findLastUserIndex(messages) {
    for (let index = messages.length - 1; index >= 0; index -= 1) {
        if (messages[index]?.role === "user") {
            return index;
        }
    }

    return -1;
}

function flattenThreadMessageText(message) {
    if (!message?.content || !Array.isArray(message.content)) {
        return "";
    }

    return message.content
        .map((part) => {
            if (part?.type === "text" || part?.type === "reasoning") {
                return String(part.text ?? "");
            }

            return "";
        })
        .join("\n")
        .trim();
}

function normalizeUserAppendMessage(message) {
    const text = flattenAppendContent(message?.content);

    return {
        id: message?.id || makeID("user"),
        role: "user",
        createdAt: new Date(),
        content: [{ type: "text", text }],
        attachments: [],
        metadata: {
            custom: {}
        }
    };
}

function flattenAppendContent(content) {
    if (typeof content === "string") {
        return content.trim();
    }

    if (!Array.isArray(content)) {
        return "";
    }

    return content
        .map((part) => {
            if (part?.type === "text") {
                return String(part.text ?? "");
            }

            return "";
        })
        .join("\n")
        .trim();
}

function createAssistantMessage({ id, content, status }) {
    return {
        id,
        role: "assistant",
        createdAt: new Date(),
        content,
        status,
        metadata: {
            unstable_state: null,
            unstable_annotations: [],
            unstable_data: [],
            steps: [],
            custom: {}
        }
    };
}

function updateAssistantMessage(state, updater) {
    const lastMessage = state.messages.at(-1);
    if (lastMessage?.role === "assistant") {
        state.messages[state.messages.length - 1] = updater(lastMessage);
        return;
    }

    state.messages.push(
        updater(
            createAssistantMessage({
                id: makeID("assistant"),
                content: [],
                status: { type: "running" }
            })
        )
    );
}

function convertRunParts(parts) {
    if (!Array.isArray(parts)) {
        return [];
    }

    return parts
        .map((part) => {
            switch (part.type) {
                case "reasoning":
                    return { type: "reasoning", text: part.text ?? "" };
                case "tool-call":
                    return {
                        type: "tool-call",
                        toolCallId: part.id ?? makeID("tool"),
                        toolName: part.name ?? "",
                        args: part.input ?? {},
                        argsText: formatArgsText(part.input),
                        ...(part.status === "complete"
                            ? {
                                  result: part.result,
                                  isError: Boolean(part.isError)
                              }
                            : {})
                    };
                case "text":
                    return { type: "text", text: part.text ?? "" };
                default:
                    return null;
            }
        })
        .filter(Boolean);
}

function formatArgsText(input) {
    if (!input || typeof input !== "object") {
        return "";
    }

    try {
        return JSON.stringify(input, null, 2);
    } catch {
        return "";
    }
}

function ensureErrorContent(content, errorMessage) {
    if (Array.isArray(content) && content.length > 0) {
        return content;
    }

    return [{ type: "text", text: `I hit an error: ${errorMessage}` }];
}

async function getActiveTabID() {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    return tab?.id ?? null;
}

function ensureState(tabId) {
    if (!tabState.has(tabId)) {
        tabState.set(tabId, {
            threadKey: null,
            messages: [],
            isRunning: false,
            runID: null,
            error: null,
            service: { ok: true, message: "Loading Navi settings…" },
            serviceState: { isAuthenticated: false },
            toolCallsInFlight: new Set()
        });
    }

    return tabState.get(tabId);
}

function resetThreadState(state) {
    state.messages = [];
    state.isRunning = false;
    state.runID = null;
    state.error = null;
    state.toolCallsInFlight.clear();
}

function snapshotState(state) {
    return {
        messages: state.messages,
        isRunning: state.isRunning,
        runID: state.runID,
        error: state.error,
        service: state.service,
        serviceState: state.serviceState,
        updateAvailable: cachedUpdateAvailable
    };
}

async function hydrateState(tabId) {
    if (hydratedTabs.has(tabId)) {
        return ensureState(tabId);
    }

    hydratedTabs.add(tabId);

    try {
        const state = ensureState(tabId);
        const threadKey = await resolveThreadKey(tabId);
        state.threadKey = threadKey;
        const snapshot = await loadThread(threadKey).catch(() => null);
        if (!snapshot) {
            return ensureState(tabId);
        }

        state.messages = deserializeMessages(snapshot.messages);
        state.isRunning = Boolean(snapshot.isRunning);
        state.runID = snapshot.runID ?? null;
        state.error = snapshot.error ?? null;
        state.service = snapshot.service ?? { ok: true, message: "Loading Navi settings…" };
        state.serviceState = snapshot.serviceState ?? { isAuthenticated: false };
        return state;
    } catch {
        return ensureState(tabId);
    }
}

async function persistState(tabId) {
    try {
        const state = ensureState(tabId);
        const threadKey = state.threadKey ?? (await resolveThreadKey(tabId));
        const snapshot = {
            messages: serializeMessages(state.messages),
            isRunning: state.isRunning,
            runID: state.runID,
            error: state.error,
            service: state.service,
            serviceState: state.serviceState
        };

        await saveThread(threadKey, snapshot);
    } catch {}
}

async function commitState(tabId) {
    const state = ensureState(tabId);
    const snapshot = snapshotState(state);
    await persistState(tabId);
    browser.runtime.sendMessage({ type: "assistant:state", tabId, state: snapshot }).catch(() => {});
    return snapshot;
}

function serializeMessages(messages) {
    return (messages ?? []).map((message) => ({
        ...message,
        createdAt: message.createdAt instanceof Date ? message.createdAt.toISOString() : message.createdAt
    }));
}

function deserializeMessages(messages) {
    return (messages ?? []).map((message) => ({
        ...message,
        createdAt: message?.createdAt ? new Date(message.createdAt) : new Date()
    }));
}

function makeID(prefix) {
    return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

async function resolveThreadKey(tabId) {
    const state = ensureState(tabId);
    if (state.threadKey) {
        return state.threadKey;
    }

    try {
        state.threadKey = await getTabThreadKey(tabId);
        return state.threadKey;
    } catch {
        state.threadKey = `${TAB_SESSION_PREFIX}${tabId}`;
        return state.threadKey;
    }
}

function checkForAppUpdate() {
    const currentVersion = browser.runtime.getManifest().version;

    fetch(APPCAST_URL)
        .then((response) => response.text())
        .then((xml) => {
            const matches = [...xml.matchAll(/sparkle:shortVersionString="([^"]+)"/g)];
            if (matches.length === 0) return;

            const latest = matches
                .map((match) => match[1])
                .sort(compareVersions)
                .at(-1);

            if (!latest) return;

            const nextValue = compareVersions(latest, currentVersion) > 0;
            if (nextValue === cachedUpdateAvailable) return;

            cachedUpdateAvailable = nextValue;
            for (const tabId of tabState.keys()) {
                void commitState(tabId);
            }
        })
        .catch(() => {});
}

function compareVersions(a, b) {
    const pa = a.split(".").map(Number);
    const pb = b.split(".").map(Number);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
        const diff = (pa[i] || 0) - (pb[i] || 0);
        if (diff !== 0) return diff;
    }
    return 0;
}

async function injectSidebar(tabId) {
    try {
        if (sidebarTabs.has(tabId)) {
            await closeSidebar(tabId);
        } else {
            await openSidebar(tabId);
        }
    } catch {}
}

async function openSidebar(tabId, { animate = true } = {}) {
    sidebarTabs.add(tabId);

    let shortcut = null;
    try {
        const commands = await browser.commands.getAll();
        shortcut = commands.find((command) => command.name === "toggle-sidebar")?.shortcut || null;
    } catch {}

    await browser.scripting.executeScript({
        target: { tabId },
        func: (id, width, sc, anim) => {
            window.__naviTabId = id;
            window.__naviSidebarWidth = width;
            window.__naviShortcut = sc;
            window.__naviAnimate = anim;
        },
        args: [tabId, SIDEBAR_WIDTH, shortcut, animate]
    });
    await browser.scripting.executeScript({
        target: { tabId },
        files: ["sidebar-inject.js"]
    });
}

async function closeSidebar(tabId) {
    sidebarTabs.delete(tabId);

    await browser.scripting.executeScript({
        target: { tabId },
        func: () => {
            const el = document.getElementById("navi-sidebar-container");
            if (!el) return;
            el.style.transition = "transform 0.3s cubic-bezier(0.4, 0, 0.2, 1)";
            el.style.transform = "translateX(100%)";
            setTimeout(() => el.remove(), 400);
        }
    });
}

function delay(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
