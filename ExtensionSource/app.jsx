import React, { useEffect, useMemo, useState } from "react";
import { AssistantRuntimeProvider, useExternalStoreRuntime } from "@assistant-ui/react";
import { Thread } from "./components/assistant-ui/thread.jsx";
import { TooltipIconButton } from "./components/assistant-ui/tooltip-icon-button.jsx";
import { TooltipProvider } from "./components/ui/tooltip.jsx";
import { Sparkles, PlusBubble } from "./components/icons.jsx";

export function PopupApp() {
    const [readyState, setReadyState] = useState({
        status: "loading",
        error: "",
        tabId: null,
        pageTitle: "Connecting to Safari…",
        pageURL: "",
        initialState: null
    });

    useEffect(() => {
        let didCancel = false;

        void (async () => {
            try {
                const [{ id: tabId, title, url } = {}] = await browser.tabs.query({
                    active: true,
                    currentWindow: true
                });

                if (!tabId) {
                    throw new Error("No active tab was found.");
                }

                const response = await browser.runtime.sendMessage({
                    type: "app:init",
                    tabId
                });

                if (!response?.ok) {
                    throw new Error(response?.error ?? "Unable to load Navi.");
                }

                if (!didCancel) {
                    setReadyState({
                        status: "ready",
                        error: "",
                        tabId,
                        pageTitle: String(title || hostnameFromURL(url) || "Current tab"),
                        pageURL: String(url || ""),
                        initialState: response.state
                    });
                }
            } catch (error) {
                if (!didCancel) {
                    setReadyState({
                        status: "error",
                        error: error.message,
                        tabId: null,
                        pageTitle: "Unavailable",
                        pageURL: "",
                        initialState: null
                    });
                }
            }
        })();

        return () => {
            didCancel = true;
        };
    }, []);

    return (
        <main className="flex h-full min-h-0 flex-col overflow-hidden bg-background text-foreground">
            {readyState.status === "loading" ? (
                <StateCard title="Loading Navi" body="Connecting the popup to the current tab and native bridge." />
            ) : null}

            {readyState.status === "error" ? (
                <StateCard tone="error" title="Navi is unavailable" body={readyState.error} />
            ) : null}

            {readyState.status === "ready" ? (
                <ChatWorkspace
                    initialState={readyState.initialState}
                    pageTitle={readyState.pageTitle}
                    pageURL={readyState.pageURL}
                    tabId={readyState.tabId}
                />
            ) : null}
        </main>
    );
}

export function SidebarApp({ tabId: propTabId, pageTitle: propTitle, pageURL: propURL }) {
    const [readyState, setReadyState] = useState({
        status: "loading",
        error: "",
        tabId: null,
        pageTitle: "Connecting…",
        pageURL: "",
        initialState: null
    });

    useEffect(() => {
        let didCancel = false;

        void (async () => {
            try {
                if (!propTabId) {
                    throw new Error("No tab ID was provided.");
                }

                const response = await browser.runtime.sendMessage({
                    type: "app:init",
                    tabId: propTabId
                });

                if (!response?.ok) {
                    throw new Error(response?.error ?? "Unable to load Navi.");
                }

                if (!didCancel) {
                    setReadyState({
                        status: "ready",
                        error: "",
                        tabId: propTabId,
                        pageTitle: String(propTitle || hostnameFromURL(propURL) || "Current tab"),
                        pageURL: String(propURL || ""),
                        initialState: response.state
                    });
                }
            } catch (error) {
                if (!didCancel) {
                    setReadyState({
                        status: "error",
                        error: error.message,
                        tabId: null,
                        pageTitle: "Unavailable",
                        pageURL: "",
                        initialState: null
                    });
                }
            }
        })();

        return () => {
            didCancel = true;
        };
    }, [propTabId, propTitle, propURL]);

    return (
        <main className="flex h-full min-h-0 flex-col overflow-hidden bg-background text-foreground">
            {readyState.status === "loading" ? (
                <StateCard title="Loading Navi" body="Connecting to the current tab." />
            ) : null}

            {readyState.status === "error" ? (
                <StateCard tone="error" title="Navi is unavailable" body={readyState.error} />
            ) : null}

            {readyState.status === "ready" ? (
                <ChatWorkspace
                    initialState={readyState.initialState}
                    pageTitle={readyState.pageTitle}
                    pageURL={readyState.pageURL}
                    tabId={readyState.tabId}
                />
            ) : null}
        </main>
    );
}

