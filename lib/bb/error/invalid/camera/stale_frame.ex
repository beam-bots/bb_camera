# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.Invalid.Camera.StaleFrame do
  @moduledoc """
  A driver delivered a frame whose sequence didn't advance.

  Consumers are promised a frame strictly newer than the last one they were
  given, and that promise is built on the sequence number. A driver that
  repeats or rewinds one would make a consumer's next request block forever, so
  the frame is refused and the driver told, rather than accepted and quietly
  mis-ordered.
  """
  use BB.Error,
    class: :invalid,
    fields: [:camera, :sequence, :last_sequence]

  @type t :: %__MODULE__{
          camera: atom(),
          sequence: non_neg_integer() | nil,
          last_sequence: non_neg_integer() | nil
        }

  defimpl BB.Error.Severity do
    def severity(_), do: :error
  end

  def message(error) do
    "Camera #{inspect(error.camera)} delivered frame #{inspect(error.sequence)} " <>
      "after #{inspect(error.last_sequence)}; sequence must strictly increase."
  end
end
