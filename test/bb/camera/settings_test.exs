# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.SettingsTest do
  use ExUnit.Case, async: true

  alias BB.Camera.Settings

  describe "provenance" do
    test "values start out as requested, the weakest claim" do
      settings = Settings.new(%{width: 640, frame_rate: 30.0})

      refute Settings.actual?(settings, :width)
      refute Settings.actual?(settings, :frame_rate)
    end

    test "a verified value says so" do
      settings =
        %{width: 640}
        |> Settings.new()
        |> Settings.put(:width, 320, :actual)

      assert Settings.actual?(settings, :width)
      assert Settings.get(settings, :width) == 320
    end

    test "a measurement is not a claim about the setting" do
      settings =
        %{frame_rate: 30.0}
        |> Settings.new()
        |> Settings.put(:frame_rate, 30.0, :requested)
        |> Settings.measure(:frame_rate, 28.7)

      refute Settings.actual?(settings, :frame_rate)
      assert Settings.get(settings, :frame_rate) == 30.0
      assert settings.measured.frame_rate == 28.7
    end

    test "the worked case from a real driver: dimensions known, rate only asked for" do
      settings =
        %{width: 640, height: 480, pixel_format: :jpeg, frame_rate: 30.0}
        |> Settings.new()
        |> Settings.put(:width, 640, :actual)
        |> Settings.put(:height, 480, :actual)
        |> Settings.put(:pixel_format, :jpeg, :actual)
        |> Settings.put(:frame_rate, 30.0, :requested)
        |> Settings.measure(:frame_rate, 28.7)

      assert Settings.actual?(settings, :width)
      assert Settings.actual?(settings, :height)
      refute Settings.actual?(settings, :frame_rate)
    end
  end

  describe "changed/2" do
    test "reports only what moved" do
      before = Settings.new(%{brightness: 50, contrast: 10})
      aftr = Settings.new(%{brightness: 90, contrast: 10})

      assert Settings.changed(before, aftr) == %{brightness: 90}
    end

    test "a new key counts as a change" do
      assert Settings.changed(Settings.new(%{}), Settings.new(%{gain: 2})) == %{gain: 2}
    end
  end

  describe "merge/2" do
    test "the incoming provenance comes with the incoming value" do
      base = Settings.new(%{width: 640})
      update = Settings.put(Settings.new(%{}), :width, 320, :actual)

      merged = Settings.merge(base, update)

      assert Settings.get(merged, :width) == 320
      assert Settings.actual?(merged, :width)
    end
  end
end
