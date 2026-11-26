# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Media do
  @moduledoc """
  Reading frames from a camera with a loop of your own.

  The same mechanism as `BB.Camera.subscribe/3` and friends, shaped for code
  that would rather block than handle messages - an HTTP route writing chunks
  to a browser being the obvious case:

      {:ok, session} = BB.Camera.Media.open(MyRobot, :eye, format: {:raw, :I420})

      Stream.repeatedly(fn -> BB.Camera.Media.next(session, 2_000) end)
      |> Enum.reduce_while(conn, fn
        {:ok, frame}, conn -> {:cont, write_part(conn, frame)}
        {:error, _}, conn -> {:halt, conn}
      end)

      BB.Camera.Media.close(session)

  `next/2` returns a frame strictly newer than the one it last returned, so a
  loop like that one runs at the camera's frame rate rather than spinning: the
  bound is the camera, not the processor. Frames produced while you weren't
  asking are dropped rather than queued, which is why a consumer that stalls
  costs the camera nothing and a browser that falls behind sees a current
  picture rather than an ever-lengthening backlog.

  Every failure mode is an `{:error, _}` return rather than a hang: a timeout,
  a capture that ended, a capture that failed, a camera process that died. Any
  of them is a safe signal to stop streaming.
  """

  alias BB.Camera
  alias BB.Camera.{Frame, StreamInfo}
  alias BB.Camera.Media.Session
  alias BB.Error.State.Camera.{EndOfCapture, NotRunning, Timeout}

  @doc """
  Open a session on a camera's capture.

  ## Options

  - `:format` - assert the camera produces this format. A consumer that can
    only read `:I420` should say `format: {:raw, :I420}` and be told so here,
    rather than find out from the bytes.
  - `:owner` - the process the session belongs to, defaulting to the caller.
    The hub monitors it, so a disconnected browser or a crashed route releases
    the capture.
  """
  @spec open(module(), atom(), keyword()) :: {:ok, Session.t()} | {:error, struct()}
  def open(robot, camera, opts \\ []) do
    with {:ok, subscription} <- Camera.subscribe(robot, camera, opts) do
      {:ok, %Session{subscription: subscription, stream_info: subscription.stream_info}}
    end
  end

  @doc """
  Wait for the next frame.

  Returns a frame strictly newer than the last one this session returned,
  immediately if one is already waiting.

  On timeout the outstanding demand is cancelled at the hub before returning,
  and any frame that arrived while the timeout was being processed is picked up
  rather than stranded in the caller's mailbox. A timeout before any frame has
  ever arrived is the signal to answer 503 rather than commit to a stream the
  camera isn't producing.
  """
  @spec next(Session.t(), timeout()) :: {:ok, Frame.t()} | {:error, struct()}
  def next(%Session{} = session, timeout \\ 5000) do
    case Camera.request(session.subscription) do
      :ok -> await(session, timeout)
      {:error, _} = error -> error
    end
  end

  @doc """
  Close the session, releasing the consumer.

  Capture stops when the last session on a camera closes.
  """
  @spec close(Session.t()) :: :ok
  def close(%Session{} = session) do
    :ok = Camera.unsubscribe(session.subscription)
    flush(session)
  end

  @doc """
  What the camera was producing when this session opened.

  A frame carries its own `format`, `width` and `height`, which is what to
  describe a *frame* with; this is the camera's advertised format, captured
  once. A camera that renegotiates mid-capture will produce frames that
  disagree with it, and the frames are the truth.
  """
  @spec stream_info(Session.t()) :: StreamInfo.t()
  def stream_info(%Session{stream_info: stream_info}), do: stream_info

  defp await(session, timeout) do
    await(session, timeout, deadline(timeout))
  end

  defp await(session, timeout, deadline) do
    %{ref: ref, monitor: monitor, robot: robot, camera: camera} = session.subscription

    receive do
      {:bb_camera, ^ref, %Frame{} = frame} ->
        {:ok, frame}

      {:bb_camera, ^ref, {:stream_info, _stream_info}} ->
        await(session, timeout, deadline)

      {:bb_camera, ^ref, :end_of_capture} ->
        {:error, EndOfCapture.exception(robot: robot, camera: camera, reason: :ended)}

      {:bb_camera, ^ref, {:capture_failed, error}} ->
        {:error, error}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, NotRunning.exception(robot: robot, camera: camera)}
    after
      remaining(deadline) ->
        Camera.cancel_request(session.subscription)
        collect_racing_frame(session, timeout)
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # The cancellation above is synchronous, so by the time it returns the hub
  # has either sent a frame or it never will. Checking the mailbox without
  # waiting distinguishes the two, and keeps a frame that arrived microseconds
  # before the deadline from being left behind to confuse the next call.
  defp collect_racing_frame(session, timeout) do
    %{ref: ref, robot: robot, camera: camera} = session.subscription

    receive do
      {:bb_camera, ^ref, %Frame{} = frame} -> {:ok, frame}
      {:bb_camera, ^ref, :end_of_capture} -> {:error, end_of_capture(robot, camera)}
      {:bb_camera, ^ref, {:capture_failed, error}} -> {:error, error}
    after
      0 -> {:error, Timeout.exception(robot: robot, camera: camera, timeout: timeout)}
    end
  end

  defp end_of_capture(robot, camera) do
    EndOfCapture.exception(robot: robot, camera: camera, reason: :ended)
  end

  defp flush(session) do
    ref = session.subscription.ref

    receive do
      {:bb_camera, ^ref, _} -> flush(session)
    after
      0 -> :ok
    end
  end
end
