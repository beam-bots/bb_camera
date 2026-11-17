# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.StreamInfo do
  @moduledoc """
  What a camera produces: format and geometry.

  There are two of these in play for any running camera, and the difference
  matters.

  The **declared** one comes from `c:BB.Camera.stream_info/1`, which runs during
  discovery against robots that aren't started. It can only describe what the
  DSL asked for.

  The **live** one is whatever the driver handed to `BB.Camera.Hub` once it had
  opened the device and seen a real frame. A camera asked for 1280x720 that
  negotiated 640x480 reports the latter, as soon as it knows it, via
  `BB.Camera.Hub.update_stream_info/2`.

  Consumers are told about a change before the first frame it describes, so
  nothing ever attributes a frame to the wrong geometry.
  """

  alias BB.Camera.Format

  defstruct [:format, :width, :height, :frame_rate, metadata: %{}]

  @type t :: %__MODULE__{
          format: Format.t(),
          width: pos_integer(),
          height: pos_integer(),
          frame_rate: float() | nil,
          metadata: map()
        }

  @schema [
    format: [type: :atom, required: true, doc: "Media format; see `BB.Camera.Format`"],
    width: [type: :pos_integer, required: true, doc: "Width in pixels"],
    height: [type: :pos_integer, required: true, doc: "Height in pixels"],
    frame_rate: [
      type: {:or, [:float, nil]},
      default: nil,
      doc: "Nominal frames per second, or nil when unknown or variable"
    ],
    metadata: [
      type: :map,
      default: %{},
      doc: "Format extras, e.g. `%{pixel_format: :I420}` for JPEG chroma subsampling"
    ]
  ]

  @doc """
  Build a stream info, rejecting formats this package won't carry.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    with {:ok, opts} <- Spark.Options.validate(opts, @schema),
         {:ok, _format} <- Format.validate(opts[:format]) do
      {:ok, struct(__MODULE__, opts)}
    end
  end

  @doc """
  Like `new/1`, but raises.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, info} -> info
      {:error, error} -> raise error
    end
  end
end
