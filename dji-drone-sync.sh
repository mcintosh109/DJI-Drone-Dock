#!/bin/bash
# DJI drone photo and video dock.
#
#   dji-drone-sync.sh           dock mode: run by udev when the drone is plugged in
#   dji-drone-sync.sh --flush   flush mode: run every 15 minutes by dji-drone-flush.timer
#   dji-drone-sync.sh --check   checks the Immich settings and prints the result
#
# Dock mode finds the drone's storage (its SD card AND its internal storage),
# copies new photos and videos into a cache on the Pi's SD card
# (/var/lib/dji-drone/cache), unmounts the drone, then uploads the cache to
# Immich, into an album (default "Drone Photos"). If Immich is down, the
# files wait safely in the cache, and flush mode uploads them once it's back.
#
# DJI drones show up on a computer in one of two ways, depending on the model:
#   - as USB drives ("mass storage"): one drive per storage. These are
#     mounted READ-ONLY, so nothing on the drone can be changed.
#   - as an MTP device (like a phone, or the RC 2 controller): mounted
#     with jmtpfs. The script only ever reads from it.
# Both are tried, and every DCIM folder found is copied.
#
# Safeguards:
#   - nothing on the drone is ever changed or deleted
#   - only DJI devices are touched (USB vendor ID 2ca3), and never the RC 2
#     controller (product 1021), so this can share a Pi with the RC 2 dock
#   - a cached file is only deleted once Immich confirms it has it, and it
#     has been added to the album
#   - Immich itself recognises files it already has (by their checksum),
#     so nothing is ever uploaded twice
#   - it leaves KEEP_FREE_MB of space free on the Pi, so a big video can't
#     fill up the SD card; what didn't fit is copied on a later dock
#   - files are copied under a hidden name and renamed when complete, and
#     hidden files are never uploaded, so half-copied files are never sent
#   - the drone is always unmounted, even if something goes wrong
#   - the Immich API key is never put on a command line (where any user
#     of the Pi could see it with `ps`)
#
# Exit codes (shown by `systemctl status dji-drone-sync.service`):
#   0 = success, nothing to do, or Immich is down / not set up yet and the
#       files are waiting safely in the cache
#   1 = the drone could not be found, a copy or upload failed, the API key
#       was rejected, or the sync was stopped
set -u

# The DJI_* variables are only for the tests (tests/test-drone-sync.sh).
MNT=${DJI_MNT:-/mnt/drone}
STATE=${DJI_STATE:-/var/lib/dji-drone}   # on the Pi's SD card
CACHE=$STATE/cache                       # files waiting to be uploaded to Immich
IMPORTED=$STATE/imported.list            # files already in Immich: "size<TAB>path"
WAITING_FLAG=$STATE/immich-waiting       # exists while uploads can't happen (so it's logged once)
LOG=${DJI_LOG:-/var/log/dji-drone-sync.log}
CONF=${DJI_CONF:-/etc/dji-drone/immich.conf}
LOCK_DIR=${DJI_LOCK_DIR:-/run}
COPY_LOCK=$LOCK_DIR/dji-drone-copy.lock
UPLOAD_LOCK=$LOCK_DIR/dji-drone-upload.lock
LOCK_WAIT=${DJI_LOCK_WAIT:-300}          # dock mode: seconds to wait for a running sync
DETECT_WAIT=${DJI_DETECT_WAIT:-120}      # seconds to wait for the drone's storage to appear
RETRY_EVERY=${DJI_RETRY_EVERY:-10}       # seconds between tries while waiting
VENDOR=${DJI_VENDOR:-2ca3}               # DJI's USB vendor ID
SKIP_PRODUCTS=${DJI_SKIP_PRODUCTS:-1021} # USB product IDs to ignore (1021 = RC 2 controller)
KEEP_FREE_MB=${DJI_KEEP_FREE_MB:-2048}   # always leave this much space free on the Pi
PROC_MOUNTS=${DJI_PROC_MOUNTS:-/proc/mounts}
FREE_KB_OVERRIDE=${DJI_FREE_KB:-}        # tests only: pretend this much space is free
DEVICE_ID=dji-drone-dock                 # how this dock names itself to Immich

