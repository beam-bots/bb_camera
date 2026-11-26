# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.DiscoveryTest do
  use ExUnit.Case, async: false

  alias BB.Camera
  alias BB.Camera.TestBots.{MixedTopology, SingleCamera}

  describe "discover/2 on a robot that isn't running" do
    test "finds cameras at every attachment point" do
      cameras = Camera.discover(MixedTopology)

      assert Enum.map(cameras, & &1.name) |> Enum.sort() == [:eye, :neck_cam, :overhead]
    end

    test "ignores sensors that aren't cameras" do
      refute MixedTopology |> Camera.discover() |> Enum.any?(&(&1.name == :thermometer))
    end

    test "reports the topology path and pubsub topic of each camera" do
      cameras = Map.new(Camera.discover(MixedTopology), &{&1.name, &1})

      assert cameras[:overhead].path == [:overhead]
      assert cameras[:overhead].topic == [:sensor, :overhead]
      assert cameras[:overhead].attached_to == :robot

      assert cameras[:neck_cam].path == [:base, :neck, :neck_cam]
      assert cameras[:neck_cam].attached_to == {:joint, :neck}

      assert cameras[:eye].path == [:base, :neck, :head, :eye]
      assert cameras[:eye].topic == [:sensor, :base, :neck, :head, :eye]
      assert cameras[:eye].attached_to == {:link, :head}
    end

    test "an offline camera is reported as declared, not omitted" do
      assert [camera] = Camera.discover(SingleCamera)
      assert camera.status == :declared
      assert camera.pid == nil
    end

    test "a declared camera still reports the format it asked for" do
      cameras = Map.new(Camera.discover(MixedTopology), &{&1.name, &1})

      assert cameras[:eye].stream_info.width == 640
      assert cameras[:eye].stream_info.height == 480
      assert cameras[:eye].stream_info.format == {:raw, :I420}
    end

    test "carries no driver options, so device paths can't leak into a UI" do
      [camera] = Camera.discover(SingleCamera)

      refute :options in Map.keys(Map.from_struct(camera))
      refute :child_spec in Map.keys(Map.from_struct(camera))
    end
  end

  describe "discover/2 on a running robot" do
    setup do
      start_supervised!(SingleCamera)
      :ok
    end

    test "reports the live hub" do
      assert [camera] = Camera.discover(SingleCamera)
      assert camera.status == :running
      assert is_pid(camera.pid)
    end

    test "filters by status" do
      assert [] = Camera.discover(SingleCamera, status: :declared)
      assert [_] = Camera.discover(SingleCamera, status: :running)
    end

    test "reports :capturing once a consumer has arrived and the driver confirmed" do
      BB.subscribe(SingleCamera, [:sensor, :head, :eye])

      {:ok, subscription} = Camera.subscribe(SingleCamera, :eye)
      assert_receive {:bb, _, %BB.Message{payload: %BB.Message.Camera.BeginCapture{}}}

      assert [%{status: :capturing}] = Camera.discover(SingleCamera)
      Camera.unsubscribe(subscription)
    end
  end

  describe "stream_info/2" do
    test "reports the declared format for a stopped camera" do
      assert {:ok, info} = Camera.stream_info(SingleCamera, :eye)
      assert info.format == {:raw, :I420}
    end

    test "names the cameras it does know about when asked for one it doesn't" do
      assert {:error, error} = Camera.stream_info(SingleCamera, :nonexistent)
      assert error.known == [:eye]
    end
  end
end
