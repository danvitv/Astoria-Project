# Mobile chat performance: input latency, heat, and battery

Status: synthetic baseline, input/draft optimizations, code audit, and Android
typing/idle traces completed, 2026-10-04.
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

### Reproducible desktop synthetic baseline

Run the opt-in harness from the project root:

```powershell
flutter test test/performance --dart-define=CHAT_SYNTHETIC_PERF=true --concurrency=1 --reporter expanded
```

Without the define these benchmarks are skipped by the normal test suite.
They use fabricated messages and a temporary database, never local chat data.
Each result is a `CHAT_SYNTHETIC` JSON line. The repository harness uses the
actual draft method and a background SQLite executor, with 4 warmups and 20
samples per history size (50 / 500 / 2000), with and without Studio/swipes.
It reports save time, a separate history decode control, and main-isolate
heartbeat gaps. Gaps are scheduling observations, not Flutter frame timings;
the OS does not guarantee a 1 ms timer. Composer scenarios count actual subtree
builds and debounced draft callbacks for text, backspace, cursor, composition,
and idle through the simulated IME connection, with one pump per event.

Use these to reproduce redundant work and history-size scaling, then compare
changes on the same machine / SDK with serial runs. `flutter test` is a debug
host environment: absolute timings do not predict Android input latency,
WebView/GPU cost, phone heating, or watts. Native traces are still needed for
those measurements.

### Baseline results, 2026-10-04

Windows host, Dart 3.12.0, `flutter test` debug environment, serial cases, no
analyzer running during measurement. Two full runs agreed on the work counts
and history-size scaling. The table reports the second run, in milliseconds:

| Messages | History | JSON UTF-8 MB | Draft save p50 / p95 | Decode control p50 / p95 | Largest heartbeat gap per save p50 / p95 |
|---|---|---:|---:|---:|---:|
| 50 | Plain | 0.13 | 5.51 / 10.28 | 0.33 / 0.37 | 2.00 / 2.08 |
| 500 | Plain | 1.29 | 15.17 / 20.60 | 4.94 / 5.93 | 4.28 / 6.03 |
| 2000 | Plain | 5.18 | 52.53 / 67.64 | 17.06 / 27.79 | 18.18 / 26.60 |
| 50 | Studio / swipes | 0.31 | 6.15 / 17.35 | 0.94 / 1.00 | 2.02 / 2.50 |
| 500 | Studio / swipes | 3.06 | 26.35 / 35.21 | 5.98 / 7.53 | 6.79 / 9.38 |
| 2000 | Studio / swipes | 12.23 | 103.45 / 135.21 | 28.48 / 36.04 | 28.29 / 39.86 |

Idle heartbeat gaps were approximately 2 ms median in all cases. The first run
had 99.80 ms median save / 25.52 ms median decode for the largest rich history;
absolute durations vary, while the scaling is consistent. Full save latency
includes asynchronous database work and is not the duration of UI blocking.
The isolated decode and heartbeat observations identify main-isolate work, but
do not establish its proportion of each save or Android's missed-frame rate.

Composer work counts were identical in both runs:

| Scenario | IME events | Composer builds | GlassSurface builds | Draft callbacks after pause |
|---|---:|---:|---:|---:|
| Type | 80 | 80 | 400 | 1 |
| Backspace | 40 | 40 | 200 | 1 |
| Cursor only | 40 | 40 | 200 | 1 |
| Composition only | 40 | 40 | 200 | 1 |
| Idle | 80 pumps | 0 | 0 | 0 |

No draft callbacks occurred during these event bursts. Cursor and composition
scenarios retained identical text, yet rebuilt the whole composer once per
event and requested another draft save after the pause. Each such event also
caused about 138 other element builds in this configured subtree. Counts are
element rebuilds, not pixels repainted, GPU passes, or native IME latency. This
harness isolates the composer: its idle result says nothing about timers in
the rest of the chat or a native WebView.

