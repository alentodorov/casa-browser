#!/bin/bash
# Renders the direction-D (tiles) mockups into this folder (no window is opened)
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 render-tiles.swift -o /tmp/casa-render-tiles
/tmp/casa-render-tiles "$PWD"
