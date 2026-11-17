# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.Hardware.Camera.CaptureFailed do
  @moduledoc """
  The driver couldn't start, or couldn't continue, capturing.

  Reported by the driver through `BB.Camera.Hub.capture_failed/2`. The hub
  publishes `BB.Message.Camera.EndCapture` and hands this error to every
  subscriber, so no consumer is left waiting on a stream that will never
  resume.
  """
  use BB.Error,
    class: :hardware,
    fields: [:camera, :reason]

  @type t :: %__MODULE__{camera: atom(), reason: term()}

  defimpl BB.Error.Severity do
    def severity(_), do: :error
  end

  def message(error) do
    "Capture failed on camera #{inspect(error.camera)}: #{inspect(error.reason)}."
  end
end
