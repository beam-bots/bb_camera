<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [v0.1.0](https://github.com/beam-bots/bb_camera/compare/v0.1.0...v0.1.0) (2026-11-18)
### Breaking Changes:

* call the capture-state cadence `publish_rate`, not a telemetry clock by James Harton



### Improvements:

* record where the camera was on every frame by James Harton

* measure the real frame rate in the hub and publish it by James Harton

* configure cameras through parameters, not a settings channel by James Harton

* use `Spark.implements_behaviour?/2` to detect camera drivers by James Harton

### Bug Fixes:

* don't measure a new capture session against the last one's end by James Harton

* don't serve or strand consumers across a capture session boundary by James Harton
