# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Media.Session do
  @moduledoc """
  A `BB.Camera.Media` consumer's handle on a camera.

  `stream_info` is the camera's advertised format at the moment the session
  opened. Describe a *frame* with the frame's own `format`, `width` and
  `height`: a camera that renegotiates its geometry mid-capture produces frames
  that disagree with what it advertised, and the frames are the truth.
  """

  alias BB.Camera.{StreamInfo, Subscription}

  defstruct [:subscription, :stream_info]

  @type t :: %__MODULE__{
          subscription: Subscription.t(),
          stream_info: StreamInfo.t()
        }
end
