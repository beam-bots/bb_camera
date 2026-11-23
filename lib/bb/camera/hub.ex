# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Hub do
  @moduledoc """
  The one capture a camera has, shared by everyone watching it.

  One hub per camera, started and linked by the driver in its `init/1`. It
  registers itself in the robot's own `Registry` under `{:camera, name}`, so
  consumers find it the same way they find anything else in a robot.

  ## What it is for

  A camera has one physical capture no matter how many things want to watch it,
  and image data is large enough that the usual answer - publish and let
  subscribers sort it out - stops working. A raw 1080p stream is close to a
  hundred megabytes a second; put that through a fan-out registry with no backpressure
  and a single slow consumer becomes an unbounded mailbox and then a dead node.
  So frames do not go on `BB.PubSub` at all. They come through here, and here
  there are bounds at both ends:

  * **Ingress** - `deliver/2` is a synchronous call. The driver blocks until
    the hub has taken the frame, so at most one frame per driver is ever in
    flight and the hub's mailbox cannot grow faster than it drains.
  * **Buffer** - the hub keeps exactly one frame, the latest. A new frame
    replaces the previous one whether or not anybody read it.
  * **Egress** - a consumer gets a frame only when it has asked for one, one at
    a time, and only one strictly newer than the last it received.

  That last clause is what makes a `next`-in-a-loop consumer - an HTTP route
  streaming to a browser, say - run at the camera's frame rate rather than spinning: there is
  nothing to return until the camera produces something new.

  The interface is deliberately source-agnostic. A driver reading a V4L2 device
  through a subprocess, one calling into a platform capture framework from a
  NIF, and one generating frames arithmetically all meet it the same way: they
  hand over a `BB.Camera.Frame` and wait for the hub to take it.

  ## Lifecycle is driver-confirmed

  The hub asks the driver to start capturing when the first consumer arrives
  and to stop when the last one leaves, but it does not assume either worked. A
  driver confirms with `capture_started/2` or reports `capture_failed/2`, and
  only then is `BB.Message.Camera.BeginCapture` published. A camera whose
  device fails to open never claims to be capturing, and every consumer waiting
  on it is told rather than left on a stream that will not resume.

  Because those confirmations are asynchronous, the hub tracks capture as a
  state machine - `:idle`, `:starting`, `:capturing`, `:stopping` - rather than
  a boolean. A consumer arriving while a stop is still in flight does not race
  it: the restart is held until the stop is confirmed, and the confirmation is
  attributed to the session it belongs to, so a new consumer is never told that
  a capture it was never part of has ended.

  A capture failure is not retried automatically. Subscribers are told, and the
  hub returns to `:idle`; a driver whose device is missing would otherwise be
  restarted in a tight loop for as long as anyone was watching.

  ## How fast it is really going

  Every frame passes through `deliver/2`, so the hub is the one place that can
  measure a camera's real rate without each driver being asked to. While
  capture is running it counts frames over a window and publishes
  `BB.Message.Camera.CaptureState` at the end of each one, carrying what was
  asked for alongside what the frames actually did. The same pair is stamped
  onto every frame.

  The window is counted, not smoothed, so a capture that has stalled reports
  `0.0` rather than the rate it used to manage.

  ## Bounding what happens before the hub

  `deliver/2` bounds what crosses into `bb_camera`. It cannot bound what
  accumulates between an external source and the BEAM. An Erlang port offers no
  ingress flow control - `Port.open`'s `busy_limits_msgq` does not provide one
  for port-to-owner data - and a native capture callback delivering frames into
  a process mailbox has the same problem. A driver has to bound that itself: a
  capped output rate, a drain-only owner process, hard buffer and frame-size
  caps, an explicit overload trip.

  Nor does closing a port stop the program behind it. Neither `Port.close/1`,
  killing the port's owner, nor the owner crashing will end the spawned
  process; it is reparented and carries on. This usually goes unnoticed because
  the program dies of `SIGPIPE` on its next write to the closed pipe - which is
  exactly what does not happen to a camera that has wedged. A driver that
  spawns anything needs an explicit reaper; `terminate/2` is not enough.
  """

  use GenServer

  alias BB.Camera.{Format, Frame, StreamInfo}
  alias BB.Error.Invalid.Camera.StaleFrame
  alias BB.Error.State.Camera.NotCapturing
  alias BB.Message
  alias BB.Message.Camera.{BeginCapture, CaptureState, EndCapture}
  alias BB.Robot.Runtime
  alias BB.Robot.State, as: RobotState

  require Logger

  @default_publish_rate 1

  @start_schema [
    bb: [
      type: :map,
      required: true,
      doc: "The `%{robot:, path:}` injected into the driver's options"
    ],
    stream_info: [
      type: {:struct, StreamInfo},
      required: true,
      doc: "What the camera is expected to produce"
    ],
    driver: [
      type: :pid,
      doc: "The process to drive capture, defaults to the process calling `start_link/1`"
    ],
    publish_rate: [
      type: :any,
      doc: """
      How often `BB.Message.Camera.CaptureState` is published, in hertz -
      a `Localize.Unit` or a plain number. Defaults to
      `#{@default_publish_rate}`.

      `:external` instead of a rate means the hub closes no window of its own
      and publishes only when sent `{:tick, monotonic_ns}`, taking that
      timestamp as the end of the window. Hand it a real
      `System.monotonic_time(:nanosecond)` unless you mean to measure against
      something else.
      """
    ]
  ]

  # ----------------------------------------------------------------------------
  # Driver-facing API
  # ----------------------------------------------------------------------------

  @doc """
  Start a hub for the camera the calling driver serves.

  Call this from the driver's `init/1`. The default `:driver` is the calling
  process, resolved here rather than in the hub's own `init/1` - where `self()`
  would be the hub.

  The hub links to the driver and monitors it. The link covers a crash; the
  monitor covers a clean exit, which a link would not propagate, and which
  would otherwise leave a hub registered for a camera that no longer exists.

  ## Options

  #{Spark.Options.docs(@start_schema)}
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, opts} <- Spark.Options.validate(opts, @start_schema) do
      opts = Keyword.put_new(opts, :driver, self())
      robot = opts[:bb].robot
      name = List.last(opts[:bb].path)
      GenServer.start_link(__MODULE__, opts, name: BB.Process.via(robot, {:camera, name}))
    end
  end

  @doc """
  Hand a frame over, blocking until the hub has taken it.

  Synchronous by design. This is the only ingress bound that exists, and
  wrapping it in a `Task` to "avoid blocking capture" reintroduces precisely
  the unbounded queue it is here to prevent. The hub does nothing with a frame
  beyond storing it and passing it to whoever has asked, so the call returns
  promptly; a timeout means the hub is wedged, which is a crash rather than a
  dropped frame.

  Returns `{:error, %BB.Error.Invalid.Camera.StaleFrame{}}` if the sequence
  doesn't strictly increase, and `{:error, %BB.Error.State.Camera.NotCapturing{}}`
  if capture hasn't been confirmed started. Both are bugs in the driver, and
  neither takes the hub down with it.
  """
  @spec deliver(GenServer.server(), Frame.t(), timeout()) :: :ok | {:error, struct()}
  def deliver(hub, %Frame{} = frame, timeout \\ 5000) do
    GenServer.call(hub, {:deliver, frame}, timeout)
  end

  @doc """
  Confirm that capture is running, optionally with the format it's really
  running at.

  Until this is called the camera is not capturing as far as anything else is
  concerned. Passing a `StreamInfo` is the same as calling
  `update_stream_info/2` first, and is how a driver reports the geometry it
  negotiated rather than the one it asked for.

  Each confirmation starts a new session: the frame counter returns to zero,
  every subscriber's idea of what it has already seen is cleared, and the hub
  forgets the sequence it last saw. That last part is what lets a driver choose
  - restart its sequence at zero for each session, or carry one counter across
  restarts because its capture backend does. Both are accepted; what the hub
  insists on is only that the sequence strictly increases *within* a session.
  """
  @spec capture_started(GenServer.server(), StreamInfo.t() | nil) :: :ok
  def capture_started(hub, stream_info \\ nil) do
    GenServer.call(hub, {:capture_started, stream_info})
  end

  @doc """
  Report that capture has stopped cleanly.

  When the hub was the one that asked - because the last consumer left - it
  uses its own reason for the published event rather than the one given here,
  so a driver never has to work out why it was asked to stop.
  """
  @spec capture_stopped(GenServer.server(), atom()) :: :ok
  def capture_stopped(hub, reason \\ :driver_stopped) do
    GenServer.call(hub, {:capture_stopped, reason})
  end

  @doc """
  Report that capture failed.

  Publishes `BB.Message.Camera.EndCapture` with `reason: :error` and hands the
  error to every subscriber of the session that failed. The hub does not
  restart capture by itself afterwards.
  """
  @spec capture_failed(GenServer.server(), struct()) :: :ok
  def capture_failed(hub, error) do
    GenServer.call(hub, {:capture_failed, error})
  end

  @doc """
  Replace the live stream format.

  Call it when the first real frame reveals the actual geometry, or when a
  change to the camera's options alters it. Each subscriber is told as
  `{:bb_camera, ref, {:stream_info, info}}` immediately before the first frame
  the new format describes.

  The buffered frame is discarded, because it was encoded under the old format
  and there is no longer an honest way to describe it: announcing the new
  format and then handing over the old frame would be worse than dropping one
  frame from a stream whose policy is already to drop frames.
  """
  @spec update_stream_info(GenServer.server(), StreamInfo.t()) :: :ok
  def update_stream_info(hub, %StreamInfo{} = stream_info) do
    GenServer.call(hub, {:update_stream_info, stream_info})
  end

  @doc """
  Whether the driver has confirmed capture is running.
  """
  @spec capturing?(GenServer.server()) :: boolean()
  def capturing?(hub), do: GenServer.call(hub, :capturing?)

  @doc """
  The hub's capture state: `:idle`, `:starting`, `:capturing` or `:stopping`.
  """
  @spec capture_state(GenServer.server()) :: :idle | :starting | :capturing | :stopping
  def capture_state(hub), do: GenServer.call(hub, :capture_state)

  # ----------------------------------------------------------------------------
  # Consumer-facing API, reached through `BB.Camera`
  # ----------------------------------------------------------------------------

  @doc false
  @spec subscribe(GenServer.server(), pid(), keyword()) ::
          {:ok, reference(), StreamInfo.t()} | {:error, struct()}
  def subscribe(hub, owner, opts), do: GenServer.call(hub, {:subscribe, owner, opts})

  @doc false
  @spec request(GenServer.server(), reference()) :: :ok
  def request(hub, ref), do: GenServer.call(hub, {:request, ref})

  @doc false
  @spec cancel_request(GenServer.server(), reference()) :: :ok
  def cancel_request(hub, ref), do: GenServer.call(hub, {:cancel_request, ref})

  @doc false
  @spec unsubscribe(GenServer.server(), reference()) :: :ok
  def unsubscribe(hub, ref), do: GenServer.call(hub, {:unsubscribe, ref})

  @doc false
  @spec stream_info(GenServer.server()) :: StreamInfo.t()
  def stream_info(hub), do: GenServer.call(hub, :stream_info)

  @doc false
  @spec status(GenServer.server()) :: :capturing | :running
  def status(hub), do: GenServer.call(hub, :status)

  # ----------------------------------------------------------------------------
  # Server
  # ----------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    bb = opts[:bb]
    driver = opts[:driver]

    camera = List.last(bb.path)

    {:ok,
     %{
       bb: bb,
       camera: camera,
       topic: [:sensor | bb.path],
       driver: driver,
       driver_monitor: Process.monitor(driver),
       robot_state: nil,
       runtime_monitor: nil,
       attached_to: attachment(bb.robot, camera, bb.path),
       stream_info: opts[:stream_info],
       stream_info_generation: 0,
       capture_state: :idle,
       stop_reason: nil,
       latest: nil,
       last_sequence: nil,
       frame_count: 0,
       subscribers: %{},
       publish_rate: opts[:publish_rate] || @default_publish_rate,
       publish_loop: nil,
       window_frames: 0,
       measured_frame_rate: nil
     }}
  end

  @impl GenServer
  def handle_call({:subscribe, owner, opts}, _from, state) do
    case Format.assert(state.stream_info.format, opts[:format]) do
      :ok ->
        ref = make_ref()

        subscriber = %{
          pid: owner,
          monitor: Process.monitor(owner),
          demand?: false,
          last_sequence: nil,
          generation: state.stream_info_generation,
          in_session?: state.capture_state in [:starting, :capturing]
        }

        state = put_in(state.subscribers[ref], subscriber)
        {:reply, {:ok, ref, state.stream_info}, request_capture(state)}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:request, ref}, _from, state) do
    case state.subscribers do
      %{^ref => _} -> {:reply, :ok, serve(put_in(state.subscribers[ref].demand?, true), ref)}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:cancel_request, ref}, _from, state) do
    case state.subscribers do
      %{^ref => _} -> {:reply, :ok, put_in(state.subscribers[ref].demand?, false)}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:unsubscribe, ref}, _from, state) do
    {:reply, :ok, drop_subscriber(state, ref)}
  end

  def handle_call({:deliver, frame}, _from, state)
      when state.capture_state in [:capturing, :stopping] do
    state = ensure_robot_state(state)

    case sequence_for(frame, state) do
      {:ok, sequence} ->
        frame = %{
          frame
          | sequence: sequence,
            measured_frame_rate: state.measured_frame_rate,
            requested_frame_rate: state.stream_info.frame_rate,
            attached_to: state.attached_to,
            joint_configurations: joint_configurations(state, frame)
        }

        state =
          %{
            state
            | latest: frame,
              last_sequence: sequence,
              frame_count: state.frame_count + 1,
              window_frames: state.window_frames + 1
          }
          |> serve_all()

        {:reply, :ok, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:deliver, _frame}, _from, state) do
    {:reply, {:error, NotCapturing.exception(robot: state.bb.robot, camera: state.camera)}, state}
  end

  def handle_call({:capture_started, stream_info}, _from, state) do
    state = if stream_info, do: replace_stream_info(state, stream_info), else: state

    state = %{
      state
      | capture_state: if(state.capture_state == :stopping, do: :stopping, else: :capturing),
        frame_count: 0,
        last_sequence: nil,
        latest: nil,
        subscribers: forget_sequences(state.subscribers),
        publish_loop: start_window(state),
        window_frames: 0,
        measured_frame_rate: nil
    }

    publish(state, BeginCapture,
      stream_info: state.stream_info,
      subscriber_count: map_size(state.subscribers)
    )

    {:reply, :ok, state}
  end

  def handle_call({:capture_stopped, reason}, _from, state) do
    {:reply, :ok, end_capture(state, state.stop_reason || reason, nil)}
  end

  def handle_call({:capture_failed, error}, _from, state) do
    {:reply, :ok, end_capture(state, :error, error)}
  end

  def handle_call({:update_stream_info, stream_info}, _from, state) do
    {:reply, :ok, replace_stream_info(state, stream_info)}
  end

  def handle_call(:stream_info, _from, state), do: {:reply, state.stream_info, state}
  def handle_call(:capture_state, _from, state), do: {:reply, state.capture_state, state}

  def handle_call(:capturing?, _from, state),
    do: {:reply, state.capture_state == :capturing, state}

  def handle_call(:status, _from, state) do
    {:reply, if(state.capture_state == :capturing, do: :capturing, else: :running), state}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when monitor == state.driver_monitor do
    {:stop, :normal, state}
  end

  # The state struct is only a handle on a table `Runtime` owns. When it goes
  # the handle is worthless, and holding it would raise on the next frame
  # rather than simply going without a pose for a moment.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when monitor == state.runtime_monitor do
    {:noreply, %{state | robot_state: nil, runtime_monitor: nil}}
  end

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    state.subscribers
    |> Enum.filter(fn {_ref, subscriber} -> subscriber.pid == pid end)
    |> Enum.reduce(state, fn {ref, _}, state -> drop_subscriber(state, ref) end)
    |> then(&{:noreply, &1})
  end

  # A tick with no loop behind it is one that outlived the session it was
  # scheduled in, which `cancel/1` races rather than prevents.
  def handle_info(tick, %{publish_loop: nil} = state)
      when tick == :tick
      when is_tuple(tick) and elem(tick, 0) == :tick do
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    {dt, _skipped, loop} = BB.Loop.tick(state.publish_loop)
    {:noreply, close_window(%{state | publish_loop: loop}, dt)}
  end

  def handle_info({:tick, at_ns}, state) when is_integer(at_ns) do
    {dt, _skipped, loop} = BB.Loop.observe(state.publish_loop, at_ns)
    {:noreply, close_window(%{state | publish_loop: loop}, dt)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ----------------------------------------------------------------------------
  # Capture lifecycle
  # ----------------------------------------------------------------------------

  defp request_capture(%{capture_state: :idle} = state) do
    send(state.driver, {:bb_camera, :start_capture})

    %{
      state
      | capture_state: :starting,
        stop_reason: nil,
        subscribers: begin_session(state.subscribers)
    }
  end

  defp request_capture(state), do: state

  defp release_capture(%{subscribers: subscribers} = state) when map_size(subscribers) > 0,
    do: state

  defp release_capture(%{capture_state: state_name} = state)
       when state_name in [:starting, :capturing] do
    send(state.driver, {:bb_camera, :stop_capture})
    %{state | capture_state: :stopping, stop_reason: :no_subscribers}
  end

  defp release_capture(state), do: state

  defp end_capture(state, reason, error) do
    publish(state, EndCapture, reason: reason, error: error, frame_count: state.frame_count)
    notify_session(state, termination_message(reason, error))

    state = %{
      state
      | capture_state: :idle,
        stop_reason: nil,
        latest: nil,
        last_sequence: nil,
        subscribers: end_session(state.subscribers),
        publish_loop: stop_window(state),
        window_frames: 0,
        measured_frame_rate: nil
    }

    if reason != :error and map_size(state.subscribers) > 0 do
      request_capture(state)
    else
      state
    end
  end

  defp termination_message(:error, error), do: {:capture_failed, error}
  defp termination_message(_reason, _error), do: :end_of_capture

  # Who belongs to a capture session is settled when the session is *asked
  # for*, not when the driver gets round to confirming it. A confirmation can
  # arrive after the hub has already asked for a stop, and a consumer that
  # turned up in that window must not be enrolled in a session it will be told
  # has ended moments later.
  defp begin_session(subscribers) do
    Map.new(subscribers, fn {ref, subscriber} ->
      {ref, %{subscriber | in_session?: true, last_sequence: nil}}
    end)
  end

  # A new session starts its sequence wherever the driver likes, so what a
  # consumer saw in the last one tells it nothing about what is new in this
  # one.
  defp forget_sequences(subscribers) do
    Map.new(subscribers, fn {ref, subscriber} ->
      {ref, %{subscriber | last_sequence: nil}}
    end)
  end

  # A subscriber that was in the session has been told the capture ended, so
  # its request has been answered and its demand is spent.
  #
  # One that arrived while the stop was in flight was told nothing, because
  # nothing that concerned it happened. Its request is still outstanding and
  # must survive into the next session - dropping it here is invisible to the
  # consumer, which would simply wait out its timeout on a camera that had
  # restarted perfectly well.
  defp end_session(subscribers) do
    Map.new(subscribers, fn
      {ref, %{in_session?: true} = subscriber} ->
        {ref, %{subscriber | in_session?: false, last_sequence: nil, demand?: false}}

      {ref, subscriber} ->
        {ref, %{subscriber | last_sequence: nil}}
    end)
  end

  defp notify_session(state, message) do
    Enum.each(state.subscribers, fn {ref, subscriber} ->
      if subscriber.in_session?, do: send(subscriber.pid, {:bb_camera, ref, message})
    end)
  end

  defp replace_stream_info(state, stream_info) do
    %{
      state
      | stream_info: stream_info,
        stream_info_generation: state.stream_info_generation + 1,
        latest: nil
    }
  end

  # ----------------------------------------------------------------------------
  # Frame dispatch
  # ----------------------------------------------------------------------------

  defp sequence_for(%Frame{sequence: nil}, state), do: {:ok, (state.last_sequence || -1) + 1}

  defp sequence_for(%Frame{sequence: sequence}, %{last_sequence: nil}), do: {:ok, sequence}

  defp sequence_for(%Frame{sequence: sequence}, %{last_sequence: last}) when sequence > last,
    do: {:ok, sequence}

  defp sequence_for(%Frame{sequence: sequence}, state) do
    {:error,
     StaleFrame.exception(
       camera: state.camera,
       sequence: sequence,
       last_sequence: state.last_sequence
     )}
  end

  defp serve_all(state), do: Enum.reduce(Map.keys(state.subscribers), state, &serve(&2, &1))

  defp serve(%{latest: nil} = state, _ref), do: state

  defp serve(state, ref) do
    subscriber = state.subscribers[ref]

    if servable?(subscriber, state.latest) do
      send_stream_info_if_changed(state, ref, subscriber)
      send(subscriber.pid, {:bb_camera, ref, state.latest})

      put_in(state.subscribers[ref], %{
        subscriber
        | demand?: false,
          last_sequence: state.latest.sequence,
          generation: state.stream_info_generation
      })
    else
      state
    end
  end

  # A frame belongs to the capture session it was produced in, and so does a
  # consumer. Serving one across that boundary would hand a consumer a frame
  # from a session it never joined - and worse, set its idea of what it has
  # seen from a sequence the next session knows nothing about.
  defp servable?(subscriber, frame) do
    subscriber.demand? and subscriber.in_session? and fresh?(frame, subscriber)
  end

  defp fresh?(_frame, %{last_sequence: nil}), do: true
  defp fresh?(frame, %{last_sequence: last}), do: frame.sequence > last

  defp send_stream_info_if_changed(state, ref, subscriber) do
    if subscriber.generation != state.stream_info_generation do
      send(subscriber.pid, {:bb_camera, ref, {:stream_info, state.stream_info}})
    end

    :ok
  end

  defp drop_subscriber(state, ref) do
    case pop_in(state.subscribers[ref]) do
      {nil, state} ->
        state

      {subscriber, state} ->
        Process.demonitor(subscriber.monitor, [:flush])
        release_capture(state)
    end
  end

  # ----------------------------------------------------------------------------
  # Where the camera was
  # ----------------------------------------------------------------------------

  # A camera on a gimbal is somewhere different in every frame, and once the
  # joints have moved there is no recovering where it was - except from the
  # robot's joint history, which is asked for the configuration at the frame's
  # own capture time rather than at whatever moment it reached the hub. Reading
  # it is cheap enough to do per frame; computing the transform is not, and is
  # reproducible later from this, so it isn't done here.
  #
  # When history can't answer - it's turned off, or the frame was captured
  # before it began, as around a `Runtime` restart - the configuration current
  # as the frame arrives is the best there is, and is what a frame carried
  # before history existed.
  defp joint_configurations(%{robot_state: nil}, _frame), do: %{}

  defp joint_configurations(state, frame) do
    case RobotState.get_all_configurations_at(state.robot_state, frame.monotonic_time) do
      {:ok, configurations} -> configurations
      {:error, _cannot_answer} -> RobotState.get_all_configurations(state.robot_state)
    end
  end

  # The robot struct records where every sensor in the topology hangs, so this
  # reads it rather than deriving it a second time. It is compile-time data,
  # which means a hub can say where its camera is even when nothing is
  # running.
  #
  # Robot-level sensors are the exception: `BB.Robot.Builder` collects only
  # the ones declared inside the topology, so a camera in the `sensors` block
  # is absent from `robot.sensors` entirely. Such a sensor has nothing above
  # it but the robot, which its path says by having no parent in it.
  defp attachment(robot_module, camera, path) do
    case robot_module.robot() do
      %{sensors: %{^camera => %{attached_to: attached_to}}} -> attached_to
      _otherwise -> if length(path) < 2, do: :robot
    end
  rescue
    UndefinedFunctionError -> nil
  end

  # The state struct carries the ETS table `Runtime` owns, so a hub that
  # cached one across a `Runtime` restart would be holding a deleted table and
  # would raise on the next frame. Monitoring it means the reference is
  # dropped when it dies and picked up again on the next frame, which is the
  # only moment it is needed.
  defp ensure_robot_state(%{robot_state: nil} = state) do
    case fetch_robot_state(state.bb.robot) do
      nil -> state
      robot_state -> %{state | robot_state: robot_state, runtime_monitor: monitor_runtime(state)}
    end
  end

  defp ensure_robot_state(state), do: state

  defp monitor_runtime(state) do
    case BB.Process.whereis(state.bb.robot, Runtime) do
      pid when is_pid(pid) -> Process.monitor(pid)
      _otherwise -> nil
    end
  end

  # A hub can run without a robot behind it - in a driver's own unit tests,
  # say - and a camera that cannot say where it was pointing is a better
  # answer than one that refuses to start. Anything other than "nothing is
  # there" is worth saying out loud, though: a `Runtime` too busy to answer
  # would otherwise produce empty pose snapshots for the life of the process
  # with nothing to explain them.
  defp fetch_robot_state(robot) do
    Runtime.get_robot_state(robot)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      nil

    :exit, reason ->
      Logger.warning(
        "#{inspect(robot)} could not be asked for its state, so frames will carry no pose: " <>
          inspect(reason)
      )

      nil
  end

  # ----------------------------------------------------------------------------
  # Publishing capture state
  # ----------------------------------------------------------------------------

  # A loop is built fresh for each session rather than re-armed. `arm/1` keeps
  # the timestamp of the last tick, so a re-armed loop measures its first
  # interval of a new session from the last tick of the previous one - the
  # whole idle gap between them included - and a camera that had been stopped
  # for an hour would open with a rate near zero. There is nothing to carry
  # across: a window belongs to the session it was counted in.
  defp start_window(state) do
    stop_window(state)

    state.bb
    |> BB.Loop.new(clock: clock_for(state.publish_rate))
    |> BB.Loop.arm()
  end

  defp stop_window(%{publish_loop: nil}), do: nil
  defp stop_window(state), do: BB.Loop.cancel(state.publish_loop)

  defp clock_for(:external), do: :external
  defp clock_for(rate), do: {:rate, rate}

  # The rate is counted over the window rather than smoothed across the
  # session, so a capture that has stalled reports 0.0 rather than whatever it
  # last managed. A tick with no interval behind it - the first of a session -
  # has nothing to divide by and says so.
  defp close_window(%{capture_state: capture_state} = state, _dt)
       when capture_state not in [:capturing, :stopping],
       do: state

  defp close_window(state, dt) do
    measured = if dt && dt > 0, do: state.window_frames / dt

    publish(state, CaptureState,
      capture_state: state.capture_state,
      frames: state.window_frames,
      measured_frame_rate: measured,
      requested_frame_rate: state.stream_info.frame_rate,
      subscriber_count: map_size(state.subscribers)
    )

    %{state | window_frames: 0, measured_frame_rate: measured}
  end

  # ----------------------------------------------------------------------------
  # PubSub
  # ----------------------------------------------------------------------------

  defp publish(state, payload_module, fields) do
    message = Message.new!(payload_module, state.camera, fields)
    BB.publish(state.bb.robot, state.topic, message)
  end
end
