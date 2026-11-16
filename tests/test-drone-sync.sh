#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-drone-sync.sh - tests for dji-drone-sync.sh, with a fake drone and a
# fake Immich server.
#
#   bash tests/test-drone-sync.sh
#
# Nothing real is touched: the "drone", its "USB drives", the mount
# commands and "Immich" are all fakes in a temporary folder. Needs rsync,
# jq, flock and sha1sum.
# ---------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/dji-drone-sync.sh"
T=$(mktemp -d /tmp/dji-drone-test-XXXXXX)
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
PASSED=0; FAILED=0
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then echo "  PASS  $name"; PASSED=$((PASSED+1)); else echo "  FAIL  $name"; FAILED=$((FAILED+1)); fi; }

mkdir -p "$T/bin" "$T/mnt" "$T/mtp-drone" "$T/ums" "$T/immich/assets" "$T/immich/albums"
: > "$T/proc-mounts"

# ---- The fake drone -------------------------------------------------------------
# MTP mode: while $T/mtp-on exists, `jmtpfs -l` lists the drone (and, while
# $T/rc2-on exists, an RC 2 controller too). Mounting copies $T/mtp-drone.
cat > "$T/bin/jmtpfs" <<EOF
#!/bin/bash
if [ "\$1" = -l ]; then
  echo "Available devices (busLocation, devNum, productId, vendorId, product, vendor):"
  [ -e "$T/rc2-on" ] && echo "1, 4, 0x1021, 0x2ca3, RC 2, DJI"
  [ -e "$T/mtp-on" ] && echo "1, 7, 0x1020, 0x2ca3, DJI drone, DJI"
  exit 0
fi
for a; do case "\$a" in -device=*) dev=\${a#-device=};; -*) ;; *) mp=\$a;; esac; done
echo "jmtpfs \${dev:-none}" >> "$T/mount-calls"
[ "\${dev:-}" = "1,7" ] && [ -e "$T/mtp-on" ] || { echo "No mtp devices found" >&2; exit 1; }
cp -a "$T/mtp-drone/." "\$mp/"
echo "jmtpfs \$mp fuse.jmtpfs rw 0 0" >> "$T/proc-mounts"
EOF

# Mass storage mode: while $T/ums-on exists, lsblk lists two DJI drives
# (sdb1 = the SD card, sdc = internal storage), a USB stick that isn't
# DJI (sdd1), and the Pi's own SD card. Mounting copies $T/ums/<name>.
cat > "$T/bin/lsblk" <<EOF
#!/bin/bash
echo 'NAME="/dev/mmcblk0p2" TYPE="part" FSTYPE="ext4" LABEL="rootfs"'
[ -e "$T/ums-on" ] || exit 0
echo 'NAME="/dev/sdb" TYPE="disk" FSTYPE="" LABEL=""'
echo 'NAME="/dev/sdb1" TYPE="part" FSTYPE="exfat" LABEL="SD\x20card"'
echo 'NAME="/dev/sdc" TYPE="disk" FSTYPE="vfat" LABEL=""'
echo 'NAME="/dev/sdd1" TYPE="part" FSTYPE="vfat" LABEL="USB\x20STICK"'
EOF
cat > "$T/bin/udevadm" <<'EOF'
#!/bin/bash
for a; do case "$a" in --name=*) dev=${a#--name=};; esac; done
case "$dev" in
  /dev/sdb*|/dev/sdc*) printf 'ID_BUS=usb\nID_VENDOR_ID=2ca3\nID_MODEL_ID=0020\n' ;;
  /dev/sdd*)           printf 'ID_BUS=usb\nID_VENDOR_ID=0781\nID_MODEL_ID=5567\n' ;;
  *)                   printf 'ID_PATH=platform-mmc\n' ;;
