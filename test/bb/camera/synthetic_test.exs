# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.SyntheticTest do
  use ExUnit.Case, async: false

  alias BB.Camera
  alias BB.Camera.{Frame, Media, Synthetic}
  alias BB.Camera.TestBots.{FailingCamera, FreeRunningCamera, MixedTopology, SingleCamera}
  alias BB.Message.Camera.{BeginCapture, EndCapture}

  describe "default frames" do
    test "are whole I420 frames at the size asked for" do
      for frame <- Synthetic.default_frames(640, 480) do
        assert {:ok, %Frame{}} =
                 Frame.new(format: {:raw, :I420}, width: 640, height: 480, data: frame)
      end
    end

    test "differ from each other, so a test can tell one from the next" do
      frames = Synthetic.default_frames(160, 120)
      assert length(Enum.uniq(frames)) == length(frames)
    end
  end

  describe "externally clocked" do
    setup do
      start_supervised!(SingleCamera)
      {:ok, session} = Media.open(SingleCamera, :eye)
      on_exit(fn -> Media.close(session) end)
      %{session: session}
    end

    test "produces a frame per call and no others", %{session: session} do
      :ok = Synthetic.capture_frame(SingleCamera, :eye)
      assert {:ok, %Frame{sequence: 0}} = Media.next(session, 1_000)

      :ok = Synthetic.capture_frame(SingleCamera, :eye)
      assert {:ok, %Frame{sequence: 1}} = Media.next(session, 1_000)
    end

    test "cycles its frames, so successive frames are byte-distinguishable", %{session: session} do
      frames =
        for _ <- 1..4 do
          :ok = Synthetic.capture_frame(SingleCamera, :eye)
          {:ok, frame} = Media.next(session, 1_000)
          frame.data
        end

      assert frames == Synthetic.default_frames(160, 120)
    end

    test "stamps capture timestamps on every frame", %{session: session} do
      :ok = Synthetic.capture_frame(SingleCamera, :eye)
      assert {:ok, frame} = Media.next(session, 1_000)

      assert is_integer(frame.monotonic_time)
      assert is_integer(frame.wall_time)
      assert frame.wall_time > 0
    end
  end

  describe "geometry" do
    setup do
      start_supervised!(MixedTopology)
      :ok
    end

    test "is what it was asked for" do
      BB.subscribe(MixedTopology, [:sensor, :base, :neck, :head, :eye])

      {:ok, session} = Media.open(MixedTopology, :eye)
      assert_receive {:bb, _, %BB.Message{payload: %BeginCapture{stream_info: info}}}

      assert info.width == 640
      assert info.height == 480

      :ok = Synthetic.capture_frame(MixedTopology, :eye)
      assert {:ok, %Frame{width: 640, height: 480}} = Media.next(session, 1_000)

      Media.close(session)
    end

    test "must be even, since I420 halves its chroma in both directions" do
      assert {:error, %BB.Error.Invalid.Camera.UnsupportedFormat{reason: :invalid_dimensions}} =
               Synthetic.stream_info(width: 161, height: 120)
    end
  end

  describe "capture failure" do
    setup do
      start_supervised!(FailingCamera)
      :ok
    end

    test "a camera that can't start reports failure rather than silence" do
      BB.subscribe(FailingCamera, [:sensor, :head, :eye])
      {:ok, session} = Media.open(FailingCamera, :eye)

      assert {:error, error} = Media.next(session, 1_000)
      assert error.__struct__ == BB.Error.Hardware.Camera.CaptureFailed

      assert_receive {:bb, _, %BB.Message{payload: %EndCapture{reason: :error}}}
    end

    test "never claims to be capturing" do
      {:ok, _session} = Media.open(FailingCamera, :eye)

      refute Enum.any?(Camera.discover(FailingCamera), &(&1.status == :capturing))
    end
  end

  describe "rate clocked" do
    setup do
      start_supervised!(FreeRunningCamera)
      :ok
    end

    test "produces frames without being asked to" do
      {:ok, session} = Media.open(FreeRunningCamera, :eye)

      assert {:ok, %Frame{}} = Media.next(session, 2_000)
      assert {:ok, %Frame{}} = Media.next(session, 2_000)

      Media.close(session)
    end

    test "declares the frame rate it was configured with" do
      assert {:ok, info} = Camera.stream_info(FreeRunningCamera, :eye)
      assert info.frame_rate == 200.0
    end

    test "stops producing when the last consumer goes" do
      BB.subscribe(FreeRunningCamera, [:sensor, :head, :eye])

      {:ok, session} = Media.open(FreeRunningCamera, :eye)
      assert {:ok, %Frame{}} = Media.next(session, 2_000)

      Media.close(session)
      assert_receive {:bb, _, %BB.Message{payload: %EndCapture{reason: :no_subscribers}}}
    end
  end
end
