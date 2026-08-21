# Fix #879 — permission/question requests are not forwarded to Sesori (task stuck "in progress")

## Symptom

While a task runs (often a bash/powershell call), OpenCode emits a permission
request (`permission.asked`) or question request (`question.asked`), but Sesori
shows the action stuck "in progress" and never surfaces the pending prompt. Only
a forced refresh sometimes reveals it. Answering in Sesori lets the task
continue.

## Root-cause analysis

The plugin has three paths that must all work for a pending prompt to surface:

1. **SSE event → typed event** (`SseEventParser` + generated
   `sse_event_data.g.dart`). The manifest declares `permission.asked`
   (`id`, `sessionID`, `permission`, `patterns`) and `question.asked`
   (`id`, `sessionID`, `questions`). Verified against upstream v1.18.16/1.18.19:
   both events additionally carry an optional object `tool` field
   (`{messageID, callID}`) on `question.asked` (and `metadata`/`always`/object
   `tool` on `permission.asked`). Our hand-written decoder reads only declared
   fields, so unknown extra fields do not break parsing — this path is intact.
2. **Typed event → tracker + bridge event** (`OpenCodePluginImpl._handleRawSseEvent`).
   `_service.handleSseEvent` records the pending id in `ActiveSessionTracker`,
   and `_mapper.map` emits `BridgeSsePermissionAsked` / `BridgeSseQuestionAsked`.
   This path is wired correctly for well-formed payloads.
3. **Malformed-payload drop path.** If any declared field fails to decode, the
   parser returns `malformedKnownPayload` and the frame is silently dropped
   (only a log line) — no tracker entry, no bridge event, no summary refresh.
   This is the dangerous failure mode: Sesori keeps showing "in progress"
   because nothing else signals awaiting-input until a refresh re-reads the
   REST lists.

**Hypothesis (root cause):** the wire shape of `question.asked` drifted from our
manifest. Upstream v1.17.7+ added the optional `tool` object to
`question.asked`; when a *tool-driven* question fires (the exact #879 scenario —
a bash/powershell tool call asking for permission), the payload carries
`tool: {messageID, callID}`. Our manifest does not declare it, so today we
happen to survive; but any future drift in a *declared* field's type (e.g.
`patterns` arriving as something other than a plain string list, or a declared
required field missing on some runtime versions) lands every such frame in the
silent `malformedKnownPayload` drop, which reproduces the issue exactly:
stuck "in progress", no surfaced question, recoverable only by a refresh that
re-reads `GET /question`.

The fix therefore hardens the forwarding path rather than rewiring it:

- Declare the real wire shape (`tool`) so the decoder matches upstream instead
  of relying on "undeclared fields are ignored" luck.
- Make the silent-drop failure observable *and* self-healing: when a known
  question/permission frame fails payload decode, still surface it — trigger a
  projects-summary re-emit so clients re-pull the pending lists immediately,
  instead of staying blind until a manual refresh.

This keeps the change small, preserves the sealed-class/no-magic-string rules,
and directly targets "surface as soon as it arrives, without a forced refresh".

## Exact changes

Package: `bridge/sesori_plugin_opencode`

1. `tool/opencode_events_v1.json` — add the optional `tool` ref field to
   `question.asked` (matches upstream `QuestionTool {messageID, callID}`);
   update the manifest comment.
2. Regenerate `lib/src/models/sse_event_data.g.dart` via
   `dart run tool/generate_sse_events.dart` (generated file, not hand-edited).
3. Add `QuestionTool` to `_v1Imports` in `tool/generate_sse_events.dart`.
   `lib/src/models/openapi/question_tool.g.dart` already exists.
4. `lib/src/opencode_plugin_impl.dart` — in `_handleRawSseEvent`, on
   `SseParseOutcome.malformedKnownPayload` whose `eventType` is a
   question/permission event, call `_emitProjectsSummary()` after logging so
   connected surfaces re-query the pending lists at once (self-healing instead
   of stuck-until-refresh).
5. Tests:
   - `test/opencode_plugin_impl_test.dart`: regression tests that a live SSE
     `question.asked` (with the `tool` field present, mirroring a tool-driven
     ask) forwards `BridgeSseQuestionAsked` with the right ids/questions AND
     flips the session's awaiting-input summary without any refresh; same for
     `permission.asked` carrying the extra upstream fields (`metadata`,
     `always`, object `tool`) → `BridgeSsePermissionAsked`.
   - `test/sse_event_parser_test.dart`: parse coverage for both frames
     including the optional `tool` object.
   - Malformed-question-frame recovery: a `question.asked` frame with a broken
     payload still triggers a summary re-emit (no silent blindness).

Out of scope (already correct, verified): reply/reject clearing
(`replyToQuestion`/`replyToPermission` clear the tracker and emit
replied events), cold-start hydration of pending lists, child-session display
root stamping.

## Verification

- `cd bridge/sesori_plugin_opencode && dart analyze --fatal-infos`
- `dart test`
