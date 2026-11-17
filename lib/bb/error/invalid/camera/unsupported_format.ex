# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.Invalid.Camera.UnsupportedFormat do
  @moduledoc """
  A media format this package will not carry.

  The `reason` says why:

  - `:interframe` - the format's frames depend on earlier frames (H.264 and
    friends). `BB.Camera.Hub` keeps only the latest frame and drops the rest,
    which is lossless for independently decodable frames and silently
    destructive for these. Rather than hand a consumer a stream that decodes to
    garbage, it refuses to carry it at all.
  - `:not_implemented` - a format that could in principle be carried but isn't
    yet, raw pixel buffers being the obvious one.
  - `:mismatch` - the caller asserted a format the camera doesn't produce.
  """
  use BB.Error,
    class: :invalid,
    fields: [:format, :expected, :reason]

  @type reason :: :interframe | :not_implemented | :mismatch

  @type t :: %__MODULE__{
          format: term(),
          expected: term(),
          reason: reason()
        }

  defimpl BB.Error.Severity do
    def severity(_), do: :error
  end

  def message(%{reason: :interframe} = error) do
    "#{inspect(error.format)} is an interframe codec. Dropping stale frames " <>
      "would corrupt the stream, so bb_camera will not carry it."
  end

  def message(%{reason: :mismatch} = error) do
    "Expected #{inspect(error.expected)}, but the camera produces " <>
      "#{inspect(error.format)}."
  end

  def message(%{format: format}) do
    "#{inspect(format)} is not a format bb_camera carries. Supported: :jpeg."
  end
end
