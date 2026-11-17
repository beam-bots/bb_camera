# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera do
  @moduledoc """
  Behaviour and API for cameras in the BB framework.

  A camera is an ordinary `BB.Sensor` that happens to produce rather more data
  than a sensor usually does. It is declared in the robot DSL like any other
  sensor, supervised like any other sensor, and `bb` itself knows nothing about
  cameras.

      topology do
        link :head do
          sensor :eye, {BB.Camera.Synthetic, width: 640, height: 480}
        end
      end

  ## Frames do not go on PubSub

  Everything else in `bb` publishes its readings and lets subscribers sort it
  out. Cameras cannot: a 1080p MJPEG stream is tens of megabytes a second, and
  a fan-out registry with no backpressure turns one slow subscriber into an
  unbounded mailbox. So `BB.PubSub` carries camera *lifecycle* only - capture
  started and ended, settings applied and rejected - and frames travel over the
  bounded interface `BB.Camera.Hub` serves.

  The split is not an optimisation. It is what lets a robot keep running when a
  consumer stalls.

  ## Consuming a camera

  Two shapes over the same mechanism. Pull, which suits anything with its own
  loop - an HTTP route writing chunks, say:

      {:ok, session} = BB.Camera.Media.open(MyRobot, :eye, format: :jpeg)
      {:ok, frame} = BB.Camera.Media.next(session, 2_000)
      :ok = BB.Camera.Media.close(session)

  And demand, which suits anything with its own notion of backpressure - a
  Membrane pipeline, or a GenServer that wants frames as messages:

      {:ok, sub} = BB.Camera.subscribe(MyRobot, :eye)
      :ok = BB.Camera.request(sub)
      receive do
        {:bb_camera, ref, %BB.Camera.Frame{} = frame} when ref == sub.ref -> frame
      end

  In both, a request yields exactly one frame, strictly newer than the last one
  you were given. A consumer that asks in a loop therefore runs at the camera's
  frame rate; one that asks slowly gets the latest frame each time and misses
  the ones in between, which for independently decodable frames is lossless for
  what survives. That is also why this package refuses interframe codecs
  outright - see `BB.Camera.Format`.

  ## Writing a driver

  One module, `use BB.Sensor` and `use BB.Camera`. Two callbacks of your own,
  then three messages from the hub to answer. `BB.Camera.Synthetic` is a
  complete worked example; the short version is:

      defmodule MyCamera do
        use BB.Sensor, options_schema: [...]
        use BB.Camera

        @impl BB.Camera
        def stream_info(opts) do
          BB.Camera.StreamInfo.new(format: :jpeg, width: opts[:width], height: opts[:height])
        end

        @impl BB.Sensor
        def init(opts) do
          {:ok, info} = stream_info(opts)
          {:ok, hub} = BB.Camera.Hub.start_link(bb: opts[:bb], stream_info: info)
          {:ok, %{bb: opts[:bb], hub: hub}}
        end

        @impl BB.Sensor
        def handle_info({:bb_camera, :start_capture}, state), do: ...
        def handle_info({:bb_camera, :stop_capture}, state), do: ...
        def handle_info({:bb_camera, {:put_settings, settings, ref}}, state), do: ...
      end

  Nothing in this interface assumes where frames come from. A driver reading a
  device through a subprocess, one calling a platform capture API from a NIF,
  and one synthesising frames all meet it identically.
  """

  alias BB.Camera.{Discovery, Format, Hub, Info, Settings, StreamInfo, Subscription}
  alias BB.Error.Invalid.Camera.UnknownCamera
  alias BB.Error.State.Camera.NotRunning

  # ----------------------------------------------------------------------------
  # Behaviour
  # ----------------------------------------------------------------------------

  @doc """
  What this camera will produce, derived from its declared options alone.

  **This must be pure.** It is called during discovery, against robots that are
  not running, with the options exactly as written in the DSL - parameter
  references unresolved, hardware unopened, possibly absent. Describe what was
  asked for.

  What the camera turns out to actually produce is reported at runtime through
  `BB.Camera.Hub.capture_started/2` or `BB.Camera.Hub.update_stream_info/2`,
  and that value is what consumers see once it exists.

  Return `{:error, %BB.Error.Invalid.Camera.UnknownStreamInfo{}}` when the
  options genuinely cannot imply a format; discovery then reports
  `stream_info: nil` rather than inventing one.
  """
  @callback stream_info(opts :: keyword()) :: {:ok, StreamInfo.t()} | {:error, struct()}

  @doc """
  The settings this camera accepts, as a `Spark.Options` schema.

  Defaults to accepting nothing. Settings are validated against this before the
  driver is asked to apply them, so an invalid set never reaches hardware.
  """
  @callback settings_schema() :: Spark.Options.t()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour BB.Camera

      @impl BB.Camera
      def settings_schema, do: Spark.Options.new!([])

      defoverridable settings_schema: 0
    end
  end

  # ----------------------------------------------------------------------------
  # Discovery
  # ----------------------------------------------------------------------------

  @doc """
  Every camera `robot` declares, whether or not it is running.

  Cameras that are declared but have no live hub are reported with
  `status: :declared` rather than omitted.

  ## Options

  - `:status` - keep only cameras in this state (`:capturing`, `:running` or
    `:declared`). Defaults to all of them.
  """
  @spec discover(module(), keyword()) :: [Info.t()]
  def discover(robot, opts \\ []) do
    cameras = Discovery.discover(robot)

    case Keyword.get(opts, :status) do
      nil -> cameras
      status -> Enum.filter(cameras, &(&1.status == status))
    end
  end

  @doc """
  What a camera is producing.

  The live format when the camera is running, the declared one when it isn't.
  """
  @spec stream_info(module(), atom()) :: {:ok, StreamInfo.t()} | {:error, struct()}
  def stream_info(robot, camera) do
    with {:ok, info} <- find(robot, camera) do
      case info.stream_info do
        nil -> {:error, NotRunning.exception(robot: robot, camera: camera)}
        stream_info -> {:ok, stream_info}
      end
    end
  end

  @doc """
  Whether frames in `format` decode without reference to each other.

  The predicate this package's format support is gated on. See
  `BB.Camera.Format`.
  """
  @spec independent_frames?(term()) :: boolean()
  defdelegate independent_frames?(format), to: Format

  # ----------------------------------------------------------------------------
  # Demand interface
  # ----------------------------------------------------------------------------

  @doc """
  Become a consumer of a camera's capture.

  Subscribing delivers nothing by itself - call `request/1` for each frame you
  want. It does start capture if nobody else was watching, and the camera stops
  capturing when the last subscription goes.

  ## Options

  - `:format` - assert the camera produces this format, failing loudly if it
    doesn't. A consumer that can only handle JPEG should say so here rather
    than discover it from the bytes.
  - `:owner` - the process frames are sent to, defaulting to the caller. The
    hub monitors it and unsubscribes automatically when it dies, so a crashed
    consumer releases the capture rather than pinning it.

  The returned subscription's `monitor` watches the hub and belongs to the
  *calling* process, which is not necessarily `:owner`. Subscribing on one
  process's behalf from another is supported - the frames go where you said -
  but the owner won't learn of a dead camera from a monitor it doesn't hold.
  Subscribe from the process that will consume unless you have a reason not to.
  """
  @spec subscribe(module(), atom(), keyword()) :: {:ok, Subscription.t()} | {:error, struct()}
  def subscribe(robot, camera, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())

    with {:ok, hub} <- hub(robot, camera),
         {:ok, ref, stream_info} <- Hub.subscribe(hub, owner, opts) do
      {:ok,
       %Subscription{
         robot: robot,
         camera: camera,
         hub: hub,
         ref: ref,
         monitor: Process.monitor(hub),
         stream_info: stream_info
       }}
    end
  end

  @doc """
  Ask for one frame.

  You will be sent `{:bb_camera, subscription.ref, %BB.Camera.Frame{}}` once a
  frame strictly newer than your last one exists - immediately if one already
  does.

  At most one request is outstanding at a time; asking again before delivery
  changes nothing. Demand does not accumulate, so a consumer that stops asking
  simply stops receiving, and the camera's memory use doesn't depend on how
  long it takes to come back.

  These also arrive on a subscription, regardless of outstanding demand:

  - `{:bb_camera, ref, {:stream_info, info}}` immediately before the first
    frame a changed format describes.
  - `{:bb_camera, ref, :end_of_capture}` when capture stopped cleanly.
  - `{:bb_camera, ref, {:capture_failed, error}}` when it failed.
  """
  @spec request(Subscription.t()) :: :ok | {:error, struct()}
  def request(%Subscription{} = subscription) do
    with_live_hub(subscription, fn -> Hub.request(subscription.hub, subscription.ref) end)
  end

  @doc """
  Withdraw an outstanding request.

  Leaves the subscription in place. Use it when you've stopped waiting - after
  a timeout, say - so the hub isn't holding demand nothing will collect.
  """
  @spec cancel_request(Subscription.t()) :: :ok | {:error, struct()}
  def cancel_request(%Subscription{} = subscription) do
    with_live_hub(subscription, fn -> Hub.cancel_request(subscription.hub, subscription.ref) end)
  end

  @doc """
  Stop consuming. Capture stops when the last subscription goes.
  """
  @spec unsubscribe(Subscription.t()) :: :ok
  def unsubscribe(%Subscription{} = subscription) do
    Process.demonitor(subscription.monitor, [:flush])
    with_live_hub(subscription, fn -> Hub.unsubscribe(subscription.hub, subscription.ref) end)
    :ok
  end

  # A camera that has died owes its consumers nothing, and a consumer tidying
  # up after one shouldn't have to find out whether it is still there first -
  # the answer can change between asking and acting. Treat the exit as the
  # answer.
  defp with_live_hub(subscription, fun) do
    fun.()
  catch
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown, :killed] ->
      {:error, NotRunning.exception(robot: subscription.robot, camera: subscription.camera)}
  end

  # ----------------------------------------------------------------------------
  # Settings
  # ----------------------------------------------------------------------------

  @doc """
  A running camera's settings, with the provenance of each value.
  """
  @spec settings(module(), atom()) :: {:ok, Settings.t()} | {:error, struct()}
  def settings(robot, camera) do
    with {:ok, hub} <- hub(robot, camera), do: {:ok, Hub.settings(hub)}
  end

  @doc """
  Change a camera's settings, waiting for the driver to report the outcome.

  The given settings are a patch: they are merged over the camera's current
  values before validation, so changing one setting cannot reset another to its
  schema default. The driver is handed the complete resulting set.

  Returns the camera's full settings on success, including whatever the driver
  was able to verify. A driver that doesn't answer within `timeout` gets its
  request abandoned rather than left pending forever.
  """
  @spec put_settings(module(), atom(), keyword() | map(), timeout()) ::
          {:ok, Settings.t()} | {:error, struct()}
  def put_settings(robot, camera, settings, timeout \\ 5000) do
    with {:ok, hub} <- hub(robot, camera) do
      Hub.put_settings(hub, Map.new(settings), timeout)
    end
  end

  # ----------------------------------------------------------------------------
  # Resolution
  # ----------------------------------------------------------------------------

  @doc """
  The hub serving a camera, if it's running.
  """
  @spec hub(module(), atom()) :: {:ok, pid()} | {:error, struct()}
  def hub(robot, camera) do
    with {:ok, _info} <- find(robot, camera) do
      case Discovery.hub_pid(robot, camera) do
        :undefined -> {:error, NotRunning.exception(robot: robot, camera: camera)}
        pid -> {:ok, pid}
      end
    end
  end

  defp find(robot, camera) do
    cameras = discover(robot)

    case Enum.find(cameras, &(&1.name == camera)) do
      nil ->
        {:error,
         UnknownCamera.exception(
           robot: robot,
           camera: camera,
           known: Enum.map(cameras, & &1.name)
         )}

      info ->
        {:ok, info}
    end
  end
end
