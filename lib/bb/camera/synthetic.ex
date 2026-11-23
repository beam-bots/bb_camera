# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Synthetic do
  @moduledoc """
  A camera with no camera behind it.

  A complete `BB.Sensor` + `BB.Camera` driver that produces raw `:I420` frames
  from a generated test pattern. Drop it anywhere a real camera would go: in
  tests, in a preview UI on a machine with no hardware attached, or as the
  worked example to copy when writing a driver that does talk to something.

      topology do
        link :head do
          sensor :eye, {BB.Camera.Synthetic, clock: :external}
        end
      end

  ## Clocking

  `{:rate, hertz}` runs a `BB.Loop` and produces frames on its own, which is
  what you want behind a UI.

  `:external` produces a frame only when `capture_frame/2` is called, which is
  what you want in a test. It makes the whole pipeline deterministic: ask for a
  frame, produce one, assert you received it, with no sleeps and nothing
  racing. Every test in this package is written that way.

      {:ok, sub} = BB.Camera.subscribe(MyRobot, :eye)
      :ok = BB.Camera.request(sub)
      :ok = BB.Camera.Synthetic.capture_frame(MyRobot, :eye)
      assert_receive {:bb_camera, ^ref, %BB.Camera.Frame{}}

  ## Frames

  By default it cycles through `default_frames/2`: vertical bars of grey that
  shift along each frame, at whatever size it was asked for. `:I420` subsamples
  its chroma by two in each direction, so the width and height must both be
  even. `:frames` replaces them with your own, which must be `:I420` at the
  configured size.
  """

  import BB.Unit
  import BB.Unit.Option

  use BB.Sensor,
    options_schema: [
      width: [type: :pos_integer, default: 160, doc: "Frame width; must be even"],
      height: [type: :pos_integer, default: 120, doc: "Frame height; must be even"],
      clock: [
        type: {:or, [{:tuple, [{:in, [:rate]}, :any]}, {:in, [:external]}]},
        default: {:rate, 10},
        doc: "`{:rate, hertz}` to free-run, or `:external` to produce on demand"
      ],
      publish_rate: [
        type: {:or, [unit_type(compatible: :hertz), {:in, [:external]}]},
        default: ~u(1 hertz),
        doc: """
        How often the hub publishes `BB.Message.Camera.CaptureState`, or
        `:external` to publish only when it is sent `{:tick, monotonic_ns}`
        """
      ],
      frames: [
        type: {:list, :string},
        doc: "Raw `:I420` frames at the configured size to cycle through, instead of the defaults"
      ],
      fail_capture: [
        type: :boolean,
        default: false,
        doc: "Fail to start capturing, for exercising the capture-failure path"
      ]
    ]

  use BB.Camera

  alias BB.Camera.{Format, Frame, Hub, StreamInfo}
  alias BB.Error.Hardware.Camera.CaptureFailed
  alias BB.Error.Invalid.Camera.FrameSizeMismatch
  alias BB.Robot.Units

  @format {:raw, :I420}
  @default_frame_count 4
  @default_width 160
  @default_height 120

  @doc """
  Produce one frame now.

  Only meaningful with `clock: :external`. Synchronous: it returns once the hub
  has taken the frame, so a test can request, capture and assert without
  waiting on anything.

  Returns `{:error, %BB.Error.State.Camera.NotCapturing{}}` until a consumer
  has subscribed *and* this driver has confirmed capture started. Subscribing
  is not enough: the hub asks the driver to start and the driver answers
  asynchronously, so a test that opens a session and immediately captures will
  race that answer.

  Wait for the event rather than guessing at the gap:

      BB.subscribe(MyRobot, [:sensor, :head, :eye])
      {:ok, session} = BB.Camera.Media.open(MyRobot, :eye)
      assert_receive {:bb, _, %BB.Message{payload: %BB.Message.Camera.BeginCapture{}}}

      :ok = BB.Camera.Synthetic.capture_frame(MyRobot, :eye)

  Anything driving an externally clocked camera from behind a consumer needs
  this, so it is worth doing once in a test `setup`.
  """
  @spec capture_frame(module(), atom()) :: :ok | {:error, struct()}
  def capture_frame(robot, camera) do
    BB.Process.call(robot, camera, {:bb_camera_synthetic, :capture_frame})
  end

  @doc """
  The `:I420` frames this camera cycles through by default at `width` x
  `height`.

  Vertical bars of grey, shifted along by a quarter of the width each frame,
  with neutral chroma. Every frame differs from the others, so a test can tell
  which one it was handed.
  """
  @spec default_frames(pos_integer(), pos_integer()) :: [binary()]
  def default_frames(width, height) do
    chroma = :binary.copy(<<128>>, div(width, 2) * div(height, 2) * 2)

    for index <- 0..(@default_frame_count - 1) do
      shift = div(width * index, @default_frame_count)
      row = for x <- 0..(width - 1), into: <<>>, do: <<rem((x + shift) * 4, 256)>>
      :binary.copy(row, height) <> chroma
    end
  end

  @impl BB.Camera
  def stream_info(opts) do
    StreamInfo.new(
      format: @format,
      width: Keyword.get(opts, :width, @default_width),
      height: Keyword.get(opts, :height, @default_height),
      frame_rate: declared_frame_rate(Keyword.get(opts, :clock, {:rate, 10}))
    )
  end

  @impl BB.Sensor
  def init(opts) do
    opts = Map.new(opts)

    with {:ok, stream_info} <- stream_info(Enum.to_list(opts)),
         {:ok, frames} <- frames(opts, stream_info) do
      {:ok, hub} =
        Hub.start_link(
          bb: opts.bb,
          stream_info: stream_info,
          publish_rate: opts.publish_rate
        )

      {:ok,
       %{
         bb: opts.bb,
         hub: hub,
         stream_info: stream_info,
         frames: frames,
         index: 0,
         sequence: 0,
         clock: opts.clock,
         fail_capture: opts.fail_capture,
         loop: BB.Loop.new(opts.bb, clock: loop_clock(opts.clock)),
         capturing?: false
       }}
    else
      {:error, error} -> {:stop, error}
    end
  end

  @impl BB.Sensor
  def handle_info({:bb_camera, :start_capture}, %{fail_capture: true} = state) do
    Hub.capture_failed(
      state.hub,
      CaptureFailed.exception(camera: camera_name(state), reason: :fail_capture_option)
    )

    {:noreply, state}
  end

  def handle_info({:bb_camera, :start_capture}, state) do
    Hub.capture_started(state.hub, state.stream_info)
    {:noreply, %{state | capturing?: true, loop: BB.Loop.arm(state.loop)}}
  end

  def handle_info({:bb_camera, :stop_capture}, state) do
    state = %{state | capturing?: false, loop: BB.Loop.cancel(state.loop)}
    Hub.capture_stopped(state.hub, :no_subscribers)
    {:noreply, state}
  end

  def handle_info(:tick, %{capturing?: true} = state) do
    {_dt, _skipped, loop} = BB.Loop.tick(state.loop)
    {:noreply, emit(%{state | loop: loop})}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl BB.Sensor
  def handle_call({:bb_camera_synthetic, :capture_frame}, _from, state) do
    case deliver(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, error, state} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :not_implemented}, state}

  @impl BB.Sensor
  def terminate(_reason, state) do
    BB.Loop.cancel(state.loop)
    :ok
  end

  defp frames(%{frames: frames}, stream_info) when is_list(frames) do
    {:ok, size} = Format.frame_size(stream_info.format, stream_info.width, stream_info.height)

    case Enum.find(frames, &(byte_size(&1) != size)) do
      nil ->
        {:ok, frames}

      wrong ->
        {:error,
         FrameSizeMismatch.exception(
           format: stream_info.format,
           width: stream_info.width,
           height: stream_info.height,
           expected: size,
           actual: byte_size(wrong)
         )}
    end
  end

  defp frames(_opts, stream_info) do
    {:ok, default_frames(stream_info.width, stream_info.height)}
  end

  defp emit(state) do
    case deliver(state) do
      {:ok, state} -> state
      {:error, _error, state} -> state
    end
  end

  defp deliver(state) do
    frame =
      Frame.new!(
        format: state.stream_info.format,
        width: state.stream_info.width,
        height: state.stream_info.height,
        data: Enum.at(state.frames, rem(state.index, length(state.frames))),
        sequence: state.sequence
      )

    state = %{state | index: state.index + 1, sequence: state.sequence + 1}

    case Hub.deliver(state.hub, frame) do
      :ok -> {:ok, state}
      {:error, error} -> {:error, error, state}
    end
  end

  defp declared_frame_rate(:external), do: nil
  defp declared_frame_rate({:rate, rate}) when is_number(rate), do: rate / 1

  defp declared_frame_rate({:rate, %Localize.Unit{} = rate}) do
    rate |> Localize.Unit.convert!("hertz") |> Units.extract_float()
  end

  defp loop_clock(:external), do: :external
  defp loop_clock({:rate, rate}), do: {:rate, rate}

  defp camera_name(state), do: List.last(state.bb.path)
end
