<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# bb_camera usage rules

## Never publish frames

`BB.PubSub` carries camera lifecycle only: `BB.Message.Camera.BeginCapture`,
`EndCapture`, `ApplySettings`, `RejectSettings`. Frame bytes go over
`BB.Camera.Hub` and nowhere else, including inside error payloads. A frame on a
fan-out registry has no backpressure behind it, and one slow subscriber is
enough to take the node down.

## Consuming

- `BB.Camera.Media.open/3` + `next/2` + `close/1` when you have a loop.
- `BB.Camera.subscribe/3` + `request/1` + `unsubscribe/1` when you want
  messages.
- `BB.Camera.Membrane.Source` when you have a pipeline.

A request yields exactly one frame, strictly newer than the last one you were
given. Don't build a consumer that assumes it can re-read the current frame —
it can't, and that is what stops a `next`-in-a-loop consumer spinning.

Assert the format you can handle (`format: :jpeg`) at `open/3` or
`subscribe/3`. Being told at open is better than discovering it from the bytes.

Treat any `{:error, _}` from `next/2` as a reason to stop streaming. The
distinctions matter for diagnostics, not for control flow.

## Discovering

Use `BB.Camera.discover/1`. Don't write a second DSL walker — it works on
stopped robots, and it deliberately omits driver options so device paths and
credentials can't leak into a UI.

If a package treats `bb_camera` as optional, guard with
`Code.ensure_loaded?(BB.Camera)` and return `[]`. A robot can't declare a
camera without the package, because `use BB.Camera` wouldn't compile.

## Writing a driver

- One module: `use BB.Sensor` and `use BB.Camera`.
- `c:BB.Camera.stream_info/1` **must be pure**. It runs during discovery
  against robots that aren't running, with unresolved DSL options. Describe
  what was asked for; report what you actually got through
  `BB.Camera.Hub.capture_started/2` or `update_stream_info/2`.
- Start the hub in `init/1` with `BB.Camera.Hub.start_link/1`. Don't register
  it yourself.
- Answer `{:bb_camera, :start_capture}` with `capture_started/2` **or**
  `capture_failed/2`. Capture isn't claimed until you confirm it, and a device
  that fails to open must say so rather than go quiet.
- `BB.Camera.Hub.deliver/2` is a synchronous call. That is the only bound on
  ingress there is. Never wrap it in a `Task`.
- Bound what happens before the hub yourself. Ports have no ingress
  backpressure, and closing a port doesn't kill the program behind it.
- Report values you verified as `:actual` and values you only asked for as
  `:requested`. `BB.Camera.Settings` exists so that distinction survives to
  whoever is looking at the robot.

## Testing

Clock a synthetic or test camera `:external` and drive it frame by frame. Never
sleep, and never race a timeout against work that is merely slow. Every test in
this package waits for the event that proves the thing happened.
