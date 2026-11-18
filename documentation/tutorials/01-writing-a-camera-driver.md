<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# Writing a camera driver

A camera driver is one module. It is a `BB.Sensor`, so the framework
supervises it, names it and hands it its options like any other sensor; and it
is a `BB.Camera`, which is what makes it discoverable as a camera and gives it
somewhere to put frames.

```elixir
defmodule MyCamera do
  use BB.Sensor, options_schema: [device: [type: :string, required: true]]
  use BB.Camera
end
```

Nothing below assumes where your frames come from. A subprocess, a NIF calling
a platform capture framework, a network stream, or arithmetic all meet this
interface identically.

## The one callback of your own

### `stream_info/1` — and it must be pure

```elixir
@impl BB.Camera
def stream_info(opts) do
  BB.Camera.StreamInfo.new(
    format: :jpeg,
    width: opts[:width],
    height: opts[:height]
  )
end
```

This runs during *discovery*, against robots that are not running, with the
options exactly as written in the DSL — parameter references unresolved,
hardware unopened, possibly absent. Describe what was asked for. Don't open a
device, don't read a file, don't assume a process exists.

What the camera turns out to actually produce is a separate question, answered
at runtime (below). If the options genuinely can't imply a format, return
`{:error, %BB.Error.Invalid.Camera.UnknownStreamInfo{}}` and discovery will
report `stream_info: nil` rather than inventing one.

## Starting the hub

```elixir
@impl BB.Sensor
def init(opts) do
  {:ok, declared} = stream_info(opts)
  {:ok, hub} = BB.Camera.Hub.start_link(bb: opts[:bb], stream_info: declared)

  {:ok, %{bb: opts[:bb], hub: hub, capture: nil}}
end
```

The hub registers itself in the robot's registry — you don't do that. It links
to you, so you fail together, and monitors you, which catches the clean exit a
link wouldn't propagate.

## Two messages to answer

### Starting

```elixir
def handle_info({:bb_camera, :start_capture}, state) do
  case open_device(state) do
    {:ok, state} ->
      BB.Camera.Hub.capture_started(state.hub, actual_stream_info(state))
      {:noreply, state}

    {:error, reason} ->
      BB.Camera.Hub.capture_failed(
        state.hub,
        BB.Error.Hardware.Camera.CaptureFailed.exception(camera: name(state), reason: reason)
      )

      {:noreply, state}
  end
end
```

You are asked to start when the first consumer arrives. **Capture isn't
claimed until you confirm it**: nothing publishes `BeginCapture`, nothing
reports the camera as `:capturing`, and no frame you deliver will be accepted.
A device that fails to open must say so — every consumer waiting on it is then
told, rather than left on a stream that will never produce.

Passing a `StreamInfo` to `capture_started/2` is how you report the geometry
you *negotiated* rather than the one you asked for. It replaces the declared
format from here on, and consumers are told before the first frame it
describes.

### Stopping

```elixir
def handle_info({:bb_camera, :stop_capture}, state) do
  state = close_device(state)
  BB.Camera.Hub.capture_stopped(state.hub)
  {:noreply, state}
end
```

You are asked to stop when the last consumer leaves. You don't need to work out
why — when the hub asked, it uses its own reason for the published event.

## Reconfiguring at runtime

A camera is configured like every other component: through
`c:BB.Sensor.options_schema/0`. A robot can fill any of those options from a
parameter, and changing it at runtime re-validates the options against your
schema and calls your `c:BB.Sensor.handle_options/2`:

```elixir
parameters do
  group :camera do
    param(:width, type: :pos_integer, default: 640)
  end
end

topology do
  link :head do
    sensor :eye, {MyCamera, device: "/dev/video0", width: param([:camera, :width])}
  end
end
```

```elixir
@impl BB.Sensor
def handle_options(new_opts, state) do
  {:ok, reopen_device(state, new_opts)}
end
```

Two things to get right here.

**Say what changed, in the right way.** If you can retune the device in place
and the geometry moved, `BB.Camera.Hub.update_stream_info/2` tells consumers
before the first frame the new format describes. If the change means a new
capture — as it does whenever the device negotiates on open — then it is an
end and a beginning: `capture_stopped/2`, then `capture_started/2` when the
replacement produces a frame. Don't announce a format the old capture is still
producing.

**You cannot refuse.** The contract is `{:ok, state} | {:stop, reason}`; there
is no "no thank you". Worse, the parameter was validated against *its own*
declared type, stored, and published before you were asked, so stopping means
restarting into the same value and stopping again. Declare parameters with
bounds that match the options they feed — `type: :pos_integer` above, not
`:integer` — and treat `{:stop, _}` as the last resort it is.

