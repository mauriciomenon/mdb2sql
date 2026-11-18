#!/usr/bin/env bash
# Debian 13 amd64: tools, build, tests and products in dist/debian/amd64/ (see README-BUILD.txt).
exec "$(dirname "$0")/scripts/build_debian.sh"
