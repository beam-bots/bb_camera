# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Synthetic do
  @moduledoc """
  A camera with no camera behind it.

  A complete `BB.Sensor` + `BB.Camera` driver that produces real JPEG frames
  from a built-in cycle of images. Drop it anywhere a real camera would go: in
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

  ## Geometry, and why it might not be what you asked for

  The built-in frames are 160x120. Asking for another size without supplying
  your own `:frames` gets you 160x120 anyway - there is no JPEG encoder here to
  resize anything with - and the camera says so: it reports the dimensions it
  parsed out of the actual frame through
  `BB.Camera.Hub.capture_started/2`, so the live stream info is right even
  though the declared one isn't.

  That is not a workaround. It is exactly what a real camera does when it
  negotiates something other than what it was asked for, and having a driver
  that exercises the path on demand is worth more than one that pretends the
  question never comes up.
  """

  use BB.Sensor,
    options_schema: [
      width: [
        type: :pos_integer,
        default: 160,
        doc: "Requested width. The built-in frames are 160 wide regardless."
      ],
      height: [
        type: :pos_integer,
        default: 120,
        doc: "Requested height. The built-in frames are 120 high regardless."
      ],
      clock: [
        type: {:or, [{:tuple, [{:in, [:rate]}, :any]}, {:in, [:external]}]},
        default: {:rate, 10},
        doc: "`{:rate, hertz}` to free-run, or `:external` to produce on demand"
      ],
      frames: [
        type: {:list, :string},
        doc: "JPEG binaries to cycle through, instead of the built-in ones"
      ],
      fail_capture: [
        type: :boolean,
        default: false,
        doc: "Fail to start capturing, for exercising the capture-failure path"
      ]
    ]

  use BB.Camera

  alias BB.Camera.{Frame, Hub, StreamInfo}
  alias BB.Error.Hardware.Camera.CaptureFailed
  alias BB.Robot.Units

  @frame_count 4
  @builtin_width 160
  @builtin_height 120

  @frame_paths for index <- 0..(@frame_count - 1),
                   do:
                     Path.join([
                       __DIR__,
                       "..",
                       "..",
                       "..",
                       "priv",
                       "synthetic",
                       "frame_#{index}.jpg"
                     ])

  for path <- @frame_paths, do: @external_resource(path)

  @builtin_frames Enum.map(@frame_paths, &File.read!/1)

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
  The JPEG frames this camera cycles through by default.
  """
  @spec builtin_frames() :: [binary()]
  def builtin_frames, do: @builtin_frames

  @impl BB.Camera
  def stream_info(opts) do
    StreamInfo.new(
      format: :jpeg,
      width: Keyword.get(opts, :width, @builtin_width),
      height: Keyword.get(opts, :height, @builtin_height),
      frame_rate: declared_frame_rate(Keyword.get(opts, :clock, {:rate, 10}))
    )
  end

  @impl BB.Sensor
  def init(opts) do
    opts = Map.new(opts)
    {:ok, declared} = stream_info(Enum.to_list(opts))
    frames = Map.get(opts, :frames) || @builtin_frames

    {:ok, hub} = Hub.start_link(bb: opts.bb, stream_info: declared)

    {:ok,
     %{
       bb: opts.bb,
       hub: hub,
       frames: frames,
       index: 0,
       sequence: 0,
       clock: opts.clock,
       fail_capture: opts.fail_capture,
       loop: BB.Loop.new(opts.bb, clock: loop_clock(opts.clock)),
       capturing?: false
     }}
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
    Hub.capture_started(state.hub, actual_stream_info(state))
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

  defp emit(state) do
    case deliver(state) do
      {:ok, state} -> state
      {:error, _error, state} -> state
    end
  end

  defp deliver(state) do
    frame =
      Frame.new!(
        format: :jpeg,
        width: @builtin_width,
        height: @builtin_height,
        data: Enum.at(state.frames, rem(state.index, length(state.frames))),
        sequence: state.sequence
      )

    state = %{state | index: state.index + 1, sequence: state.sequence + 1}

    case Hub.deliver(state.hub, frame) do
      :ok -> {:ok, state}
      {:error, error} -> {:error, error, state}
    end
  end

  defp actual_stream_info(state) do
    StreamInfo.new!(
      format: :jpeg,
      width: @builtin_width,
      height: @builtin_height,
      frame_rate: declared_frame_rate(state.clock)
    )
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
