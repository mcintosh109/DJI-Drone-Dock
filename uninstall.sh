#!/bin/bash
# Removes the DJI drone photo dock. Run with: sudo ./uninstall.sh
# Your Immich settings and the cache on the Pi are NOT touched.

set -e
if [ "$EUID" -ne 0 ]; then echo "Run with sudo"; exit 1; fi

echo "Stopping the 15 minute timer..."
# || true: carry on if the timer was never installed
systemctl disable --now dji-drone-flush.timer 2>/dev/null || true

echo "Removing installed files..."
# rm -f does not complain if a file is already gone
rm -f /usr/local/bin/dji-drone-sync.sh \
      /etc/systemd/system/dji-drone-sync.service \
      /etc/systemd/system/dji-drone-flush.service \
      /etc/systemd/system/dji-drone-flush.timer \
      /etc/udev/rules.d/99-dji-drone.rules \
      /etc/logrotate.d/dji-drone-sync

# Tell systemd and udev the files are gone
systemctl daemon-reload
udevadm control --reload-rules

echo "Done. These were kept, delete them yourself if you no longer need them:"
echo "  /etc/dji-drone/immich.conf     your Immich address and API key"
echo "  /var/lib/dji-drone             the cache on the Pi, and the list of files already uploaded"
echo "  /var/log/dji-drone-sync.log    the sync log"
echo "Packages (jmtpfs, fuse3, rsync, curl, jq, exfatprogs, logrotate) were left installed."

# Warn if files are still waiting to be uploaded
WAITING=$(find /var/lib/dji-drone/cache -type f -not -name '.*' 2>/dev/null | wc -l)
if [ "$WAITING" -gt 0 ]; then
  echo
  echo "WARNING: $WAITING photo(s)/video(s) in /var/lib/dji-drone/cache were never uploaded to Immich."
  echo "If deleting from the drone was on, these may be the ONLY copies."
  echo "Copy them somewhere safe before deleting that folder."
fi
