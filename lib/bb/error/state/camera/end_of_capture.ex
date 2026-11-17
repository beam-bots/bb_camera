# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.State.Camera.EndOfCapture do
  @moduledoc """
  Capture stopped cleanly while a consumer was still reading.

  Distinct from `BB.Error.Hardware.Camera.CaptureFailed`: the stream ended
  because it was asked to, not because anything went wrong.
  """
  use BB.Error,
    class: :state,
    fields: [:robot, :camera, :reason, :frame_count]

  @type t :: %__MODULE__{
          robot: module(),
          camera: atom(),
          reason: atom(),
          frame_count: non_neg_integer()
        }

  defimpl BB.Error.Severity do
    def severity(_), do: :warning
  end

  def message(error) do
    "Capture on camera #{inspect(error.camera)} ended (#{inspect(error.reason)}) " <>
      "after #{error.frame_count} frames."
  end
end
