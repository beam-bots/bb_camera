# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.State.Camera.NotRunning do
  @moduledoc """
  The camera is declared but its `BB.Camera.Hub` isn't alive.

  The robot may not be started, the sensor may have crashed, or the hardware
  may be absent. Discovery still lists the camera - with `status: :declared` -
  because an operator needs to see a camera that should be there and isn't.
  """
  use BB.Error,
    class: :state,
    fields: [:robot, :camera]

  @type t :: %__MODULE__{robot: module(), camera: atom()}

  defimpl BB.Error.Severity do
    def severity(_), do: :error
  end

  def message(error) do
    "Camera #{inspect(error.camera)} on #{inspect(error.robot)} is declared but not running."
  end
end
