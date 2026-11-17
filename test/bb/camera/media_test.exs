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
