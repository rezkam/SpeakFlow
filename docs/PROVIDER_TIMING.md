# Batch provider timing

Enable observability at Info verbosity to collect these events. They use the existing
observability storage, retention, and enabled/disabled settings. This instrumentation
covers ChatGPT Batch and Mistral Batch, not realtime WebSocket providers.

## Correlation

`ProviderTiming` events carry `schemaVersion=1`, an allowlisted `provider`, a generated
`requestId`, and an `attempt` number. In the recording pipeline, `requestId` is the
existing `taskId` in `Transcription.chunk_submitted`, `chunk_succeeded`, and
`chunk_failed`. The event's `sessionId` is captured before scheduling and remains
attached to the original recording, even if a replacement recording starts.

Attempt numbers start at 1. Request-level phases use attempt 0. Retries keep the same
request and session IDs. Direct provider calls outside a recording generate a request
ID and may have no session ID. Event persistence is asynchronous: use IDs and explicit
elapsed durations rather than assuming adjacent records describe adjacent operations.

## Events

- `provider_attempt_started`: one actual provider attempt begins.
- `provider_attempt_finished`: one terminal outcome and monotonic `elapsedMs`, with
  optional numeric `httpStatus`, `urlErrorCode`, and categorical `retryable`.
- `provider_phase_finished`: `phase`, monotonic `elapsedMs`, and categorical `outcome`.
- `http_task_metrics`: URLSession duration, transaction/redirect counts, and availability.
- `http_transaction_metrics`: per-transaction network milestones and byte counts.

Local phases are `scheduling`, `configuration`, `rate_limit`, `request_build`, `decode`,
and `retry_delay`. `authentication` includes credential loading and any refresh network
request, so it is not necessarily local CPU time. `transport` spans the awaited HTTP
operation, including its deadline handling. `provider_call` spans the entire provider
call, including local setup, retries, and decoding. These intervals overlap; do not add
parent and child durations together.

ChatGPT preserves its existing retry, rate-limit, credential, timeout, and cancellation
policy. Mistral preserves its existing single-attempt policy and shared connection pool.
`retryable` describes the existing error classification, not a promise that a retry was
performed. Count actual subsequent attempt-start events to establish retries.

## Network phases

| Field | URLSession milestone interval |
| --- | --- |
| `dnsMs` | domain lookup start to end |
| `connectMs` | connection start to end |
| `tlsMs` | secure connection start to end |
| `uploadMs` | request start to request end |
| `responseWaitMs` | request end to response start |
| `downloadMs` | response start to response end |
| `timeToFirstByteMs` | fetch start to response start |

`responseWaitMs` is **not server processing time**. It includes network propagation,
provider queueing/processing, and buffering that cannot be separated client-side.
`uploadMs` is URLSession's transmission interval, not proof of server receipt.
`connectMs` may include TLS; `tlsMs` is not an additional interval to sum with it.
First-byte timing overlaps setup, upload, and response wait.

Transactions also record connection reuse, allowlisted protocol/fetch type, body byte
counts, and optional HTTP status. Redirects can produce multiple transactions within
one attempt. A reused connection normally lacks DNS/connect/TLS milestones.

Unavailable, nonfinite, or reversed milestones are omitted, never reported as zero.
A measured zero remains zero. An absent metrics callback or empty transaction list is
reported with `metricsAvailable=false`; `metricsCollected` distinguishes those cases.
Injected test transports need not provide URLSession metrics. Missing network phases
are unknown, not evidence that upload or response wait was instantaneous.

## Following an Enter delay

1. Find `key_interceptor_enter_captured` and `recording_stop_requested` for the recording.
2. Follow its `sessionId` through `chunk_submitted` and the provider timing events.
   Match `taskId` to `requestId` to distinguish concurrent chunks and retries.
3. Compare request-level local phases with upload, response-wait, and download intervals.
   The last required chunk can dominate the stop delay, even if earlier chunks were fast.
4. Follow `chunk_succeeded`, `batch_finalization_completed`, insertion events, and
   `press_enter_queued` / `press_enter_emitted` under the same session ID.
   Existing `focus_lost_waiting` / `focus_regained` events identify focus-safe pauses.

Stop-to-Enter timestamp differences approximate the complete delay. They also contain
audio drain, ordered-delivery waits, finalization scheduling, and insertion/modifier/focus
waits that are not network phases. These existing events are retained without changing
finalization, insertion, or Enter behavior. They do not provide a separate monotonic
measurement of every internal queue wait. `press_enter_emitted` means the key was posted,
not that a third-party app accepted it or submitted a message.

## Reliability and privacy

For a defined observation window, count attempt outcomes, HTTP status categories,
timeouts, cancellations, and observed retries separately for each provider. Compare
request-level `provider_call` duration distributions, not just successful attempt times.
A failed attempt followed by success is a recovered request, not a failed request.
Cancellation is not evidence of provider failure. Missing terminal events can reflect
truncated/rotated logs or process termination. Do not infer availability from a small,
selected sample or compare batch measurements to uninstrumented realtime providers.

Only generated correlation IDs, allowlisted categories, counts, and durations enter
these timing events. They contain no transcript, audio, credentials, endpoint, headers,
response body, or free-form error description. Existing text-capture settings do not
add payloads to timing events. Raw observability files may contain unrelated sensitive
records; extract only the required timing fields before sharing diagnostics.

Loopback HTTP probes and injected failure/retry tests establish instrumentation behavior.
They do not measure live provider latency, availability, or third-party Enter acceptance.
