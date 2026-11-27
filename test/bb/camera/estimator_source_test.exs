# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.EstimatorSourceTest do
  use ExUnit.Case, async: false

  alias BB.Camera
  alias BB.Camera.{Frame, Hub, Media, Synthetic}
  alias BB.Error.Hardware.Camera.CaptureFailed
  alias BB.Message
  alias BB.Message.Camera.{BeginCapture, EndCapture}
  alias BB.Test.RecordingEstimator

  @camera_path [:sensor, :head, :eye]

  defmodule WatchedCamera do
    @moduledoc false
    use BB

    topology do
      link :head do
        sensor :eye, {Synthetic, clock: :external} do
          estimator(:watcher, RecordingEstimator)
        end
      end
    end
  end

  defmodule GatedCamera do
    @moduledoc false
    use BB

    topology do
      link :head do
        sensor :eye, {Synthetic, clock: :external} do
          estimator(:watcher, {RecordingEstimator, gated: true})
        end
      end
    end
  end

  defmodule StaleCamera do
    @moduledoc false
    use BB

    topology do
      link :head do
        sensor :eye, {Synthetic, clock: :external} do
          estimator :watcher, RecordingEstimator do
            max_input_age(~u(1 nanosecond))
          end
        end
      end
    end
  end

  defmodule LostCamera do
    @moduledoc false
    use BB

    topology do
      link :head do
        sensor :eye, {Synthetic, clock: :external} do
          estimator :watcher, RecordingEstimator do
            lost_after(~u(1 millisecond))
          end
        end
      end
    end
  end

  defmodule BrokenCamera do
    @moduledoc false
    use BB

    topology do
      link :head do
        sensor :eye, {Synthetic, clock: :external, fail_capture: true} do
          estimator(:watcher, RecordingEstimator)
        end
      end
    end
  end

  describe "frames reach handle_input" do
    test "one frame per completed dispatch" do
      start_watched(WatchedCamera)

      :ok = Synthetic.capture_frame(WatchedCamera, :eye)
      assert_receive {:received, :input, %Frame{sequence: 0}}

      :ok = Synthetic.capture_frame(WatchedCamera, :eye)
      assert_receive {:received, :input, %Frame{sequence: 1}}
    end

    test "nothing is requested while handle_input is held, and the newest frame follows release" do
      estimator = start_watched(GatedCamera)

      :ok = Synthetic.capture_frame(GatedCamera, :eye)
      assert_receive {:received, :holding, %Frame{sequence: 0}}

      # Had the estimator asked for a frame while held, the hub would have sent
      # it each of these, and the first would be dispatched next.
      :ok = Synthetic.capture_frame(GatedCamera, :eye)
      :ok = Synthetic.capture_frame(GatedCamera, :eye)

      send(estimator, :release)
      assert_receive {:received, :input, %Frame{sequence: 0}}
      assert_receive {:received, :holding, %Frame{sequence: sequence}}
      assert sequence == 2

      send(estimator, :release)
      assert_receive {:received, :input, %Frame{sequence: 2}}
    end
  end

  describe "health is driven by frame time" do
    test "a frame older than max_input_age is dropped before handle_input" do
      attach_telemetry(StaleCamera, [[:bb, :estimator, :dropped], [:bb, :estimator, :transition]])
      estimator = start_watched(StaleCamera)

      :ok = Synthetic.capture_frame(StaleCamera, :eye)

      assert_receive {:telemetry, :dropped, %{reason: :stale_input, source_input: :parent}}
      assert_receive {:telemetry, :transition, %{to: :degraded, reason: :stale_input}}
      :sys.get_state(estimator)
      refute_received {:received, :input, _}
    end

    test "a frame recovers an estimator that was lost" do
      attach_telemetry(LostCamera, [[:bb, :estimator, :transition]])
      start_watched(LostCamera)

      assert_receive {:telemetry, :transition, %{to: :lost}}

      :ok = Synthetic.capture_frame(LostCamera, :eye)

      assert_receive {:received, :input, %Frame{}}
      assert_receive {:telemetry, :transition, %{from: :lost, to: :degraded, reason: :recovered}}
    end
  end

  describe "capture lifecycle" do
    test "the estimator resumes when a capture ends cleanly and restarts" do
      start_watched(WatchedCamera)
      {:ok, hub} = Camera.hub(WatchedCamera, :eye)

      :ok = Hub.capture_stopped(hub, :driver_stopped)
      assert_receive {:bb, @camera_path, %Message{payload: %EndCapture{}}}
      assert_receive {:bb, @camera_path, %Message{payload: %BeginCapture{}}}

      :ok = Synthetic.capture_frame(WatchedCamera, :eye)
      assert_receive {:received, :input, %Frame{}}
    end

    test "a failed capture makes the estimator lost, and it recovers when capture restarts" do
      attach_telemetry(WatchedCamera, [[:bb, :estimator, :transition]])
      estimator = start_watched(WatchedCamera)
      {:ok, hub} = Camera.hub(WatchedCamera, :eye)

      :ok = Hub.capture_failed(hub, CaptureFailed.exception(camera: :eye, reason: :test))
      assert_receive {:bb, @camera_path, %Message{payload: %EndCapture{reason: :error}}}

      assert_receive {:telemetry, :transition,
                      %{from: :healthy, to: :lost, reason: :source_failed}}

      {:ok, session} = Media.open(WatchedCamera, :eye)
      on_exit(fn -> Media.close(session) end)
      assert_receive {:bb, @camera_path, %Message{payload: %BeginCapture{}}}

      :ok = Synthetic.capture_frame(WatchedCamera, :eye)
      assert_receive {:received, :input, %Frame{}}
      assert_receive {:telemetry, :transition, %{from: :lost, to: :degraded, reason: :recovered}}
      assert BB.Process.whereis(WatchedCamera, :watcher) == estimator
    end

    test "a camera that cannot capture leaves its estimator lost and running, not restarting" do
      attach_telemetry(BrokenCamera, [[:bb, :estimator, :transition]])
      start_robot(BrokenCamera)
      {:ok, hub} = Camera.hub(BrokenCamera, :eye)
      assert Hub.capture_state(hub) == :idle

      estimator = BB.Process.whereis(BrokenCamera, :watcher)
      monitor = Process.monitor(estimator)

      assert_receive {:telemetry, :transition, %{to: :lost, reason: :source_failed}}
      :sys.get_state(estimator)

      refute_received {:DOWN, ^monitor, _, _, _}
      refute_received {:received, :input, _}
    end
  end

  describe "the estimator restarts with its camera" do
    test "after the driver crashes, it receives frames from the new hub" do
      assert_restarts_against_new_hub(fn -> BB.Process.whereis(WatchedCamera, :eye) end)
    end

    test "after the hub crashes, it receives frames from the new hub" do
      assert_restarts_against_new_hub(fn ->
        {:ok, hub} = Camera.hub(WatchedCamera, :eye)
        hub
      end)
    end
  end

  # The estimator is stopped by its supervisor - exit reason `:shutdown` - not
  # by itself, and the replacement subscribes only after the new driver, and
  # so the new hub, is running. Were it started first, its subscribe would
  # fail in `init/1` and it would never see a frame.
  defp assert_restarts_against_new_hub(victim) do
    estimator = start_watched(WatchedCamera)
    {:ok, old_hub} = Camera.hub(WatchedCamera, :eye)
    estimator_monitor = Process.monitor(estimator)

    Process.exit(victim.(), :kill)

    assert_receive {:DOWN, ^estimator_monitor, :process, ^estimator, :shutdown}
    assert_receive {:bb, @camera_path, %Message{payload: %BeginCapture{}}}

    :ok = Synthetic.capture_frame(WatchedCamera, :eye)
    assert_receive {:received, :input, %Frame{}}

    {:ok, new_hub} = Camera.hub(WatchedCamera, :eye)
    assert new_hub != old_hub
    assert BB.Process.whereis(WatchedCamera, :watcher) != estimator
  end

  defp start_watched(robot) do
    start_robot(robot)
    BB.Process.whereis(robot, :watcher)
  end

  # The estimator subscribes as the robot starts, and the hub asks the driver
  # to start capturing before that subscription returns. A call through the
  # driver therefore lands after it has answered - and its answer to the hub
  # is synchronous - so the capture has started, or failed, by the time this
  # returns. It is too early to have seen `BeginCapture` on PubSub, which can't
  # be subscribed to until the robot is running.
  defp start_robot(robot) do
    :persistent_term.put({RecordingEstimator, robot}, self())
    on_exit(fn -> :persistent_term.erase({RecordingEstimator, robot}) end)
    start_supervised!(robot)
    :sys.get_state(BB.Process.whereis(robot, :eye))
    {:ok, _} = BB.subscribe(robot, @camera_path)
  end

  defp attach_telemetry(robot, events) do
    handler_id = "estimator-source-#{:erlang.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn
        event, measurements, %{robot: ^robot} = metadata, _ ->
          send(test_pid, {:telemetry, List.last(event), Map.merge(measurements, metadata)})

        _event, _measurements, _metadata, _ ->
          :ok
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
