# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.Invalid.Camera.InvalidSettings do
  @moduledoc """
  Settings failed the driver's `c:BB.Camera.settings_schema/0`.

  Caught by `BB.Camera.Hub` before the driver is asked to apply anything, so a
  rejected set never reaches hardware.
  """
  use BB.Error,
    class: :invalid,
    fields: [:camera, :settings, :reason]

  @type t :: %__MODULE__{
          camera: atom(),
          settings: map(),
          reason: term()
        }

  defimpl BB.Error.Severity do
    def severity(_), do: :error
  end

  def message(error) do
    "Settings rejected for camera #{inspect(error.camera)}: #{inspect(error.reason)}."
  end
end
