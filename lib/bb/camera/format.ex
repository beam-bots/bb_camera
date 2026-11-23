# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Format do
  @moduledoc """
  Which media formats `bb_camera` will carry: raw pixels, and nothing else.

  `BB.Camera.Hub` keeps exactly one frame per camera and drops anything staler.
  That policy is lossless for frames that stand alone and destructive for
  frames that reference earlier ones, so the hub only carries frames that
  stand alone. It goes further than that and only carries *raw* frames: a
  driver decodes whatever its device produces - MJPEG, H.264, anything - before
  handing a frame over. Every consumer then gets pixels it can use directly,
  rather than each one decoding the same frame for itself, and a codec whose
  frames depend on each other is the driver's problem rather than the hub's.

  A format is `{:raw, pixel_format}`, where `pixel_format` is one of
  `Membrane.RawVideo`'s - `:I420`, `:NV12`, `:YUY2`, `:RGB` and so on - so a
  frame can be handed to a Membrane pipeline without translating anything.

  ## Packing

  A raw frame's `data` is tightly packed: planes laid end to end in their
  conventional order, rows with no padding between them. Its size is exactly
  `Membrane.RawVideo.frame_size/3` for its format and dimensions. Hardware that
  pads rows to an alignment has to have that padding stripped by its driver.
  """

  alias BB.Error.Invalid.Camera.UnsupportedFormat
  alias Membrane.RawVideo

  @type pixel_format :: RawVideo.pixel_format()

  @type t :: {:raw, pixel_format()}

  @doc """
  Whether every frame in this format decodes without reference to any other.

  True of every raw format, and of nothing this package carries besides.
  """
  @spec independent_frames?(term()) :: boolean()
  def independent_frames?({:raw, pixel_format}) when is_atom(pixel_format), do: true
  def independent_frames?(_format), do: false

  @doc """
  The size in bytes of one frame in `format` at `width` x `height`, checking
  along the way that this package will carry it.

  Returns `{:error, %UnsupportedFormat{}}` with a `reason` of:

  - `:encoded` - anything other than `{:raw, pixel_format}`. Decode it in the
    driver.
  - `:unknown_pixel_format` - a raw format `Membrane.RawVideo` doesn't name.
  - `:invalid_dimensions` - dimensions the pixel format can't take, such as an
    odd width for chroma-subsampled `:I420`.
  """
  @spec frame_size(term(), pos_integer(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, UnsupportedFormat.t()}
  def frame_size({:raw, pixel_format} = format, width, height) do
    case RawVideo.frame_size(pixel_format, width, height) do
      {:ok, size} ->
        {:ok, size}

      {:error, :invalid_pixel_format} ->
        {:error, UnsupportedFormat.exception(format: format, reason: :unknown_pixel_format)}

      {:error, :invalid_dimensions} ->
        {:error,
         UnsupportedFormat.exception(
           format: format,
           width: width,
           height: height,
           reason: :invalid_dimensions
         )}
    end
  end

  def frame_size(format, _width, _height) do
    {:error, UnsupportedFormat.exception(format: format, reason: :encoded)}
  end

  @doc """
  Check a camera's format against what a caller asserted it would be.

  `nil` asserts nothing.
  """
  @spec assert(t(), term()) :: :ok | {:error, UnsupportedFormat.t()}
  def assert(_format, nil), do: :ok
  def assert(format, format), do: :ok

  def assert(format, expected) do
    {:error, UnsupportedFormat.exception(format: format, expected: expected, reason: :mismatch)}
  end
end