These results justify prioritizing text-change-only draft scheduling, reducing
unrelated composer rebuilds, and removing full-history reconstruction from the
draft persistence path. Validate changes against this baseline and the
existing draft/send race tests, then verify input and power on a device.

### Implemented changes and repeat measurements

- Composer chrome rebuilds only when message/guidance emptiness changes, or
  another actual UI state changes. EditableText handles text, cursor,
  composition, and multiline layout. Only actual message text changes schedule
  draft saves; impersonation cancels pending debounce and does not save streams.
- Draft writes now use one atomic SQL update guarded by session id and
  `json_array_length(messages_json)`. They return only the draft instead of
  transferring/scanning/decoding the full chat on the UI isolate. The shared
  write queue and save-epoch/session/count fences remain. Identical in-memory
  drafts still get the durable write but do not publish another ChatState.
- The app-wide history watcher now selects projected metadata on the DB
  executor and suppresses unchanged metadata before character/avatar reads.
  Previously every draft write transferred and scanned all session histories,
  then emitted even when metadata was unchanged. Equality includes preview,
   character, origin, and index so real same-timestamp changes are delivered.
   The device follow-up also projects individual typed session-name/origin and
   last-message preview fields, rather than transferring whole variables or the
   last message's reasoning/swipes. Legacy text-part content and UTF-16
   continuation offsets remain supported; malformed optional variables are
   ignored as before.
- History subscription callbacks are fenced against disposal, rebuild, and
  newer asynchronous updates. The faster query exposed an existing late
  callback in the hidden-character test.

Same Windows/SDK/debug harness, 4 warmups and 20 samples per case. Final serial
run after these changes, milliseconds:

| Messages | History | Draft save p50 / p95 | Largest heartbeat gap per save p50 / p95 |
|---|---|---:|---:|
| 50 | Plain | 3.73 / 6.00 | 1.96 / 2.14 |
| 500 | Plain | 5.65 / 12.55 | 2.01 / 2.51 |
| 2000 | Plain | 14.98 / 32.33 | 2.00 / 2.47 |
| 50 | Studio / swipes | 3.98 / 4.76 | 1.93 / 2.15 |
| 500 | Studio / swipes | 10.31 / 20.09 | 2.00 / 2.42 |
| 2000 | Studio / swipes | 27.34 / 78.96 | 2.04 / 2.94 |

For the largest rich chat the save median fell from 103.45 to 27.34 ms; heartbeat
gap p95 fell from 39.86 to 2.94 ms. SQLite still parses the count and rewrites the
row off the UI isolate; this is not constant-cost persistence. One small plain
case had a 32.48 ms maximum heartbeat outlier, so the result does not imply a
universal scheduling bound. The independent decode control is still measured
by the harness but is no longer part of the production draft path.

An eighth scenario adds a live metadata subscription with two rich chats
(2000 + 500 messages). After only the draft-write optimization, 20 saves caused
21 metadata emissions (including initial): save p50/p95 45.25/129.21 ms,
heartbeat 8.66/9.92 ms. After the watcher optimization: one initial emission,
save 28.87/89.44 ms, heartbeat 2.12/2.95 ms. Each sample waits for watcher delivery;
this confirms avoided downstream work, not actual phone battery savings.

| Scenario | IME events | Composer builds before / after | GlassSurface builds before / after | Draft callbacks before / after |
|---|---:|---:|---:|---:|
| Type | 80 | 80 / 1 | 400 / 5 | 1 / 1 |
| Backspace | 40 | 40 / 0 | 200 / 0 | 1 / 1 |
| Cursor only | 40 | 40 / 0 | 200 / 0 | 1 / 0 |
| Composition only | 40 | 40 / 0 | 200 / 0 | 1 / 0 |
| Idle | 80 pumps | 0 / 0 | 0 / 0 | 0 / 0 |

