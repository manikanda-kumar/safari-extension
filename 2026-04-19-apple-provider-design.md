# Apple Provider Design

Date: 2026-04-19

## Summary

Add Apple Foundation Models as a first-class macOS-only provider for Navi chat.

Phase 1 keeps the change intentionally small:

- Apple is available as an explicit provider in the macOS app UI.
- Apple becomes the default provider on supported Macs when the system model is available.
- Apple is clearly labeled `Chat only`.
- Apple participates in the existing native provider architecture instead of introducing a parallel runtime.
- Apple does not support browser tool calling in phase 1.
- Apple does not add any vision or screenshot understanding in phase 1.

If Apple is unavailable at runtime, Navi should automatically use another configured provider. If no other provider is configured, the app should ask the user to configure one.

## Goals

- Add Apple as a first-class provider without redesigning the extension/native bridge.
- Keep Apple chat integrated into the existing run lifecycle and streaming UI.
- Preserve user choice so other providers remain selectable.
- Keep the first implementation narrow enough that it can be delivered and validated without expanding tool-calling scope.
- Preserve the reasoning around vision limitations for future reference.

## Non-Goals

- Apple tool calling in phase 1.
- Apple-powered browser automation in phase 1.
- Screenshot, OCR, or multimodal image input in phase 1.
- iOS or iPadOS Apple-provider support in phase 1.
- Reworking the JavaScript extension protocol.

## Current Architecture

The current app already has the right high-level shape for adding another native provider:

- The Safari extension talks to Swift through the native bridge.
- The native side resolves a provider and launches a run.
- A generic `LLMProvider` abstraction streams model events into a shared session loop.
- The browser-agent session owns run state, streamed text, and the tool loop.

Relevant code paths:

- `Packages/NaviKit/Sources/NaviKit/Bridge/NativeMessageRouter.swift`
- `Packages/NaviKit/Sources/NaviKit/Agent/BrowserAgentCoordinator.swift`
- `Packages/NaviKit/Sources/NaviKit/LLM/LLMProvider.swift`
- `Packages/NaviKit/Sources/NaviKit/Agent/LLMBrowserAgentSession.swift`
- `Packages/NaviKit/Sources/NaviKit/Auth/AssistantServiceStore.swift`
- `Packages/NaviKit/Sources/NaviKit/Models/NativeModels.swift`

This makes Apple a good fit for an additive provider implementation.

## Proposed Approach

### Provider Model

Add a new `apple` case to the provider model.

Expected behavior:

- `Apple` appears in the macOS provider picker.
- `Apple` is the default selected provider on supported Macs when the system model is usable.
- Users can manually switch to any other provider.
- `Apple` should be marked in the UI as `Chat only`.

The provider model should continue to expose display metadata and default model identity, but Apple should not participate in the auth/OAuth assumptions used by cloud providers.

### Availability And Fallback

Apple provider selection cannot be treated as equivalent to “has stored credentials.”

The provider store needs to distinguish between:

- selected provider
- configured provider
- currently usable provider

For Apple, usability depends on Foundation Models availability checks rather than credentials. At runtime:

1. If Apple is selected and usable, use Apple.
2. If Apple is selected but unusable, try another configured provider.
3. If no other configured provider exists, surface a setup/unavailable message.

This logic should live near provider resolution rather than inside the streaming loop so the runtime either launches a valid provider or fails early with a clear message.

### Runtime Integration

Phase 1 should preserve the current flow:

1. The extension asks the native bridge to start a run.
2. The coordinator resolves the effective provider.
3. The coordinator creates a provider implementation conforming to `LLMProvider`.
4. The existing `LLMBrowserAgentSession` streams content into the UI.

The Apple provider should be a new `FoundationModelsProvider` that conforms to `LLMProvider` and emits the same event types used by the rest of the app.

The intended diff is small:

- add `apple` to the provider enum
- add a Foundation Models-backed provider implementation
- update provider resolution/defaulting
- update service-state reporting for availability-based providers
- disable tool wiring for Apple in phase 1

The extension/native bridge contract should not change.

### Chat-Only Capability Gate

The current runtime assumes tool-capable providers by default because runs are created with browser tools and the shared session loop knows how to execute tool calls.

For Apple phase 1, the session should run with no tools:

- Apple receives `tools: []`.
- Apple never enters the tool-call branch in normal operation.
- The rest of the session flow stays the same for text streaming and completion.

