# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Membrane.Source) and Code.ensure_loaded?(Membrane.JPEG) do
  defmodule BB.Camera.Membrane.Source do
    @moduledoc """
    A `Membrane.Source` that reads from a BB camera.

    Membrane's demand maps one-to-one onto `BB.Camera.request/1`, so a pipeline
    exerts real backpressure on the camera and nothing accumulates outside it.
    The element asks the hub for a frame for each buffer the pipeline demands,
    and the hub holds one frame regardless, so a pipeline that falls behind sees
    current frames rather than a growing backlog.

        import Membrane.ChildrenSpec

        child(:camera, %BB.Camera.Membrane.Source{robot: MyRobot, camera: :eye})
        |> child(:sink, %Membrane.Testing.Sink{})

    ## Format

    The output pad carries `Membrane.JPEG`, the standard format struct, so
    downstream Membrane JPEG elements interoperate without a shim. The element
    re-emits it whenever the camera renegotiates its geometry - the camera tells
    consumers before the first frame encoded the new way, so the format a
    downstream element holds always matches the buffer it is about to receive.

    `pixel_format` comes from `stream_info.metadata[:pixel_format]` and is `nil`
    when the driver doesn't report chroma subsampling, which `Membrane.JPEG`
    permits.

    ## Timestamps

    `pts` is nanoseconds since the first frame of this element's session, not
    raw monotonic time - `System.monotonic_time/1` is routinely a large negative
    number, and a pipeline that starts its timeline there is one subtraction away
    from nonsense. The untouched capture timestamps are preserved in
    `metadata.bb_camera` for anything that needs to correlate a buffer with the
    rest of the robot's telemetry.

    ## Formats it refuses

    Constructing the element against a camera whose format this package won't
    carry fails at setup rather than at the first buffer. See
    `BB.Camera.Format` - the short version is that an interframe codec cannot
    survive the frame-dropping this interface is built on, so it is refused
    rather than corrupted.
    """

    use Membrane.Source

    alias BB.Camera
    alias BB.Camera.Frame
    alias Membrane.Buffer

    def_options(
      robot: [
        spec: module(),
        description: "The robot module the camera is declared on"
      ],
      camera: [
        spec: atom(),
        description: "The camera's sensor name"
      ],
      end_of_stream_on_capture_end?: [
        spec: boolean(),
        default: true,
        description: """
        Whether a cleanly ended capture ends the stream. With `false`,
        the element stays in place and resumes if capture restarts.
        """
      ]
    )

    def_output_pad(:output, accepted_format: %Membrane.JPEG{}, flow_control: :manual)

    @impl true
    def handle_init(_ctx, opts) do
      {[],
       %{
         robot: opts.robot,
         camera: opts.camera,
         end_of_stream_on_capture_end?: opts.end_of_stream_on_capture_end?,
         subscription: nil,
         stream_info: nil,
         demand: 0,
         epoch: nil,
         format_sent?: false
       }}
    end

    @impl true
    def handle_setup(_ctx, state) do
      case Camera.subscribe(state.robot, state.camera, format: :jpeg) do
        {:ok, subscription} ->
          {[], %{state | subscription: subscription, stream_info: subscription.stream_info}}

        {:error, error} ->
          raise error
      end
    end

    @impl true
    def handle_playing(_ctx, state) do
      {stream_format_action(state), %{state | format_sent?: true}}
    end

    @impl true
    def handle_demand(:output, size, :buffers, _ctx, state) do
      state = %{state | demand: state.demand + size}
      {[], pull(state)}
    end

    @impl true
    def handle_info({:bb_camera, ref, %Frame{} = frame}, _ctx, state)
        when ref == state.subscription.ref do
      state = %{
        state
        | demand: max(state.demand - 1, 0),
          epoch: state.epoch || frame.monotonic_time
      }

      {[buffer: {:output, buffer(frame, state)}], pull(state)}
    end

    def handle_info({:bb_camera, ref, {:stream_info, stream_info}}, _ctx, state)
        when ref == state.subscription.ref do
      state = %{state | stream_info: stream_info}
      {stream_format_action(state), state}
    end

    def handle_info({:bb_camera, ref, :end_of_capture}, _ctx, state)
        when ref == state.subscription.ref do
      if state.end_of_stream_on_capture_end? do
        {[end_of_stream: :output], state}
      else
        {[], state}
      end
    end

    def handle_info({:bb_camera, ref, {:capture_failed, error}}, _ctx, state)
        when ref == state.subscription.ref do
      raise error
    end

    def handle_info({:DOWN, monitor, :process, _pid, _reason}, _ctx, state)
        when monitor == state.subscription.monitor do
      {[end_of_stream: :output], state}
    end

    def handle_info(_message, _ctx, state), do: {[], state}

    @impl true
    def handle_terminate_request(_ctx, state) do
      if state.subscription, do: Camera.unsubscribe(state.subscription)
      {[terminate: :normal], state}
    end

    # One outstanding request at a time is the hub's contract, so asking again
    # while a frame is in flight is a no-op there. Asking once per demanded
    # buffer, as each arrives, is what keeps the pipeline's demand and the
    # camera's in step.
    defp pull(%{demand: 0} = state), do: state

    defp pull(state) do
      Camera.request(state.subscription)
      state
    end

    defp stream_format_action(%{stream_info: nil}), do: []

    defp stream_format_action(%{stream_info: stream_info}) do
      [
        stream_format:
          {:output,
           %Membrane.JPEG{
             width: stream_info.width,
             height: stream_info.height,
             pixel_format: Map.get(stream_info.metadata, :pixel_format)
           }}
      ]
    end

    defp buffer(frame, state) do
      %Buffer{
        payload: frame.data,
        pts: frame.monotonic_time - state.epoch,
        metadata: %{
          bb_camera: %{
            sequence: frame.sequence,
            width: frame.width,
            height: frame.height,
            format: frame.format,
            monotonic_time: frame.monotonic_time,
            wall_time: frame.wall_time
          }
        }
      }
    end
  end
end
