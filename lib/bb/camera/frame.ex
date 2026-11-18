# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Frame do
  @moduledoc """
  One independently decodable frame of media.

  Deliberately *not* a `BB.Message`. Frames never travel over `BB.PubSub` -
  they go over the bounded interface `BB.Camera.Hub` serves, and nowhere else.
  Putting megabytes of image data through a fan-out registry with no
  backpressure is the specific failure mode this package exists to avoid.

  ## Dimensions

  `width` and `height` are the dimensions the frame is *actually* encoded at,
  which is not necessarily what the camera was asked for. A driver that can
  parse them out of the data - the SOF marker of a JPEG, say - should do so
  rather than echoing back its own request.

  ## Timestamps

  `monotonic_time` and `wall_time` are both integer nanoseconds, matching
  `BB.Message`'s envelope. `monotonic_time` is the one to measure intervals
  with and may be negative; `wall_time` is the one to display.
  `DateTime.from_unix!(frame.wall_time, :nanosecond)` if you want a `DateTime`.

  Stamp them with the moment the frame was captured when you know it - for a
  port-based driver, when the frame's last byte left the port - rather than
  leaving them to default to when the struct happened to be built.

  ## Sequence

  `sequence` identifies the frame within its capture session and must strictly
  increase *within that session*. Consumers are promised a frame strictly newer
  than the last one they received, and that promise rests entirely on this
  number. A driver with its own counter should set it; one that leaves it `nil`
  gets it stamped by the hub.

  The hub forgets the last sequence it saw whenever capture is confirmed
  started, so a driver may restart its count at zero for each session or carry
  a single counter across restarts - whichever its capture backend makes
  natural. Neither is more correct, and the hub accepts both.

  ## Frame rates

  `requested_frame_rate` is what the camera was asked for, and
  `measured_frame_rate` is what the frames before this one actually did, over
  the most recent window the hub measured. Both are stamped by the hub, so a
  driver sets neither; both can be `nil`, the first if the camera never said
  what it was asking for and the second until a window has closed.

  They are named fields rather than `metadata` keys because every frame has
  them whatever the driver is. `metadata` is for what only some drivers know -
  a JPEG's component count, say - and nothing should go in it that the
  framework puts on every frame.

  ## Where the camera was

  A camera on a gimbal is somewhere different in every frame, and the pose it
  had when a frame was captured cannot be recovered afterwards - by the time
  anyone asks, the joints have moved. So the hub stamps
  `joint_configurations` onto each frame as it passes through: every joint's
  configuration, read from the robot's state as the frame arrived.

  `attached_to` says where the camera hangs - `{:link, name}`, `{:joint,
  name}` or `:robot` - which is what turns those configurations into a pose:

      BB.Robot.Kinematics.forward_kinematics(
        robot,
        frame.joint_configurations,
        link_name
      )

  The transform is deliberately *not* computed here. It is a chain of 4x4
  `Nx` products, which on a small target costs far more per frame than reading
  the configurations does, and most frames are never asked where they were
  taken. Snapshotting the cheap, perishable part and leaving the expensive,
  reproducible part to whoever wants it is the whole trick.

  Every joint is captured rather than only the camera's own chain. It costs
  one more table read per joint and answers questions the camera's chain
  can't, such as where the gripper was in this picture.

  **This is the most recently known configuration, not the configuration at
  the shutter.** Joint state is only as fresh as the last estimator update
  that wrote it. A joint reporting at 100Hz is tighter than a 30fps frame
  interval; a slow encoder is not, and nothing here can make it so.
  """

  alias BB.Camera.Format

  defstruct [
    :format,
    :width,
    :height,
    :data,
    :sequence,
    :monotonic_time,
    :wall_time,
    :measured_frame_rate,
    :requested_frame_rate,
    :attached_to,
    joint_configurations: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          format: Format.t(),
          width: pos_integer(),
          height: pos_integer(),
          data: binary(),
          sequence: non_neg_integer() | nil,
          monotonic_time: integer(),
          wall_time: integer(),
          measured_frame_rate: float() | nil,
          requested_frame_rate: float() | nil,
          attached_to: {:link, atom()} | {:joint, atom()} | :robot | nil,
          joint_configurations: %{atom() => number()},
          metadata: map()
        }

  @schema [
    format: [type: :atom, required: true, doc: "Media format; see `BB.Camera.Format`"],
    width: [type: :pos_integer, required: true, doc: "Encoded width in pixels"],
    height: [type: :pos_integer, required: true, doc: "Encoded height in pixels"],
    data: [
      type: {:custom, __MODULE__, :validate_binary, []},
      required: true,
      doc: "The encoded frame"
    ],
    sequence: [
      type: {:or, [:non_neg_integer, nil]},
      default: nil,
      doc: "Position in the capture session; stamped by the hub when nil"
    ],
    monotonic_time: [
      type: :integer,
      doc: "Capture time from `System.monotonic_time(:nanosecond)`"
    ],
    wall_time: [type: :integer, doc: "Capture time from `System.system_time(:nanosecond)`"],
    measured_frame_rate: [
      type: {:or, [:float, nil]},
      default: nil,
      doc: "Frames per second the stream was running at; stamped by the hub"
    ],
    requested_frame_rate: [
      type: {:or, [:float, nil]},
      default: nil,
      doc: "Frames per second the camera was asked for; stamped by the hub"
    ],
    attached_to: [
      type: :any,
      default: nil,
      doc: "Where on the robot the camera is; stamped by the hub"
    ],
    joint_configurations: [
      type: :map,
      default: %{},
      doc: "Every joint's configuration as at capture; stamped by the hub"
    ],
    metadata: [
      type: :map,
      default: %{},
      doc: "Format-specific extras, such as a JPEG's component count"
    ]
  ]

  @doc """
  Build a frame, validating it and stamping any timestamps left out.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    with {:ok, opts} <- Spark.Options.validate(opts, @schema),
         {:ok, _format} <- Format.validate(opts[:format]) do
      {:ok,
       struct(
         __MODULE__,
         Keyword.merge(
           [
             monotonic_time: System.monotonic_time(:nanosecond),
             wall_time: System.system_time(:nanosecond)
           ],
           opts
         )
       )}
    end
  end

  @doc """
  Like `new/1`, but raises.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, frame} -> frame
      {:error, error} -> raise error
    end
  end

  @doc false
  def validate_binary(value) when is_binary(value), do: {:ok, value}
  def validate_binary(value), do: {:error, "expected a binary, got: #{inspect(value)}"}
end
