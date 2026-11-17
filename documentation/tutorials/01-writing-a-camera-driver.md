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

## Two callbacks of your own

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

### `settings_schema/0` — optional

```elixir
@impl BB.Camera
def settings_schema do
  Spark.Options.new!(frame_rate: [type: :float, default: 30.0])
end
```

Settings are validated against this before you are asked to apply them, so an
invalid set never reaches your hardware. Defaults to accepting nothing.

## Starting the hub

```elixir
@impl BB.Sensor
def init(opts) do
  {:ok, declared} = stream_info(opts)

  {:ok, hub} =
    BB.Camera.Hub.start_link(
      bb: opts[:bb],
      stream_info: declared,
      settings: BB.Camera.Settings.new(%{frame_rate: 30.0}),
      settings_schema: settings_schema()
    )

  {:ok, %{bb: opts[:bb], hub: hub, capture: nil}}
end
```

The hub registers itself in the robot's registry — you don't do that. It links
to you, so you fail together, and monitors you, which catches the clean exit a
link wouldn't propagate.

## Three messages to answer

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

### Settings

```elixir
def handle_info({:bb_camera, {:put_settings, settings, ref}}, state) do
  BB.Camera.Hub.settings_result(state.hub, ref, apply_settings(settings, state))
  {:noreply, state}
end
```

`settings` is the complete resulting set, not just the keys that changed — the
hub merges a caller's patch over the current values first, so a change to one
setting can't reset another to its schema default.

To report something nobody asked for — a value the device changed underneath
you, or a frame rate you measured — use `BB.Camera.Hub.update_settings/2`.

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
never race a timeout against work that is merely slow.

```elixir
{:ok, session} = BB.Camera.Media.open(MyRobot, :eye, format: :jpeg)
:ok = MyCamera.capture_frame(MyRobot, :eye)
assert {:ok, %BB.Camera.Frame{}} = BB.Camera.Media.next(session, 1_000)
```

`BB.Camera.Synthetic` is a complete driver built this way and is worth reading
start to finish — it is shorter than this page.

For the lifecycle races, `BB.Camera.TestDriver` in this package's
`test/support/` holds open the window between the hub asking for something and
a driver confirming it. Every interesting race lives in that window.
