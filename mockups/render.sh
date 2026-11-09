#!/bin/bash
# Renders the mockup PNGs into this folder (no window is opened)
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 render.swift -o /tmp/casa-render
/tmp/casa-render "$PWD"