EditableText still rebuilds to render input. The first typed event changes
empty to nonempty; the remaining events no longer rebuild the surrounding
buttons/glass. Regression coverage includes guidance's latest text, IME
composition/cursor, impersonation, attachments, rejected sends, durable draft
clearing, session changes, message-count guards, and metadata changes.

Remaining candidate: a genuinely changed draft still publishes ChatState and
can rebuild `chat_screen.dart` (which watches the full chat provider), entering
search/layout/bridge checks. Existing identity guards suppress unnecessary DOM
message synchronization. Measure this residual cost before separating draft
notifications or narrowing more subscriptions.

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

### Overall code audit: next priorities

These are observed code paths, not a measured attribution of phone power.

1. **Periodic scripts can overlap.** `periodic_trigger_scheduler.dart` launches
   each tick without an in-flight guard per block. `PeriodicJsBlockRunner`
   cancels a job when the active context changes, but does not serialize repeated
   jobs for the same block. A script slower than its interval can accumulate
   work. The scheduler already pauses when the app is not resumed and restricts
   execution to the active chat. Next: controlled slow-script test, then
   single-flight/coalescing per block without losing legitimate ticks.
2. **Memory vector search loads too broadly.** `MemoryVectorSearcher` loads all
   `memory_entry` embeddings before filtering the current entry ids. Hashing,
   vector decoding, and similarity scoring then run on the calling isolate.
   Lorebook search already selects relevant source ids, but its scoring also
   needs a CPU benchmark. Next: synthetic entry-count/dimension cases, filtered
   memory lookup, then isolate scoring if measured. This is preparation-time
   work, not evidence of an idle loop.
3. **Image timers ignore battery-saver cadence.** WebView `ImgGenTimer` walks
   rendered message/shadow trees every 100 ms while image generation is active,
   even in battery saver. Text and extension clocks already switch to 1000 ms.
   The image timer stops when no active clocks remain. Next: align cadence and
   measure selector/update work with many rendered image blocks.
4. **Animated effects and hidden WebView lifecycle need native profiling.**
   CSS has backdrop filters and continuous pending/shimmer/typing animations;
   Flutter also has screen-scoped animated indicators. Main JS frame loops
   inspected are bounded or event-driven; no unconditional idle loop was found.
   The kept-alive WebView may retain compositor work offscreen: verify its
   actual native lifecycle rather than inferring this from retained objects.
5. **Foreground holds explicitly keep the phone awake.** The mobile service
   enables wake/Wi-Fi locks and stops at zero reference-counted holds. Leases
   are serialized/idempotent; no leak was established. Generation, embedding,
   sync, and post-generation jobs can legitimately hold it after story output.
   Trace hold ownership and duration after Stop/job settlement. The silent
   audio helper is iOS-only and does not explain Android load.
6. **Sync is bursty, not continuous polling.** Auto-sync defaults to a full push
   every five eligible messages, with an in-flight guard and foreground lease
   cleanup. Large-library manifest/file work can explain spikes; benchmark it
   separately when enabled. Danvi reports auto-sync is disabled, so automatic
   pushes are excluded from candidates for his reported typing/heat symptoms.
   Update checks are hourly, foreground-aware, and guarded. Catalog
   challenge polling is local to the challenge widget and cancels on disposal.

Suggested sequence after input/drafts: slow-script overlap regression and image
timer cadence, vector-search synthetic benchmark, then native WebView/blur and
foreground-hold traces. Optimize the largest confirmed remaining source first.

## Android device follow-up, 2026-10-04

Device: Xiaomi model 2412DPC0AG / MT6899, Android 15, 1220 x 2712, peak refresh
setting 120 Hz; Google WebView 153.0.8010.36 and Gboard. Native arm64 dev-channel
profile builds were installed over the existing app with the same signing
certificate, preserving application data. The owner manually typed/deleted in
an existing 107-message chat; no story/API generation was initiated. Auto-sync
and periodic extension scripts are disabled in this user's setup.

