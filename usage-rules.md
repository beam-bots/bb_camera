<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# bb_camera Usage Rules

`bb_camera` provides camera support for [Beam Bots](https://hexdocs.pm/bb): the
`BB.Camera` behaviour, the bounded shared capture interface `BB.Camera.Hub`,
discovery, the `BB.Message.Camera.*` payloads, a no-hardware driver
(`BB.Camera.Synthetic`) and a Membrane source. Hardware drivers live elsewhere
(`bb_camera_v4l` and friends). For BB framework basics, see `bb`'s rules
(`mix usage_rules.sync <file> bb:all`); this file covers only what's specific to
cameras.

## Core principles

1. **Frames never go on `BB.PubSub`.** It carries capture lifecycle
   (`BB.Message.Camera.BeginCapture`, `EndCapture`) and periodic telemetry
   (`CaptureState`), and nothing else — not in events, not in errors, not in
   metadata. A frame on a fan-out registry has no backpressure behind it, and
   one slow subscriber is enough to take the node down.
2. **A request yields exactly one frame, strictly newer than your last.** You
   cannot re-read the current frame. That is what stops a `next`-in-a-loop
   consumer spinning at CPU speed instead of capture rate.
3. **Capture is driver-confirmed and shared.** The hub asks a driver to start
   when the first consumer arrives and to stop when the last leaves; one
   capture serves every consumer. Nothing claims to be capturing until the
   driver says so.
4. **A camera is configured like any other component.** `options_schema/0`,
   filled from parameters with `param/1`, changed through
   `c:BB.Sensor.handle_options/2`. There is no camera-specific settings
   channel — there was, and it was deleted as a duplicate of the parameter
   system.

## Wiring it in

A camera is an ordinary sensor whose callback module also implements
`BB.Camera`. Attach it wherever it physically is, so its pose comes out right:

```elixir
parameters do
  group :camera do
    param(:width, type: :integer, default: 1280)
  end
end

topology do
  link :base do
    joint :pan do
      type(:revolute)

      link :head do
        sensor :eye, {BB.Camera.V4L,
          device: "/dev/video0",
          width: param([:camera, :width]),
          height: 720
        }
      end
    end
  end
end
```

Changing `[:camera, :width]` at runtime re-validates the driver's options and
calls its `handle_options/2`.

## Consuming

- `BB.Camera.Media.open/3` + `next/2` + `close/1` when you have a loop.
- `BB.Camera.subscribe/3` + `request/1` + `unsubscribe/1` when you want
  messages.
- `BB.Camera.Membrane.Source` when you have a pipeline.

Assert the format you can handle (`format: :jpeg`) at `open/3` or
`subscribe/3`. Being told at open is better than discovering it from the bytes.

Treat any `{:error, _}` from `next/2` as a reason to stop streaming. The
distinctions matter for diagnostics, not for control flow.

## What a frame carries

Beyond `data`, `width`, `height` and the timestamps, `BB.Camera.Frame` has
fields the hub stamps that you get for free:

- `requested_frame_rate` / `measured_frame_rate` — what was asked for, and what
  the frames before this one actually did. Compare them; they are separate
  claims on purpose.
- `joint_configurations` — every joint's configuration as at capture, so a
  gimballed camera's pose is recoverable later. Feed it to
  `BB.Robot.Kinematics.forward_kinematics/3` with `attached_to`. It is the most
  recently known configuration, not the one at the shutter.
- `attached_to` — `{:link, name}`, `{:joint, name}` or `:robot`.

`metadata` is for format-specific extras only (a JPEG's component count). Don't
put anything in it that every frame has.

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
- Reconfigure in `handle_options/2`. Restart capture only if the change
  actually reaches the device.
- Don't measure your own frame rate. The hub sees every frame and publishes
  `CaptureState` for every camera.
- Pass `telemetry_clock` through to the hub so a robot can change how often
  that is published.

## Anti-patterns

- **Don't add a camera-specific configuration path.** Options and parameters
  are the one way in. A second channel is what was removed.
- **Don't return `{:error, _}` from `handle_options/2`.** The contract is
  `{:ok, state} | {:stop, reason}`. And know what `{:stop, _}` costs: the
  parameter is already stored, so the component restarts into the same bad
  value. Give parameters bounds that match the options they feed.
- **Don't compute forward kinematics per frame.** Snapshot the configurations
  and let the consumer compute a transform when it actually wants one; on a
  small target the `Nx` cost per frame is the thing that hurts.
- **Don't sleep in tests.** Clock a synthetic or test camera `:external` and
  drive it frame by frame; clock the hub's telemetry `:external` and close a
  window by sending `{:tick, monotonic_ns}`. Wait for the event that proves
  the thing happened.

## Further reading

- [bb_camera docs](https://hexdocs.pm/bb_camera)
- `BB.Camera.Hub` for the capture state machine and the demand model
- [Writing a camera driver](https://hexdocs.pm/bb_camera/01-writing-a-camera-driver.html)
