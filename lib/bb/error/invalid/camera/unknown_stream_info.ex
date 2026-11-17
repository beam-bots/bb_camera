# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.Invalid.Camera.UnknownStreamInfo do
  @moduledoc """
  A driver can't say what it will produce from its declared options alone.

  `c:BB.Camera.stream_info/1` runs during discovery against robots that aren't
  running, so it can't ask the hardware. A driver whose format genuinely only
  becomes knowable once the device is open returns this, and discovery reports
  `stream_info: nil` rather than guessing.
  """
  use BB.Error,
    class: :invalid,
    fields: [:module, :reason]

  @type t :: %__MODULE__{
          module: module(),
          reason: term()
        }

  defimpl BB.Error.Severity do
    def severity(_), do: :warning
  end

  def message(error) do
    "#{inspect(error.module)} can't derive a stream format from its options: " <>
      "#{inspect(error.reason)}."
  end
end
