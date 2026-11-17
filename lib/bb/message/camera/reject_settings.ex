# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Message.Camera.RejectSettings do
  @moduledoc """
  A settings change was refused, by the schema or by the driver.

  Published as well as returned to the caller, because a rejected setting is
  something an operator watching the robot should see even when they weren't
  the one who asked for it.
  """

  defstruct [:settings, :error]

  use BB.Message,
    schema: [
      settings: [type: :map, required: true, doc: "The settings as requested"],
      error: [type: :struct, required: true, doc: "Why they were refused"]
    ]

  @type t :: %__MODULE__{settings: map(), error: struct()}
end
