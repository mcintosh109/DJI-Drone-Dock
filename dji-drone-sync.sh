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
# With DELETE_FROM_DRONE=yes (the installer asks), each file is deleted from
# the drone as soon as its copy in the cache has been checked byte for byte,
# BEFORE the upload, so the drone's storage is free when it's unplugged.
# Until the upload finishes, the cache on the Pi holds the only copy.
#
# DJI drones show up on a computer in one of two ways, depending on the model:
#   - as USB drives ("mass storage"): one drive per storage. These are
#     mounted READ-ONLY, so nothing on the drone can be changed.
#   - as an MTP device (like a phone, or the RC 2 controller): mounted
#     with jmtpfs. The script only ever reads from it.
# Both are tried, and every DCIM folder found is copied.
#
# Safeguards:
#   - nothing on the drone is changed, unless DELETE_FROM_DRONE=yes. Then a
#     file is only deleted from the drone once the copy in the cache has
#     been compared with it byte for byte (or, for a file that's already in
#     Immich, its checksum matches the one Immich confirmed). Files that
#     didn't fit in the cache are never deleted.
#   - only DJI devices are touched (USB vendor ID 2ca3), and never the RC 2
#     controller (product 1021), so this can share a Pi with the RC 2 dock
#   - a cached file is only deleted once Immich confirms it has it, and it
#     has been added to the album
#   - Immich itself recognises files it already has (by their checksum),
#     so nothing is ever uploaded twice
#   - the cache holds at most CACHE_LIMIT_GB (default 20 GB), and it always
#     leaves KEEP_FREE_GB (default 5 GB) free on the Pi, for the system and
#     other programs like the RC 2 dock, so big videos can't fill up the
#     SD card; what didn't fit stays on the drone for a later dock
#   - files are copied under a hidden name and renamed when complete, and
#     hidden files are never uploaded, so half-copied files are never sent
#   - while files are left on the drone because the cache was full, the
#     drone stays mounted: the cache is uploaded, and every
#     REFILL_CHECK_MINUTES it checks if the cache has emptied, then refills
#     it, until the drone is empty (or it's unplugged, or it gives up after
#     REFILL_GIVE_UP_HOURS)
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
IMPORTED=$STATE/imported.list            # files already in Immich: "size<TAB>checksum<TAB>path"
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
KEEP_FREE_MB_OVERRIDE=${DJI_KEEP_FREE_MB:-}  # tests only: the space to keep free, in MB
PROC_MOUNTS=${DJI_PROC_MOUNTS:-/proc/mounts}
FREE_KB_OVERRIDE=${DJI_FREE_KB:-}        # tests only: pretend this much space is free
CACHE_LIMIT_MB_OVERRIDE=${DJI_CACHE_LIMIT_MB:-}  # tests only: a cache limit smaller than 1 GB
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

