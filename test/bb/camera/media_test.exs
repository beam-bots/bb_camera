# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.MediaTest do
  use ExUnit.Case, async: false

  alias BB.Camera.{Frame, Media, Synthetic, TestDriver}
  alias BB.Camera.TestBots.{GatedCamera, SingleCamera}
  alias BB.Error.Hardware.Camera.CaptureFailed
  alias BB.Error.Invalid.Camera.UnsupportedFormat
  alias BB.Error.State.Camera.{EndOfCapture, NotRunning, Timeout}
  alias BB.Message.Camera.{BeginCapture, EndCapture}

  describe "against the synthetic camera" do
    setup do
      start_supervised!(SingleCamera)
      {:ok, session} = Media.open(SingleCamera, :eye, format: :jpeg)
      on_exit(fn -> Media.close(session) end)
      %{session: session}
    end

    test "next/2 returns a real JPEG", %{session: session} do
      :ok = Synthetic.capture_frame(SingleCamera, :eye)

      assert {:ok, %Frame{} = frame} = Media.next(session, 1_000)
      assert frame.format == :jpeg
      assert <<0xFF, 0xD8, _::binary>> = frame.data
    end

    test "successive calls return successive frames", %{session: session} do
      :ok = Synthetic.capture_frame(SingleCamera, :eye)
      assert {:ok, first} = Media.next(session, 1_000)

      :ok = Synthetic.capture_frame(SingleCamera, :eye)
      assert {:ok, second} = Media.next(session, 1_000)

      assert second.sequence > first.sequence
      refute second.data == first.data
    end

    test "a camera producing nothing times out rather than hanging", %{session: session} do
      assert {:error, %Timeout{}} = Media.next(session, 50)
    end

    test "a timeout doesn't strand the frame that arrives just after it", %{session: session} do
      assert {:error, %Timeout{}} = Media.next(session, 50)

      :ok = Synthetic.capture_frame(SingleCamera, :eye)
      assert {:ok, %Frame{}} = Media.next(session, 1_000)
    end

    test "asserting the wrong format fails at open rather than at the bytes" do
      assert {:error, %UnsupportedFormat{reason: :mismatch}} =
               Media.open(SingleCamera, :eye, format: :h264)
    end

    test "the synthetic camera reports the geometry it actually produced" do
      assert {:ok, info} = BB.Camera.stream_info(SingleCamera, :eye)
      assert info.width == 160
      assert info.height == 120
    end
  end

  describe "a loop over next/2" do
    setup do
      start_supervised!(SingleCamera)
      {:ok, session} = Media.open(SingleCamera, :eye, format: :jpeg)
      on_exit(fn -> Media.close(session) end)
      %{session: session}
    end

    test "is bounded by the camera, not by the processor", %{session: session} do
      # Three frames exist; a fourth call has nothing newer to return and must
      # time out rather than re-serve the third. This is exactly the loop an
      # MJPEG HTTP route runs, and the reason it doesn't spin.
      for _ <- 1..3, do: :ok = Synthetic.capture_frame(SingleCamera, :eye)

      assert {:ok, _} = Media.next(session, 1_000)
      assert {:error, %Timeout{}} = Media.next(session, 50)
    end
  end

  describe "termination" do
    setup do
      start_supervised!(GatedCamera)
      :ok = TestDriver.report_to(GatedCamera, :eye)
      {:ok, session} = Media.open(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      %{session: session}
    end

    test "a capture that ends is reported, not waited on", %{session: session} do
      :ok = TestDriver.confirm_stop(GatedCamera, :eye)

      assert {:error, %EndOfCapture{}} = Media.next(session, 1_000)
    end

    test "a capture that fails surfaces the driver's error", %{session: session} do
      error = CaptureFailed.exception(camera: :eye, reason: :device_vanished)
      :ok = TestDriver.fail(GatedCamera, :eye, error)

      assert {:error, ^error} = Media.next(session, 1_000)
    end

    test "a camera that dies is an error, not a hang", %{session: session} do
      stop_supervised!(GatedCamera)

      assert {:error, %NotRunning{}} = Media.next(session, 1_000)
    end
  end

  describe "a robot shut down while a consumer is mid-stream" do
    setup do
      start_supervised!(SingleCamera)
      :ok
    end

    test "reports to the consumer rather than taking it down with the camera" do
      parent = self()

      # Deliberately unlinked: a consumer is connected to a camera by monitors
      # in both directions and never by a link, so a camera coming down must
      # arrive as a return value rather than as an exit signal. Anything that
      # linked them would make a routine robot shutdown kill every browser
      # connection's process on the way past.
      {consumer, monitor} =
        spawn_monitor(fn ->
          {:ok, session} = Media.open(SingleCamera, :eye)
          send(parent, :streaming)
          send(parent, {:result, Media.next(session, 5_000)})
        end)

      assert_receive :streaming

      stop_supervised!(SingleCamera)

      assert_receive {:result, {:error, %NotRunning{}}}
      assert_receive {:DOWN, ^monitor, :process, ^consumer, :normal}
    end

    test "closing a session whose camera is already gone succeeds quietly" do
      {:ok, session} = Media.open(SingleCamera, :eye)
      stop_supervised!(SingleCamera)

      # A transport closes its session in an `after` block, over a response it
      # has usually already written. A close that raised because the camera
      # went away first would turn a stream that worked into a 500 - so this
      # has to be the quietest operation in the package.
      assert :ok = Media.close(session)
      assert :ok = Media.close(session)
    end

    test "a consumer that had already asked for a frame is told, not left waiting" do
      parent = self()

      {_consumer, monitor} =
        spawn_monitor(fn ->
          {:ok, subscription} = BB.Camera.subscribe(SingleCamera, :eye)
          :ok = BB.Camera.request(subscription)
          send(parent, :waiting)

          receive do
            {:DOWN, ref, :process, _pid, _reason} when ref == subscription.monitor ->
              send(parent, :camera_down)
          after
            5_000 -> send(parent, :gave_up)
          end
        end)

      assert_receive :waiting

      stop_supervised!(SingleCamera)

      assert_receive :camera_down
      assert_receive {:DOWN, ^monitor, :process, _, :normal}
    end
  end

  describe "open/3 against a camera that isn't running" do
    test "reports the camera as declared but not running" do
      assert {:error, %NotRunning{}} = Media.open(SingleCamera, :eye)
    end

    test "reports an unknown camera differently from an offline one" do
      assert {:error, error} = Media.open(SingleCamera, :no_such_camera)
      assert error.__struct__ == BB.Error.Invalid.Camera.UnknownCamera
    end
  end

  describe "sharing" do
    setup do
      start_supervised!(SingleCamera)
      :ok
    end

    test "two sessions share one capture and each gets every frame it asks for" do
      {:ok, first} = Media.open(SingleCamera, :eye)
      {:ok, second} = Media.open(SingleCamera, :eye)

      :ok = Synthetic.capture_frame(SingleCamera, :eye)

      assert {:ok, a} = Media.next(first, 1_000)
      assert {:ok, b} = Media.next(second, 1_000)
      assert a.sequence == b.sequence

      Media.close(first)
      Media.close(second)
    end

    test "capture continues while any session remains" do
      {:ok, first} = Media.open(SingleCamera, :eye)
      {:ok, second} = Media.open(SingleCamera, :eye)

      Media.close(first)

      :ok = Synthetic.capture_frame(SingleCamera, :eye)
      assert {:ok, %Frame{}} = Media.next(second, 1_000)

      Media.close(second)
    end

    test "capture stops when the last session closes" do
      BB.subscribe(SingleCamera, [:sensor, :head, :eye])

      {:ok, session} = Media.open(SingleCamera, :eye)
      assert_receive {:bb, _, %BB.Message{payload: %BeginCapture{}}}
      assert [%{status: :capturing}] = BB.Camera.discover(SingleCamera)

      Media.close(session)
      assert_receive {:bb, _, %BB.Message{payload: %EndCapture{reason: :no_subscribers}}}

      assert [%{status: :running}] = BB.Camera.discover(SingleCamera)
    end
  end
end
