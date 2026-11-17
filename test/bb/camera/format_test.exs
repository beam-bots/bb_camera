# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.FormatTest do
  use ExUnit.Case, async: true

  alias BB.Camera.{Format, StreamInfo}

  describe "what it carries" do
    test "jpeg frames decode independently" do
      assert Format.independent_frames?(:jpeg)
      assert {:ok, :jpeg} = Format.validate(:jpeg)
    end
  end

  describe "what it refuses" do
    for codec <- [:h264, :h265, :hevc, :vp8, :vp9, :av1, :mpeg4, :theora] do
      test "#{codec} is refused as interframe, not carried and dropped" do
        assert {:error, error} = Format.validate(unquote(codec))
        assert error.reason == :interframe
        refute Format.independent_frames?(unquote(codec))
      end
    end

    test "a format that could be carried but isn't yet is distinguished from one that can't" do
      assert {:error, %{reason: :not_implemented}} = Format.validate({:raw, :rgb8})
      assert {:error, %{reason: :interframe}} = Format.validate(:h264)
    end

    test "an unrecognised format is refused rather than assumed safe" do
      assert {:error, %{reason: :not_implemented}} = Format.validate(:something_new)
    end
  end

  describe "assertions by a consumer" do
    test "no assertion accepts anything" do
      assert :ok = Format.assert(:jpeg, nil)
    end

    test "a matching assertion passes" do
      assert :ok = Format.assert(:jpeg, :jpeg)
    end

    test "a mismatch is reported as a mismatch, not as an unsupported format" do
      assert {:error, error} = Format.assert(:jpeg, :h264)
      assert error.reason == :mismatch
      assert error.format == :jpeg
      assert error.expected == :h264
    end
  end

  describe "StreamInfo" do
    test "refuses an interframe format at construction" do
      assert {:error, %{reason: :interframe}} =
               StreamInfo.new(format: :h264, width: 1920, height: 1080)
    end

    test "builds for a format it carries" do
      assert {:ok, info} = StreamInfo.new(format: :jpeg, width: 640, height: 480)
      assert info.frame_rate == nil
      assert info.metadata == %{}
    end

    test "raises from new!/1 rather than returning something unusable" do
      assert_raise BB.Error.Invalid.Camera.UnsupportedFormat, fn ->
        StreamInfo.new!(format: :vp9, width: 640, height: 480)
      end
    end
  end
end
