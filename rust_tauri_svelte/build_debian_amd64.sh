#!/usr/bin/env bash
# Debian 13 amd64: testes + .deb + .zip em dist/debian/amd64/ (ver README-BUILD.txt). Pelo Windows: build_debian_amd64_wsl.ps1
exec "$(dirname "$0")/scripts/build_debian.sh"
