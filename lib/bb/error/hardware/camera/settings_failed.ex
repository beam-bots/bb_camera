# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.Hardware.Camera.SettingsFailed do
  @moduledoc """
  The driver rejected settings that passed its own schema.

  Schema-valid but device-invalid: a frame rate the sensor can't sustain at the
  configured resolution, an exposure outside the range the hardware reports.
  """
  use BB.Error,
    class: :hardware,
    fields: [:camera, :setting, :reason]

  @type t :: %__MODULE__{camera: atom(), setting: atom() | nil, reason: term()}

  defimpl BB.Error.Severity do
    def severity(_), do: :error
  end

  def message(%{setting: nil} = error) do
    "Camera #{inspect(error.camera)} rejected the settings: #{inspect(error.reason)}."
  end

  def message(error) do
    "Camera #{inspect(error.camera)} rejected #{inspect(error.setting)}: #{inspect(error.reason)}."
  end
end
