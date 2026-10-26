#!/usr/bin/env bash
# Kept so existing links, cron entries and muscle memory still work.
# Everything lives in fedora-setup.sh now.
#
#   ./fedora44-setup.sh --help
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$here/fedora-setup.sh" "$@"
