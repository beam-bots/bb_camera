<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

<img src="https://github.com/beam-bots/bb/blob/main/logos/beam_bots_logo.png?raw=true" alt="Beam Bots Logo" width="250" />

# bb_camera

[![CI](https://github.com/beam-bots/bb_camera/actions/workflows/ci.yml/badge.svg)](https://github.com/beam-bots/bb_camera/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache--2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Hex version badge](https://img.shields.io/hexpm/v/bb_camera.svg)](https://hex.pm/packages/bb_camera)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/bb_camera)
[![REUSE status](https://api.reuse.software/badge/github.com/beam-bots/bb_camera)](https://api.reuse.software/info/github.com/beam-bots/bb_camera)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/beam-bots/bb_camera)

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

So `BB.PubSub` carries camera *lifecycle* only — capture started and ended —
and frames travel over a bounded interface served by one `BB.Camera.Hub` per
camera. The split isn't an optimisation; it is what lets a robot keep running
when a consumer stalls.

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

## Installation

Add `bb_camera` to your dependencies:

```elixir
def deps do
  [
    {:bb, "~> 0.33"},
    {:bb_camera, "~> 0.1"}
  ]
end
```

You will also want a driver. `BB.Camera.Synthetic` ships here and needs no
hardware; `bb_camera_v4l` drives Linux V4L2 devices.

## Membrane is optional

`BB.Camera.Membrane.Source` needs `membrane_core` and `membrane_jpeg_format`,
and both are **optional dependencies** — the element is compiled only when
they're loaded. Everything else in the package works without them.

That is not tidiness. Membrane depends on `ratio`, which declares
`decimal ~> 1.6 or ~> 2.0`, while `bb` wants `decimal 3.x` through `localize`.
A robot that isn't building a media pipeline shouldn't be dragged down to a
`decimal` it doesn't want — and `decimal 2.4.1` carries two open DoS
advisories, so being dragged there also fails `mix hex.audit`.

If you want the source element, add all three lines:

```elixir
def deps do
  [
    {:bb, "~> 0.33"},
    {:bb_camera, "~> 0.1"},

    {:membrane_core, "~> 1.3"},
    {:membrane_jpeg_format, "~> 0.1"},

    # `ratio` pins `decimal` below what `bb` wants and below the versions that
    # fix CVE-2026-97853 and CVE-2026-32686. `ratio` treats `decimal` as
    # optional and Membrane never hands it one, so overriding is safe.
    {:decimal, "~> 3.0", override: true}
  ]
end
```

The override has to be in *your* `mix.exs`: Mix only honours `override: true`
from the top-level project, so the copy `bb_camera` carries for its own
dev/test tree does nothing for you.

If you skip the override you'll resolve to `decimal 2.4.1` and `mix hex.audit`
will fail. If you skip the Membrane deps entirely, `BB.Camera.Membrane.Source`
simply won't exist — `Code.ensure_loaded?/1` is the way to check for it at
runtime.

## Licence

Apache-2.0.
