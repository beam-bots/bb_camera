# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.Invalid.Camera.FrameSizeMismatch do
  @moduledoc """
  A raw frame's data isn't the size its format and dimensions say it is.

  A raw frame carries nothing but pixels, so its format and dimensions are the
  only description a consumer has of what is in it. Data of the wrong size
  means one of them is wrong - most often a capture tool that padded its rows,
  or one that quietly delivered a different size from the one requested - and
  a consumer that trusted it would read every pixel from the wrong place. So
  the frame is refused rather than built.
  """
  use BB.Error,
    class: :invalid,
    fields: [:format, :width, :height, :expected, :actual]

  @type t :: %__MODULE__{
          format: BB.Camera.Format.t(),
          width: pos_integer(),
          height: pos_integer(),
          expected: pos_integer(),
          actual: non_neg_integer()
        }

  defimpl BB.Error.Severity do
    def severity(_), do: :error
  end

  def message(error) do
    "A #{error.width}x#{error.height} #{inspect(error.format)} frame is " <>
      "#{error.expected} bytes, but the data is #{error.actual}."
  end
end
