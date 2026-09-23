#!/bin/bash
# Compiles the real DSP (Sources/DSP.swift + Settings.swift) with tests/dsp-tests.swift and runs the
# orientation and volume checks: a distinct tone per content channel is fed through the Processor and
# every output slot is checked for what it carries and at which level.
# The test file is compiled as main.swift because swiftc allows top-level code only there in a multi-file build.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
cp tests/dsp-tests.swift "$T/main.swift"
swiftc -O -o "$T/dsptest" "$T/main.swift" Sources/DSP.swift Sources/Settings.swift
"$T/dsptest"
