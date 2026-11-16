#!/bin/bash
# Installs the DJI drone photo dock. Run with: sudo ./install.sh
# Safe to run again, e.g. after updating this repo. Your settings are kept;
# settings that are new in this version are added (it asks about deleting
# from the drone).

# Stop at the first command that fails
set -e

# Must run as root (sudo), because it writes to system folders
if [ "$EUID" -ne 0 ]; then echo "Run with sudo"; exit 1; fi

# Work from the folder this script is in, so the files below are found
cd "$(dirname "$0")"

CONF=/etc/dji-drone/immich.conf

echo "Installing packages..."
# jmtpfs: mounts drones that show up as an MTP device (like a phone)
# fuse3: needed by jmtpfs, and provides fusermount for unmounting
# rsync: copies the photos and videos
# curl: talks to Immich
# jq: reads Immich's replies (JSON)
# exfatprogs: lets the Pi read SD cards formatted as exFAT
# logrotate: keeps the log file from growing forever
apt-get install -y jmtpfs fuse3 rsync curl jq exfatprogs logrotate

echo "Installing files..."
# install copies a file and sets its permissions in one step
install -m 755 dji-drone-sync.sh /usr/local/bin/dji-drone-sync.sh
install -m 644 dji-drone-sync.service /etc/systemd/system/dji-drone-sync.service
install -m 644 dji-drone-flush.service /etc/systemd/system/dji-drone-flush.service
install -m 644 dji-drone-flush.timer /etc/systemd/system/dji-drone-flush.timer
install -m 644 99-dji-drone.rules /etc/udev/rules.d/99-dji-drone.rules
install -m 644 dji-drone-sync.logrotate /etc/logrotate.d/dji-drone-sync
# /var/lib/dji-drone holds the cache: files waiting to be uploaded to Immich
mkdir -p /mnt/drone /var/lib/dji-drone/cache
# /etc/dji-drone holds the Immich settings; only root may look inside
install -d -m 700 /etc/dji-drone

# Tell systemd and udev to load the new files
systemctl daemon-reload
udevadm control --reload-rules

# Start the 15 minute timer now, and at every boot
systemctl enable --now dji-drone-flush.timer

# ---- Immich settings -----------------------------------------------------------
if [ ! -f "$CONF" ]; then
  # [ -t 0 ] is true when someone is typing at a terminal
  if [ -t 0 ]; then
    echo
    echo "Immich settings (press Enter to skip; you can edit $CONF later)"
    read -rp "Immich address, e.g. http://192.168.1.50:2283 : " URL
    read -rsp "Immich API key (it won't show as you type): " KEY; echo
    read -rp "Album name [Drone Photos]: " ALBUM
    [ -n "$ALBUM" ] || ALBUM="Drone Photos"
    [ -n "$URL" ] || URL="http://192.168.1.50:2283"
    [ -n "$KEY" ] || KEY="CHANGE_ME"
  else
    echo "Note: no terminal, so not asking for the Immich settings."
    URL="http://192.168.1.50:2283"; KEY="CHANGE_ME"; ALBUM="Drone Photos"
  fi
  # umask 077 makes the file readable by root only from the moment it is
  # created. The ( ) keeps that setting inside this one command.
  # awk fills in the three settings in the example file. The values are
  # passed through the environment (ENVIRON), so any characters in them
  # are copied exactly as typed.
  (umask 077; URL=$URL KEY=$KEY ALBUM=$ALBUM awk '
     /^IMMICH_URL=/     { print "IMMICH_URL=" ENVIRON["URL"]; next }
     /^IMMICH_API_KEY=/ { print "IMMICH_API_KEY=" ENVIRON["KEY"]; next }
     /^IMMICH_ALBUM=/   { print "IMMICH_ALBUM=" ENVIRON["ALBUM"]; next }
     /^# ---- Dock settings/ { exit }
     { print }' examples/immich.conf.example > "$CONF")
fi
chmod 600 "$CONF"

# Settings added in newer versions: add them to an existing settings file
# if they're missing, without touching anything that's already there.
if ! grep -q '^[[:space:]]*DELETE_FROM_DRONE[[:space:]]*=' "$CONF"; then
  ANSWER=n
  if [ -t 0 ]; then
    echo
    echo "Delete photos and videos from the drone once they're copied to the Pi?"
    echo "(They're checked byte for byte first. Until they're uploaded, the Pi has the only copy.)"
    read -rp "Delete from the drone? [Y/n]: " ANSWER
    case "$ANSWER" in [nN]*) ANSWER=n ;; *) ANSWER=y ;; esac
  else
    echo "Note: no terminal, so not deleting from the drone. To turn it on, set DELETE_FROM_DRONE=yes in $CONF"
  fi
  if [ "$ANSWER" = y ]; then VALUE=yes; else VALUE=no; fi
  printf '\n# yes = delete photos/videos from the drone once their copy on the Pi is checked\nDELETE_FROM_DRONE=%s\n' "$VALUE" >> "$CONF"
fi
if ! grep -q '^[[:space:]]*CACHE_LIMIT_GB[[:space:]]*=' "$CONF"; then
  printf '\n# The most the cache on the Pi may hold, in GB\nCACHE_LIMIT_GB=20\n' >> "$CONF"
fi

echo
echo "Checking the Immich settings..."
/usr/local/bin/dji-drone-sync.sh --check ||
  echo "Fix the settings with: sudo nano $CONF   then check again with: sudo dji-drone-sync.sh --check"
echo
echo "Done. Plug in the drone and watch: tail -f /var/log/dji-drone-sync.log"
