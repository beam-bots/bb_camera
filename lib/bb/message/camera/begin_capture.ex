# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Message.Camera.BeginCapture do
  @moduledoc """
  A camera has started capturing.

  Published when the *driver* confirms capture with
  `BB.Camera.Hub.capture_started/2` - not when a consumer subscribes. A driver
  whose device fails to open never produces this message; it produces
  `BB.Message.Camera.EndCapture` with `reason: :error` instead. There is no
  window in which the system says it is capturing and isn't.

  Carries no image data, as nothing published on `BB.PubSub` ever does.
  """

  alias BB.Camera.StreamInfo

  defstruct [:stream_info, :subscriber_count]

  use BB.Message,
    schema: [
      stream_info: [
        type: {:struct, StreamInfo},
        required: true,
        doc: "What the camera is producing, as the driver confirmed it"
      ],
      subscriber_count: [
        type: :non_neg_integer,
        required: true,
        doc: "Consumers sharing this capture when it started"
      ]
    ]

  @type t :: %__MODULE__{
          stream_info: StreamInfo.t(),
          subscriber_count: non_neg_integer()
        }
end
