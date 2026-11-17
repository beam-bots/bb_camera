<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

Guidance for coding assistants working on `bb_camera`.

## What this package is

Camera support for Beam Bots. It owns the `BB.Camera` behaviour, the bounded
shared capture interface (`BB.Camera.Hub`), discovery, the
`BB.Message.Camera.*` lifecycle payloads, the generic `BB.Error.*.Camera.*`
types, a no-hardware driver (`BB.Camera.Synthetic`), and a Membrane source
adapter.

It does **not** own any hardware driver (`bb_camera_v4l` and friends do), any
HTTP transport or UI (`bb_liveview` and `bb_kino` do), and it does not modify
`bb`.

## The one invariant

**No frame bytes on `BB.PubSub`, ever.** Not in events, not in errors, not in
metadata. PubSub carries capture and settings lifecycle only. A frame on a
fan-out registry has no backpressure behind it, and one slow subscriber is
enough to take a node down. `test/bb/camera/hub_test.exs` asserts this
directly; if a change makes that test awkward, the change is wrong.

## Design decisions worth not re-litigating

- **`Hub.deliver/2` is synchronous.** It is the only bound on ingress that
  exists. Making it a cast, or wrapping it in a `Task`, reintroduces the
  unbounded queue it exists to prevent.
- **A request never re-delivers a sequence the consumer already has.** This is
  what stops an HTTP read-in-a-loop consumer spinning at CPU speed rather than
  capture rate.
- **Capture lifecycle is driver-confirmed**, tracked as `:idle`, `:starting`,
  `:capturing`, `:stopping` rather than a boolean. `BeginCapture` is published
  when the driver confirms, never when a subscriber arrives. The state machine
  exists because a consumer arriving while a stop is in flight used to be told
  that a capture it was never part of had ended.
- **The hub forgets `last_sequence` at `capture_started`**, so a driver may
  restart its count per session or carry one counter across restarts.
- **A frame is only ever served to a consumer that belongs to its capture
  session.** `serve/2` checks `in_session?` as well as demand. Without it a
  consumer arriving while a stop was in flight could be handed a frame from
  the outgoing session.
- **Ending a session spends the demand of consumers it notified, and only
  those.** A consumer that arrived during the stop was told nothing, so its
  request is still outstanding and must survive into the next session.
  Clearing it is invisible to the consumer, which then sits out its whole
  timeout on a camera that restarted perfectly well.
- **The Membrane source releases its subscription at end of stream.** Staying
  subscribed would keep the hub's subscriber count above zero, which is what
  it restarts capture on — leaving a camera capturing for an element that will
  never read another buffer. With `end_of_stream_on_capture_end?: false` it
  instead re-offers its outstanding demand, which the hub has just spent.
- **`c:BB.Camera.stream_info/1` must be pure.** Discovery calls it on robots
  that aren't running.
- **`BB.Camera.Info` carries no driver options**, so device paths and
  credentials can't reach a UI through discovery.
- **Interframe formats are refused, not dropped.** See `BB.Camera.Format`.
- **Membrane is an optional dependency**, and the source element is compiled
  only when it's loaded — Membrane constrains `decimal` to `~> 2.0` through
  `ratio`, which a robot not building a media pipeline shouldn't have to
  accept.

## Tests are event-driven, never timed

No `Process.sleep/1`, no test double that takes 300ms, no `refute_receive`
standing in for "it didn't happen". Use `BB.Camera.Synthetic` with
`clock: :external` and drive it frame by frame, or `BB.Camera.TestDriver`
(in `test/support/`) when you need to hold open the window between the hub
asking a driver to do something and the driver confirming — every lifecycle
race lives in that window.

To show something *didn't* happen, push a synchronous call through the process
first, then `refute_received` without waiting. There are no timed
`refute_receive`s in this suite and there should not be one.

Two mistakes this suite has made and corrected, worth not repeating:

- **Producing several frames and then asserting several buffers.** The camera
  holds only the latest frame, so that asserts the consumer happened to be
  scheduled between deliveries — green on a quiet laptop, red under CI load.
  Collect each frame before producing the next.
- **Reading a `BB.Camera.Media` session from a process that didn't open it.**
  Frames go to the subscription's owner, so the reader must be the opener.

## Running things

```bash
mix check --no-retry     # the quality gate: format, credo --strict, dialyzer, reuse, hex.audit
mix test
```

In the workspace, run with `BB_VERSION=local` to resolve `bb` from the sibling
checkout.

## Licensing headers

Every source file carries an SPDX header — `#` for code, an HTML comment for
Markdown, a `<file>.license` sidecar for binaries. `mix check` runs
`reuse lint`. A new file credits the user you're working for, from
`git config user.name`, with the current year.
