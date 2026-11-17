# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Format do
  @moduledoc """
  Which media formats `bb_camera` will carry, and why it refuses the rest.

  `BB.Camera.Hub` keeps exactly one frame per camera and drops anything staler.
  That policy is lossless for formats whose frames decode independently, and
  destructive for formats whose frames reference earlier ones. So the set of
  formats this package carries is exactly the set where dropping is safe.

  Today that set is `:jpeg` - a stream of complete JPEG images, what the world
  calls MJPEG. Raw pixel buffers would also qualify and are simply not
  implemented yet; they are rejected as `:not_implemented` rather than
  `:interframe`, because the distinction matters to anyone deciding whether to
  add one.

  Interframe codecs are refused outright. There is no mode in which this
  package carries H.264 and drops frames, because the result would decode to
  garbage without anything in the pipeline noticing.
  """

  alias BB.Error.Invalid.Camera.UnsupportedFormat

  @supported [:jpeg]

  @interframe [:h264, :h265, :hevc, :vp8, :vp9, :av1, :mpeg4, :theora]

  @type t :: :jpeg

  @doc """
  The formats this package carries.
  """
  @spec supported() :: [t()]
  def supported, do: @supported

  @doc """
  Whether every frame in this format decodes without reference to any other.

  This is the predicate the hub's drop-the-stale-frame policy is safe under,
  and therefore the predicate format support is gated on.
  """
  @spec independent_frames?(term()) :: boolean()
  def independent_frames?(format), do: format in @supported

  @doc """
  Check a format is one this package will carry.

  Returns `{:error, %UnsupportedFormat{reason: :interframe}}` for codecs whose
  frames depend on each other, and `:not_implemented` for anything else.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, UnsupportedFormat.t()}
  def validate(format) when format in @supported, do: {:ok, format}

  def validate(format) when format in @interframe do
    {:error, UnsupportedFormat.exception(format: format, reason: :interframe)}
  end

  def validate(format) do
    {:error, UnsupportedFormat.exception(format: format, reason: :not_implemented)}
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
