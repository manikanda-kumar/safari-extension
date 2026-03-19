const NATIVE_APP_ID = "com.finnvoorhees.Navi";

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

export function createRun(prompt, conversation = []) {
    return sendNative({
        action: "startRun",
        prompt,
        conversation
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
        () => browser.runtime.sendNativeMessage(NATIVE_APP_ID, payload),
        () => browser.runtime.sendNativeMessage(payload)
    ];

    let lastError = null;

    for (const candidate of candidates) {
        try {
            const response = await candidate();
            if (!response?.ok) {
                throw new Error(response?.error ?? "Native assistant request failed.");
            }

            return response;
        } catch (error) {
            lastError = error;
        }
    }

    throw new Error(
        lastError?.message ?? "Safari native messaging is unavailable. Run the Navi app and reopen the extension."
    );
}
