#!/bin/sh
# Prints REBOOT or ok, plus the packages that asked for it. Read-only.
if [ -e /var/run/reboot-required ]; then
  echo "REBOOT $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)"
else
  echo ok
fi
