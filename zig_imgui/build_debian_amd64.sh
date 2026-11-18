#!/usr/bin/env bash
# Debian 13 amd64: ferramentas fixas, testes, build e produtos (.deb, .zip) em dist/debian/amd64/ (ver README-BUILD.txt).
exec bash "$(dirname "$0")/scripts/build_debian.sh"
