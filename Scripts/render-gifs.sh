#!/bin/sh
# Regenerates the README GIFs into docs/gifs (or the directory given as $1).
# The renderer is compiled together with the package sources so it can use the
# engine's internal API; nothing is added to the package itself.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -O -o .build/render-gifs \
  $(find Sources/ThinkingOrbKit -name '*.swift') \
  Scripts/RenderGIFs/main.swift
.build/render-gifs "${1:-docs/gifs}"
