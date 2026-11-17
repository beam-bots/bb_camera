# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Info do
  @moduledoc """
  What `BB.Camera.discover/1` reports about one camera.

  ## There is deliberately no `:options` field

  A camera's DSL options are where its device path, its URL and - for a network
  camera - its credentials live. Discovery is what a user interface enumerates
  to draw a list of cameras, and a struct that carried those options would put
  them one careless `inspect` away from a rendered page or a log line.
  Discovery reads them to call `c:BB.Camera.stream_info/1` and keeps them.

  ## Status

  - `:declared` - in the DSL, no hub alive. The robot isn't started, the sensor
    crashed, or the hardware isn't there. Reported rather than omitted: a
    camera that should exist and doesn't is exactly what an operator needs to
    see. `stream_info` is then the declared one, or `nil` if the driver
    couldn't derive one from options alone.
  - `:running` - hub alive, nobody watching, no capture in progress.
  - `:capturing` - hub alive and the driver has confirmed capture is running.
  """

  alias BB.Camera.StreamInfo

  defstruct [
    :robot,
    :name,
    :path,
    :topic,
    :module,
    :attached_to,
    :stream_info,
    :status,
    :pid
  ]

  @type status :: :capturing | :running | :declared

  @type t :: %__MODULE__{
          robot: module(),
          name: atom(),
          path: [atom()],
          topic: [atom()],
          module: module(),
          attached_to: {:link, atom()} | {:joint, atom()} | :robot,
          stream_info: StreamInfo.t() | nil,
          status: status(),
          pid: pid() | nil
        }
end
