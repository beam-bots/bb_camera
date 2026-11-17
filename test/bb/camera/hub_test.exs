# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.HubTest do
  use ExUnit.Case, async: false

  alias BB.Camera
  alias BB.Camera.{Frame, Hub, Settings, StreamInfo, TestDriver}
  alias BB.Camera.TestBots.GatedCamera
  alias BB.Error.Hardware.Camera.CaptureFailed
  alias BB.Message.Camera.{ApplySettings, BeginCapture, EndCapture, RejectSettings}

  setup do
    start_supervised!(GatedCamera)
    :ok = TestDriver.report_to(GatedCamera, :eye)
    :ok
  end

  describe "reaching the driver" do
    test "the hub's capture requests arrive at the sensor process, not at itself" do
      {:ok, _subscription} = Camera.subscribe(GatedCamera, :eye)

      assert_receive {:driver, :start_capture}
    end
  end

  describe "capture lifecycle" do
    test "capture isn't claimed until the driver confirms it" do
      {:ok, _subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}

      assert [%{status: :running}] = Camera.discover(GatedCamera)

      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert [%{status: :capturing}] = Camera.discover(GatedCamera)
    end

    test "BeginCapture is published on confirmation, not on subscription" do
      BB.subscribe(GatedCamera, [:sensor, :head, :eye])

      {:ok, _subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      refute_received {:bb, _, %BB.Message{payload: %BeginCapture{}}}

      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert_receive {:bb, _, %BB.Message{payload: %BeginCapture{subscriber_count: 1}}}
    end

    test "a failed start tells every subscriber and publishes EndCapture" do
      BB.subscribe(GatedCamera, [:sensor, :head, :eye])
      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      ref = subscription.ref
      assert_receive {:driver, :start_capture}

      error = CaptureFailed.exception(camera: :eye, reason: :no_such_device)
      :ok = TestDriver.fail(GatedCamera, :eye, error)

      assert_receive {:bb_camera, ^ref, {:capture_failed, ^error}}
      assert_receive {:bb, _, %BB.Message{payload: %EndCapture{reason: :error}}}
    end

    test "a failed capture is not retried while subscribers remain" do
      {:ok, _subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}

      :ok = TestDriver.fail(GatedCamera, :eye, CaptureFailed.exception(camera: :eye))

      # Push a call through the driver so anything it was going to be sent has
      # already arrived, then check nothing was.
      :ok = TestDriver.report_to(GatedCamera, :eye)
      refute_received {:driver, :start_capture}
    end

    test "capture stops when the last subscriber goes" do
      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      :ok = Camera.unsubscribe(subscription)
      assert_receive {:driver, :stop_capture}
    end

    test "a consumer arriving mid-stop is not told the capture ended" do
      {:ok, first} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      :ok = Camera.unsubscribe(first)
      assert_receive {:driver, :stop_capture}

      # The stop is still in flight. A new consumer arrives inside that window.
      {:ok, second} = Camera.subscribe(GatedCamera, :eye)
      second_ref = second.ref

      :ok = TestDriver.confirm_stop(GatedCamera, :eye)

      refute_receive {:bb_camera, ^second_ref, :end_of_capture}, 50
      assert_receive {:driver, :start_capture}
    end

    test "a start confirmed after the stop was asked for doesn't enrol a new consumer" do
      {:ok, first} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}

      # The driver hasn't answered yet. The last consumer leaves, so a stop is
      # asked for, and a new consumer turns up before either is confirmed.
      :ok = Camera.unsubscribe(first)
      assert_receive {:driver, :stop_capture}

      {:ok, second} = Camera.subscribe(GatedCamera, :eye)
      second_ref = second.ref

      # Only now does the driver confirm the start, followed by the stop.
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      :ok = TestDriver.confirm_stop(GatedCamera, :eye)

      refute_received {:bb_camera, ^second_ref, :end_of_capture}
      assert_receive {:driver, :start_capture}
    end

    test "capture restarts for a consumer that arrived mid-stop" do
      {:ok, first} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      :ok = Camera.unsubscribe(first)
      assert_receive {:driver, :stop_capture}

      {:ok, second} = Camera.subscribe(GatedCamera, :eye)
      :ok = TestDriver.confirm_stop(GatedCamera, :eye)

      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      :ok = Camera.request(second)
      :ok = TestDriver.deliver(GatedCamera, :eye, "after-restart")

      ref = second.ref
      assert_receive {:bb_camera, ^ref, %Frame{data: "after-restart"}}
    end

    test "a restarted capture isn't withheld by what a consumer saw last time" do
      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      ref = subscription.ref
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      # Run the sequence well up in the first session.
      for n <- 1..5 do
        :ok = Camera.request(subscription)
        :ok = TestDriver.deliver(GatedCamera, :eye, "session-one-#{n}")
        assert_receive {:bb_camera, ^ref, %Frame{}}
      end

      # A fresh session starts its sequence at zero again.
      :ok = TestDriver.confirm_stop(GatedCamera, :eye)
      assert_receive {:bb_camera, ^ref, :end_of_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      :ok = Camera.request(subscription)
      :ok = TestDriver.deliver(GatedCamera, :eye, "session-two")

      assert_receive {:bb_camera, ^ref, %Frame{data: "session-two", sequence: 0}}
    end
  end

  describe "demand" do
    setup do
      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      %{subscription: subscription, ref: subscription.ref}
    end

    test "nothing arrives without a request", %{ref: ref} do
      :ok = TestDriver.deliver(GatedCamera, :eye, "unasked-for")

      refute_received {:bb_camera, ^ref, %Frame{}}
    end

    test "a request pending before a frame is served when one arrives", %{
      subscription: subscription,
      ref: ref
    } do
      :ok = Camera.request(subscription)
      :ok = TestDriver.deliver(GatedCamera, :eye, "first")

      assert_receive {:bb_camera, ^ref, %Frame{data: "first"}}
    end

    test "a request after a frame is served immediately", %{
      subscription: subscription,
      ref: ref
    } do
      :ok = TestDriver.deliver(GatedCamera, :eye, "already-here")
      :ok = Camera.request(subscription)

      assert_receive {:bb_camera, ^ref, %Frame{data: "already-here"}}
    end

    test "a second request never re-delivers a frame already given", %{
      subscription: subscription,
      ref: ref
    } do
      :ok = Camera.request(subscription)
      :ok = TestDriver.deliver(GatedCamera, :eye, "only-once")
      assert_receive {:bb_camera, ^ref, %Frame{data: "only-once"}}

      :ok = Camera.request(subscription)

      # The request is in the hub - a synchronous call proves it has been
      # processed - and there is nothing newer for it to be answered with.
      refute_received {:bb_camera, ^ref, %Frame{}}
    end

    test "a waiting request is answered by the next new frame, not the old one", %{
      subscription: subscription,
      ref: ref
    } do
      :ok = Camera.request(subscription)
      :ok = TestDriver.deliver(GatedCamera, :eye, "one")
      assert_receive {:bb_camera, ^ref, %Frame{data: "one"}}

      :ok = Camera.request(subscription)
      refute_received {:bb_camera, ^ref, %Frame{}}

      :ok = TestDriver.deliver(GatedCamera, :eye, "two")
      assert_receive {:bb_camera, ^ref, %Frame{data: "two"}}
    end

    test "only the latest frame survives; the ones in between are dropped", %{
      subscription: subscription,
      ref: ref
    } do
      :ok = TestDriver.deliver(GatedCamera, :eye, "stale-one")
      :ok = TestDriver.deliver(GatedCamera, :eye, "stale-two")
      :ok = TestDriver.deliver(GatedCamera, :eye, "current")

      :ok = Camera.request(subscription)

      assert_receive {:bb_camera, ^ref, %Frame{data: "current"}}
      refute_received {:bb_camera, ^ref, %Frame{}}
    end

    test "a cancelled request is not answered by a later frame", %{
      subscription: subscription,
      ref: ref
    } do
      :ok = Camera.request(subscription)
      :ok = Camera.cancel_request(subscription)
      :ok = TestDriver.deliver(GatedCamera, :eye, "too-late")

      refute_received {:bb_camera, ^ref, %Frame{}}
    end

    test "consumers share one capture and each sees every frame it asks for" do
      {:ok, other} = Camera.subscribe(GatedCamera, :eye)
      other_ref = other.ref

      :ok = Camera.request(other)
      :ok = TestDriver.deliver(GatedCamera, :eye, "shared")

      assert_receive {:bb_camera, ^other_ref, %Frame{data: "shared"}}
      refute_received {:driver, :start_capture}
    end
  end

  describe "stream format changes" do
    setup do
      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      %{subscription: subscription, ref: subscription.ref}
    end

    test "a frame encoded under the old format is not handed out under the new one", %{
      subscription: subscription,
      ref: ref
    } do
      :ok = TestDriver.deliver(GatedCamera, :eye, "old-geometry")

      :ok =
        TestDriver.update_stream_info(
          GatedCamera,
          :eye,
          StreamInfo.new!(format: :jpeg, width: 320, height: 240)
        )

      :ok = Camera.request(subscription)

      refute_received {:bb_camera, ^ref, %Frame{data: "old-geometry"}}
    end

    test "the new format arrives before the first frame it describes", %{
      subscription: subscription,
      ref: ref
    } do
      :ok =
        TestDriver.update_stream_info(
          GatedCamera,
          :eye,
          StreamInfo.new!(format: :jpeg, width: 320, height: 240)
        )

      :ok = Camera.request(subscription)
      :ok = TestDriver.deliver(GatedCamera, :eye, "new-geometry")

      assert_receive {:bb_camera, ^ref, {:stream_info, %StreamInfo{width: 320}}}
      assert_receive {:bb_camera, ^ref, %Frame{data: "new-geometry"}}
    end

    test "an unchanged format is not re-announced", %{
      subscription: subscription,
      ref: ref
    } do
      :ok = Camera.request(subscription)
      :ok = TestDriver.deliver(GatedCamera, :eye, "same-as-before")
      assert_receive {:bb_camera, ^ref, %Frame{}}

      refute_received {:bb_camera, ^ref, {:stream_info, _}}
    end
  end

  describe "frame validation" do
    setup do
      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      %{subscription: subscription}
    end

    test "a frame whose sequence doesn't advance is refused" do
      frame = Frame.new!(format: :jpeg, width: 64, height: 48, data: "a", sequence: 5)
      assert :ok = TestDriver.deliver_raw(GatedCamera, :eye, frame)

      repeat = Frame.new!(format: :jpeg, width: 64, height: 48, data: "b", sequence: 5)
      assert {:error, error} = TestDriver.deliver_raw(GatedCamera, :eye, repeat)
      assert error.sequence == 5
      assert error.last_sequence == 5
    end

    test "the hub stamps a sequence the driver left out" do
      frame = Frame.new!(format: :jpeg, width: 64, height: 48, data: "a")
      assert frame.sequence == nil
      assert :ok = TestDriver.deliver_raw(GatedCamera, :eye, frame)
    end
  end

  test "a frame delivered before capture is confirmed is refused" do
    {:ok, _subscription} = Camera.subscribe(GatedCamera, :eye)
    assert_receive {:driver, :start_capture}

    assert {:error, %{__struct__: BB.Error.State.Camera.NotCapturing}} =
             TestDriver.deliver(GatedCamera, :eye, "too-early")
  end

  describe "settings" do
    setup do
      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      %{subscription: subscription}
    end

    test "changing one setting doesn't reset the others to their schema defaults" do
      task =
        Task.async(fn -> Camera.put_settings(GatedCamera, :eye, %{brightness: 90}) end)

      assert_receive {:driver, {:put_settings, settings}}

      assert settings == %{brightness: 90, contrast: 10}

      :ok = TestDriver.settings_result(GatedCamera, :eye, {:ok, Settings.new(settings)})
      assert {:ok, applied} = Task.await(task)
      assert Settings.get(applied, :contrast) == 10
    end

    test "an applied change is published with just what moved" do
      BB.subscribe(GatedCamera, [:sensor, :head, :eye])

      task = Task.async(fn -> Camera.put_settings(GatedCamera, :eye, %{brightness: 90}) end)
      assert_receive {:driver, {:put_settings, settings}}
      :ok = TestDriver.settings_result(GatedCamera, :eye, {:ok, Settings.new(settings)})
      {:ok, _} = Task.await(task)

      assert_receive {:bb, _, %BB.Message{payload: %ApplySettings{changed: changed}}}
      assert changed == %{brightness: 90}
    end

    test "settings outside the driver's schema never reach the driver" do
      BB.subscribe(GatedCamera, [:sensor, :head, :eye])

      assert {:error, error} = Camera.put_settings(GatedCamera, :eye, %{nonsense: true})
      assert error.camera == :eye

      refute_received {:driver, {:put_settings, _}}
      assert_receive {:bb, _, %BB.Message{payload: %RejectSettings{}}}
    end

    test "a driver that never answers doesn't leave the request pending forever" do
      assert {:error, error} = Camera.put_settings(GatedCamera, :eye, %{brightness: 90}, 100)
      assert error.camera == :eye

      # The abandoned request is gone: answering it now changes nothing, and a
      # fresh request still works.
      :ok = TestDriver.settings_result(GatedCamera, :eye, {:ok, Settings.new(%{brightness: 90})})

      task = Task.async(fn -> Camera.put_settings(GatedCamera, :eye, %{contrast: 20}) end)

      # Match on the new request specifically: the abandoned one was reported
      # too, and is still sitting in this process's mailbox.
      assert_receive {:driver, {:put_settings, %{contrast: 20}}}

      :ok = TestDriver.settings_result(GatedCamera, :eye, {:ok, Settings.new(%{contrast: 20})})
      assert {:ok, _} = Task.await(task)
    end
  end

  describe "driver-initiated settings" do
    setup do
      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      %{subscription: subscription}
    end

    test "a driver can report a value nobody asked it to change" do
      BB.subscribe(GatedCamera, [:sensor, :head, :eye])

      :ok = TestDriver.update_settings(GatedCamera, :eye, Settings.new(%{brightness: 75}))

      assert_receive {:bb, _, %BB.Message{payload: %ApplySettings{changed: %{brightness: 75}}}}
      assert {:ok, settings} = Camera.settings(GatedCamera, :eye)
      assert Settings.get(settings, :brightness) == 75
    end

    test "a measurement alone is recorded without announcing a change" do
      BB.subscribe(GatedCamera, [:sensor, :head, :eye])

      measured = Settings.measure(Settings.new(%{}), :frame_rate, 28.7)
      :ok = TestDriver.update_settings(GatedCamera, :eye, measured)

      assert {:ok, settings} = Camera.settings(GatedCamera, :eye)
      assert settings.measured.frame_rate == 28.7

      # The settings didn't change, so nothing was published. The synchronous
      # read above has already been through the hub, so there is nothing still
      # in flight to wait for.
      refute_received {:bb, _, %BB.Message{payload: %ApplySettings{}}}
    end
  end

  describe "what reaches PubSub" do
    test "no frame bytes are ever published, on any topic" do
      BB.subscribe(GatedCamera, [])

      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      :ok = Camera.request(subscription)
      :ok = TestDriver.deliver(GatedCamera, :eye, "sentinel-frame-bytes")

      ref = subscription.ref
      assert_receive {:bb_camera, ^ref, %Frame{data: "sentinel-frame-bytes"}}

      refute Enum.any?(drain_pubsub(), fn message ->
               message |> :erlang.term_to_binary() |> String.contains?("sentinel-frame-bytes")
             end)
    end

    defp drain_pubsub(acc \\ []) do
      receive do
        {:bb, _topic, %BB.Message{} = message} -> drain_pubsub([message | acc])
      after
        0 -> acc
      end
    end
  end

  describe "consumer death" do
    test "a dead consumer releases the capture" do
      {:ok, _keeper} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      task =
        Task.async(fn ->
          {:ok, _} = Camera.subscribe(GatedCamera, :eye)
          :subscribed
        end)

      assert :subscribed = Task.await(task)

      hub = BB.Process.whereis(GatedCamera, {:camera, :eye})
      assert Hub.capture_state(hub) == :capturing
    end

    test "capture stops when the last consumer dies rather than unsubscribes" do
      task =
        Task.async(fn ->
          {:ok, _} = Camera.subscribe(GatedCamera, :eye)
          :subscribed
        end)

      assert :subscribed = Task.await(task)
      assert_receive {:driver, :start_capture}
      assert_receive {:driver, :stop_capture}
    end
  end
end
