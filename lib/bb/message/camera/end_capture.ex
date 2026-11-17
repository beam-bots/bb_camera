# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Message.Camera.EndCapture do
  @moduledoc """
  A camera has stopped capturing.

  `reason` distinguishes the three ways that happens:

  - `:no_subscribers` - the last consumer went away, so the hub asked the
    driver to stop. The ordinary case.
  - `:driver_stopped` - the driver stopped of its own accord.
  - `:error` - capture failed. `error` carries the `BB.Error` the driver
    reported, and every subscriber is told separately rather than being left
    waiting on a stream that will not resume.
  """

  defstruct [:reason, :error, :frame_count]

  use BB.Message,
    schema: [
      reason: [
        type: {:in, [:no_subscribers, :driver_stopped, :error]},
        required: true,
        doc: "Why capture ended"
      ],
      error: [
        type: {:or, [:struct, nil]},
        default: nil,
        doc: "The `BB.Error` behind an `:error` reason"
      ],
      frame_count: [
        type: :non_neg_integer,
        required: true,
        doc: "Frames delivered during the session"
      ]
    ]

  @type t :: %__MODULE__{
          reason: :no_subscribers | :driver_stopped | :error,
          error: struct() | nil,
          frame_count: non_neg_integer()
        }
end
