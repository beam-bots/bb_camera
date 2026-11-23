# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.FormatTest do
  use ExUnit.Case, async: true

  alias BB.Camera.{Format, Frame, StreamInfo}
  alias BB.Error.Invalid.Camera.{FrameSizeMismatch, UnsupportedFormat}

  describe "what it carries" do
    test "raw frames decode independently" do
      assert Format.independent_frames?({:raw, :I420})
    end

    test "a raw frame's size follows from its pixel format and dimensions" do
      assert {:ok, 460_800} = Format.frame_size({:raw, :I420}, 640, 480)
      assert {:ok, 614_400} = Format.frame_size({:raw, :YUY2}, 640, 480)
      assert {:ok, 921_600} = Format.frame_size({:raw, :RGB}, 640, 480)
    end
  end

  describe "what it refuses" do
    for codec <- [:jpeg, :h264, :h265, :vp9, :av1] do
      test "#{codec} is refused as encoded" do
        assert {:error, %UnsupportedFormat{reason: :encoded}} =
                 Format.frame_size(unquote(codec), 640, 480)

        refute Format.independent_frames?(unquote(codec))
      end
    end

    test "a pixel format Membrane doesn't name" do
      assert {:error, %UnsupportedFormat{reason: :unknown_pixel_format}} =
               Format.frame_size({:raw, :rgb8}, 640, 480)
    end

    test "dimensions the pixel format can't take" do
      assert {:error, %UnsupportedFormat{reason: :invalid_dimensions, width: 641, height: 480}} =
               Format.frame_size({:raw, :I420}, 641, 480)
    end
  end

  describe "assertions by a consumer" do
    test "no assertion accepts anything" do
      assert :ok = Format.assert({:raw, :I420}, nil)
    end

    test "a matching assertion passes" do
      assert :ok = Format.assert({:raw, :I420}, {:raw, :I420})
    end

    test "a mismatch is reported as a mismatch, not as an unsupported format" do
      assert {:error, error} = Format.assert({:raw, :I420}, {:raw, :NV12})
      assert error.reason == :mismatch
      assert error.format == {:raw, :I420}
      assert error.expected == {:raw, :NV12}
    end
  end

  describe "StreamInfo" do
    test "refuses an encoded format at construction" do
      assert {:error, %{reason: :encoded}} =
               StreamInfo.new(format: :h264, width: 1920, height: 1080)
    end

    test "builds for a format it carries" do
      assert {:ok, info} = StreamInfo.new(format: {:raw, :I420}, width: 640, height: 480)
      assert info.frame_rate == nil
      assert info.metadata == %{}
    end

    test "raises from new!/1 rather than returning something unusable" do
      assert_raise UnsupportedFormat, fn ->
        StreamInfo.new!(format: :jpeg, width: 640, height: 480)
      end
    end
  end

  describe "Frame" do
    test "builds when the data is exactly one frame" do
      data = :binary.copy(<<0>>, 12)
      assert {:ok, %Frame{}} = Frame.new(format: {:raw, :I420}, width: 4, height: 2, data: data)
    end

    test "refuses data of the wrong size rather than misreading every pixel" do
      assert {:error, %FrameSizeMismatch{expected: 12, actual: 11}} =
               Frame.new(
                 format: {:raw, :I420},
                 width: 4,
                 height: 2,
                 data: :binary.copy(<<0>>, 11)
               )
    end
  end
end