This avoids adding Apple-specific session types or duplicating the run loop.

### Tool Calling Status

Tool calling is explicitly deferred to a separate follow-up phase.

Reasons to defer:

- It is the first meaningful point where Apple stops being a near-drop-in provider.
- It would require mapping Navi’s generic tool schema and results into Apple’s Foundation Models tool APIs.
- It would introduce browser-automation reliability work that is unrelated to validating Apple chat.

Future Apple tool-calling work should be treated as a separate phase after chat is stable.

## UI Behavior

macOS UI behavior should be:

- show `Apple` in the provider picker
- label it `Chat only`
- keep all other providers selectable
- if Apple is selected but unavailable, either fall back automatically or explain that another provider must be configured

The first release should avoid hiding large parts of the app. A capability label is sufficient for phase 1.

## Error Handling

New user-visible error cases:

- Apple unavailable on this Mac
- Apple Intelligence / system model not ready
- Apple selected, but no fallback provider is configured
- Apple context limits exceeded

The first three should be handled during provider resolution and service-state loading. The session layer should only handle normal run-time generation errors.

## Context Window Considerations

Apple Foundation Models has a tighter context window than Navi’s current assumptions.

Phase 1 should not attempt a full context-management rewrite, but the design should acknowledge that:

- current conversation and page context may need trimming sooner on Apple than on other providers
- large page context may become a follow-up issue after the provider is integrated

This should be tracked as a likely phase-1 follow-up rather than solved preemptively.

## Testing Strategy

Keep tests narrow and high-leverage.

Recommended coverage:

- provider-selection test for Apple defaulting and fallback behavior
- service-state test for Apple availability reporting
- integration-style test proving Apple runs with no tools attached
- UI-level test or view-model test for `Chat only` labeling if a lightweight seam already exists

Do not add tests for Apple tool calling or vision behavior in phase 1.

## Implementation Notes

Likely touched files:

- `Packages/NaviKit/Sources/NaviKit/Models/NativeModels.swift`
- `Packages/NaviKit/Sources/NaviKit/Auth/AssistantServiceStore.swift`
- `Packages/NaviKit/Sources/NaviKit/Agent/BrowserAgentCoordinator.swift`
- `Packages/NaviKit/Sources/NaviKit/LLM/LLMProvider.swift`
- new `Packages/NaviKit/Sources/NaviKit/LLM/FoundationModelsProvider.swift`
- macOS app UI files that expose provider selection and status
- package/project platform settings for Foundation Models support

## Risks

- Apple availability rules are more dynamic than credential-backed providers.
- Context window limits may make some page-heavy prompts degrade sooner.
- Streaming behavior may not map one-to-one with current provider expectations and could require small adaptation in the provider wrapper.
- If the UI implies browser control while Apple is selected, users may expect tool use that phase 1 does not provide.

## Vision Reference

This section is intentionally preserved for future work.

### What Apple Foundation Models Can Do Here

- text generation
- text understanding
- structured output
- tool calling in principle

### What It Cannot Do For Navi

Apple Foundation Models does not give Navi direct multimodal screenshot understanding in this design.

It should be treated as:

- not a vision model
- not a screenshot-analysis model
- not a direct replacement for a multimodal cloud model

So the following are out of scope for the Foundation Models provider itself:

- passing screenshots directly to the model
- asking the model to inspect a page image
- image embeddings
- visual grounding from pixels alone

### What Would Be Possible Later

If Navi later needs “vision” on macOS, the practical architecture is separate from the Apple chat provider:

1. Capture an image or screenshot on the native side.
2. Use Apple Vision or VisionKit for OCR or image analysis.
3. Convert the result into text or structured observations.
4. Feed that result back into the Apple chat model as prompt/context or tool output.

That would be a new screenshot/OCR/vision subsystem, not an extension of the phase-1 Apple provider.

## Recommended Delivery Sequence

1. Add Apple to the provider model and macOS UI.
2. Implement Foundation Models provider for text streaming only.
3. Resolve Apple availability and fallback behavior.
4. Mark Apple as `Chat only` and pass no tools for Apple runs.
5. Validate chat end-to-end on macOS.
6. Revisit context trimming only if Apple usage exposes concrete failures.
7. Treat Apple tool calling as a separate follow-up phase.