function ChatWorkspace({ initialState, pageTitle, pageURL, tabId }) {
    const [extensionState, setExtensionState] = useState(initialState);
    const [threadSeed, setThreadSeed] = useState(0);
    const pageHost = hostnameFromURL(pageURL);

    useEffect(() => {
        const handleRuntimeMessage = (message) => {
            if (message?.type !== "assistant:state" || message.tabId !== tabId) {
                return;
            }

            setExtensionState(message.state);
        };

        browser.runtime.onMessage.addListener(handleRuntimeMessage);
        return () => {
            browser.runtime.onMessage.removeListener(handleRuntimeMessage);
        };
    }, [tabId]);

    const suggestions = useMemo(() => {
        const label = pageTitle || pageHost || "this page";
        return [
            { prompt: `Summarize ${label}` },
            { prompt: `Explain the important details on ${label}` },
            { prompt: `What actions can I take on ${label}?` },
            { prompt: `Extract the key facts from ${label}` }
        ];
    }, [pageHost, pageTitle]);

    const serviceOK = Boolean(extensionState?.service?.ok);
    const statusBanner = buildStatusBanner(extensionState);
    const agentMode = extensionState?.agentMode === "navigator" ? "navigator" : "assistant";

    const handleNewThread = async () => {
        const response = await browser.runtime.sendMessage({
            type: "assistant:newThread",
            tabId
        });

        if (!response?.ok) {
            throw new Error(response?.error ?? "Unable to start a new thread.");
        }

        setExtensionState(response.state);
        setThreadSeed((value) => value + 1);
    };

    const handleSetMode = async (mode) => {
        const response = await browser.runtime.sendMessage({
            type: "assistant:setMode",
            tabId,
            mode
        });

        if (!response?.ok) {
            throw new Error(response?.error ?? "Unable to switch Navi mode.");
        }

        setExtensionState(response.state);
    };

    return (
        <TooltipProvider>
            <section className="flex h-full min-h-0 flex-col overflow-hidden">
                <header className="border-b border-border/70 bg-background/95 px-4 pb-3 pt-3 backdrop-blur">
                    <div className="flex items-start justify-between gap-3">
                        <div className="min-w-0">
                            <div className="flex items-center gap-2">
                                <div className="flex size-8 shrink-0 items-center justify-center rounded-full border border-border bg-card text-primary shadow-sm">
                                    <Sparkles className="size-4" />
                                </div>
                                <div className="min-w-0">
                                    <h1 className="truncate text-[15px] font-semibold leading-none tracking-[-0.02em]">
                                        Navi
                                    </h1>
                                    <p className="mt-1 truncate text-xs text-muted-foreground">{pageTitle}</p>
                                </div>
                            </div>
                        </div>

                        <div className="flex shrink-0 items-center gap-1">
                            {extensionState?.updateAvailable ? (
                                <button
                                    onClick={() => {
                                        browser.runtime
                                            .sendNativeMessage("com.manik.Navi", { action: "checkForUpdates" })
                                            .catch(() => {});
                                    }}
                                    className="rounded-full border border-blue-300/60 bg-blue-50 px-2.5 py-1 text-[11px] font-medium text-blue-900 transition-colors hover:bg-blue-100"
                                >
                                    Update available
                                </button>
                            ) : null}
                            <TooltipIconButton
                                onClick={() => {
                                    void handleNewThread().catch((error) => {
                                        setExtensionState((current) => ({
                                            ...current,
                                            error: error.message
                                        }));
                                    });
                                }}
                                className="size-8"
                                tooltip="New Thread"
                                side="bottom"
                            >
                                <PlusBubble className="size-[18px]" />
                            </TooltipIconButton>
                        </div>
                    </div>

                    <div className="mt-3 inline-flex items-center gap-1 rounded-xl border border-border/70 bg-card/70 p-1">
                        <button
                            onClick={() => {
                                void handleSetMode("assistant").catch((error) => {
                                    setExtensionState((current) => ({ ...current, error: error.message }));
                                });
                            }}
                            className={`rounded-lg px-2.5 py-1 text-[11px] font-medium transition-colors ${
                                agentMode === "assistant"
                                    ? "bg-primary text-primary-foreground"
                                    : "text-muted-foreground hover:bg-muted"
                            }`}
                        >
                            Assistant
                        </button>
                        <button
                            onClick={() => {
                                void handleSetMode("navigator").catch((error) => {
                                    setExtensionState((current) => ({ ...current, error: error.message }));
                                });
                            }}
                            className={`rounded-lg px-2.5 py-1 text-[11px] font-medium transition-colors ${
                                agentMode === "navigator"
                                    ? "bg-primary text-primary-foreground"
                                    : "text-muted-foreground hover:bg-muted"
                            }`}
                        >
                            Navigator
                        </button>
                    </div>

                    {statusBanner ? (
                        <div
                            className={`mt-3 rounded-2xl border px-3 py-2 text-[12px] leading-5 ${statusBanner.className}`}
                        >
                            {statusBanner.text}
                        </div>
                    ) : null}
                </header>

                <div className="min-h-0 flex-1 overflow-hidden">
                    {serviceOK ? (
                        <ChatRuntimePanel
                            key={`thread-${tabId}-${threadSeed}`}
                            extensionState={extensionState}
                            pageTitle={pageTitle}
                            suggestions={suggestions}
                            tabId={tabId}
                            onStateChange={setExtensionState}
                        />
                    ) : (
                        <StateCard
                            body={
                                extensionState?.service?.message ??
                                "Open the Navi app and sign in before using the extension."
                            }
                            title="Sign in required"
                        />
                    )}
                </div>
            </section>
        </TooltipProvider>
    );
}

