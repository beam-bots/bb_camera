# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.Invalid.Camera.UnknownCamera do
  @moduledoc """
  No camera by that name is declared on the robot.

  This is a configuration error, not a runtime one: a camera that is declared
  but not running reports `BB.Error.State.Camera.NotRunning` instead.
  """
  use BB.Error,
    class: :invalid,
    fields: [:robot, :camera, :known]

  @type t :: %__MODULE__{
          robot: module(),
          camera: atom(),
          known: [atom()]
        }

  defimpl BB.Error.Severity do
    def severity(_), do: :error
  end

  def message(%{known: []} = error) do
    "#{inspect(error.robot)} declares no cameras, so #{inspect(error.camera)} can't be one."
  end

  def message(error) do
    "#{inspect(error.robot)} has no camera called #{inspect(error.camera)}. " <>
      "It has: #{inspect(error.known)}."
  end
end
