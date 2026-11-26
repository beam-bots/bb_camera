# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Membrane.SourceTest do
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias BB.Camera.{Frame, StreamInfo, Synthetic, TestDriver}
  alias BB.Camera.Membrane.Source
  alias BB.Camera.TestBots.{GatedCamera, SingleCamera}
  alias BB.Message.Camera.BeginCapture
  alias Membrane.Testing

  describe "in a real pipeline" do
    setup do
      start_supervised!(SingleCamera)
      :ok
    end

    test "a sink downstream of the source receives the camera's raw frames" do
      BB.subscribe(SingleCamera, [:sensor, :head, :eye])
      pipeline = start_pipeline(SingleCamera, :eye)

      assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{
        width: 160,
        height: 120,
        pixel_format: :I420,
        aligned: true
      })

      :ok = await_capture()

      :ok = Synthetic.capture_frame(SingleCamera, :eye)

      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: payload})
      assert payload == hd(Synthetic.default_frames(160, 120))

      Testing.Pipeline.terminate(pipeline)
    end

    test "successive frames arrive in order with increasing sequence metadata" do
      BB.subscribe(SingleCamera, [:sensor, :head, :eye])
      pipeline = start_pipeline(SingleCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{})
      :ok = await_capture()

      # One frame at a time, each asserted before the next is produced. The
      # camera only ever holds the latest frame, so producing three in a row
      # and expecting three buffers would be asserting that the source happened
      # to be scheduled between them - which is exactly the kind of thing that
      # passes here and fails under CI load.
      :ok = Synthetic.capture_frame(SingleCamera, :eye)
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{metadata: %{bb_camera: first}})

      :ok = Synthetic.capture_frame(SingleCamera, :eye)
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{metadata: %{bb_camera: second}})

      assert second.sequence > first.sequence

      Testing.Pipeline.terminate(pipeline)
    end

    test "presentation timestamps start at zero and advance" do
      BB.subscribe(SingleCamera, [:sensor, :head, :eye])
      pipeline = start_pipeline(SingleCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{})
      :ok = await_capture()

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
      assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{})

      hub = BB.Process.whereis(GatedCamera, {:camera, :eye})

      assert [%{demand?: true}] = subscribers(hub)

      Testing.Pipeline.terminate(pipeline)
    end

    test "a frame is served per request, and the pipeline keeps up with the camera" do
      pipeline = start_pipeline(GatedCamera, :eye)

      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{})

      # Each frame is collected before the next is produced. A pipeline keeping
      # up sees every frame; this asserts that, and nothing about scheduling.
      for n <- 1..3 do
        label = "frame-#{n}"
        payload = TestDriver.frame_data(label)
        :ok = TestDriver.deliver(GatedCamera, :eye, label)
        assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^payload})
      end

      Testing.Pipeline.terminate(pipeline)
    end

    test "the camera holds one frame however many the pipeline has taken" do
      pipeline = start_pipeline(GatedCamera, :eye)

      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{})

      for n <- 1..4 do
        label = "produced-#{n}"
        payload = TestDriver.frame_data(label)
        :ok = TestDriver.deliver(GatedCamera, :eye, label)
        assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^payload})
      end

      # What a pipeline buffers downstream of the source is Membrane's
      # business. What bb_camera is answerable for is that the camera's own
      # memory doesn't grow with it: one frame held, one request outstanding,
      # no matter how many have gone past.
      hub = BB.Process.whereis(GatedCamera, {:camera, :eye})
      assert %Frame{sequence: 3} = :sys.get_state(hub).latest
      assert [%{demand?: true}] = subscribers(hub)

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
      assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{width: 64, height: 48})

      :ok = TestDriver.deliver(GatedCamera, :eye, "small")
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "small" <> _})

      :ok =
        TestDriver.update_stream_info(
          GatedCamera,
          :eye,
          StreamInfo.new!(format: {:raw, :I420}, width: 320, height: 240)
        )

      :ok = TestDriver.deliver(GatedCamera, :eye, "large")

      assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{width: 320, height: 240})
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "large" <> _})

      Testing.Pipeline.terminate(pipeline)
    end

    test "a capture that ends cleanly ends the stream" do
      pipeline = start_pipeline(GatedCamera, :eye)

      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{})

      :ok = TestDriver.confirm_stop(GatedCamera, :eye)

      assert_end_of_stream(pipeline, :sink)

      Testing.Pipeline.terminate(pipeline)
    end
  end

  describe "end of capture" do
    setup do
      start_supervised!(GatedCamera)
      :ok = TestDriver.report_to(GatedCamera, :eye)
      :ok
    end

    test "ending the stream releases the camera rather than leaving it capturing" do
      pipeline = start_pipeline(GatedCamera, :eye, end_of_stream_on_capture_end?: true)

      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{})

      :ok = TestDriver.confirm_stop(GatedCamera, :eye)
      assert_end_of_stream(pipeline, :sink)

      # The element stopped consuming, so it must stop being a consumer. If it
      # stayed subscribed the hub would see a subscriber and keep asking the
      # driver to capture - for an element that will never read another buffer.
      #
      # The hub does restart once on the way past, because it decides whether
      # to restart before the element has had a chance to leave. That is a
      # single bounded flap, and it ends with the driver asked to stop and
      # nobody subscribed, which is what this asserts.
      assert_receive {:driver, :stop_capture}

      hub = BB.Process.whereis(GatedCamera, {:camera, :eye})
      assert [] = subscribers(hub)

      Testing.Pipeline.terminate(pipeline)
    end

    test "a released element emits nothing for a frame still in flight" do
      # Unsubscribing doesn't recall a message already on its way, so the
      # element has to tolerate one. Exercised directly: there is no way to
      # time the arrival of an in-flight message through a live pipeline
      # without guessing, and guessing is what these tests don't do.
      frame =
        Frame.new!(
          format: {:raw, :I420},
          width: 64,
          height: 48,
          data: TestDriver.frame_data("too-late"),
          sequence: 9
        )

      released = %{subscription: nil, demand: 1, epoch: nil}

      assert {[], ^released} = Source.handle_info({:bb_camera, make_ref(), frame}, nil, released)

      assert {[], ^released} =
               Source.handle_info({:bb_camera, make_ref(), :end_of_capture}, nil, released)
    end

    test "staying through a restart resumes rather than stalling" do
      pipeline = start_pipeline(GatedCamera, :eye, end_of_stream_on_capture_end?: false)

      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{})

      :ok = TestDriver.deliver(GatedCamera, :eye, "before-restart")
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "before-restart" <> _})

      # Capture ends with the element still subscribed and Membrane's demand
      # still outstanding. The hub spends the demand of everyone it told the
      # capture had ended, so an element that doesn't re-offer it would sit
      # here forever once capture came back.
      :ok = TestDriver.confirm_stop(GatedCamera, :eye)

      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      :ok = TestDriver.deliver(GatedCamera, :eye, "after-restart")
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "after-restart" <> _})

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
      # element refuses to exist rather than starting and failing later.
      assert_raise BB.Error.State.Camera.NotRunning, fn ->
        Source.handle_setup(nil, state)
      end
    end
  end

  defp start_pipeline(robot, camera, opts \\ []) do
    Testing.Pipeline.start_supervised!(
      spec:
        child(:camera, %Source{
          robot: robot,
          camera: camera,
          end_of_stream_on_capture_end?: Keyword.get(opts, :end_of_stream_on_capture_end?, true)
        })
        |> child(:sink, %Testing.Sink{autodemand: Keyword.get(opts, :autodemand, true)})
    )
  end

  # `handle_playing` emits the stream format before the driver has been asked
  # to start, let alone confirmed. Anything that then drives an externally
  # clocked camera has to wait for the confirmation or it races it and gets
  # `NotCapturing`.
  defp await_capture do
    assert_receive {:bb, _, %BB.Message{payload: %BeginCapture{}}}
    :ok
  end
end
