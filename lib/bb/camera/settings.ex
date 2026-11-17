# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Settings do
  @moduledoc """
  A camera's settings, carrying how each value is known as well as what it is.

  Camera drivers are routinely in a position to report a number they never
  verified. Pass `-framerate 30` to ffmpeg and you can say the camera is set to
  30fps without anything ever having confirmed it; parse the SOF marker of a
  JPEG the device actually produced and you genuinely know its dimensions.
  Collapsing both into a plain map makes the second indistinguishable from the
  first, which is how an operator ends up debugging hardware that was never
  configured the way the UI claimed.

  So each key carries a provenance:

  - `:actual` - read back from the device, or parsed out of the data it
    produced.
  - `:requested` - what we asked for, unverified. The honest answer for a flag
    nobody queried back.

  `measured` is separate again: an observation, like a frame rate averaged over
  a sliding window, which neither confirms nor contradicts the setting but is
  what an operator actually wants to see next to it.

      Settings.new(%{width: 640, height: 480, frame_rate: 30.0})
      |> Settings.put(:width, 640, :actual)
      |> Settings.put(:height, 480, :actual)
      |> Settings.put(:frame_rate, 30.0, :requested)
      |> Settings.measure(:frame_rate, 28.7)
  """

  defstruct values: %{}, provenance: %{}, measured: %{}

  @type provenance :: :actual | :requested

  @type t :: %__MODULE__{
          values: %{atom() => term()},
          provenance: %{atom() => provenance()},
          measured: %{atom() => term()}
        }

  @doc """
  Build settings from a plain map of values.

  Every value starts out `:requested` - the weakest claim - so a driver that
  never calls `put/4` can't accidentally assert it verified anything.
  """
  @spec new(map() | keyword()) :: t()
  def new(values \\ %{})

  def new(values) when is_list(values), do: new(Map.new(values))

  def new(values) when is_map(values) do
    %__MODULE__{
      values: values,
      provenance: Map.new(values, fn {key, _} -> {key, :requested} end)
    }
  end

  @doc """
  Set a value and say how it is known.
  """
  @spec put(t(), atom(), term(), provenance()) :: t()
  def put(settings, key, value, provenance) when provenance in [:actual, :requested] do
    %{
      settings
      | values: Map.put(settings.values, key, value),
        provenance: Map.put(settings.provenance, key, provenance)
    }
  end

  @doc """
  Record an observation of a setting without claiming it as the setting.
  """
  @spec measure(t(), atom(), term()) :: t()
  def measure(settings, key, value) do
    %{settings | measured: Map.put(settings.measured, key, value)}
  end

  @doc """
  Fetch a value.
  """
  @spec get(t(), atom(), term()) :: term()
  def get(settings, key, default \\ nil), do: Map.get(settings.values, key, default)

  @doc """
  Whether a value was verified against the device rather than merely asked for.
  """
  @spec actual?(t(), atom()) :: boolean()
  def actual?(settings, key), do: Map.get(settings.provenance, key) == :actual

  @doc """
  Merge new values in, keeping the provenance that comes with them.
  """
  @spec merge(t(), t()) :: t()
  def merge(settings, %__MODULE__{} = other) do
    %__MODULE__{
      values: Map.merge(settings.values, other.values),
      provenance: Map.merge(settings.provenance, other.provenance),
      measured: Map.merge(settings.measured, other.measured)
    }
  end

  @doc """
  The keys whose values differ between two settings.
  """
  @spec changed(t(), t()) :: map()
  def changed(%__MODULE__{} = before, %__MODULE__{} = aftr) do
    aftr.values
    |> Enum.filter(fn {key, value} -> Map.get(before.values, key) != value end)
    |> Map.new()
  end
end
