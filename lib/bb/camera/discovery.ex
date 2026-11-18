# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.Discovery do
  @moduledoc """
  Finds the cameras a robot declares.

  A static walk of the robot's DSL - the robot-level `sensors` section plus
  every link and joint in the topology - keeping the sensors whose callback
  module implements `BB.Camera`. It needs nothing running, which is the point:
  a camera that should be there and isn't is exactly what an operator needs to
  see, and a UI that can only list cameras once they work is no use while
  something is broken.

  Live hubs are merged in where they exist, so a single pass gives both the
  declared set and the running state.
  """

  alias BB.Camera.{Hub, Info, StreamInfo}
  alias BB.Dsl

  @doc """
  Every camera `robot` declares, running or not.
  """
  @spec discover(module()) :: [Info.t()]
  def discover(robot) do
    robot
    |> declared()
    |> Enum.map(fn {sensor, path, attached_to} ->
      build_info(robot, sensor, path, attached_to)
    end)
  end

  @doc """
  The declared sensors of `robot` that are cameras, with their topology
  position.

  Returns `{%BB.Dsl.Sensor{}, parent_path, attached_to}` tuples, options and
  all. Internal: the options are what `c:BB.Camera.stream_info/1` needs and are
  deliberately not carried into `BB.Camera.Info`.
  """
  @spec declared(module()) :: [{Dsl.Sensor.t(), [atom()], Info.t()}]
  def declared(robot) do
    robot_level =
      robot
      |> Dsl.Info.sensors()
      |> Enum.map(&{&1, [], :robot})

    nested =
      robot
      |> Dsl.Info.topology()
      |> Enum.flat_map(&walk_link(&1, []))

    Enum.filter(robot_level ++ nested, fn {sensor, _path, _attached_to} ->
      sensor |> module_for() |> camera?()
    end)
  end

  @doc """
  The hub serving a camera, or `:undefined`.

  A robot that has never started has no registry at all, and asking one that
  doesn't exist raises rather than answering. Everything here has to work on
  stopped robots, so the absence of the registry is just another way of saying
  nothing is running.
  """
  @spec hub_pid(module(), atom()) :: pid() | :undefined
  def hub_pid(robot, name) do
    if Process.whereis(BB.Process.registry_name(robot)) do
      BB.Process.whereis(robot, {:camera, name})
    else
      :undefined
    end
  end

  @doc """
  Whether `module` is a camera driver.
  """
  @spec camera?(module()) :: boolean()
  def camera?(module) when is_atom(module),
    do: Spark.implements_behaviour?(module, BB.Camera)

  def camera?(_), do: false

  defp walk_link(link, path) do
    link_path = path ++ [link.name]

    sensors = Enum.map(link.sensors, &{&1, link_path, {:link, link.name}})
    joints = Enum.flat_map(link.joints, &walk_joint(&1, link_path))

    sensors ++ joints
  end

  defp walk_joint(joint, path) do
    joint_path = path ++ [joint.name]

    sensors = Enum.map(joint.sensors, &{&1, joint_path, {:joint, joint.name}})
    children = if joint.link, do: walk_link(joint.link, joint_path), else: []

    sensors ++ children
  end

  defp build_info(robot, sensor, parent_path, attached_to) do
    path = parent_path ++ [sensor.name]
    hub = hub_pid(robot, sensor.name)

    %Info{
      robot: robot,
      name: sensor.name,
      path: path,
      topic: [:sensor | path],
      module: module_for(sensor),
      attached_to: attached_to,
      stream_info: nil,
      status: :declared,
      pid: nil
    }
    |> put_runtime(hub)
    |> put_declared_stream_info(sensor)
  end

  defp put_runtime(info, :undefined), do: info

  defp put_runtime(info, hub) do
    %{
      info
      | pid: hub,
        status: Hub.status(hub),
        stream_info: Hub.stream_info(hub)
    }
  end

  defp put_declared_stream_info(%{stream_info: %StreamInfo{}} = info, _sensor), do: info

  defp put_declared_stream_info(info, sensor) do
    case info.module.stream_info(options_for(sensor)) do
      {:ok, %StreamInfo{} = stream_info} -> %{info | stream_info: stream_info}
      _ -> info
    end
  end

  defp module_for(%Dsl.Sensor{child_spec: {module, _opts}}), do: module
  defp module_for(%Dsl.Sensor{child_spec: module}), do: module

  defp options_for(%Dsl.Sensor{child_spec: {_module, opts}}), do: opts
  defp options_for(%Dsl.Sensor{child_spec: _module}), do: []
end
