#!/bin/sh
# Failed systemd units (system scope). Prints "none" when clean. Read-only.
out=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
echo "${out:-none}"