### Confirmed remaining input bottleneck and correction

The first native typing sample, after the initial synthetic optimizations,
still spent 576 of 1362 main-isolate CPU samples in `_projectedMetadata`, with
573 samples including JSON decoding. A short chat can have very large session
variables and a last message with Studio output/swipes; the initial projection
still transferred and decoded both whole objects after table invalidation.

The query now projects only the required typed scalar/preview fields on the
background SQLite executor. In a second approximately 25-second manual typing
sample, `_projectedMetadata` accounted for 8 of 880 samples and JSON decoding
did not appear. This establishes removal of that work; manual typing rates and
profiler initialization differed, so the counts are not a controlled percentage
improvement in total CPU or input latency.

Regression tests cover large variables, reasoning/swipes, invalid optional
variables, legacy text-part content, emoji continuation offsets, and real
same-timestamp metadata changes. The live-subscription synthetic fixture now
also includes 30 extra chats with large variables/reasoning/swipes (32 chats
total). On this expanded fixture, 20 draft saves emitted only the initial
metadata list; save p50/p95 was 69.67/109.86 ms and heartbeat-gap p50/p95 was
2.47/3.48 ms. This changed fixture is not directly comparable to the earlier
two-chat table.

### Frame and idle observations

Flutter frame events were filtered by their frame start within the CPU sampling
window, excluding queued events from before capture:

| Scenario | Frames | Build p50 / p95 | Raster p50 / p95 | Total span p50 / p95 |
|---|---:|---:|---:|---:|
| Manual typing, about 25 seconds | 378 | 0.77 / 5.10 ms | 3.50 / 6.88 ms | 10.53 / 16.76 ms |
| Idle with focused input and keyboard, about 25 seconds | 50 | 1.59 / 2.01 ms | 9.70 / 11.09 ms | 14.85 / 16.14 ms |

The typing sample had 20 total spans over 16.67 ms, with a 38.23 ms maximum.
Total span includes vsync overhead and is not key-event-to-present latency;
the configured peak refresh rate does not establish the active refresh rate
or deadline of every frame. Native frame-timeline slices do not cover all
Flutter surfaces and must not replace the Flutter event distribution.

Focused idle produced about two frames per second, consistent with caret
blinking, rather than continuous 60/120 Hz Flutter rebuilding. Even these rare
frames invoke Android external-view composition: 50
`AndroidExternalViewEmbedder::SubmitFlutterView` slices totaled 380.64 ms.
After CPU profiling/timeline recording were disabled and the keyboard was
hidden, a separate 30-second system trace still showed 60 native draw frames.
Hiding the keyboard alone need not remove text-field focus or stop the caret.
This is evidence to profile native composition/repaint isolation next, not
proof that blur or an unconditional WebView animation causes the work.

During typing, Perfetto showed material background database-worker CPU time
(about 6.8 CPU seconds in the 30-second system trace). Moving JSON work off the
UI isolate fixes responsiveness but does not eliminate the SQLite scan/count
and row-write cost or table-wide query invalidation. Next database optimization
should measure avoiding metadata re-query on draft-only updates, with all
watcher/atomic-write semantics preserved, rather than suppressing notifications
globally. A focused snapshot after idle showed no Astoria generation foreground
service or Astoria-owned partial wake lock; this does not verify all holds after
Studio/Stop, which was not exercised on the phone in this capture.

### Measurement limits and handling

The phone remained USB-powered/charging. Hardware power-rail packets were empty;
neither watts nor battery-life/temperature improvement was measured. CPU
sampling and trace collection also add work. CPU profiling and timeline streams
were disabled after capture. Raw traces, CPU samples, screenshots, service URLs,
and the original APK backup are temporary local diagnostics, not repository
files. Release-mode confirmation, repeatable native input latency, separate
effect toggles, Studio/Stop hold lifetimes, and unplugged power measurements
remain follow-ups.

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
