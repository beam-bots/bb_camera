# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

# Robots log loudly when their supervision tree comes down, which is every
# test's teardown. Captured rather than silenced, so a failing test still
# reports what was logged.
ExUnit.start(capture_log: true)
