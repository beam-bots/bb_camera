# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.Invalid.Camera.UnsupportedFormat do
  @moduledoc """
  A media format this package will not carry.

  `bb_camera` carries raw frames only; see `BB.Camera.Format`. The `reason`
  says what was wrong:

  - `:encoded` - the format is a codec (JPEG, H.264, ...) rather than
    `{:raw, pixel_format}`. Drivers decode before handing frames to the hub.
  - `:unknown_pixel_format` - a raw format whose pixel format
    `Membrane.RawVideo` doesn't name.
  - `:invalid_dimensions` - dimensions the pixel format can't take, such as an
    odd width for chroma-subsampled `:I420`.
  - `:mismatch` - the caller asserted a format the camera doesn't produce.
  """
  use BB.Error,
    class: :invalid,
    fields: [:format, :expected, :width, :height, :reason]

  @type reason :: :encoded | :unknown_pixel_format | :invalid_dimensions | :mismatch

  @type t :: %__MODULE__{
          format: term(),
          expected: term(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          reason: reason()
        }

  defimpl BB.Error.Severity do
    def severity(_), do: :error
  end

  def message(%{reason: :encoded} = error) do
    "#{inspect(error.format)} is an encoded format, and bb_camera carries raw " <>
      "frames only. Decode it in the driver."
  end

  def message(%{reason: :unknown_pixel_format} = error) do
    "#{inspect(error.format)} names a pixel format Membrane.RawVideo doesn't know."
  end

  def message(%{reason: :invalid_dimensions} = error) do
    "#{inspect(error.format)} can't be #{error.width}x#{error.height}."
  end

  def message(%{reason: :mismatch} = error) do
    "Expected #{inspect(error.expected)}, but the camera produces " <>
      "#{inspect(error.format)}."
  end
end
