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
metadata. PubSub carries capture lifecycle only. A frame on a fan-out registry
has no backpressure behind it, and one slow subscriber is enough to take a node
down. `test/bb/camera/hub_test.exs` asserts this directly; if a change makes
that test awkward, the change is wrong.

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
- **A camera is configured through `c:BB.Sensor.options_schema/0` and nothing
  else.** There was briefly a second channel — a `settings_schema/0` callback,
  a `put_settings` round trip, `ApplySettings`/`RejectSettings` and a
  provenance-carrying `Settings` struct — and it was deleted. It duplicated
  what the parameter system already does: in `bb_camera_v4l` its schema held
  `width`, `height` and `frame_rate`, the same three keys as that driver's
  options. Options can be filled from parameters with `param/1`, are validated
  on every change, and are persisted by a `BB.Parameter.Store`; settings were
  none of those. Reconfigure in `c:BB.Sensor.handle_options/2`. Do not
  reintroduce a camera-specific configuration path.
- **What the camera actually produces is `StreamInfo`, not a setting.** A
  driver reports negotiated geometry with `Hub.update_stream_info/2`, which is
  the honest channel for "what I got" as distinct from "what I asked for".
- **The hub measures the frame rate, and no driver should.** Every frame goes
  through `deliver/2`, so one implementation covers every camera. The window
  is counted rather than smoothed, so a stalled capture reports `0.0` instead
  of the rate it used to manage, and it closes on a clock so it still reports
  when frames have stopped entirely.
- **The hub stamps the pose snapshot, and no driver should.** Where a robot's
  joints are isn't something a camera driver author should have to know
  about. Every joint's configuration is read from the state table per frame
  rather than just the camera's own chain, because the chain can't answer
  where the gripper was. That is not free: it is a lookup and a decode per
  joint per frame, and a `:floating` or `:planar` joint decodes a whole
  `BB.Math.Transform`, which a legged robot at 60fps would feel.
  `BB.Robot.State.get_chain_configurations/2` is the narrower read if it ever
  needs to be.
- **The transform is not computed per frame.** Forward kinematics is a chain
  of 4x4 `Nx` products, which on a small target costs far more than reading
  configurations, and most frames are never asked where they were taken. The
  cheap perishable part is snapshotted; the expensive reproducible part is
  left to whoever wants it.
- **A pose snapshot is the most recently known configuration, not the
  configuration at the shutter.** Joint state is as fresh as the last
  estimator write and no fresher. Say so rather than letting it read as an
  exact instant.
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

Testing against a driver that *can't* be externally clocked — a real one
reading real hardware — means arranging quiet rather than waiting for it:
configure the camera slowly enough that it genuinely cannot produce within the
window you're asserting about, instead of picking a timeout you hope is long
enough.

## Consumers are monitored, never linked

A consumer and a camera watch each other with monitors in both directions: the
hub monitors the subscription's owner so a dead consumer releases the capture,
and `BB.Camera.subscribe/3` monitors the hub so a dead camera surfaces as an
error rather than a hang. The only link in the package is driver-to-hub, and
that is deliberate — they are useless apart.

Don't link a consumer to a camera. A robot shutting down would then kill every
consumer process on the way past, which for an HTTP transport means taking out
each connected browser's process instead of ending its response. There are
tests in `test/bb/camera/media_test.exs` that stop a robot mid-stream and
assert the consumer exits `:normal` with an error return.

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