There is no camera-specific settings channel. One schema, one way to change it.

## Delivering frames

```elixir
:ok =
  BB.Camera.Hub.deliver(
    state.hub,
    BB.Camera.Frame.new!(
      format: :jpeg,
      width: width,
      height: height,
      data: jpeg,
      sequence: state.sequence
    )
  )
```

`deliver/2` is a **synchronous call**, and this is deliberate. It is the only
bound on ingress that exists: you block until the hub has taken the frame, so
one frame per driver is ever in flight. Wrapping it in a `Task` to avoid
blocking capture reintroduces exactly the unbounded queue it exists to prevent.

Report `width` and `height` as *encoded*, not as requested — parse them out of
the data if you can.

`sequence` must strictly increase within a capture session. The hub forgets its
expectation whenever capture is confirmed started, so you may restart at zero
per session or carry one counter across restarts, whichever your backend makes
natural. Leave it `nil` and the hub stamps it.

## What the hub adds on the way past

Four fields on every frame are the hub's job, not yours. Don't compute them,
and don't duplicate them in `metadata`:

- `measured_frame_rate` and `requested_frame_rate` — the hub sees every frame,
  so it counts them. **Don't measure your own rate.** The same numbers go out
  periodically as `BB.Message.Camera.CaptureState`, once a second by default;
  accept a `:telemetry_clock` option and pass it to `Hub.start_link/1` so a
  robot can change that.
- `joint_configurations` and `attached_to` — where the robot was when the
  frame arrived, so a gimballed camera's pose can be recovered afterwards.
  Your driver knows nothing about the robot's shape and shouldn't have to.

`metadata` is yours, and it is for what only *your* format knows — a JPEG's
component count, its precision, whether it was progressive. Anything every
frame has belongs in a named field, which means it belongs to `bb_camera`.

## Bounding what happens before the hub

`deliver/2` bounds what crosses into `bb_camera`. It cannot bound what
accumulates before it, and two things routinely catch people out.

**Ports have no ingress backpressure.** `Port.open`'s `busy_limits_msgq` is
accepted but does not govern port-to-owner data; a fast producer will queue
gigabytes into your mailbox. Cap your output rate, keep a drain-only owner
process that does nothing but frame, impose hard buffer and frame-size limits
with resync, and trip explicitly on mailbox depth.

**Closing a port does not kill the program behind it.** Neither does killing
the port's owner, nor the owner crashing — the process is reparented and
carries on. It usually dies of `SIGPIPE` on its next write, which is exactly
what doesn't happen when a camera has wedged. You need an explicit reaper;
`terminate/2` is not enough.

A native capture callback pushing frames into a process mailbox has the same
shape of problem and wants the same kind of answer.

## If your driver feeds a Membrane pipeline

`BB.Camera.Membrane.Source` is compiled only when Membrane is loaded, because
Membrane's `ratio` pins `decimal` below what `bb` wants — and below the
versions that fix its DoS advisories. Opting in means three additions to *your*
`mix.exs`, including the override, which Mix only honours from the top-level
project:

```elixir
{:membrane_core, "~> 1.3"},
{:membrane_jpeg_format, "~> 0.1"},
{:decimal, "~> 3.0", override: true}
```

Nothing a driver does requires any of this. The hub interface is the same
either way.

## Testing it

Clock your driver externally and drive it frame by frame. Never sleep, and
never race a timeout against work that is merely slow. Give your driver some
way for a test to say "produce one now" — `BB.Camera.Synthetic.capture_frame/2`
is that function for the synthetic camera, and yours wants an equivalent:

```elixir
{:ok, session} = BB.Camera.Media.open(MyRobot, :eye, format: :jpeg)
:ok = MyCamera.capture_frame(MyRobot, :eye)
assert {:ok, %BB.Camera.Frame{}} = BB.Camera.Media.next(session, 1_000)
```

The hub's telemetry has the same treatment: start it `telemetry_clock:
:external` and close a measurement window by sending the hub
`{:tick, monotonic_ns}`, rather than waiting a real second for one.

`BB.Camera.Synthetic` is a complete driver built this way and is worth reading
start to finish — it is shorter than this page.

For the lifecycle races, `BB.Camera.TestDriver` in this package's
`test/support/` holds open the window between the hub asking for something and
a driver confirming it. Every interesting race lives in that window.
