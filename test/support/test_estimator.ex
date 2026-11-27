# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.TestEstimator do
  @moduledoc """
  Estimator that forwards every input it is given to a test process.

  The same double as `BB.Test.RecordingEstimator` in `bb`, which lives in that
  package's `test/support` and so isn't compiled when `bb` is a dependency.

  Before starting the robot, put the recipient pid into persistent term:

      :persistent_term.put({BB.Camera.TestEstimator, MyRobot}, self())

  It sends `{:received, :input, input}` for each call to `handle_input/2`.
  Pass `gated: true` to have it hold each input until the test sends the
  estimator's process `:release`; it sends `{:received, :holding, input}` as
  it starts waiting. Every held input must be released, or the robot can't
  shut down.
  """
  use BB.Estimator,
    options_schema: [
      gated: [
        type: :boolean,
        required: false,
        default: false,
        doc: "Hold each input until the estimator is sent `:release`"
      ]
    ]

  @impl BB.Estimator
  def init(opts) do
    bb = Keyword.fetch!(opts, :bb)
    recipient = :persistent_term.get({__MODULE__, bb.robot}, nil)
    {:ok, %{recipient: recipient, gated: Keyword.fetch!(opts, :gated)}}
  end

  @impl BB.Estimator
  def handle_input(input, state) do
    if state.gated, do: hold(state.recipient, input)
    forward(state.recipient, :input, input)
    {:noreply, state}
  end

  defp hold(recipient, input) do
    forward(recipient, :holding, input)

    receive do
      :release -> :ok
    end
  end

  defp forward(nil, _kind, _input), do: :ok
  defp forward(pid, kind, input), do: send(pid, {:received, kind, input})
end
