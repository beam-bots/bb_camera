# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Error.State.Camera.Timeout do
  @moduledoc """
  No new frame arrived within the caller's timeout.

  The outstanding demand is cancelled at the hub before this is returned, so
  nothing is left dangling and no frame is stranded in the caller's mailbox.

  A timeout before any frame has ever arrived is the signal an HTTP route wants
  for answering 503 rather than committing a 200 to a camera that never
  produces.
  """
  use BB.Error,
    class: :state,
    fields: [:robot, :camera, :timeout]

  @type t :: %__MODULE__{robot: module(), camera: atom(), timeout: timeout()}

  defimpl BB.Error.Severity do
    def severity(_), do: :warning
  end

  def message(error) do
    "No new frame from camera #{inspect(error.camera)} within #{inspect(error.timeout)}ms."
  end
end