esac
EOF
# Changes made in a mounted folder (deleted files) only reach the fake
# drone if the mount is writable, like a real one: fake-writeback copies
# the folder back to the fake drone when its mount is "rw". MTP mounts are
# always writable; USB drives only after "mount -o remount,rw".
cat > "$T/bin/fake-writeback" <<EOF
#!/bin/bash
mp=\$1
line=\$(grep " \$mp " "$T/proc-mounts" | head -n1)
src=\${line%% *}; opts=\$(echo "\$line" | cut -d" " -f4)
case ",\$opts," in *,rw,*) ;; *) exit 0 ;; esac
if [ "\$src" = jmtpfs ]; then dest="$T/mtp-drone"; else dest="$T/ums/\$(basename "\$src")"; fi
find "\$dest" -mindepth 1 -delete
cp -a "\$mp/." "\$dest/"
EOF
cat > "$T/bin/mount" <<EOF
#!/bin/bash
# mount -o OPTIONS DEVICE FOLDER, or mount -o remount,rw|ro FOLDER
opts=\$2
if [[ \$opts == remount,* ]]; then
  mp=\$3; new=\${opts#remount,}
  echo "remount \$new \$(basename "\$mp")" >> "$T/mount-calls"
  fake-writeback "\$mp"    # changes made while writable are kept
  awk -v mp="\$mp" -v o="\$new" '\$2 == mp { \$4 = o } { print }' "$T/proc-mounts" > "$T/pm.tmp"
  mv "$T/pm.tmp" "$T/proc-mounts"
  exit 0
fi
dev=\$3; mp=\$4
echo "mount \$opts \$dev" >> "$T/mount-calls"
cp -a "$T/ums/\$(basename "\$dev")/." "\$mp/"
echo "\$dev \$mp vfat \$opts 0 0" >> "$T/proc-mounts"
EOF
# umount / fusermount: keep changes if writable, empty the folder, forget the mount
cat > "$T/bin/umount" <<EOF
#!/bin/bash
for a; do mp=\$a; done
grep -q " \$mp " "$T/proc-mounts" || exit 1
fake-writeback "\$mp"
find "\$mp" -mindepth 1 -delete
grep -v " \$mp " "$T/proc-mounts" > "$T/pm.tmp"; mv "$T/pm.tmp" "$T/proc-mounts"
echo "unmounted \$mp" >> "$T/mount-calls"
EOF
cp "$T/bin/umount" "$T/bin/fusermount"

# ---- The fake Immich -------------------------------------------------------------
# A fake curl that answers like Immich. Assets are stored by checksum in
# $T/immich/assets, albums in $T/immich/albums/<id>.name and <id>.list.
# FAKE_IMMICH_DOWN (or the file $T/immich/down): can't connect. Files named *BROKEN* are refused (400).
# FAKE_ALBUM_FAIL: adding to an album fails.
cat > "$T/bin/curl" <<EOF
#!/bin/bash
I="$T/immich"
method=GET; out=/dev/stdout; data=""; hdrs=(); form=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) method=\$2; shift ;;
    -o) out=\$2; shift ;;
    -H) if [[ \$2 == @* ]]; then while IFS= read -r l; do hdrs+=("\$l"); done < "\${2#@}"; else hdrs+=("\$2"); fi; shift ;;
    -F|--form-string) form+=("\$2"); shift ;;
    -d) data=\$2; shift ;;
    -w|--connect-timeout|--max-time|--speed-time|--speed-limit) shift ;;
    -*) ;;
    *) url=\$1 ;;
  esac
  shift
