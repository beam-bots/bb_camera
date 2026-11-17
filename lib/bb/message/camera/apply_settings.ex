# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Message.Camera.ApplySettings do
  @moduledoc """
  A camera's settings changed.

  `settings` is the full `BB.Camera.Settings` after the change, provenance and
  all, so a subscriber doesn't have to ask. `changed` is just the keys that
  moved, for anything that only cares about the delta.
  """

  alias BB.Camera.Settings

  defstruct [:settings, :changed]

  use BB.Message,
    schema: [
      settings: [
        type: {:struct, Settings},
        required: true,
        doc: "The camera's settings after the change"
      ],
      changed: [type: :map, required: true, doc: "Just the keys whose values moved"]
    ]

  @type t :: %__MODULE__{settings: Settings.t(), changed: map()}
end
