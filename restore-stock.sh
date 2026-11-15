#!/usr/bin/env bash
# Put the Retroid Pocket 5 back on the stock .31 firmware.
#
#   ./restore-stock.sh                  # restore stock .31 and stay there
#   ./restore-stock.sh --then-install   # restore, wait for USB debugging,
#                                       # then install AshFall in the same run
#   ./restore-stock.sh --check          # preflight only: device, battery, plan
#   ./restore-stock.sh --dry-run        # download + verify, print the plan, write nothing
#
# It downloads the public .31 package (3.1 GB, pinned SHA-256 per volume and per
# image), verifies everything, then flashes super + the boot chain in ONE
# fastboot process and wipes userdata/metadata. This is the same path the
# installer uses to migrate a retail .189 device, so there is only one
# implementation.
#
# Options are forwarded to install.sh: --serial, --no-oc, --yes, --wait-debug
# SECONDS, --help.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$HERE/install.sh" --stock "$@"
