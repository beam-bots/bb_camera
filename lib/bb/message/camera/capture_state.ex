# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Message.Camera.CaptureState do
  @moduledoc """
  How a running capture is actually going, published periodically.

  `capture_state` is the same lifecycle value `BB.Camera.Hub.capture_state/1`
  returns, so a subscriber watching only this message can tell whether the
  camera is capturing or on its way down without asking. The rest describes
  the window just ended.

  `requested_frame_rate` is what the camera was asked for and
  `measured_frame_rate` is what the frames did. They are separate fields
  because they are separate claims: a driver can pass `-framerate 30` to
  ffmpeg and report 30 without anything having confirmed it, and a camera
  whose device quietly settled on 15 would otherwise look fine.

  The measured rate is counted over the window since the previous message -
  frames delivered divided by elapsed seconds - rather than smoothed across
  the whole session. That way a capture that has stalled reports `0.0` at the
  next message instead of continuing to report the rate it used to manage.
  It is `nil` only in the first message of a session, which has no window
  behind it.

  This counts frames the hub *delivered*. A driver that sheds frames to keep
  up delivers fewer than its device produced, and this reports the smaller
  number, because that is the rate consumers are actually seeing.

  Carries no image data, as nothing published on `BB.PubSub` ever does.
  """

  defstruct [
    :capture_state,
    :frames,
    :measured_frame_rate,
    :requested_frame_rate,
    :subscriber_count
  ]

  use BB.Message,
    schema: [
      capture_state: [
        type: {:in, [:capturing, :stopping]},
        required: true,
        doc: "Where the capture is in its lifecycle; see `BB.Camera.Hub`"
      ],
      frames: [
        type: :non_neg_integer,
        required: true,
        doc: "Frames delivered in the window this message covers"
      ],
      measured_frame_rate: [
        type: {:or, [:float, nil]},
        required: true,
        doc: "Frames per second over the window, or `nil` in a session's first message"
      ],
      requested_frame_rate: [
        type: {:or, [:float, nil]},
        required: true,
        doc: "Frames per second the camera was asked for, or `nil` if it never said"
      ],
      subscriber_count: [
        type: :non_neg_integer,
        required: true,
        doc: "Consumers sharing this capture"
      ]
    ]

  @type t :: %__MODULE__{
          capture_state: :capturing | :stopping,
          frames: non_neg_integer(),
          measured_frame_rate: float() | nil,
          requested_frame_rate: float() | nil,
          subscriber_count: non_neg_integer()
        }
end