done
hdr() { local h; for h in "\${hdrs[@]}"; do [[ \${h,,} == "\$1: "* ]] && echo "\${h#*: }"; done; }
reply() { printf '%s' "\$2" > "\$out"; printf '%s' "\$1"; exit 0; }
echo "\$method \$url" >> "\$I/requests"
{ [ -n "\${FAKE_IMMICH_DOWN:-}" ] || [ -e "\$I/down" ]; } && { echo "curl: (7) Failed to connect" >&2; printf 000; exit 7; }
path=\${url#*/api}
[ "\$path" = /server/ping ] && reply 200 '{"res":"pong"}'
[ "\$(hdr x-api-key)" = "\$(cat "\$I/key")" ] || reply 401 '{"message":"Invalid API key","statusCode":401}'
case "\$method \$path" in
  "GET /albums")
    for f in "\$I"/albums/*.name; do [ -e "\$f" ] || continue
      jq -cn --arg id "\$(basename "\$f" .name)" --arg n "\$(cat "\$f")" '{id:\$id, albumName:\$n}'
    done | jq -cs . > "\$I/out.json"; reply 200 "\$(cat "\$I/out.json")" ;;
  "POST /albums")
    id="album-\$(ls "\$I/albums" | grep -c name)"
    jq -r .albumName <<< "\$data" > "\$I/albums/\$id.name"; touch "\$I/albums/\$id.list"
    reply 201 "{\"id\":\"\$id\"}" ;;
  "POST /assets")
    for f in "\${form[@]}"; do case "\$f" in
      assetData=@*) file=\${f#assetData=@}; file=\${file#\"}; file=\${file%\"}; file=\${file//\\\\\\\\/\\\\}; file=\${file//\\\\\"/\"} ;;
      filename=*) name=\${f#filename=} ;;
    esac; done
    [ -f "\$file" ] || reply 400 '{"message":"assetData missing"}'
    sum=\$(hdr x-immich-checksum)
    [ "\$sum" = "\$(sha1sum "\$file" | cut -d" " -f1)" ] || reply 400 '{"message":"checksum mismatch"}'
    if [ -e "\$I/assets/\$sum" ]; then reply 200 "{\"id\":\"\$(head -n1 "\$I/assets/\$sum")\",\"status\":\"duplicate\"}"; fi
    case "\$name" in *BROKEN*) reply 400 '{"message":"Unsupported file type"}' ;; esac
    id="asset-\${sum:0:12}"
    printf '%s\n%s\n' "\$id" "\$name" > "\$I/assets/\$sum"
    reply 201 "{\"id\":\"\$id\",\"status\":\"created\"}" ;;
  PUT\ /albums/*/assets)
    [ -n "\${FAKE_ALBUM_FAIL:-}" ] && reply 500 '{"message":"Internal server error"}'
    a=\${path#/albums/}; a=\${a%/assets}
    [ -e "\$I/albums/\$a.list" ] || reply 400 '{"message":"Not found or no album.read access"}'
    id=\$(jq -r '.ids[0]' <<< "\$data")
    if grep -qxF "\$id" "\$I/albums/\$a.list"; then reply 200 "[{\"id\":\"\$id\",\"success\":false,\"error\":\"duplicate\"}]"; fi
    echo "\$id" >> "\$I/albums/\$a.list"
    reply 200 "[{\"id\":\"\$id\",\"success\":true}]" ;;
esac
reply 404 '{"message":"Not found"}'
EOF
chmod +x "$T/bin/"*
echo "TESTKEY" > "$T/immich/key"

export PATH="$T/bin:$PATH"
export DJI_MNT="$T/mnt" DJI_STATE="$T/state" DJI_LOG="$T/sync.log" DJI_CONF="$T/immich.conf" \
       DJI_LOCK_DIR="$T" DJI_PROC_MOUNTS="$T/proc-mounts" DJI_DETECT_WAIT=0 DJI_RETRY_EVERY=1 \
       DJI_FREE_KB=100000000 DJI_KEEP_FREE_MB=0 DJI_REFILL_CHECK_SECONDS=1 DJI_REFILL_GIVE_UP_SECONDS=2

write_conf() { printf 'IMMICH_URL=http://immich.test:2283/\nIMMICH_API_KEY="%s"\nIMMICH_ALBUM=%s\nDELETE_FROM_DRONE=%s\n' "${1:-TESTKEY}" "${2:-Drone Photos}" "${3:-no}" > "$T/immich.conf"; }
# media STORAGE PATH-INSIDE-DCIM [content]: put a file on the fake MTP drone
media() { mkdir -p "$(dirname "$T/mtp-drone/$1/DCIM/$2")"; echo "${3:-photo $1 $2}" > "$T/mtp-drone/$1/DCIM/$2"; }
cached() { find "$T/state/cache" -type f -not -name '.*' 2>/dev/null | wc -l; }
in_album() { cat "$T"/immich/albums/*.list 2>/dev/null | wc -l; }
assets() { find "$T/immich/assets" -type f | wc -l; }
nothing_mounted() { [ ! -s "$T/proc-mounts" ]; }
# hold_lock FILE: hold a lock, like a running sync would, until
# release_lock is called. Waits until the lock is really held, so the
# tests don't depend on timing.
hold_lock() {
  rm -f "$T/held" "$T/release"
  # shellcheck disable=SC2016  # $0 is meant for the inner bash, not this one
  flock "$1" bash -c 'touch "$0/held"; while [ ! -e "$0/release" ]; do sleep 0.1; done' "$T" &
  holder=$!
  while [ ! -e "$T/held" ]; do sleep 0.1; done
}
release_lock() { touch "$T/release"; wait "$holder"; }

touch "$T/mtp-on"
media "SD card" DJI_001/DJI_20260301101500_0001_D.JPG
media "SD card" DJI_001/DJI_20260301101500_0001_D.DNG
media "SD card" DJI_001/DJI_20260301102000_0002_D.MP4
media "SD card" DJI_001/DJI_20260301102000_0002_D.LRF     # low-res preview: skipped
media "SD card" DJI_001/DJI_20260301102000_0002_D.SRT     # subtitles: skipped
media "SD card" DJI_001/.hidden.JPG                       # hidden: skipped
media "Internal shared storage" DJI_001/DJI_0001.JPG "internal one"
media "SD card" 100MEDIA/DJI_0001.JPG "sd one"            # same name, other storage

echo "Immich not set up yet"
bash "$SYNC"; code=$?
check "exit 0 (the files wait safely in the cache)" [ "$code" -eq 0 ]
check "the photos and videos are copied to the cache" [ "$(cached)" -eq 5 ]
check "  ...from both the SD card and internal storage" bash -c "ls '$T/state/cache/Internal shared storage/DJI_001/DJI_0001.JPG' '$T/state/cache/SD card/100MEDIA/DJI_0001.JPG'"
check "  ...but not .LRF, .SRT or hidden files" bash -c "! find '$T/state/cache' -name '*.LRF' -o -name '*.SRT' -o -name '.hidden*' | grep -q ."
check "the drone was mounted by its exact USB position" grep -q "jmtpfs 1,7" "$T/mount-calls"
check "the drone was unmounted" nothing_mounted
check "the log says Immich isn't set up" grep -q "Immich isn't set up yet" "$T/sync.log"
check "nothing was sent to Immich" [ ! -e "$T/immich/requests" ]

echo "Check mode with a wrong API key"
write_conf WRONGKEY
out=$(bash "$SYNC" --check); code=$?
check "exit 1" [ "$code" -eq 1 ]
check "  ...and says the key was rejected" grep -q "rejected the API key" <<< "$out"

echo "Check mode with the right key"
write_conf
out=$(bash "$SYNC" --check); code=$?
check "exit 0" [ "$code" -eq 0 ]
check "  ...says all is OK" grep -q "^OK   Immich at http://immich.test:2283 is reachable" <<< "$out"
check "  ...and doesn't create the album yet" [ -z "$(ls "$T/immich/albums")" ]

echo "15 minute flush once Immich is set up"
bash "$SYNC" --flush; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "the album \"Drone Photos\" was created" grep -qx "Drone Photos" "$T/immich/albums/album-0.name"
check "all 5 files are in Immich" [ "$(assets)" -eq 5 ]
check "  ...and in the album" [ "$(in_album)" -eq 5 ]
check "  ...including both DJI_0001.JPGs (different files, same name)" [ "$(cat "$T"/immich/assets/* | grep -c '^DJI_0001.JPG$')" -eq 2 ]
check "the cache is empty" [ "$(cached)" -eq 0 ]
check "imported.list remembers them" [ "$(wc -l < "$T/state/imported.list")" -eq 5 ]
check "the API key was never on a command line" bash -c "! grep -rq TESTKEY '$T/immich/requests'"

echo "Dock again with nothing new"
: > "$T/immich/requests"
bash "$SYNC"; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "the log says nothing new" grep -q "no new photos or videos on the drone" "$T/sync.log"
check "nothing is copied" [ "$(cached)" -eq 0 ]
check "Immich isn't contacted" [ ! -s "$T/immich/requests" ]
check "the drone was unmounted" nothing_mounted

echo "New flight: dock, copy and upload in one go"
media "SD card" DJI_001/DJI_20260302120000_0003_D.JPG
bash "$SYNC"; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "the new photo is uploaded" grep -q "uploaded: SD card/DJI_001/DJI_20260302120000_0003_D.JPG" "$T/sync.log"
check "  ...into the existing album (no second album)" [ "$(find "$T/immich/albums" -name "*.name" | wc -l)" -eq 1 ]
check "  ...6 in the album now" [ "$(in_album)" -eq 6 ]

echo "A photo that's already in Immich (e.g. uploaded from the phone)"
media "SD card" DJI_001/DJI_20260303090000_0004_D.JPG "phone copy"
sum=$(sha1sum "$T/mtp-drone/SD card/DCIM/DJI_001/DJI_20260303090000_0004_D.JPG" | cut -d' ' -f1)
printf 'asset-from-phone\nphone.jpg\n' > "$T/immich/assets/$sum"
bash "$SYNC"; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "not uploaded again, but added to the album" grep -qx "asset-from-phone" "$T/immich/albums/album-0.list"
check "  ...the log says so" grep -q "already in Immich (added to the album): SD card/DJI_001/DJI_20260303090000_0004_D.JPG" "$T/sync.log"
check "  ...and it left the cache" [ "$(cached)" -eq 0 ]

echo "Immich down when docking: files wait in the cache on the Pi"
media "SD card" DJI_001/DJI_20260304100000_0005_D.JPG
media "SD card" "DJI_001/DJI [weird] name;x.JPG"
FAKE_IMMICH_DOWN=1 bash "$SYNC"; code=$?
check "exit 0 (the files are safe)" [ "$code" -eq 0 ]
check "both files are in the cache" [ "$(cached)" -eq 2 ]
check "the drone was unmounted" nothing_mounted
check "the log says Immich can't be reached" grep -q "can't reach Immich at http://immich.test:2283" "$T/sync.log"

echo "15 minute flush while Immich is still down"
before=$(grep -c "can't reach Immich" "$T/sync.log")
FAKE_IMMICH_DOWN=1 bash "$SYNC" --flush; code=$?
FAKE_IMMICH_DOWN=1 bash "$SYNC" --flush
check "exit 0" [ "$code" -eq 0 ]
check "the files stay in the cache" [ "$(cached)" -eq 2 ]
check "Immich being down isn't logged again every 15 minutes" [ "$(grep -c "can't reach Immich" "$T/sync.log")" -eq "$before" ]

echo "15 minute flush once Immich is back"
bash "$SYNC" --flush; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "the log says Immich is ready again" grep -q "Immich is ready again - uploading 2 file(s)" "$T/sync.log"
check "both are uploaded (odd characters in the name too)" grep -q "uploaded: SD card/DJI_001/DJI \[weird\] name;x.JPG" "$T/sync.log"
check "the cache is empty" [ "$(cached)" -eq 0 ]

echo "15 minute flush with nothing waiting"
size=$(wc -c < "$T/sync.log")
bash "$SYNC" --flush; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "  ...and writes nothing to the log" [ "$(wc -c < "$T/sync.log")" -eq "$size" ]

echo "Immich refuses one file"
media "SD card" DJI_001/DJI_BROKEN.JPG
media "SD card" DJI_001/DJI_20260305100000_0006_D.JPG
bash "$SYNC"; code=$?
check "exit 1" [ "$code" -eq 1 ]
check "the log says why" grep -q "Immich didn't accept SD card/DJI_001/DJI_BROKEN.JPG (HTTP 400: Unsupported file type) - kept in the cache" "$T/sync.log"
check "the refused file stays in the cache" bash -c "ls '$T/state/cache/SD card/DJI_001/DJI_BROKEN.JPG'"
check "the other file was still uploaded" grep -q "uploaded: SD card/DJI_001/DJI_20260305100000_0006_D.JPG" "$T/sync.log"
rm -f "$T/mtp-drone/SD card/DCIM/DJI_001/DJI_BROKEN.JPG" "$T/state/cache/SD card/DJI_001/DJI_BROKEN.JPG"

echo "Adding to the album fails"
media "SD card" DJI_001/DJI_20260306100000_0007_D.JPG
FAKE_ALBUM_FAIL=1 bash "$SYNC"; code=$?
check "exit 1" [ "$code" -eq 1 ]
check "the file stays in the cache" [ "$(cached)" -eq 1 ]
bash "$SYNC" --flush
check "  ...and is put in the album on the next try" [ "$(cached)" -eq 0 ]
check "  ...without being uploaded twice" [ "$(cat "$T"/immich/assets/* | grep -c '^DJI_20260306100000_0007_D.JPG$')" -eq 1 ]

echo "Wrong API key"
media "SD card" DJI_001/DJI_20260307100000_0008_D.JPG
write_conf WRONGKEY
bash "$SYNC"; code=$?
check "exit 1" [ "$code" -eq 1 ]
check "the log says the key was rejected" grep -q "Immich rejected the API key" "$T/sync.log"
check "the file stays in the cache" [ "$(cached)" -eq 1 ]
write_conf
bash "$SYNC" --flush
check "uploaded once the key is fixed" [ "$(cached)" -eq 0 ]

echo "Custom album name"
write_conf TESTKEY "Holiday 2026"
media "SD card" DJI_001/DJI_20260308100000_0009_D.JPG
bash "$SYNC"
check "the new album was made" grep -qx "Holiday 2026" "$T/immich/albums/album-1.name"
check "  ...and the photo is in it" [ "$(wc -l < "$T/immich/albums/album-1.list")" -eq 1 ]
write_conf

echo "Not enough space on the Pi"
mkdir -p "$T/mtp-drone/SD card/DCIM/DJI_002"
head -c 600000 /dev/urandom > "$T/mtp-drone/SD card/DCIM/DJI_002/DJI_20260309100000_0010_D.MP4"
head -c 600000 /dev/urandom > "$T/mtp-drone/SD card/DCIM/DJI_002/DJI_20260309100000_0011_D.MP4"
DJI_FREE_KB=1000 FAKE_IMMICH_DOWN=1 bash "$SYNC"; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "only what fits is copied" [ "$(cached)" -eq 1 ]
check "the log says the rest didn't fit" grep -q "1 file(s) (586KB) didn't fit in the cache on the Pi" "$T/sync.log"
bash "$SYNC"
check "the rest is copied and uploaded on the next dock" bash -c "grep -q 'uploaded: SD card/DJI_002/DJI_20260309100000_0011_D.MP4' '$T/sync.log' && [ \$(find '$T/state/cache' -type f | wc -l) -eq 0 ]"

echo "Ignores the RC 2 controller"
rm -f "$T/mtp-on"; touch "$T/rc2-on"
: > "$T/mount-calls"
bash "$SYNC"; code=$?
check "exit 1 (no drone found)" [ "$code" -eq 1 ]
check "the controller was never mounted" bash -c "! grep -q 'jmtpfs 1,4' '$T/mount-calls'"
check "the log says no drone was found" grep -q "no DCIM folder found on the drone after 0s" "$T/sync.log"

echo "The drone's storage appears a little late"
( sleep 1.5; touch "$T/mtp-on" ) &
DJI_DETECT_WAIT=10 bash "$SYNC"; code=$?
wait
check "waited for it" grep -q "waiting for the drone's storage to appear" "$T/sync.log"
check "  ...then synced normally (exit 0)" [ "$code" -eq 0 ]
rm -f "$T/rc2-on"

echo "Drone that shows up as USB drives (mass storage)"
rm -f "$T/mtp-on"; touch "$T/ums-on"
mkdir -p "$T/ums/sdb1/DCIM/100MEDIA" "$T/ums/sdc/DCIM/100MEDIA" "$T/ums/sdd1/DCIM/100MEDIA"
echo "ums sd" > "$T/ums/sdb1/DCIM/100MEDIA/DJI_0100.JPG"
echo "ums internal" > "$T/ums/sdc/DCIM/100MEDIA/DJI_0100.JPG"
echo "not the drone" > "$T/ums/sdd1/DCIM/100MEDIA/STICK.JPG"
: > "$T/mount-calls"
bash "$SYNC"; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "both drives were mounted read-only" [ "$(grep -c '^mount ro,' "$T/mount-calls")" -eq 2 ]
check "the USB stick and the Pi's own SD card were left alone" bash -c "! grep -q 'sdd1\|mmcblk' '$T/mount-calls'"
check "both photos are uploaded" bash -c "grep -q 'uploaded: SD_card/100MEDIA/DJI_0100.JPG' '$T/sync.log' && grep -q 'uploaded: sdc/100MEDIA/DJI_0100.JPG' '$T/sync.log'"
check "nothing from the USB stick" bash -c "! grep -q STICK '$T/sync.log'"
check "everything was unmounted" nothing_mounted
check "  ...and the empty mount folders removed" bash -c "[ -z \"\$(ls -A '$T/mnt')\" ]"
rm -f "$T/ums-on"; touch "$T/mtp-on"

echo "A leftover mount from a crashed run"
mkdir -p "$T/mnt"
# (marked "ro" so the fake doesn't copy the empty leftover folder back onto the drone)
echo "jmtpfs $T/mnt fuse.jmtpfs ro 0 0" >> "$T/proc-mounts"
bash "$SYNC"; code=$?
check "is removed" grep -q "removing a leftover mount" "$T/sync.log"
check "  ...then syncs normally (exit 0)" [ "$code" -eq 0 ]

echo "Copy fails partway"
media "SD card" DJI_001/DJI_20260310100000_0012_D.JPG
printf '#!/bin/bash\necho "rsync: connection unexpectedly closed" >&2\nexit 12\n' > "$T/bin/rsync"
chmod +x "$T/bin/rsync"
bash "$SYNC"; code=$?
rm -f "$T/bin/rsync"
check "exit 1" [ "$code" -eq 1 ]
check "the log says the copy failed" grep -q "copy from the drone failed (SD card, rsync exit code 12)" "$T/sync.log"
check "the drone was unmounted" nothing_mounted

echo "Stopped partway (e.g. the time limit)"
printf '#!/bin/bash\nsleep 5\n' > "$T/bin/rsync"
chmod +x "$T/bin/rsync"
bash "$SYNC" & pid=$!
sleep 1
pkill -TERM -f "$T/bin/rsync"; kill -TERM "$pid"
wait "$pid"; code=$?
rm -f "$T/bin/rsync"
check "exit 1" [ "$code" -eq 1 ]
check "the log says it was stopped" grep -q "stopped before finishing" "$T/sync.log"
check "  ...and the drone was unmounted" nothing_mounted

echo "Two docks at once"
hold_lock "$T/dji-drone-copy.lock"
DJI_LOCK_WAIT=0 bash "$SYNC"
check "the second is skipped" grep -q "another copy from a drone is already running - skipped" "$T/sync.log"
release_lock

echo "Docking while a long upload is running"
hold_lock "$T/dji-drone-upload.lock"
DJI_LOCK_WAIT=0 bash "$SYNC"; code=$?
check "the copy still happens (exit 0)" [ "$code" -eq 0 ]
check "  ...the file waits in the cache" bash -c "ls '$T/state/cache/SD card/DJI_001/DJI_20260310100000_0012_D.JPG'"
check "  ...and the log says it'll be uploaded soon" grep -q "an upload is already running" "$T/sync.log"
check "a flush during the upload skips its turn" bash -c "bash '$SYNC' --flush; [ \$(find '$T/state/cache' -type f | wc -l) -eq 1 ]"
release_lock
bash "$SYNC" --flush
check "the next flush uploads it" [ "$(cached)" -eq 0 ]

echo "A reused name (e.g. after formatting the card) is still copied"
media "SD card" DJI_001/DJI_20260301101500_0001_D.JPG "a brand new, longer photo after formatting"
bash "$SYNC"
check "the new photo is uploaded" [ "$(grep -c "uploaded: SD card/DJI_001/DJI_20260301101500_0001_D.JPG" "$T/sync.log")" -eq 2 ]

# ==== Deleting from the drone (DELETE_FROM_DRONE=yes) ==========================
on_drone() { [ -e "$T/mtp-drone/SD card/DCIM/$1" ]; }

echo "Deleting is off: nothing is deleted from the drone"
check "the photos uploaded above are all still on the drone" on_drone DJI_001/DJI_20260302120000_0003_D.JPG

echo "Delete from the drone once copied to the Pi (Immich down, so nothing is uploaded)"
write_conf TESTKEY "Drone Photos" yes
media "SD card" DJI_003/DJI_20260320100000_0020_D.JPG
media "SD card" DJI_003/DJI_20260320100500_0021_D.MP4 "a video"
media "SD card" DJI_003/DJI_20260320100500_0021_D.LRF "its preview"
media "SD card" DJI_003/DJI_20260320100500_0021_D.SRT "its subtitles"
FAKE_IMMICH_DOWN=1 bash "$SYNC"; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "the new photo and video are in the cache on the Pi" bash -c "ls '$T/state/cache/SD card/DJI_003/DJI_20260320100000_0020_D.JPG' '$T/state/cache/SD card/DJI_003/DJI_20260320100500_0021_D.MP4'"
check "  ...and deleted from the drone" bash -c "! ls '$T/mtp-drone/SD card/DCIM/DJI_003/'*.JPG '$T/mtp-drone/SD card/DCIM/DJI_003/'*.MP4"
check "  ...along with the video's .LRF preview" bash -c "! ls '$T/mtp-drone/SD card/DCIM/DJI_003/'*.LRF"
check "  ...but the .SRT subtitles are kept" on_drone DJI_003/DJI_20260320100500_0021_D.SRT
check "files already in Immich are deleted from the drone too" bash -c "! ls '$T/mtp-drone/SD card/DCIM/DJI_001/DJI_20260302120000_0003_D.JPG'"
check "  ...from internal storage too" bash -c "! ls '$T/mtp-drone/Internal shared storage/DCIM/DJI_001/DJI_0001.JPG'"
check "the log says how much was freed" grep -q "deleted .* photo(s)/video(s) from the drone" "$T/sync.log"
check "  ...BEFORE it says the drone can be unplugged" bash -c "grep 'deleted .* from the drone\|the drone can be unplugged' '$T/sync.log' | tail -2 | head -1 | grep -q deleted"
check "the drone was unmounted" nothing_mounted
bash "$SYNC" --flush
check "the next flush uploads them" grep -q "uploaded: SD card/DJI_003/DJI_20260320100500_0021_D.MP4" "$T/sync.log"

echo "A file whose copy on the Pi isn't identical is NOT deleted"
media "SD card" DJI_003/CLASH.JPG "the drone's version, longer"
mkdir -p "$T/state/cache/SD card/DJI_003"
echo "pi version" > "$T/state/cache/SD card/DJI_003/CLASH.JPG"
FAKE_IMMICH_DOWN=1 bash "$SYNC"
check "kept on the drone" on_drone DJI_003/CLASH.JPG
check "  ...and the log says why" grep -q "NOT deleted from the drone, because the copy on the Pi isn't identical: SD card/DJI_003/CLASH.JPG" "$T/sync.log"
rm -f "$T/state/cache/SD card/DJI_003/CLASH.JPG" "$T/mtp-drone/SD card/DCIM/DJI_003/CLASH.JPG"

echo "A file that doesn't match what Immich confirmed is NOT deleted"
media "SD card" DJI_003/MISMATCH.JPG "drone"
printf '%s\t%s\t%s\n' 6 0000000000000000000000000000000000000000 "SD card/DJI_003/MISMATCH.JPG" >> "$T/state/imported.list"
media "SD card" DJI_003/OLDLIST.JPG "old"
printf '%s\t%s\n' 4 "SD card/DJI_003/OLDLIST.JPG" >> "$T/state/imported.list"
bash "$SYNC"
check "kept on the drone" on_drone DJI_003/MISMATCH.JPG
check "  ...and the log says why" grep -q "NOT deleted from the drone, because it doesn't match the copy in Immich: SD card/DJI_003/MISMATCH.JPG" "$T/sync.log"
check "a file remembered without a checksum (older list) is kept too" on_drone DJI_003/OLDLIST.JPG

echo "Files that don't fit in the cache stay on the drone"
mkdir -p "$T/mtp-drone/SD card/DCIM/DJI_004"
head -c 700000 /dev/urandom > "$T/mtp-drone/SD card/DCIM/DJI_004/DJI_20260321100000_0030_D.MP4"
head -c 700000 /dev/urandom > "$T/mtp-drone/SD card/DCIM/DJI_004/DJI_20260321100000_0031_D.MP4"
DJI_CACHE_LIMIT_MB=1 FAKE_IMMICH_DOWN=1 bash "$SYNC"; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "only one fits in the 1 MB test cache" [ "$(cached)" -eq 1 ]
check "  ...that one is deleted from the drone" [ "$(find "$T/mtp-drone/SD card/DCIM/DJI_004" -type f | wc -l)" -eq 1 ]
check "  ...the other one stays on the drone" bash -c "ls '$T/mtp-drone/SD card/DCIM/DJI_004/'*_0031_D.MP4"
check "  ...and the log says so" grep -q "1 file(s) (684KB) didn't fit in the cache on the Pi (it holds up to 1.0MB" "$T/sync.log"
DJI_CACHE_LIMIT_MB=1 bash "$SYNC" --flush    # the 15 minute upload empties the cache
DJI_CACHE_LIMIT_MB=1 bash "$SYNC"
check "after the upload, the next dock copies and deletes the other one" bash -c "[ -z \"\$(ls -A '$T/mtp-drone/SD card/DCIM/DJI_004')\" ]"

echo "The cache limit counts what's already waiting in it"
mkdir -p "$T/mtp-drone/SD card/DCIM/DJI_005"
head -c 400000 /dev/urandom > "$T/mtp-drone/SD card/DCIM/DJI_005/DJI_20260322100000_0040_D.MP4"
mkdir -p "$T/state/cache/waiting"
head -c 800000 /dev/urandom > "$T/state/cache/waiting/old.MP4"
DJI_CACHE_LIMIT_MB=1 FAKE_IMMICH_DOWN=1 bash "$SYNC"
check "nothing new is copied (or deleted) when the cache is nearly full" bash -c "ls '$T/mtp-drone/SD card/DCIM/DJI_005/'*.MP4"
rm -rf "$T/state/cache/waiting"

echo "Deleting from a drone that shows up as USB drives (mounted read-only)"
rm -f "$T/mtp-on"; touch "$T/ums-on"
echo "new sd photo" > "$T/ums/sdb1/DCIM/100MEDIA/DJI_0200.JPG"
: > "$T/mount-calls"
FAKE_IMMICH_DOWN=1 bash "$SYNC"; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "the drive was made writable just for deleting" grep -q "remount rw SD_card" "$T/mount-calls"
check "  ...then read-only again" grep -q "remount ro SD_card" "$T/mount-calls"
check "the photos are deleted from both drives" bash -c "[ -z \"\$(find '$T/ums/sdb1/DCIM' '$T/ums/sdc/DCIM' -type f)\" ]"
check "  ...and are in the cache on the Pi" bash -c "ls '$T/state/cache/SD_card/100MEDIA/DJI_0200.JPG'"
check "the USB stick was not touched" bash -c "ls '$T/ums/sdd1/DCIM/100MEDIA/STICK.JPG'"
check "everything was unmounted" nothing_mounted
rm -f "$T/ums-on"; touch "$T/mtp-on"

echo "Check mode shows the drone settings"
out=$(bash "$SYNC" --check)
check "says files are deleted from the drone" grep -q "files ARE deleted from the drone" <<< "$out"
check "  ...and the cache limit (20 GB by default)" grep -q "holds up to 20GB" <<< "$out"

# ==== Refilling the cache while the drone stays plugged in =====================
drone_files() { find "$T/mtp-drone/SD card/DCIM/$1" -type f 2>/dev/null | wc -l; }
big_video() { mkdir -p "$T/mtp-drone/SD card/DCIM/$1"; head -c 600000 /dev/urandom > "$T/mtp-drone/SD card/DCIM/$1/$2"; }

echo "More on the drone than fits: upload, refill, repeat until the drone is empty"
big_video DJI_010 DJI_20260401100000_0100_D.MP4
big_video DJI_010 DJI_20260401100100_0101_D.MP4
big_video DJI_010 DJI_20260401100200_0102_D.MP4
DJI_CACHE_LIMIT_MB=1 bash "$SYNC"; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "all 3 videos were copied, one per round" grep -q "everything has been copied off the drone, in 3 rounds" "$T/sync.log"
check "  ...and all deleted from the drone" [ "$(drone_files DJI_010)" -eq 0 ]
check "  ...and all uploaded" bash -c "[ \$(grep -c 'uploaded: SD card/DJI_010/' '$T/sync.log') -eq 3 ]"
check "the log says to keep the drone plugged in" grep -q "still on the drone - keep it plugged in" "$T/sync.log"
check "'can be unplugged' comes only at the end" bash -c "grep 'everything has been copied off\|the drone can be unplugged' '$T/sync.log' | tail -2 | head -1 | grep -q everything"
check "the drone was unmounted" nothing_mounted

echo "Immich is down at first: waits, then refills once the cache empties"
big_video DJI_011 DJI_20260402100000_0110_D.MP4
big_video DJI_011 DJI_20260402100100_0111_D.MP4
before=$(grep -c "can't reach Immich" "$T/sync.log")
touch "$T/immich/down"
( sleep 2.5; rm -f "$T/immich/down" ) &
DJI_CACHE_LIMIT_MB=1 DJI_REFILL_GIVE_UP_SECONDS=30 bash "$SYNC"; code=$?
wait
check "exit 0" [ "$code" -eq 0 ]
check "it waited, then refilled" grep -q "the cache has room again - refilling it from the drone (round 2)" "$T/sync.log"
check "  ...and the drone is empty" [ "$(drone_files DJI_011)" -eq 0 ]
check "Immich being down was logged once, not at every check" [ "$(grep -c "can't reach Immich" "$T/sync.log")" -eq $((before + 1)) ]

echo "Immich stays down: gives up waiting, the rest stays on the drone"
big_video DJI_012 DJI_20260403100000_0120_D.MP4
big_video DJI_012 DJI_20260403100100_0121_D.MP4
before=$(grep -c "can't reach Immich" "$T/sync.log")
DJI_CACHE_LIMIT_MB=1 FAKE_IMMICH_DOWN=1 DJI_REFILL_GIVE_UP_SECONDS=3 bash "$SYNC"; code=$?
check "exit 0 (nothing is lost)" [ "$code" -eq 0 ]
check "the log says why it stopped" grep -q "stopped refilling: 1 file(s) (586KB) are still on the drone, because the cache on the Pi hasn't emptied" "$T/sync.log"
check "  ...one video is in the cache, one still on the drone" bash -c "[ \$(drone_files() { find '$T/mtp-drone/SD card/DCIM/DJI_012' -type f | wc -l; }; drone_files) -eq 1 ]"
check "'Immich is down' was logged once, not every check" [ "$(grep -c "can't reach Immich" "$T/sync.log")" -eq $((before + 1)) ]
check "the drone was unmounted" nothing_mounted
bash "$SYNC" --flush
DJI_CACHE_LIMIT_MB=1 bash "$SYNC"
check "the next dock copies the rest" [ "$(drone_files DJI_012)" -eq 0 ]

echo "The drone is unplugged while waiting"
big_video DJI_013 DJI_20260404100000_0130_D.MP4
big_video DJI_013 DJI_20260404100100_0131_D.MP4
(
  # Like pulling the cable: the drone's folders vanish (marked "ro" so
  # the fake doesn't copy the empty folder back onto the drone)
  sleep 1.5
  fake-writeback "$T/mnt"    # deletes on a real MTP drone happen straight away
  awk -v mp="$T/mnt" '$2 == mp { $4 = "ro" } { print }' "$T/proc-mounts" > "$T/pm2.tmp"; mv "$T/pm2.tmp" "$T/proc-mounts"
  find "$T/mnt" -mindepth 1 -delete
) &
DJI_CACHE_LIMIT_MB=1 FAKE_IMMICH_DOWN=1 DJI_REFILL_GIVE_UP_SECONDS=30 bash "$SYNC"; code=$?
wait
check "exit 0" [ "$code" -eq 0 ]
check "the log says it was unplugged" grep -q "the drone was unplugged - 1 file(s) (586KB) are still on it" "$T/sync.log"
check "  ...and the file not copied is still on the drone" [ "$(drone_files DJI_013)" -eq 1 ]
bash "$SYNC" --flush
DJI_CACHE_LIMIT_MB=1 bash "$SYNC"

echo "A file too big for the cache, even when it's empty"
mkdir -p "$T/mtp-drone/SD card/DCIM/DJI_014"
head -c 1500000 /dev/urandom > "$T/mtp-drone/SD card/DCIM/DJI_014/DJI_20260405100000_0140_D.MP4"
DJI_CACHE_LIMIT_MB=1 bash "$SYNC"; code=$?
check "exit 0, without waiting" [ "$code" -eq 0 ]
check "the log says it's too big" grep -q "because they're too big to fit in the cache on the Pi, even when it's empty" "$T/sync.log"
check "  ...and it stays on the drone" [ "$(drone_files DJI_014)" -eq 1 ]
rm -rf "$T/mtp-drone/SD card/DCIM/DJI_014"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