MODE=dock
case "${1:-}" in
  --flush) MODE=flush ;;
  --check) MODE=check ;;
esac

log() {
  if [ "$MODE" = check ]; then echo "$*"; else echo "$(date) - $*" >> "$LOG"; fi
}

# A private scratch folder (only root can read it), removed at the end
TMP=$(mktemp -d)
RESP=$TMP/response.json   # the body of Immich's last reply
HEADERS=$TMP/headers      # holds the API key header

# ---- Helpers -----------------------------------------------------------------

# True if the file name ends in a photo or video type Immich understands.
# Skipped on purpose: .LRF (low-resolution video previews) and .SRT
# (flight data subtitles).
is_media() {
  case "${1,,}" in
    *.jpg|*.jpeg|*.dng|*.heic|*.heif|*.tif|*.tiff|*.mp4|*.mov) return 0 ;;
  esac
  return 1
}

# True if two hex numbers are equal, e.g. "0x2ca3" and "2CA3"
hex_eq() {
  local a=${1// /} b=${2// /}
  a=${a#0x}; a=${a#0X}; b=${b#0x}; b=${b#0X}
  [[ $a =~ ^[0-9a-fA-F]+$ && $b =~ ^[0-9a-fA-F]+$ ]] || return 1
  [ $((16#$a)) -eq $((16#$b)) ]
}

# True if this USB product ID is one we must leave alone (e.g. the RC 2)
is_skipped_product() {
  local s
  for s in $SKIP_PRODUCTS; do hex_eq "$1" "$s" && return 0; done
  return 1
}

# Turn a drive label into a safe folder name: letters, digits, . _ - only
safe_name() {
  local n
  n=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
  n=${n##.}            # no hidden folder names
  printf '%s' "$n"
}

# A size in bytes, written for people: e.g. 586KB, 1.2GB
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

# How many files are waiting in the cache (hidden, half-copied files don't count)
cached_count() { find "$CACHE" -type f -not -name '.*' 2>/dev/null | wc -l; }

# ---- Mounting the drone ------------------------------------------------------

# Everything mounted at or under $MNT, deepest first. Read from the
# kernel's own list, which still works when a mount is broken.
mounts_under_mnt() {
  awk -v m="$MNT" '$2 == m || index($2, m "/") == 1 { print $2 }' "$PROC_MOUNTS" 2>/dev/null | sort -r
}

# Unmount everything under $MNT. Tries a normal unmount first, then a
# "lazy" one, which finishes as soon as nothing is using the drone.
unmount_all() {
  local m
  while IFS= read -r m; do
    umount "$m" 2>/dev/null || fusermount -u "$m" 2>/dev/null ||
      fusermount -uz "$m" 2>/dev/null || umount -l "$m" 2>/dev/null ||
      log "could not unmount $m"
  done < <(mounts_under_mnt)
  # Remove the empty folders made for each drive (never anything with files in it)
  find "$MNT" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
}

# Lists the drone's USB drives (mass storage), one per line: "device<TAB>label".
# lsblk lists every drive; udevadm tells us which USB device each belongs
# to. Only drives of a DJI device that isn't the controller are listed.
find_mass_storage() {
  local line dev type fstype label props vendor product
  while IFS= read -r line; do
    [[ $line =~ NAME=\"([^\"]*)\"\ TYPE=\"([^\"]*)\"\ FSTYPE=\"([^\"]*)\"\ LABEL=\"([^\"]*)\" ]] || continue
    dev=${BASH_REMATCH[1]}; type=${BASH_REMATCH[2]}
    fstype=${BASH_REMATCH[3]}; label=${BASH_REMATCH[4]}
    case "$type" in part|disk) ;; *) continue ;; esac
    [ -n "$fstype" ] || continue      # no filesystem: nothing to mount
    props=$(udevadm info --query=property --name="$dev" 2>/dev/null) || continue
    vendor=$(sed -n 's/^ID_VENDOR_ID=//p' <<< "$props")
    product=$(sed -n 's/^ID_MODEL_ID=//p' <<< "$props")
    hex_eq "$vendor" "$VENDOR" || continue
    is_skipped_product "$product" && continue
    # lsblk writes some characters in labels as \xNN; printf %b turns them back
    printf '%s\t%b\n' "$dev" "$label"
  done < <(lsblk -pPno NAME,TYPE,FSTYPE,LABEL 2>/dev/null)
}

# Mount the drone's storage under $MNT. Returns 0 if anything was mounted.
# On failure, MOUNT_ERR says what went wrong.
mount_drone() {
  local dev label name base n=0 n2 err bus devnum f3 f4 product
  MOUNT_ERR=""

  # 1. USB drives (mass storage): each one at $MNT/<its label>, read-only
  while IFS=$'\t' read -r dev label; do
    name=$(safe_name "$label")
    [ -n "$name" ] || name=$(basename "$dev")
    base=$name; n2=2
    while [ -e "$MNT/$name" ]; do name="$base-$n2"; n2=$((n2 + 1)); done
    mkdir -p "$MNT/$name"
    if err=$(mount -o ro,nosuid,nodev,noexec "$dev" "$MNT/$name" 2>&1); then
      log "mounted $dev ($name) read-only"
      n=$((n + 1))
    else
      MOUNT_ERR="$dev: $err"
      rmdir "$MNT/$name" 2>/dev/null
    fi
  done < <(find_mass_storage)
  [ "$n" -gt 0 ] && return 0

  # 2. MTP. `jmtpfs -l` lists devices as:
  #    busLocation, devNum, productId, vendorId, product, vendor
  # Only a DJI device that isn't the controller is mounted, picked by
  # its exact USB position, so a docked RC 2 is never mounted by mistake.
  while IFS=, read -r bus devnum f3 f4 _; do
    bus=${bus// /}; devnum=${devnum// /}
    [[ $bus =~ ^[0-9]+$ && $devnum =~ ^[0-9]+$ ]] || continue
    if hex_eq "$f4" "$VENDOR"; then product=$f3
    elif hex_eq "$f3" "$VENDOR"; then product=$f4
    else continue
    fi
    is_skipped_product "$product" && continue
    if err=$(jmtpfs -device="$bus,$devnum" "$MNT" 2>&1); then
      log "mounted the drone over MTP (USB $bus,$devnum)"
      return 0
    fi
    MOUNT_ERR=$err
  done < <(jmtpfs -l 2>/dev/null)
  return 1
}

# ---- Talking to Immich -------------------------------------------------------

# Read one setting (NAME=value) from the config file, without running it.
# Quotes around the value are allowed.
conf_get() {
  [ -r "$CONF" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | tail -n 1 |
    sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# api METHOD PATH [more curl options...]
# Calls Immich. Its reply goes into $RESP; the HTTP status code is printed
# (000 means Immich couldn't be reached at all). The API key is read from
# a file (-H @file), so it never appears on a command line.
api() {
  local method=$1 path=$2
  shift 2
  curl -sS -o "$RESP" -w '%{http_code}' -X "$method" -H @"$HEADERS" \
    --connect-timeout 15 "$@" "$IMMICH_URL/api$path" 2>> "$TMP/curl-errors"
}

# Immich's error message from its last reply, if it gave one
api_message() {
  local m
  m=$(jq -r '.message // empty | if type == "array" then join("; ") else . end' "$RESP" 2>/dev/null)
  [ -n "$m" ] || m=$(tail -n 1 "$TMP/curl-errors" 2>/dev/null)
  printf '%s' "$m"
}

# Log why uploads are waiting - once, not every 15 minutes. $1 is a short
# reason id, so a new reason is still logged.
waiting() {
  if [ "$MODE" != flush ] || [ "$(cat "$WAITING_FLAG" 2>/dev/null)" != "$1" ]; then
    log "$2"
  fi
  [ "$MODE" = check ] || echo "$1" > "$WAITING_FLAG"
}

# Read the settings and check Immich can be reached, the API key works,
# and find (or create) the album. Sets ALBUM_ID. Returns:
#   0 = ready   2 = not set up / unreachable (files wait)   1 = error
connect_immich() {
  local code
  IMMICH_URL=$(conf_get IMMICH_URL)
  IMMICH_URL=${IMMICH_URL%/}; IMMICH_URL=${IMMICH_URL%/api}
  local key; key=$(conf_get IMMICH_API_KEY)
  ALBUM=$(conf_get IMMICH_ALBUM)
  [ -n "$ALBUM" ] || ALBUM="Drone Photos"

  if [ -z "$IMMICH_URL" ] || [ -z "$key" ]; then
    waiting setup "Immich isn't set up yet: add IMMICH_URL and IMMICH_API_KEY to $CONF - $(cached_count) file(s) kept in the cache on the Pi"
    return 2
  fi
  # umask 077: the header file is readable by root only
  (umask 077; printf 'x-api-key: %s\n' "$key" > "$HEADERS")

  code=$(api GET /server/ping --max-time 20)
  if [ "$code" != 200 ]; then
    waiting down "can't reach Immich at $IMMICH_URL (HTTP $code: $(api_message)) - $(cached_count) file(s) kept in the cache on the Pi, retrying every 15 minutes"
    return 2
  fi

  code=$(api GET /albums --max-time 60)
  case "$code" in
    200) ;;
    401)
      waiting key "Immich rejected the API key - check IMMICH_API_KEY in $CONF ($(cached_count) file(s) kept in the cache)"
      return 1 ;;
    403)
      waiting perm "the Immich API key is missing a permission ($(api_message)) - it needs: asset.upload, album.read, album.create, albumAsset.create"
      return 1 ;;
    *)
      log "could not read the albums from Immich (HTTP $code: $(api_message))"
      return 1 ;;
  esac

  ALBUM_ID=$(jq -r --arg n "$ALBUM" '[.[] | select(.albumName == $n)][0].id // empty' "$RESP" 2>/dev/null)
  if [ -z "$ALBUM_ID" ]; then
    if [ "$MODE" = check ]; then
      log "OK   the album \"$ALBUM\" doesn't exist yet - it will be created on the first upload"
      return 0
    fi
    code=$(api POST /albums --max-time 60 -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg n "$ALBUM" '{albumName: $n}')")
    ALBUM_ID=$(jq -r '.id // empty' "$RESP" 2>/dev/null)
    if [ "$code" != 201 ] && [ "$code" != 200 ] || [ -z "$ALBUM_ID" ]; then
      log "could not create the album \"$ALBUM\" in Immich (HTTP $code: $(api_message))"
      return 1
    fi
    log "created the album \"$ALBUM\" in Immich"
  fi
  # An ID is used in a web address below, so make sure it's only letters, digits and -
  if ! [[ $ALBUM_ID =~ ^[A-Za-z0-9-]+$ ]]; then
    log "Immich returned an album ID that doesn't look right: $ALBUM_ID"
    return 1
  fi
  return 0
}

# ---- Check mode: test the settings and print the result ------------------------
if [ "$MODE" = check ]; then
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$STATE" 2>/dev/null
  if [ ! -r "$CONF" ]; then
    echo "!!   can't read $CONF (run this with sudo, and see the README: Set up Immich)"
    exit 1
  fi
  connect_immich; status=$?
  if [ "$status" -eq 0 ]; then
    echo "OK   Immich at $IMMICH_URL is reachable, the API key works, and uploads go to the album \"$ALBUM\""
  fi
  echo "     $(cached_count) file(s) are waiting in the cache on the Pi"
  [ "$status" -eq 0 ]
  exit
fi

# ---- Only one copy and one upload at a time --------------------------------------
# Copying from the drone and uploading to Immich use separate locks, so
# docking the drone is never held up by a long upload that's running.
exec 8>"$COPY_LOCK"
exec 9>"$UPLOAD_LOCK"

# COPYING is "yes" only while this run is copying from the drone, so that
# a run that has moved on to uploading never unmounts another dock's drone.
COPYING=no
cleanup() {
  [ "$COPYING" = yes ] && unmount_all
  rm -rf "$TMP"
}
trap cleanup EXIT
# If systemd stops the script (e.g. the time limit is hit), exit normally
# so that cleanup still runs and the drone is unmounted.
trap 'log "stopped before finishing (time limit or shutdown)"; exit 1' TERM INT

if ! mkdir -p "$CACHE" 2>> "$LOG"; then
  log "cannot create the cache folder $CACHE"
  exit 1
fi
touch "$IMPORTED"
COPY_FAILED=0

# ==== Dock mode: drone -> cache =================================================
if [ "$MODE" = dock ]; then
  if ! flock -w "$LOCK_WAIT" 8; then
    log "another copy from a drone is already running - skipped"
    exit 0
  fi
  COPYING=yes
  log "DJI drone detected"
  mkdir -p "$MNT"

  # A mount left behind by an interrupted run would get in the way
  if [ -n "$(mounts_under_mnt)" ]; then
    log "removing a leftover mount at $MNT"
    unmount_all
  fi

  # Mount the drone and find its DCIM folders (one per storage). The
  # storage can take a few seconds to appear, so keep trying every
  # RETRY_EVERY seconds until DETECT_WAIT runs out.
  WAITED=0
  DCIMS=()
  while true; do
    if mount_drone; then
      mapfile -t DCIMS < <(find "$MNT" -mindepth 1 -maxdepth 3 -type d -iname DCIM 2>/dev/null | sort)
      [ "${#DCIMS[@]}" -gt 0 ] && break
      MOUNT_ERR="the drone's storage was mounted, but has no DCIM folder"
      unmount_all
    fi
    if [ "$WAITED" -ge "$DETECT_WAIT" ]; then
      [ -n "$MOUNT_ERR" ] && log "last mount error: $MOUNT_ERR"
      log "no DCIM folder found on the drone after ${DETECT_WAIT}s - is the drone plugged in (with a data cable) and switched on?"
      exit 1
    fi
    [ "$WAITED" -eq 0 ] && log "waiting for the drone's storage to appear..."
    sleep "$RETRY_EVERY"
    WAITED=$((WAITED + RETRY_EVERY))
  done

  # Files already in Immich are remembered as "size<TAB>path", so they
  # aren't copied again. The size is included so that a new photo that
  # happens to reuse an old name (e.g. after formatting the card) is still copied.
  declare -A IN_IMMICH=()
  while IFS=$'\t' read -r size key; do
    [ -n "$key" ] && IN_IMMICH["$size"$'\t'"$key"]=1
  done < "$IMPORTED"

  # How much may be copied: the free space on the Pi, minus KEEP_FREE_MB
  if [ -n "$FREE_KB_OVERRIDE" ]; then free_kb=$FREE_KB_OVERRIDE
  else free_kb=$(df -Pk "$CACHE" | awk 'NR == 2 { print $4 }')
  fi
  BUDGET=$(( free_kb * 1024 - KEEP_FREE_MB * 1024 * 1024 ))

  NEW=0; NEW_BYTES=0; NO_ROOM=0; NO_ROOM_BYTES=0; i=0
  for dcim in "${DCIMS[@]}"; do
    # The storage's name is the first folder under $MNT, e.g. "SD_card".
    # Files go into the cache as <storage>/<path inside DCIM>, so a
    # DJI_0001.JPG on the SD card and one in internal storage don't clash.
    storage=${dcim#"$MNT"/}
    if [ "$storage" = "${storage%%/*}" ]; then storage=drone   # DCIM directly at the top
    else storage=${storage%%/*}
    fi
    i=$((i + 1))
    want=$TMP/want-$i
    : > "$want"
    while IFS=$'\t' read -r size rel; do
      case "/$rel" in */.*) continue ;; esac     # hidden files and folders
      is_media "$rel" || continue
      key="$storage/$rel"
      [ -n "${IN_IMMICH["$size"$'\t'"$key"]+x}" ] && continue   # already in Immich
      if [ -e "$CACHE/$key" ]; then
        # Already waiting in the cache. A different file with the same
        # name is left on the drone for now, so the waiting one isn't replaced.
        if [ "$(stat -c %s "$CACHE/$key")" != "$size" ]; then
          log "not copied yet: a different file with the same name is waiting in the cache: $key"
        fi
        continue
      fi
      if [ "$size" -gt "$BUDGET" ]; then
        NO_ROOM=$((NO_ROOM + 1)); NO_ROOM_BYTES=$((NO_ROOM_BYTES + size))
        continue
      fi
      BUDGET=$((BUDGET - size))
      NEW=$((NEW + 1)); NEW_BYTES=$((NEW_BYTES + size))
      printf '%s\n' "$rel" >> "$want"
    done < <(find "$dcim" -type f -printf '%s\t%P\n' 2>> "$LOG" | sort -t $'\t' -k 2)

    if [ -s "$want" ]; then
      mkdir -p "$CACHE/$storage"
      # rsync copies just the listed files, writing each one under a hidden
      # temporary name and renaming it when done. -t keeps each file's date.
      rsync -t --ignore-existing --files-from="$want" "$dcim"/ "$CACHE/$storage"/ 2>> "$LOG" || {
        st=$?
        log "copy from the drone failed ($storage, rsync exit code $st) - files fully copied before the error are kept"
        COPY_FAILED=1
      }
    fi
  done
  unmount_all   # finished with the drone: it can be unplugged now
  COPYING=no

  if [ "$NEW" -eq 0 ] && [ "$NO_ROOM" -eq 0 ]; then
    log "no new photos or videos on the drone"
  else
    log "copied $NEW new photo(s)/video(s) from the drone ($(human "$NEW_BYTES")) - the drone can be unplugged"
  fi
  if [ "$NO_ROOM" -gt 0 ]; then
    log "$NO_ROOM file(s) ($(human "$NO_ROOM_BYTES")) didn't fit on the Pi (it keeps ${KEEP_FREE_MB} MB free) - dock the drone again after the upload to copy the rest"
  fi
  # Let another dock start copying, while this one uploads
  flock -u 8
else
  # Flush mode: quietly do nothing if no files are waiting
  [ "$(cached_count)" -eq 0 ] && exit 0
fi

# ==== Cache -> Immich =================================================================
if [ "$MODE" = dock ]; then
  if ! flock -w "$LOCK_WAIT" 9; then
    log "an upload is already running - the new files will be uploaded within 15 minutes"
    exit "$COPY_FAILED"
  fi
else
  # A flush simply skips its turn if an upload is running
  flock -n 9 || exit 0
fi

COUNT=$(cached_count)
if [ "$COUNT" -eq 0 ]; then
  [ "$MODE" = dock ] && log "nothing waiting to upload"
  exit "$COPY_FAILED"
fi

connect_immich; status=$?
if [ "$status" -eq 2 ]; then exit "$COPY_FAILED"; fi   # files wait in the cache
if [ "$status" -ne 0 ]; then exit 1; fi

if [ -e "$WAITING_FLAG" ]; then
  log "Immich is ready again - uploading $COUNT file(s) from the cache"
  rm -f "$WAITING_FLAG"
fi
log "uploading $COUNT file(s) to the Immich album \"$ALBUM\"..."

UPLOADED=0; DUPES=0; FAILED=0
# The list of files is read on file descriptor 3, so curl can't swallow it
while IFS= read -r -d '' f <&3; do
  key=${f#"$CACHE"/}
  size=$(stat -c %s "$f")
  # The checksum lets Immich spot a file it already has before it's sent
  sum=$(sha1sum "$f" | cut -d ' ' -f 1)
  when=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%S.000Z)
  # curl needs " and \ in the file's path escaped inside the quotes
  esc=${f//\\/\\\\}; esc=${esc//\"/\\\"}

  # Immich reads the real date and GPS position from the photo itself;
  # the file's date is only a fallback. deviceAssetId and deviceId are
  # needed by older versions of Immich, and ignored by newer ones.
  # --speed-time/--speed-limit give up if nothing is sent for 2 minutes.
  code=$(api POST /assets -H "x-immich-checksum: $sum" \
    -F "assetData=@\"$esc\"" \
    --form-string "deviceAssetId=$key-$size" \
    --form-string "deviceId=$DEVICE_ID" \
    --form-string "fileCreatedAt=$when" \
    --form-string "fileModifiedAt=$when" \
    --form-string "filename=$(basename "$f")" \
    --speed-time 120 --speed-limit 1)

  case "$code" in
    200|201) ;;
    000)
      log "lost the connection to Immich ($(api_message)) - the rest stay in the cache and are retried within 15 minutes"
      FAILED=$((FAILED + 1)); break ;;
    401|403)
      log "Immich refused the upload (HTTP $code: $(api_message)) - check the API key and its permissions"
      FAILED=$((FAILED + 1)); break ;;
    *)
      log "Immich didn't accept $key (HTTP $code: $(api_message)) - kept in the cache"
      FAILED=$((FAILED + 1)); continue ;;
  esac
  status=$(jq -r '.status // empty' "$RESP" 2>/dev/null)
  id=$(jq -r '.id // empty' "$RESP" 2>/dev/null)
  if ! [[ $id =~ ^[A-Za-z0-9-]+$ ]]; then
    log "Immich's reply for $key had no asset ID - kept in the cache"
    FAILED=$((FAILED + 1)); continue
  fi

  # Put it in the album. "duplicate" here means it was already in the album.
  code=$(api PUT "/albums/$ALBUM_ID/assets" --max-time 60 \
    -H 'Content-Type: application/json' -d "$(jq -cn --arg id "$id" '{ids: [$id]}')")
  ok=$(jq -r '.[0] | (.success == true or .error == "duplicate")' "$RESP" 2>/dev/null)
  if [ "$code" != 200 ] || [ "$ok" != true ]; then
    log "uploaded $key, but could not add it to the album (HTTP $code: $(api_message)) - kept in the cache, retried later"
    FAILED=$((FAILED + 1)); continue
  fi

  # Confirmed: remember it, then remove it from the cache
  printf '%s\t%s\n' "$size" "$key" >> "$IMPORTED"
  rm -f "$f"
  if [ "$status" = duplicate ]; then
    DUPES=$((DUPES + 1))
    log "already in Immich (added to the album): $key"
  else
    UPLOADED=$((UPLOADED + 1))
    log "uploaded: $key"
  fi
done 3< <(find "$CACHE" -type f -not -name '.*' -print0 | sort -z)
find "$CACHE" -mindepth 1 -type d -empty -delete 2>/dev/null

log "Immich: $UPLOADED uploaded, $DUPES were already there, $(cached_count) left in the cache"
if [ "$COPY_FAILED" -ne 0 ] || [ "$FAILED" -ne 0 ]; then
  log "done, with errors (see above)"
  exit 1
fi
log "done"
