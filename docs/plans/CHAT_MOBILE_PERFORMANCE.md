# Mobile chat performance: input latency, heat, and battery

Status: investigation plan, 2026-10-04. No device trace has been captured yet.
Observed symptoms: delayed character insertion/deletion, phone heating, high
battery use. Code findings below are candidates, not proven device bottlenecks.

## 1. Capture a comparable baseline

Use the same physical Android phone, keyboard, theme, brightness, refresh rate,
chat, and network. Record device/OS/WebView versions and build mode. Compare a
short chat against a long chat with swipes, images, and Studio outputs.

Run each scenario separately, starting from a comparable thermal state:

- Idle chat, keyboard closed; idle chat with keyboard open.
- Continuous typing, cursor moves, selection, composition, and backspace.
- Typing with pauses longer than the 500 ms draft debounce.
- Scrollback; ordinary generation; Studio preparation/controllers/streaming.
- Stop during preparation, then idle; completed generation, then idle.
- Navigate away / background the app with and without active generation.

Use a profile build for Flutter DevTools and Android Perfetto/System Trace,
then confirm outcomes in a release build. Debug timing is not the baseline.
Capture UI/raster frame times, CPU by thread/process (including the WebView
renderer), allocation/GC, platform-channel work, and thermal state. Measure input
event-to-present latency, not just the interval to a controller notification.
For battery comparisons use repeated equal-duration runs and Android battery /
power data; a single percentage drop is too coarse. Keep charger/USB conditions
consistent and separate profiling instrumentation from power measurement.

Existing optional instrumentation: `PERF_LOG_FRAMES`, `PERF_LOG_CHAT_WEBVIEW` in
`lib/core/debug/perf_debug.dart`. The frame logger's 17 ms threshold assumes
60 Hz; inspect the actual refresh-rate budget and percentiles in traces.

## 2. First priority: isolate composer and draft costs

Confirmed paths to measure:

- `chat_input_bar.dart`: `_onTextChanged` calls `setState` on every
  `TextEditingController` notification, including selection/composing changes;
  it also resets a draft timer even when text did not change. The rebuilt input
  subtree includes the action row and glass surfaces. `hasContent` trims the
  whole draft on each build.
- `chat_draft_controller.dart`: each saved draft updates the shared ChatState.
  `chat_screen.dart` watches the full chat provider, so a draft-only update can
  rebuild the chat screen and enter search/layout/WebView synchronization work.
  Existing message-identity guards already suppress unnecessary DOM message
  synchronization; verify their cost and effectiveness before changing them.
- `ChatRepo.updateDraftIfMessageCount`: even though SQL updates only `draft`,
  it scans the entire `messagesJson` to count messages and calls `_toModel`,
  which synchronously decodes the full history on the calling isolate. Measure
  this against history length and correlate stalls with debounce completions.

If traces confirm these costs, implement in this order:

1. Localize composer button state updates (empty/nonempty, attachments,
   guidance, busy). Let EditableText handle text/cursor/composition without
   rebuilding unrelated chrome; persist only actual text changes.
2. Give draft persistence a lightweight guarded result, avoiding history
   reconstruction. Preserve the session write queue, expected-message-count
   protection, send-clears-draft ordering, and latest-save epoch.
3. Narrow ChatState subscriptions / separate draft notifications where useful,
   so draft-only writes do not repaint the chat body. Preserve draft restore,
   session switching, fullscreen editing, and send-during-save behavior.

Verify IME composition, selection, multiline growth, attachment/guidance state,
draft restore, and all draft/send race tests after each change.

## 3. Separate raster/compositor work from UI-thread work

Compare normal theme, app battery-saver mode, and controlled effect toggles:
Flutter glass blur, background blur, noise, and WebView CSS blur individually.
`NO_GLASS_BLUR`, `NO_EDGE_BLUR`, `NO_BG_BLUR`, and `NO_NOISE` affect their Dart
consumers; do not assume they disable WebView CSS backdrop filters too.

Inspect GlassSurface / background passes, WebView overlay blur strips and
native-platform-view composition, especially during keyboard and composer
height changes. `_measureBlurRegions` already compares geometry and pushes
changes directly instead of rebuilding; optimize only work shown in the trace.
Look for duplicated image decoding, unnecessarily large layers, and repeated
repaints. Choose repaint isolation, cached/static effects, or adaptive visual
quality based on the measured UI versus raster/compositor cost.

## 4. Audit work that continues while idle

- WebView generation and extension-block clocks tick every 100 ms normally
  (1000 ms in battery saver). Check termination after Stop/completion, ticking
  while offscreen, and animated rolling numbers / pending CSS animations.
- Inspect ResizeObserver and requestAnimationFrame chains during idle and
  virtual-scroll stabilization; do not remove required height correction.
- Audit kept-alive hidden WebViews, Flutter animations, and extension periodic
  scripts. The periodic scheduler already pauses on app background; verify
  visibility and no overlapping expensive jobs during foreground idle.
- Trace generation/post-generation foreground leases and Android wake locks:
  all holds must release after Stop and job settlement, without suppressing
  intentionally active background generation. `_acquireForeground` is shared
  by generation, embedding, drafts, and other background jobs.
- Attribute sync, embedding, auto-summary/drafts, and thumbnail work by their
  own timelines; defer/batch bounded work when appropriate. Verify no duplicate
  scheduling or repeated full-history work before introducing another cache.

## 5. Acceptance and delivery

Record before/after input latency p50/p95, missed-frame rate, UI/raster p95,
idle CPU, CPU time per turn, allocation rate, wake-lock duration, and power /
temperature over equal scenarios. Set absolute latency targets against the
device refresh rate after the first trace, and require a repeatable improvement
on the same device, including long chats. Check a second Android device if
available.

Idle must not retain generation clocks/holds once their jobs have finished;
navigation/background must not keep hidden UI animation alive. Legitimate
background work, Studio results, draft durability, and Stop/new-send ownership
must remain correct. Deliver small measured changes: composer/drafts first,
then the largest proven renderer or idle-work source, with regression checks
appropriate to each layer.
