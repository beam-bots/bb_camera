# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.EstimatorSource do
  @moduledoc """
  Delivers a camera's frames to the estimators nested inside it.

  Every camera names this as its `c:BB.Sensor.estimator_source/0`, through
  `use BB.Camera`, so an estimator declared inside a camera sensor receives a
  `%BB.Camera.Frame{}` in `c:BB.Estimator.handle_input/2`:

      sensor :eye, {BB.Camera.Synthetic, width: 640, height: 480} do
        estimator :detector, MyDetector
      end

  It is a consumer like any other, over `BB.Camera.subscribe/3` and
  `BB.Camera.request/1`. The estimator asks for a frame only when it has
  finished with the last, so one that falls behind is handed the newest frame
  when it is ready rather than a backlog, and nothing it hasn't asked for
  reaches its mailbox.

  `max_input_age`, `lost_after` and latency are measured from the frame's own
  `monotonic_time` - when it was captured, not when it was delivered.

  The estimator stays subscribed through the end of a capture, and through a
  failed one: the hub restarts a capture that ended cleanly while anyone is
  still subscribed, and a failed one starts again when somebody new subscribes.
  An estimator whose camera has stopped producing is told so by `lost_after`,
  as one whose sensor has stopped publishing is. A camera whose hub has gone
  is a different matter - the subscription is dead - so the estimator stops,
  and its supervisor starts it again against the new one.
  """

  @behaviour BB.Estimator.Source

  alias BB.Camera
  alias BB.Camera.{Frame, Subscription}

  @impl BB.Estimator.Source
  def subscribe(robot, sensor_path, _args) do
    Camera.subscribe(robot, List.last(sensor_path))
  end

  @impl BB.Estimator.Source
  def input_event(%Subscription{ref: ref}, {:bb_camera, ref, %Frame{} = frame}),
    do: {:input, frame, frame.monotonic_time, node()}

  # Arrives immediately ahead of the frame that answers the request, so asking
  # again here would leave a second request outstanding behind that frame.
  def input_event(%Subscription{ref: ref}, {:bb_camera, ref, {:stream_info, _info}}),
    do: :no_input

  # The hub spends the request of every consumer it tells a capture has ended,
  # cleanly or not, so the estimator has to ask again to be served by the next
  # session.
  def input_event(%Subscription{ref: ref}, {:bb_camera, ref, :end_of_capture}), do: :spent

  def input_event(%Subscription{ref: ref}, {:bb_camera, ref, {:capture_failed, _error}}),
    do: :spent

  def input_event(%Subscription{monitor: monitor}, {:DOWN, monitor, :process, _hub, reason}),
    do: {:ended, reason}

  def input_event(_subscription, _message), do: nil

  # A hub that has died answers with an error, and the monitor in the
  # subscription reports the same death as `{:ended, reason}`. That is the one
  # place the estimator acts on it.
  @impl BB.Estimator.Source
  def request(subscription) do
    _ = Camera.request(subscription)
    :ok
  end
end
