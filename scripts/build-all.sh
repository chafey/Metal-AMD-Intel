#!/bin/sh
# Build everything that is currently implemented (see root Makefile).
set -eu
cd "$(dirname "$0")/.."
make all
