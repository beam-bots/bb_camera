# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.HubTest do
  use ExUnit.Case, async: false

  import BB.Unit

  alias BB.Camera
  alias BB.Camera.{Frame, Hub, Media, StreamInfo, TestDriver}
  alias BB.Camera.TestBots.GatedCamera
  alias BB.Error.Hardware.Camera.CaptureFailed
  alias BB.Message.Camera.{BeginCapture, CaptureState, EndCapture}

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

      # `confirm_stop` is a call through the driver into the hub, so when it
      # returns the hub has finished ending the session and sent whatever it
      # was going to send. Checking the mailbox without waiting is therefore
      # conclusive, where a timed `refute_receive` would only be a guess that
      # happened to hold on an idle machine.
      :ok = TestDriver.confirm_stop(GatedCamera, :eye)

      refute_received {:bb_camera, ^second_ref, :end_of_capture}
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
      assert_receive {:bb_camera, ^ref, %Frame{data: "after-restart" <> _}}
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

      assert_receive {:bb_camera, ^ref, %Frame{data: "session-two" <> _, sequence: 0}}
    end
  end

  describe "retrying a failed capture" do
    setup do
      {:ok, hub} = Camera.hub(GatedCamera, :eye)
      %{hub: hub}
    end

    test "waits for the backoff rather than retrying at once", %{hub: hub} do
      {:ok, _subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}

      :ok = TestDriver.fail(GatedCamera, :eye, CaptureFailed.exception(camera: :eye))

      # Push a call through the driver so anything it was going to be sent has
      # already arrived, then check nothing was.
      :ok = TestDriver.report_to(GatedCamera, :eye)
      refute_received {:driver, :start_capture}

      send(hub, :retry_capture)
      assert_receive {:driver, :start_capture}
    end

    test "tells subscribers of every failure, not just the first", %{hub: hub} do
      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      ref = subscription.ref
      assert_receive {:driver, :start_capture}

      first = CaptureFailed.exception(camera: :eye, reason: :first)
      :ok = TestDriver.fail(GatedCamera, :eye, first)
      assert_receive {:bb_camera, ^ref, {:capture_failed, ^first}}

      send(hub, :retry_capture)
      assert_receive {:driver, :start_capture}

      second = CaptureFailed.exception(camera: :eye, reason: :second)
      :ok = TestDriver.fail(GatedCamera, :eye, second)
      assert_receive {:bb_camera, ^ref, {:capture_failed, ^second}}
    end

    test "a consumer arriving during the backoff joins the retry", %{hub: hub} do
      {:ok, _first} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.fail(GatedCamera, :eye, CaptureFailed.exception(camera: :eye))

      {:ok, _second} = Camera.subscribe(GatedCamera, :eye)
      :ok = TestDriver.report_to(GatedCamera, :eye)
      refute_received {:driver, :start_capture}

      send(hub, :retry_capture)
      assert_receive {:driver, :start_capture}

      :ok = TestDriver.report_to(GatedCamera, :eye)
      refute_received {:driver, :start_capture}
    end

    test "a retry that succeeds is a new session like any other", %{hub: hub} do
      BB.subscribe(GatedCamera, [:sensor, :head, :eye])
      {:ok, first} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.fail(GatedCamera, :eye, CaptureFailed.exception(camera: :eye))

      # Arrives during the backoff, and asks for a frame before there is any
      # capture to take one from.
      {:ok, second} = Camera.subscribe(GatedCamera, :eye)
      :ok = Camera.request(second)

      send(hub, :retry_capture)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      assert_receive {:bb, _, %BB.Message{payload: %BeginCapture{subscriber_count: 2}}}

      :ok = Camera.request(first)
      :ok = TestDriver.deliver(GatedCamera, :eye, "after-retry")

      first_ref = first.ref
      second_ref = second.ref
      assert_receive {:bb_camera, ^first_ref, %Frame{data: "after-retry" <> _, sequence: 0}}
      assert_receive {:bb_camera, ^second_ref, %Frame{data: "after-retry" <> _, sequence: 0}}
    end

    test "stops when the last subscriber leaves", %{hub: hub} do
      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.fail(GatedCamera, :eye, CaptureFailed.exception(camera: :eye))

      :ok = Camera.unsubscribe(subscription)
      send(hub, :retry_capture)

      assert Hub.capture_state(hub) == :idle
      :ok = TestDriver.report_to(GatedCamera, :eye)
      refute_received {:driver, :start_capture}

      # With nothing waiting, the next consumer starts capture straight away.
      {:ok, _subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
    end
  end

  describe "the retry backoff" do
    setup do
      {:ok, info} = StreamInfo.new(format: {:raw, :I420}, width: 64, height: 48)
      %{bb: %{robot: GatedCamera, path: [:head, :spare]}, stream_info: info}
    end

    test "retries on a timer of its own", %{bb: bb, stream_info: info} do
      {:ok, hub} =
        Hub.start_link(
          bb: bb,
          stream_info: info,
          publish_rate: :external,
          retry_delay: ~u(0 second)
        )

      {:ok, _ref, _info} = Hub.subscribe(hub, self(), [])
      assert_receive {:bb_camera, :start_capture}

      :ok = Hub.capture_failed(hub, CaptureFailed.exception(camera: :spare))

      assert_receive {:bb_camera, :start_capture}
    end

    test "doubles with each consecutive failure up to its ceiling, and resets on success", %{
      bb: bb,
      stream_info: info
    } do
      # Delays far longer than the test, so a timer's remaining time says
      # which delay it was set for without anything having to wait for it.
      {:ok, hub} =
        Hub.start_link(
          bb: bb,
          stream_info: info,
          publish_rate: :external,
          retry_delay: ~u(1000 second),
          max_retry_delay: ~u(3000 second)
        )

      {:ok, _ref, _info} = Hub.subscribe(hub, self(), [])
      assert_receive {:bb_camera, :start_capture}

      assert fail_and_read_backoff(hub) in 1..1_000_000
      assert fail_and_read_backoff(hub) in 1_000_001..2_000_000
      assert fail_and_read_backoff(hub) in 2_000_001..3_000_000
      assert fail_and_read_backoff(hub) in 2_000_001..3_000_000

      :ok = Hub.capture_started(hub)
      assert fail_and_read_backoff(hub) in 1..1_000_000
    end
  end

  describe "a consumer that arrives while a stop is in flight" do
    test "is not served a frame from the session it never joined" do
      {:ok, first} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      :ok = Camera.unsubscribe(first)
      assert_receive {:driver, :stop_capture}

      # Inside the stop window: a new consumer arrives and asks for a frame,
      # and the old session produces one more.
      {:ok, second} = Camera.subscribe(GatedCamera, :eye)
      second_ref = second.ref
      :ok = Camera.request(second)
      :ok = TestDriver.deliver(GatedCamera, :eye, "belongs-to-the-old-session")

      # `deliver` is a call through the driver into the hub, so the hub has
      # finished with that frame by now. It isn't this consumer's to have.
      refute_received {:bb_camera, ^second_ref, %Frame{}}
    end

    test "keeps its request across the restart instead of waiting out a timeout" do
      {:ok, first} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      :ok = Camera.unsubscribe(first)
      assert_receive {:driver, :stop_capture}

      {:ok, second} = Camera.subscribe(GatedCamera, :eye)
      second_ref = second.ref
      :ok = Camera.request(second)
      :ok = TestDriver.deliver(GatedCamera, :eye, "belongs-to-the-old-session")

      :ok = TestDriver.confirm_stop(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      # The request was made before the restart and never answered, so it is
      # still outstanding. Clearing it along with the ended session's requests
      # would be invisible to the consumer, which would sit through its whole
      # timeout on a camera that had come back perfectly well.
      :ok = TestDriver.deliver(GatedCamera, :eye, "belongs-to-the-new-session")

      assert_receive {:bb_camera, ^second_ref, %Frame{data: "belongs-to-the-new-session" <> _}}
    end

    test "a media session reads the first frame of the new capture without re-asking" do
      {:ok, keeper} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      :ok = Camera.unsubscribe(keeper)
      assert_receive {:driver, :stop_capture}

      parent = self()

      # The session has to be opened by the process that will read from it -
      # frames go to the subscription's owner - so the reader opens it and
      # says when it is in, which is inside the stop window.
      reader =
        Task.async(fn ->
          {:ok, session} = Media.open(GatedCamera, :eye)
          send(parent, :opened)
          Media.next(session, 5_000)
        end)

      assert_receive :opened

      :ok = TestDriver.confirm_stop(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      :ok = TestDriver.deliver(GatedCamera, :eye, "first-of-the-new-session")

      assert {:ok, %Frame{data: "first-of-the-new-session" <> _}} = Task.await(reader)
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

      assert_receive {:bb_camera, ^ref, %Frame{data: "first" <> _}}
    end

    test "a request after a frame is served immediately", %{
      subscription: subscription,
      ref: ref
    } do
      :ok = TestDriver.deliver(GatedCamera, :eye, "already-here")
      :ok = Camera.request(subscription)

      assert_receive {:bb_camera, ^ref, %Frame{data: "already-here" <> _}}
    end

    test "a second request never re-delivers a frame already given", %{
      subscription: subscription,
      ref: ref
    } do
      :ok = Camera.request(subscription)
      :ok = TestDriver.deliver(GatedCamera, :eye, "only-once")
      assert_receive {:bb_camera, ^ref, %Frame{data: "only-once" <> _}}

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
      assert_receive {:bb_camera, ^ref, %Frame{data: "one" <> _}}

      :ok = Camera.request(subscription)
      refute_received {:bb_camera, ^ref, %Frame{}}

      :ok = TestDriver.deliver(GatedCamera, :eye, "two")
      assert_receive {:bb_camera, ^ref, %Frame{data: "two" <> _}}
    end

    test "only the latest frame survives; the ones in between are dropped", %{
      subscription: subscription,
      ref: ref
    } do
      :ok = TestDriver.deliver(GatedCamera, :eye, "stale-one")
      :ok = TestDriver.deliver(GatedCamera, :eye, "stale-two")
      :ok = TestDriver.deliver(GatedCamera, :eye, "current")

      :ok = Camera.request(subscription)

      assert_receive {:bb_camera, ^ref, %Frame{data: "current" <> _}}
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

      assert_receive {:bb_camera, ^other_ref, %Frame{data: "shared" <> _}}
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
          StreamInfo.new!(format: {:raw, :I420}, width: 320, height: 240)
        )

      :ok = Camera.request(subscription)

      refute_received {:bb_camera, ^ref, %Frame{data: "old-geometry" <> _}}
    end

    test "the new format arrives before the first frame it describes", %{
      subscription: subscription,
      ref: ref
    } do
      :ok =
        TestDriver.update_stream_info(
          GatedCamera,
          :eye,
          StreamInfo.new!(format: {:raw, :I420}, width: 320, height: 240)
        )

      :ok = Camera.request(subscription)
      :ok = TestDriver.deliver(GatedCamera, :eye, "new-geometry")

      assert_receive {:bb_camera, ^ref, {:stream_info, %StreamInfo{width: 320}}}
      assert_receive {:bb_camera, ^ref, %Frame{data: "new-geometry" <> _}}
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
      frame = test_frame("a", sequence: 5)
      assert :ok = TestDriver.deliver_frame(GatedCamera, :eye, frame)

      repeat = test_frame("b", sequence: 5)
      assert {:error, error} = TestDriver.deliver_frame(GatedCamera, :eye, repeat)
      assert error.sequence == 5
      assert error.last_sequence == 5
    end

    test "the hub stamps a sequence the driver left out" do
      frame = test_frame("a")
      assert frame.sequence == nil
      assert :ok = TestDriver.deliver_frame(GatedCamera, :eye, frame)
    end
  end

  test "a frame delivered before capture is confirmed is refused" do
    {:ok, _subscription} = Camera.subscribe(GatedCamera, :eye)
    assert_receive {:driver, :start_capture}

    assert {:error, %{__struct__: BB.Error.State.Camera.NotCapturing}} =
             TestDriver.deliver(GatedCamera, :eye, "too-early")
  end

  describe "publishing capture state" do
    setup do
      {:ok, subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)
      {:ok, hub} = Camera.hub(GatedCamera, :eye)
      BB.subscribe(GatedCamera, [:sensor, :head, :eye])

      %{hub: hub, subscription: subscription}
    end

    test "a session's first window has no interval behind it", %{hub: hub} do
      send(hub, {:tick, 1_000})

      assert_receive {:bb, _, %BB.Message{payload: %CaptureState{} = published}}
      assert published.measured_frame_rate == nil
      assert published.frames == 0
    end

    test "a later session measures from its own start, not the previous one's end",
         %{hub: hub, subscription: subscription} do
      send(hub, {:tick, 0})
      assert_receive {:bb, _, %BB.Message{payload: %CaptureState{measured_frame_rate: nil}}}

      # End the session, and leave a long gap before the next one.
      :ok = Camera.unsubscribe(subscription)
      assert_receive {:driver, :stop_capture}
      :ok = TestDriver.confirm_stop(GatedCamera, :eye)

      {:ok, _subscription} = Camera.subscribe(GatedCamera, :eye)
      assert_receive {:driver, :start_capture}
      :ok = TestDriver.confirm_start(GatedCamera, :eye)

      # An hour of wall clock later, measured against the previous session's
      # last tick, 30 frames would read as 0.008fps rather than nothing.
      send(hub, {:tick, 3_600_000_000_000})

      assert_receive {:bb, _, %BB.Message{payload: %CaptureState{} = published}}
      assert published.measured_frame_rate == nil
    end

    test "reports the frames per second the window actually carried", %{hub: hub} do
      send(hub, {:tick, 0})
      assert_receive {:bb, _, %BB.Message{payload: %CaptureState{measured_frame_rate: nil}}}

      for _ <- 1..30, do: :ok = TestDriver.deliver(GatedCamera, :eye)

      send(hub, {:tick, 1_000_000_000})

      assert_receive {:bb, _, %BB.Message{payload: %CaptureState{} = published}}
      assert published.frames == 30
      assert published.measured_frame_rate == 30.0
      assert published.subscriber_count == 1
    end

    test "a stalled capture reports nothing rather than what it used to manage",
         %{hub: hub} do
      send(hub, {:tick, 0})
      assert_receive {:bb, _, %BB.Message{payload: %CaptureState{measured_frame_rate: nil}}}

      for _ <- 1..10, do: :ok = TestDriver.deliver(GatedCamera, :eye)
      send(hub, {:tick, 1_000_000_000})
      assert_receive {:bb, _, %BB.Message{payload: %CaptureState{measured_frame_rate: 10.0}}}

      # No frames at all in the next window.
      send(hub, {:tick, 2_000_000_000})

      assert_receive {:bb, _, %BB.Message{payload: %CaptureState{} = published}}
      assert published.frames == 0
      assert published.measured_frame_rate == 0.0
    end

    test "carries the rate the camera was asked for, as asked for" do
      :ok =
        TestDriver.confirm_start(
          GatedCamera,
          :eye,
          StreamInfo.new!(format: {:raw, :I420}, width: 64, height: 48, frame_rate: 30.0)
        )

      {:ok, hub} = Camera.hub(GatedCamera, :eye)
      send(hub, {:tick, 0})

      assert_receive {:bb, _, %BB.Message{payload: %CaptureState{} = published}}
      assert published.requested_frame_rate == 30.0
    end

    test "a frame carries both rates, so holding one is enough to compare them",
         %{hub: hub, subscription: subscription} do
      send(hub, {:tick, 0})
      for _ <- 1..15, do: :ok = TestDriver.deliver(GatedCamera, :eye)
      send(hub, {:tick, 1_000_000_000})
      assert_receive {:bb, _, %BB.Message{payload: %CaptureState{measured_frame_rate: 15.0}}}

      ref = subscription.ref

      # The hub holds the newest frame, so the first request is answered from
      # the one delivered before the window closed - stamped with the rate as
      # it stood then, which was nothing.
      :ok = Camera.request(subscription)
      assert_receive {:bb_camera, ^ref, %Frame{measured_frame_rate: nil}}

      :ok = Camera.request(subscription)
      :ok = TestDriver.deliver(GatedCamera, :eye)

      assert_receive {:bb_camera, ^ref, %Frame{} = frame}
      assert frame.measured_frame_rate == 15.0
      assert frame.requested_frame_rate == nil
    end

    test "an idle camera publishes nothing, however often it is ticked",
         %{hub: hub, subscription: subscription} do
      :ok = Camera.unsubscribe(subscription)
      assert_receive {:driver, :stop_capture}
      :ok = TestDriver.confirm_stop(GatedCamera, :eye)
      assert Hub.capture_state(hub) == :idle

      send(hub, {:tick, 1_000_000_000})

      # The tick has been through the hub by the time this call is answered, so
      # there is nothing still in flight to wait for.
      assert Hub.capture_state(hub) == :idle
      refute_received {:bb, _, %BB.Message{payload: %CaptureState{}}}
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
      assert_receive {:bb_camera, ^ref, %Frame{data: "sentinel-frame-bytes" <> _}}

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

  # Fails the capture the hub is starting and reads how long the retry it
  # scheduled has left, then fires that retry by hand so the hub asks for
  # capture again.
  defp fail_and_read_backoff(hub) do
    :ok = Hub.capture_failed(hub, CaptureFailed.exception(camera: :spare))

    %{retry: timer} = :sys.get_state(hub)
    remaining_ms = :erlang.read_timer(timer)

    send(hub, {:timeout, timer, :retry_capture})
    assert_receive {:bb_camera, :start_capture}

    remaining_ms
  end

  defp test_frame(label, opts \\ []) do
    Frame.new!(
      [format: {:raw, :I420}, width: 64, height: 48, data: TestDriver.frame_data(label)] ++ opts
    )
  end
end
