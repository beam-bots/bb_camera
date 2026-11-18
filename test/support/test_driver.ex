# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.TestDriver do
  @moduledoc """
  A camera driver that does nothing until a test tells it to.

  `BB.Camera.Synthetic` answers the hub immediately, which is what you want
  when exercising the ordinary path. It is useless for the races, which all
  live in the window between the hub asking a driver to do something and the
  driver confirming it did. This driver holds that window open for as long as a
  test wants.

  Every message the hub sends is forwarded to the registered reporter process
  rather than acted on, and each confirmation is a separate call the test
  makes when it is ready:

      BB.Camera.TestDriver.report_to(Robot, :eye)
      {:ok, sub} = BB.Camera.subscribe(Robot, :eye)
      assert_received {:driver, :start_capture}          # hub asked
      BB.Camera.TestDriver.confirm_start(Robot, :eye)    # driver answers, now

  Nothing here sleeps, and nothing races: a test that wants to know what
  happens when a subscriber arrives mid-stop simply doesn't confirm the stop
  until it has arrived.
  """

  use BB.Sensor,
    options_schema: [
      width: [type: :pos_integer, default: 64],
      height: [type: :pos_integer, default: 48]
    ]

  use BB.Camera

  alias BB.Camera.{Frame, Hub, StreamInfo}

  @impl BB.Camera
  def stream_info(opts) do
    StreamInfo.new(
      format: :jpeg,
      width: Keyword.get(opts, :width, 64),
      height: Keyword.get(opts, :height, 48)
    )
  end

  @impl BB.Sensor
  def init(opts) do
    opts = Map.new(opts)
    {:ok, info} = stream_info(Enum.to_list(opts))
    {:ok, hub} = Hub.start_link(bb: opts.bb, stream_info: info)

    {:ok, %{bb: opts.bb, hub: hub, reporter: nil, sequence: 0}}
  end

  # Everything the hub asks for is reported, never acted on.
  @impl BB.Sensor
  def handle_info({:bb_camera, :start_capture}, state) do
    report(state, :start_capture)
    {:noreply, state}
  end

  def handle_info({:bb_camera, :stop_capture}, state) do
    report(state, :stop_capture)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl BB.Sensor
  def handle_call({:test, :report_to, pid}, _from, state) do
    {:reply, :ok, %{state | reporter: pid}}
  end

  def handle_call({:test, :confirm_start, stream_info}, _from, state) do
    {:reply, Hub.capture_started(state.hub, stream_info), %{state | sequence: 0}}
  end

  def handle_call({:test, :confirm_stop, reason}, _from, state) do
    {:reply, Hub.capture_stopped(state.hub, reason), state}
  end

  def handle_call({:test, :fail, error}, _from, state) do
    {:reply, Hub.capture_failed(state.hub, error), state}
  end

  def handle_call({:test, :update_stream_info, stream_info}, _from, state) do
    {:reply, Hub.update_stream_info(state.hub, stream_info), state}
  end

  def handle_call({:test, :deliver, data}, _from, state) do
    frame =
      Frame.new!(
        format: :jpeg,
        width: 64,
        height: 48,
        data: data,
        sequence: state.sequence
      )

    {:reply, Hub.deliver(state.hub, frame), %{state | sequence: state.sequence + 1}}
  end

  def handle_call({:test, :deliver_raw, frame}, _from, state) do
    {:reply, Hub.deliver(state.hub, frame), state}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :not_implemented}, state}

  defp report(%{reporter: nil}, _message), do: :ok
  defp report(%{reporter: pid}, message), do: send(pid, {:driver, message})

  # --------------------------------------------------------------------------
  # Test-facing helpers
  # --------------------------------------------------------------------------

  @doc "Forward every hub request to the calling process."
  def report_to(robot, camera), do: call(robot, camera, {:test, :report_to, self()})

  @doc "Answer a pending `:start_capture`."
  def confirm_start(robot, camera, stream_info \\ nil),
    do: call(robot, camera, {:test, :confirm_start, stream_info})

  @doc "Answer a pending `:stop_capture`."
  def confirm_stop(robot, camera, reason \\ :driver_stopped),
    do: call(robot, camera, {:test, :confirm_stop, reason})

  @doc "Report that capture failed."
  def fail(robot, camera, error), do: call(robot, camera, {:test, :fail, error})

  @doc "Report a new live format."
  def update_stream_info(robot, camera, stream_info),
    do: call(robot, camera, {:test, :update_stream_info, stream_info})

  @doc "Hand a frame to the hub, with an auto-incrementing sequence."
  def deliver(robot, camera, data \\ "jpeg"), do: call(robot, camera, {:test, :deliver, data})

  @doc "Hand a frame to the hub exactly as given."
  def deliver_raw(robot, camera, frame), do: call(robot, camera, {:test, :deliver_raw, frame})

  defp call(robot, camera, message), do: BB.Process.call(robot, camera, message)
end
