# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.TestBots.NotACamera do
  @moduledoc "An ordinary sensor, to prove discovery discriminates."
  use BB.Sensor

  @impl BB.Sensor
  def init(opts), do: {:ok, %{bb: opts[:bb]}}
end

defmodule BB.Camera.TestBots.SingleCamera do
  @moduledoc "One link-attached camera, driven frame by frame."
  use BB

  settings do
    name(:bb_camera_single)
  end

  topology do
    link :head do
      sensor(:eye, {BB.Camera.Synthetic, clock: :external})
    end
  end
end

defmodule BB.Camera.TestBots.FailingCamera do
  @moduledoc "A camera whose capture never starts."
  use BB

  settings do
    name(:bb_camera_failing)
  end

  topology do
    link :head do
      sensor(:eye, {BB.Camera.Synthetic, clock: :external, fail_capture: true})
    end
  end
end

defmodule BB.Camera.TestBots.FreeRunningCamera do
  @moduledoc "A camera that clocks itself, for the Membrane pipeline test."
  use BB

  settings do
    name(:bb_camera_free_running)
  end

  topology do
    link :head do
      sensor(:eye, {BB.Camera.Synthetic, clock: {:rate, 200}})
    end
  end
end

defmodule BB.Camera.TestBots.MixedTopology do
  @moduledoc """
  Cameras at every attachment point, plus a sensor that isn't one.

  Discovery has to find all three cameras and none of the thermometer.
  """
  use BB

  settings do
    name(:bb_camera_mixed)
  end

  sensors do
    sensor(:overhead, {BB.Camera.Synthetic, clock: :external})
  end

  topology do
    link :base do
      sensor(:thermometer, BB.Camera.TestBots.NotACamera)

      joint :neck do
        type(:fixed)

        sensor(:neck_cam, {BB.Camera.Synthetic, clock: :external})

        link :head do
          sensor(:eye, {BB.Camera.Synthetic, clock: :external, width: 640, height: 480})
        end
      end
    end
  end
end

defmodule BB.Camera.TestBots.GatedCamera do
  @moduledoc "A camera whose every answer to the hub is a test's decision."
  use BB

  settings do
    name(:bb_camera_gated)
  end

  topology do
    link :head do
      sensor(:eye, BB.Camera.TestDriver)
    end
  end
end
