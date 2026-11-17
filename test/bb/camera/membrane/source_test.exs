# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Membrane.SourceTest do
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias BB.Camera.Membrane.Source
  alias BB.Camera.{StreamInfo, Synthetic, TestDriver}
  alias BB.Camera.TestBots.{GatedCamera, SingleCamera}
  alias Membrane.Testing

  describe "in a real pipeline" do
    setup do
      start_supervised!(SingleCamera)
      :ok
    end

    test "a sink downstream of the source receives the camera's JPEG frames" do
      pipeline = start_pipeline(SingleCamera, :eye)

      assert_sink_stream_format(pipeline, :sink, %Membrane.JPEG{width: 160, height: 120})

      :ok = Synthetic.capture_frame(SingleCamera, :eye)

      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: payload})
      assert <<0xFF, 0xD8, _::binary>> = payload

      Testing.Pipeline.terminate(pipeline)
    end

    test "successive frames arrive in order with increasing sequence metadata" do
      pipeline = start_pipeline(SingleCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.JPEG{})

      for _ <- 1..3, do: :ok = Synthetic.capture_frame(SingleCamera, :eye)

      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{metadata: %{bb_camera: first}})
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{metadata: %{bb_camera: second}})

      assert second.sequence > first.sequence

      Testing.Pipeline.terminate(pipeline)
    end

    test "presentation timestamps start at zero and advance" do
      pipeline = start_pipeline(SingleCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.JPEG{})

      :ok = Synthetic.capture_frame(SingleCamera, :eye)
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{pts: first_pts})
      assert first_pts == 0

      :ok = Synthetic.capture_frame(SingleCamera, :eye)
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{pts: second_pts})
      assert second_pts > 0

      Testing.Pipeline.terminate(pipeline)
    end
  end

  describe "demand" do
    setup do
      start_supervised!(GatedCamera)
      :ok = TestDriver.report_to(GatedCamera, :eye)
      :ok
    end

    test "a pipeline's bulk demand becomes one outstanding request at the camera" do
      # Membrane grants a manual output pad a sizeable demand up front - 100
      # buffers here. The source must not turn that into 100 requests: the
      # whole point of the hub's interface is that a consumer has at most one
      # frame outstanding, so the camera's memory never depends on how much a
      # downstream element felt like asking for.
      pipeline = start_pipeline(GatedCamera, :eye)

      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.JPEG{})

      hub = BB.Process.whereis(GatedCamera, {:camera, :eye})

      assert [%{demand?: true}] = subscribers(hub)

      Testing.Pipeline.terminate(pipeline)
    end

    test "a frame is served per request, and the pipeline keeps up with the camera" do
      pipeline = start_pipeline(GatedCamera, :eye)

      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.JPEG{})

      for n <- 1..3, do: :ok = TestDriver.deliver(GatedCamera, :eye, "frame-#{n}")

      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "frame-1"})
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "frame-2"})
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "frame-3"})

      Testing.Pipeline.terminate(pipeline)
    end
  end

  defp subscribers(hub) do
    hub |> :sys.get_state() |> Map.fetch!(:subscribers) |> Map.values()
  end

  describe "stream format changes mid-pipeline" do
    setup do
      start_supervised!(GatedCamera)
      :ok = TestDriver.report_to(GatedCamera, :eye)
      :ok
    end

    test "a renegotiated geometry is re-announced before the frame it describes" do
      pipeline = start_pipeline(GatedCamera, :eye)

      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.JPEG{width: 64, height: 48})

      :ok = TestDriver.deliver(GatedCamera, :eye, "small")
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "small"})

      :ok =
        TestDriver.update_stream_info(
          GatedCamera,
          :eye,
          StreamInfo.new!(format: :jpeg, width: 320, height: 240)
        )

      :ok = TestDriver.deliver(GatedCamera, :eye, "large")

      assert_sink_stream_format(pipeline, :sink, %Membrane.JPEG{width: 320, height: 240})
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "large"})

      Testing.Pipeline.terminate(pipeline)
    end

    test "a capture that ends cleanly ends the stream" do
      pipeline = start_pipeline(GatedCamera, :eye)

      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.JPEG{})

      :ok = TestDriver.confirm_stop(GatedCamera, :eye)

      assert_end_of_stream(pipeline, :sink)

      Testing.Pipeline.terminate(pipeline)
    end
  end

  describe "refusing what it can't carry" do
    test "setup fails rather than the element starting against a camera it can't read" do
      {[], state} =
        Source.handle_init(nil, %Source{
          robot: SingleCamera,
          camera: :eye,
          end_of_stream_on_capture_end?: true
        })

      # The robot isn't running, so there is nothing to subscribe to. The
      # element refuses to exist rather than starting and failing later, which
      # is the same path an interframe format takes.
      assert_raise BB.Error.State.Camera.NotRunning, fn ->
        Source.handle_setup(nil, state)
      end
    end
  end

  defp start_pipeline(robot, camera, opts \\ []) do
    Testing.Pipeline.start_supervised!(
      spec:
        child(:camera, %Source{robot: robot, camera: camera})
        |> child(:sink, %Testing.Sink{autodemand: Keyword.get(opts, :autodemand, true)})
    )
  end
end
