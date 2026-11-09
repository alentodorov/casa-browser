#!/bin/bash
# Checks the import reading layer (src/ImportSources.swift) without the app: browser detection, the
# Chromium cookie crypto (round trip with a made-up key), Chrome history, the binarycookies parser.
set -e
cd "$(dirname "$0")"
swiftc -O ../src/ImportSources.swift main.swift -lsqlite3 -o /tmp/casa-import-harness
/tmp/casa-import-harness
