# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Subscription do
  @moduledoc """
  A consumer's handle on a camera's capture.

  Holding one does not make frames arrive. Each `BB.Camera.request/1` asks for
  exactly one frame, strictly newer than the last one delivered on this
  subscription, and at most one request is outstanding at a time. That is what
  keeps a consumer's loop running at the camera's rate rather than at the
  processor's, and what keeps the hub's memory at one frame regardless of how
  slow a consumer is.

  `monitor` is the hub's monitor reference. Consumers should match on
  `{:DOWN, monitor, :process, _, _}` so a camera that dies surfaces as an error
  rather than a wait that never ends.
  """

  alias BB.Camera.StreamInfo

  defstruct [:robot, :camera, :hub, :ref, :monitor, :stream_info]

  @type t :: %__MODULE__{
          robot: module(),
          camera: atom(),
          hub: pid(),
          ref: reference(),
          monitor: reference(),
          stream_info: StreamInfo.t()
        }
end