function ChatRuntimePanel({ extensionState, pageTitle, suggestions, tabId, onStateChange }) {
    const store = useMemo(
        () => ({
            messages: extensionState?.messages ?? [],
            isRunning: Boolean(extensionState?.isRunning),
            suggestions,
            unstable_capabilities: {
                copy: true
            },
            onNew: async (message) => {
                const response = await browser.runtime.sendMessage({
                    type: "assistant:append",
                    tabId,
                    message
                });

                if (!response?.ok) {
                    throw new Error(response?.error ?? "Navi could not start the run.");
                }

                onStateChange(response.state);
            },
            onCancel: async () => {
                const response = await browser.runtime.sendMessage({
                    type: "assistant:stop",
                    tabId
                });

                if (!response?.ok) {
                    throw new Error(response?.error ?? "Navi could not stop the run.");
                }

                onStateChange(response.state);
            }
        }),
        [extensionState?.isRunning, extensionState?.messages, onStateChange, suggestions, tabId]
    );

    const runtime = useExternalStoreRuntime(store);

    return (
        <AssistantRuntimeProvider runtime={runtime}>
            <Thread
                welcomeSubtitle={`Ask Navi to read ${pageTitle || "the current page"}, explain it, or drive the tab for you.`}
                welcomeTitle="What should Navi do?"
            />
        </AssistantRuntimeProvider>
    );
}

function StateCard({ title, body, tone = "default" }) {
    return (
        <section className="flex min-h-0 flex-1 items-center justify-center px-5 py-6">
            <div
                className={`w-full max-w-sm rounded-[28px] border bg-card/90 p-5 shadow-sm ${tone === "error" ? "border-destructive/25 text-destructive" : "border-border text-foreground"}`}
            >
                <h2 className="text-sm font-semibold">{title}</h2>
                <p
                    className={`mt-2 text-sm leading-6 ${tone === "error" ? "text-destructive/90" : "text-muted-foreground"}`}
                >
                    {body}
                </p>
            </div>
        </section>
    );
}

function buildStatusBanner(extensionState) {
    if (extensionState?.service?.ok === false) {
        return {
            className: "border-yellow-300/40 bg-yellow-50 text-yellow-900",
            text: extensionState.service.message
        };
    }

    return null;
}

function hostnameFromURL(url) {
    if (!url) {
        return "";
    }

    try {
        return new URL(url).hostname.replace(/^www\./, "");
    } catch {
        return "";
    }
}
