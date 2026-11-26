# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.PoseSnapshotTest do
  @moduledoc """
  What a frame records about where the camera was when it was taken.
  """

  use ExUnit.Case, async: false

  alias BB.Camera.{Media, Synthetic}
  alias BB.Camera.TestBots.{GimbalCamera, GimbalCameraWithoutHistory, MixedTopology}
  alias BB.Robot.Kinematics
  alias BB.Robot.Runtime
  alias BB.Robot.State, as: RobotState

  describe "where the camera hangs" do
    setup do
      start_supervised!(MixedTopology)
      :ok
    end

    test "a link-attached camera says which link" do
      assert capture_one(MixedTopology, :eye).attached_to == {:link, :head}
    end

    test "a joint-attached camera says which joint" do
      assert capture_one(MixedTopology, :neck_cam).attached_to == {:joint, :neck}
    end

    test "a camera declared on the robot rather than its topology says so" do
      assert capture_one(MixedTopology, :overhead).attached_to == :robot
    end
  end

  describe "the joint configurations a frame carries" do
    setup do
      start_supervised!(GimbalCamera)
      %{state: Runtime.get_robot_state(GimbalCamera)}
    end

    test "are the ones in effect when the frame was captured", %{state: state} do
      :ok = RobotState.set_configuration(state, :pan, 0.25)

      assert capture_one(GimbalCamera, :eye).joint_configurations == %{pan: 0.25}
    end

    test "are looked up at the frame's capture time, not taken as they stand on arrival",
         %{state: state} do
      :ok = RobotState.set_configuration(state, :pan, 0.25)

      # A report that is already the robot's current configuration, but is for
      # a moment after this frame is captured. Read on arrival, the frame would
      # carry it; looked up at capture, it can't have happened yet.
      later = System.monotonic_time(:nanosecond) + 60_000_000_000
      :ok = RobotState.set_configuration(state, :pan, -0.5, later)

      assert capture_one(GimbalCamera, :eye).joint_configurations == %{pan: 0.25}
      assert RobotState.get_all_configurations(state) == %{pan: -0.5}
    end

    test "do not change under a frame once the joint has moved on", %{state: state} do
      :ok = RobotState.set_configuration(state, :pan, 0.25)
      frame = capture_one(GimbalCamera, :eye)

      :ok = RobotState.set_configuration(state, :pan, -0.5)

      # The whole point: the gimbal has moved, and the frame still knows where
      # it was pointing, which is not recoverable from the robot any more.
      assert frame.joint_configurations == %{pan: 0.25}
      assert RobotState.get_all_configurations(state) == %{pan: -0.5}
    end

    test "are enough to place the camera afterwards, without the robot having stayed put",
         %{state: state} do
      :ok = RobotState.set_configuration(state, :pan, 0.0)
      straight_ahead = capture_one(GimbalCamera, :eye)

      :ok = RobotState.set_configuration(state, :pan, :math.pi() / 2)
      turned = capture_one(GimbalCamera, :eye)

      robot = GimbalCamera.robot()

      refute transform_of(robot, straight_ahead) == transform_of(robot, turned)
    end
  end

  describe "on a robot that keeps no joint history" do
    setup do
      start_supervised!(GimbalCameraWithoutHistory)
      %{state: Runtime.get_robot_state(GimbalCameraWithoutHistory)}
    end

    test "are the ones current when the frame arrived", %{state: state} do
      :ok = RobotState.set_configuration(state, :pan, 0.25)
      later = System.monotonic_time(:nanosecond) + 60_000_000_000
      :ok = RobotState.set_configuration(state, :pan, -0.5, later)

      assert capture_one(GimbalCameraWithoutHistory, :eye).joint_configurations == %{pan: -0.5}
    end
  end

  defp capture_one(robot, camera) do
    {:ok, session} = Media.open(robot, camera)
    :ok = Synthetic.capture_frame(robot, camera)
    {:ok, frame} = Media.next(session, 1_000)
    :ok = Media.close(session)

    frame
  end

  defp transform_of(robot, %{attached_to: {:link, link}} = frame),
    do: Kinematics.forward_kinematics(robot, frame.joint_configurations, link)
end
