const NATIVE_APP_ID = "com.manik.Navi";

export async function loadServiceState() {
    const response = await sendNative({ action: "loadServiceState" });
    return response.serviceState;
}

export async function loadThread(threadKey) {
    const response = await sendNative({ action: "loadThread", threadKey });
    return response.thread ?? null;
}

export async function saveThread(threadKey, snapshot) {
    await sendNative({ action: "saveThread", threadKey, snapshot });
}

export async function clearThread(threadKey) {
    await sendNative({ action: "clearThread", threadKey });
}

export function createRun(prompt, conversation = [], mode = "assistant") {
    return sendNative({
        action: "startRun",
        prompt,
        conversation,
        mode
    });
}

export function cancelRun(runID) {
    return sendNative({
        action: "cancelRun",
        runID
    });
}

export function fetchRun(runID) {
    return sendNative({
        action: "getRun",
        runID
    });
}

export function submitToolResult(runID, callID, result) {
    return sendNative({
        action: "submitToolResult",
        runID,
        callID,
        result
    });
}

export async function sendNative(payload) {
    const candidates = [
        ["app", () => browser.runtime.sendNativeMessage(NATIVE_APP_ID, payload)],
        // Some Safari builds appear to wire native messaging to the extension bundle ID.
        ["extension", () => browser.runtime.sendNativeMessage(`${NATIVE_APP_ID}.Extension`, payload)],
        // Legacy fallback for engines that infer the native target.
        ["implicit", () => browser.runtime.sendNativeMessage(payload)]
    ];

    const failures = [];

    for (const [name, candidate] of candidates) {
        try {
            const response = await candidate();
            if (!response?.ok) {
                throw new Error(response?.error ?? "Native assistant request failed.");
            }

            return response;
        } catch (error) {
            failures.push(`${name}: ${error?.message ?? String(error)}`);
        }
    }

    throw new Error(
        failures.length > 0
            ? `Safari native messaging failed (${failures.join(" | ")}). Reopen Safari and Navi, then try again.`
            : "Safari native messaging is unavailable. Run the Navi app and reopen the extension."
    );
}
