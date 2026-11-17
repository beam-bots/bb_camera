# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.State.Camera.NotCapturing do
  @moduledoc """
  A frame arrived while the camera wasn't capturing.

  Capture is only considered started once the driver confirms it with
  `BB.Camera.Hub.capture_started/2`. A frame before that confirmation, or after
  `capture_stopped/2`, means the driver's own lifecycle bookkeeping has drifted
  from the hub's.
  """
  use BB.Error,
    class: :state,
    fields: [:robot, :camera]

  @type t :: %__MODULE__{robot: module(), camera: atom()}

  defimpl BB.Error.Severity do
    def severity(_), do: :error
  end

  def message(error) do
    "Camera #{inspect(error.camera)} delivered a frame while not capturing."
  end
end