# A time in seconds, written for people: e.g. 30 s, 5 min, 12 hour(s)
human_time() {
  if [ "$1" -ge 3600 ]; then echo "$(( $1 / 3600 )) hour(s)"
  elif [ "$1" -ge 60 ]; then echo "$(( $1 / 60 )) min"
  else echo "$1 s"
  fi
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
# On failure, MOUNT_ERR says what went wrong. USB_DRIVES holds the names of
# storages that are USB drives (mounted read-only).
declare -A USB_DRIVES=()
mount_drone() {
  local dev label name base n=0 n2 err bus devnum f3 f4 product
  MOUNT_ERR=""
  USB_DRIVES=()

  # 1. USB drives (mass storage): each one at $MNT/<its label>, read-only
  while IFS=$'\t' read -r dev label; do
    name=$(safe_name "$label")
    [ -n "$name" ] || name=$(basename "$dev")
    base=$name; n2=2
    while [ -e "$MNT/$name" ]; do name="$base-$n2"; n2=$((n2 + 1)); done
    mkdir -p "$MNT/$name"
    if err=$(mount -o ro,nosuid,nodev,noexec "$dev" "$MNT/$name" 2>&1); then
      log "mounted $dev ($name) read-only"
      USB_DRIVES["$name"]=1
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

# The storage a DCIM folder is on: the first folder under $MNT, e.g.
# "SD_card". Files go into the cache as <storage>/<path inside DCIM>, so a
# DJI_0001.JPG on the SD card and one in internal storage don't clash.
storage_of() {
  local s=${1#"$MNT"/}
  if [ "$s" = "${s%%/*}" ]; then echo drone   # DCIM directly at the top
  else echo "${s%%/*}"
  fi
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

# Log why uploads are waiting, but not over and over: a dock says it once,
# and the 15 minute upload only when the reason changes. $1 is a short
# reason id, so a new reason is still logged.
LOGGED_WAIT=""
waiting() {
  if [ "$LOGGED_WAIT" != "$1" ] &&
     { [ "$MODE" != flush ] || [ "$(cat "$WAITING_FLAG" 2>/dev/null)" != "$1" ]; }; then
    log "$2"
    LOGGED_WAIT=$1
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

  # CHANGE_ME is the placeholder the installer writes when Immich is skipped
  if [ -z "$IMMICH_URL" ] || [ -z "$key" ] || [ "$key" = CHANGE_ME ]; then
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

  # The reply must be a list of albums; anything else is shown in the log
  if [ "$(jq -r 'type' "$RESP" 2>/dev/null)" != array ]; then
    log "Immich's list of albums wasn't a list - it replied: $(head -c 300 "$RESP" | tr '\n' ' ')"
    return 1
  fi
  ALBUM_ID=$(jq -r --arg n "$ALBUM" '[.[] | select(.albumName == $n)][0].id // empty' "$RESP" 2>/dev/null)
  if [ -n "$ALBUM_ID" ]; then
    log "found the album \"$ALBUM\" in Immich (album ID $ALBUM_ID)"
  else
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
    log "created the album \"$ALBUM\" in Immich (album ID $ALBUM_ID)"
  fi
  # An ID is used in a web address below, so make sure it's only letters, digits and -
  if ! [[ $ALBUM_ID =~ ^[A-Za-z0-9-]+$ ]]; then
    log "Immich returned an album ID that doesn't look right: $ALBUM_ID"
    return 1
  fi
  # Double-check the album really exists before uploading anything into it
  code=$(api GET "/albums/$ALBUM_ID" --max-time 60)
  if [ "$code" != 200 ] || [ "$(jq -r '.id // empty' "$RESP" 2>/dev/null)" != "$ALBUM_ID" ]; then
    log "Immich gave the album \"$ALBUM\" the ID $ALBUM_ID, but then couldn't open it (HTTP $code: $(api_message)) - nothing uploaded, the files stay in the cache"
    return 1
  fi
  return 0
}

# The dock's own settings, from the same config file:
#   DELETE_FROM_DRONE  yes = delete each file from the drone once its copy on
#                      the Pi is checked. Anything else, or missing = never.
#   CACHE_LIMIT_GB     the most the cache on the Pi may hold (default 20)
#   KEEP_FREE_GB       always leave this much of the Pi's SD card free, for
#                      the system and other programs (default 5)
#   REFILL_CHECK_MINUTES  while the drone stays plugged in with files left
#                      on it, how often to check if the cache has emptied
#                      so it can be refilled (default 5)
#   REFILL_GIVE_UP_HOURS  stop waiting if the cache hasn't emptied after
#                      this long, e.g. because Immich is down (default 12)
# whole_number NAME DEFAULT: a setting that must be a whole number above 0
whole_number() {
  local v; v=$(conf_get "$1")
  if ! [[ $v =~ ^[0-9]+$ ]] || [ "$v" -eq 0 ]; then
    [ -n "$v" ] && log "$1=$v isn't a whole number - using $2"
    v=$2
  fi
  echo "$v"
}
read_dock_settings() {
  case "$(conf_get DELETE_FROM_DRONE)" in
    yes|Yes|YES|true|on|1) DELETE_FROM_DRONE=yes ;;
    *) DELETE_FROM_DRONE=no ;;
  esac
  local gb; gb=$(whole_number CACHE_LIMIT_GB 20)
  if [ -n "$KEEP_FREE_MB_OVERRIDE" ]; then KEEP_FREE=$(( KEEP_FREE_MB_OVERRIDE * 1024 * 1024 ))
  else KEEP_FREE=$(( $(whole_number KEEP_FREE_GB 5) * 1024 * 1024 * 1024 ))
  fi
  REFILL_CHECK=${DJI_REFILL_CHECK_SECONDS:-$(( $(whole_number REFILL_CHECK_MINUTES 5) * 60 ))}
  REFILL_GIVE_UP=${DJI_REFILL_GIVE_UP_SECONDS:-$(( $(whole_number REFILL_GIVE_UP_HOURS 12) * 3600 ))}
  if [ -n "$CACHE_LIMIT_MB_OVERRIDE" ]; then CACHE_LIMIT=$(( CACHE_LIMIT_MB_OVERRIDE * 1024 * 1024 ))
  else CACHE_LIMIT=$(( gb * 1024 * 1024 * 1024 ))
  fi
}

# Delete from the drone the files in DCIM folder $1 that are safely on the
# Pi. A file is deleted only if:
#   - its copy in the cache is identical, byte for byte (cmp), or
#   - it's already in Immich and its checksum matches the one Immich
#     confirmed (from imported.list).
# Anything else is left on the drone: files that didn't fit in the cache,
# failed copies, and a different file that happens to have the same name.
# USB drives were mounted read-only, so they're made writable just for this.
# Returns 1 if something couldn't be deleted.
delete_from_drone() {
  local dcim=$1 storage mp size rel key sum lrf writable=no failed=0 list=$TMP/delete-list
  storage=$(storage_of "$dcim")

  # First make the list, then delete (never delete while still listing)
  : > "$list"
  while IFS=$'\t' read -r size rel; do
    case "/$rel" in */.*) continue ;; esac
    is_media "$rel" || continue
    key="$storage/$rel"
    if [ -f "$CACHE/$key" ] || [ -n "${CONFIRMED["$size"$'\t'"$key"]:-}" ]; then
      printf '%s\t%s\n' "$size" "$rel" >> "$list"
    fi
  done < <(find "$dcim" -type f -printf '%s\t%P\n' 2>/dev/null)
  [ -s "$list" ] || return 0

  mp="$MNT/$storage"
  if [ -n "${USB_DRIVES[$storage]+x}" ]; then
    if ! mount -o remount,rw "$mp" 2>> "$LOG"; then
      log "could not delete from $storage: it can't be made writable - the files stay on the drone"
      return 1
    fi
    writable=yes
  fi

  while IFS=$'\t' read -r size rel; do
    key="$storage/$rel"
    if [ -f "$CACHE/$key" ]; then
      # cmp reads both files and says if they're identical
      if ! cmp -s "$dcim/$rel" "$CACHE/$key"; then
        log "NOT deleted from the drone, because the copy on the Pi isn't identical: $key"
        continue
      fi
    elif [ -z "${CONFIRMED["$size"$'\t'"$key"]:-}" ]; then
      # Can happen if an upload took the cached copy away just now: it's
      # safe on the drone, and is deleted on a later dock
      log "NOT deleted from the drone, because no checked copy was found: $key"
      continue
    else
      sum=$(sha1sum "$dcim/$rel" 2>/dev/null | cut -d ' ' -f 1)
      if [ "$sum" != "${CONFIRMED["$size"$'\t'"$key"]}" ]; then
        log "NOT deleted from the drone, because it doesn't match the copy in Immich: $key"
        continue
      fi
    fi
    if rm -f -- "${dcim:?}/${rel:?}" 2>> "$LOG" && [ ! -e "$dcim/$rel" ]; then
      DELETED=$((DELETED + 1)); DELETED_BYTES=$((DELETED_BYTES + size))
      # A video's low-quality preview (.LRF) is no use without the video
      for lrf in "$dcim/${rel%.*}.LRF" "$dcim/${rel%.*}.lrf"; do
        [ -f "$lrf" ] && rm -f -- "${lrf:?}"
      done
    else
      log "could not delete from the drone: $key"
      failed=1
    fi
  done < "$list"

  if [ "$writable" = yes ]; then
    sync    # make sure the deletes are written to the drone before unmounting
    mount -o remount,ro "$mp" 2>> "$LOG"
  fi
  return "$failed"
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
  read_dock_settings
  echo "     the cache on the Pi holds up to $(human "$CACHE_LIMIT"); $(cached_count) file(s) are waiting in it"
  echo "     $(human "$KEEP_FREE") of the Pi is always kept free; free right now: $(df -Ph "$STATE" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [ "$DELETE_FROM_DRONE" = yes ]; then
    echo "     files ARE deleted from the drone once they're copied to the Pi (DELETE_FROM_DRONE=yes)"
  else
    echo "     files are NOT deleted from the drone (to turn that on: DELETE_FROM_DRONE=yes)"
  fi
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
read_dock_settings

# ==== Copying from the drone =====================================================

# One round of copying: copy what fits from the drone into the cache, then,
# with DELETE_FROM_DRONE=yes, delete from the drone what was checked.
# Sets NEW / NEW_BYTES (copied), NO_ROOM / NO_ROOM_BYTES (didn't fit, still
# on the drone) and CACHE_USED (what was in the cache before this round).
copy_round() {
  local size a b key free_kb dcim storage i=0 want rel st

  # Files already in Immich are remembered as "size<TAB>checksum<TAB>path",
  # so they aren't copied again. The size is included so that a new photo
  # that happens to reuse an old name (e.g. after formatting the card) is
  # still copied. CONFIRMED holds the checksum Immich confirmed for each.
  # Read again every round, because uploads in between add to it.
  declare -gA IN_IMMICH=() CONFIRMED=()
  while IFS=$'\t' read -r size a b; do
    key=${b:-$a}    # older lines have no checksum: "size<TAB>path"
    [ -n "$key" ] && IN_IMMICH["$size"$'\t'"$key"]=1
    [ -n "$b" ] && CONFIRMED["$size"$'\t'"$b"]=$a
  done < "$IMPORTED"

  # How much may be copied: whichever is smaller of
  #   - the room left in the cache: CACHE_LIMIT minus what's already in it
  #   - the free space on the Pi right now, minus KEEP_FREE_GB. This is
  #     measured every round, so the system, the RC 2 dock and the logs
  #     are always counted, whatever they're using.
  if [ -n "$FREE_KB_OVERRIDE" ]; then free_kb=$FREE_KB_OVERRIDE
  else free_kb=$(df -Pk "$CACHE" | awk 'NR == 2 { print $4 }')
  fi
  local disk_room=$(( free_kb * 1024 - KEEP_FREE ))
  CACHE_USED=$(find "$CACHE" -type f -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')
  local cache_room=$(( CACHE_LIMIT - CACHE_USED ))
  local budget=$(( cache_room < disk_room ? cache_room : disk_room ))

  NEW=0; NEW_BYTES=0; NO_ROOM=0; NO_ROOM_BYTES=0
  for dcim in "${DCIMS[@]}"; do
    storage=$(storage_of "$dcim")
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
      if [ "$size" -gt "$budget" ]; then
        NO_ROOM=$((NO_ROOM + 1)); NO_ROOM_BYTES=$((NO_ROOM_BYTES + size))
        continue
      fi
      budget=$((budget - size))
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
  if [ "$NEW" -eq 0 ] && [ "$NO_ROOM" -eq 0 ]; then
    log "no new photos or videos on the drone"
  elif [ "$NEW" -gt 0 ]; then
    log "copied $NEW new photo(s)/video(s) from the drone ($(human "$NEW_BYTES"))"
  fi
  if [ "$NO_ROOM" -gt 0 ]; then
    log "$NO_ROOM file(s) ($(human "$NO_ROOM_BYTES")) didn't fit in the cache on the Pi (it holds up to $(human "$CACHE_LIMIT"), and keeps $(human "$KEEP_FREE") of the Pi free for everything else) - they stay on the drone for now"
  fi

  # Free up the drone: delete what is now safely on the Pi (or in Immich)
  if [ "$DELETE_FROM_DRONE" = yes ]; then
    DELETED=0; DELETED_BYTES=0
    for dcim in "${DCIMS[@]}"; do
      delete_from_drone "$dcim" || COPY_FAILED=1
    done
    [ "$DELETED" -gt 0 ] && log "deleted $DELETED photo(s)/video(s) from the drone ($(human "$DELETED_BYTES") freed) - they're on the Pi, waiting for Immich"
  fi
  return 0
}

# True while the drone is still plugged in: every DCIM folder can be read.
drone_still_there() {
  local d
  for d in "${DCIMS[@]}"; do ls "$d" > /dev/null 2>&1 || return 1; done
}

# ==== Cache -> Immich ==============================================================

# upload_cache [nowait]
# Uploads the cache to Immich. Returns 0 = finished, 1 = errors,
# 2 = nothing done (nothing waiting, Immich not ready, or another upload
# running: the files wait). With "nowait" it doesn't wait for another
# upload that's running. UPLOAD_DONE_ALL is "yes" if it got through every
# file it could (Immich was reachable the whole time).
upload_cache() {
  local result
  upload_cache_now "${1:-}"; result=$?
  flock -u 9    # let the 15 minute upload run again
  return "$result"
}
upload_cache_now() {
  local count status code f key size sum when esc id ok
  UPLOAD_DONE_ALL=no
  if [ "$MODE" = dock ] && [ "$1" != nowait ]; then
    if ! flock -w "$LOCK_WAIT" 9; then
      log "an upload is already running - the new files will be uploaded within 15 minutes"
      return 2
    fi
  else
    # Skip this turn if another upload is running
    flock -n 9 || return 2
  fi

  count=$(cached_count)
  if [ "$count" -eq 0 ]; then
    [ "$MODE" = dock ] && [ "$REFILLING" = no ] && log "nothing waiting to upload"
    return 2
  fi

  connect_immich; status=$?
  [ "$status" -eq 2 ] && return 2   # files wait in the cache
  [ "$status" -ne 0 ] && return 1

  if [ -e "$WAITING_FLAG" ]; then
    log "Immich is ready again - uploading $count file(s) from the cache"
    rm -f "$WAITING_FLAG"
  fi
  log "uploading $count file(s) to the Immich album \"$ALBUM\"..."

  UPLOADED=0; DUPES=0; FAILED=0; UPLOAD_DONE_ALL=yes
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
        FAILED=$((FAILED + 1)); UPLOAD_DONE_ALL=no; break ;;
      401|403)
        log "Immich refused the upload (HTTP $code: $(api_message)) - check the API key and its permissions"
        FAILED=$((FAILED + 1)); UPLOAD_DONE_ALL=no; break ;;
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
      # An album problem affects every file, so stop here rather than
      # repeat it for each one. This file and the rest are retried later.
      log "uploaded $key, but could not add it to the album \"$ALBUM\" (album ID $ALBUM_ID, HTTP $code: $(api_message)) - stopping; this file and the rest stay in the cache, retried later"
      FAILED=$((FAILED + 1)); UPLOAD_DONE_ALL=no; break
    fi

    # Confirmed: remember it (with its checksum), then remove it from the cache
    printf '%s\t%s\t%s\n' "$size" "$sum" "$key" >> "$IMPORTED"
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
  [ "$FAILED" -eq 0 ]
}

# ==== Dock mode ====================================================================
REFILLING=no         # "yes" while waiting for the cache to empty, to refill it
UPLOAD_STATUS=2
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

  ROUND=1
  copy_round

  # ---- Refill: while files are still left on the drone because the cache
  # was full, upload the cache, wait for it to empty, and copy more.
  # Stops when the drone is empty, the drone is unplugged, nothing more
  # can be copied, or the cache hasn't emptied for REFILL_GIVE_UP seconds.
  REFILLING=yes
  STOP_REASON=""
  while [ "$NO_ROOM" -gt 0 ]; do
    if [ "$NEW" -eq 0 ] && { [ "$ROUND" -gt 1 ] || [ "$CACHE_USED" -eq 0 ]; }; then
      if [ "$(cached_count)" -eq 0 ]; then
        STOP_REASON="they're too big to fit in the cache on the Pi, even when it's empty (raise CACHE_LIMIT_GB, or free up space on the Pi)"
      else
        STOP_REASON="the cache is still full of files Immich didn't accept (see above)"
      fi
      break
    fi
    log "round $ROUND done: $NO_ROOM file(s) ($(human "$NO_ROOM_BYTES")) still on the drone - keep it plugged in; uploading the cache, then refilling it (checking every $(human_time "$REFILL_CHECK"))"
    upload_cache nowait; [ "$?" -eq 1 ] && UPLOAD_STATUS=1

    # Wait until the cache is empty (or the upload got through everything
    # it could - a file Immich refuses would otherwise never let it empty)
    WAITED=0
    while [ "$(cached_count)" -gt 0 ] && [ "$UPLOAD_DONE_ALL" != yes ]; do
      if ! drone_still_there; then break 2; fi
      if [ "$WAITED" -ge "$REFILL_GIVE_UP" ]; then
        STOP_REASON="the cache on the Pi hasn't emptied for $(human_time "$REFILL_GIVE_UP") - is Immich down, or not set up yet?"
        break 2
      fi
      sleep "$REFILL_CHECK"
      WAITED=$((WAITED + REFILL_CHECK))
      upload_cache nowait; [ "$?" -eq 1 ] && UPLOAD_STATUS=1
    done
    if ! drone_still_there; then break; fi

    ROUND=$((ROUND + 1))
    log "the cache has room again - refilling it from the drone (round $ROUND)"
    copy_round
  done
  REFILLING=no

  if [ "$NO_ROOM" -gt 0 ]; then
    if ! drone_still_there; then
      log "the drone was unplugged - $NO_ROOM file(s) ($(human "$NO_ROOM_BYTES")) are still on it; plug it in again to copy them"
    else
      log "stopped refilling: $NO_ROOM file(s) ($(human "$NO_ROOM_BYTES")) are still on the drone, because $STOP_REASON"
    fi
  elif [ "$ROUND" -gt 1 ]; then
    log "everything has been copied off the drone, in $ROUND rounds"
  fi

  unmount_all   # finished with the drone: it can be unplugged now
  COPYING=no
  log "the drone can be unplugged"
  # Let another dock start copying, while this one uploads
  flock -u 8
else
  # Flush mode: quietly do nothing if no files are waiting
  [ "$(cached_count)" -eq 0 ] && exit 0
fi

# ---- Upload what's left in the cache --------------------------------------------
if [ "$MODE" = dock ]; then
  upload_cache; [ "$?" -eq 1 ] && UPLOAD_STATUS=1
else
  upload_cache nowait; UPLOAD_STATUS=$?
  [ "$UPLOAD_STATUS" -eq 2 ] && exit 0   # nothing done: quiet
fi

if [ "$COPY_FAILED" -ne 0 ] || [ "$UPLOAD_STATUS" -eq 1 ]; then
  log "done, with errors (see above)"
  exit 1
fi
log "done"
