<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# bb_camera

Camera support for [Beam Bots](https://github.com/beam-bots/bb): the
`BB.Camera` behaviour, a bounded shared capture interface, and Membrane
interoperability.

A camera is an ordinary `BB.Sensor` that happens to produce rather more data
than a sensor usually does. It is declared in the robot DSL like any other
sensor, supervised like any other sensor, and `bb` itself knows nothing about
cameras.

```elixir
topology do
  link :head do
    sensor :eye, {BB.Camera.Synthetic, width: 160, height: 120}
  end
end
```

## Frames don't go on PubSub

Everything else in `bb` publishes its readings and lets subscribers sort it
out. Cameras can't: a 1080p MJPEG stream is tens of megabytes a second, and a
fan-out registry with no backpressure turns one slow subscriber into an
unbounded mailbox and then into a dead node.

So `BB.PubSub` carries camera *lifecycle* only — capture started and ended,
settings applied and rejected — and frames travel over a bounded interface
served by one `BB.Camera.Hub` per camera. The split isn't an optimisation; it
is what lets a robot keep running when a consumer stalls.

The hub is bounded at both ends. A driver hands frames over with a synchronous
call, so one frame per driver is ever in flight. The hub keeps exactly one
frame, the latest. A consumer gets a frame only when it asks, one at a time,
and only one strictly newer than the last it received — which is what makes a
read-in-a-loop consumer run at the camera's frame rate rather than spinning.

## Consuming a camera

Pull, for code with a loop of its own:

```elixir
{:ok, session} = BB.Camera.Media.open(MyRobot, :eye, format: :jpeg)
{:ok, frame} = BB.Camera.Media.next(session, 2_000)
:ok = BB.Camera.Media.close(session)
```

Demand, for code with its own notion of backpressure:

```elixir
{:ok, subscription} = BB.Camera.subscribe(MyRobot, :eye)
:ok = BB.Camera.request(subscription)
receive do
  {:bb_camera, ref, %BB.Camera.Frame{} = frame} when ref == subscription.ref -> frame
end
```

Or a Membrane pipeline, where the pipeline's demand becomes the camera's:

```elixir
child(:camera, %BB.Camera.Membrane.Source{robot: MyRobot, camera: :eye})
|> child(:decoder, ...)
```

## Finding cameras

`BB.Camera.discover/1` walks the robot's DSL and reports every camera it
declares, running or not. It works on a stopped robot — a camera that should be
there and isn't is exactly what an operator needs to see — and it carries no
driver options, so device paths and credentials can't reach a user interface
through it.

## Formats

JPEG, meaning a stream of complete JPEG images — what the world calls MJPEG.

Interframe codecs are refused rather than carried: the hub's drop-the-stale-
frame policy is lossless for frames that decode independently and silently
destructive for frames that reference each other, so H.264 and its relatives
are rejected at construction rather than corrupted at runtime. See
`BB.Camera.Format`.

## Writing a driver

One module, `use BB.Sensor` and `use BB.Camera`, two callbacks of your own and
three messages from the hub to answer. `BB.Camera.Synthetic` is a complete
worked example that needs no hardware — use it in tests, or behind a UI on a
machine with no camera attached.

Nothing in the interface assumes where frames come from. A driver reading a
device through a subprocess, one calling a platform capture API from a NIF, and
one synthesising frames all meet it identically.

## Membrane is optional

`membrane_core` and `membrane_jpeg_format` are optional dependencies, and
`BB.Camera.Membrane.Source` is only compiled when they're present. Membrane
constrains `decimal` to `~> 2.0` through `ratio`, which a robot that isn't
building a media pipeline shouldn't have to accept. Add them yourself if you
want the source element.

## Installation

```elixir
def deps do
  [
    {:bb_camera, "~> 0.1"}
  ]
end
```

## Licence

Apache-2.0.
