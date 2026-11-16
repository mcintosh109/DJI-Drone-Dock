# DJI Drone Photo Dock

Turns a Raspberry Pi into a dock for a DJI drone. Plug the drone into the Pi and it automatically copies new photos and videos off the drone, from **both the SD card and the drone's internal storage**, into a cache on the Pi. Once each copy is checked, it **deletes the file from the drone**, so the drone's storage is free when you unplug it. Then it uploads the cache to [Immich](https://immich.app) into an album called **Drone Photos**.

It's the photo version of [dji-rc2-dock](https://github.com/mcintosh109/dji-rc2-dock), which does the same for the RC 2 controller's flight logs. Both can run on the same Pi.

> **Folder or album?** Immich doesn't have folders, it has **albums**. This dock puts everything in an album named "Drone Photos" (you can pick another name). The dock creates the album in Immich the first time it uploads something.

## How it works

1. A **udev rule** spots the drone when it's plugged in over USB. (udev is the part of Linux that notices when devices are plugged in.)
2. udev starts a **systemd service**, which runs `dji-drone-sync.sh`. (systemd is the part of Linux that starts and stops programs.)
3. The script finds the drone's storage. DJI drones show up in one of two ways, depending on the model, and both are handled:
   - as **USB drives** ("mass storage"), one drive for the SD card and one for internal storage. Each is mounted **read-only**, so nothing on the drone can be changed.
   - as an **MTP device**, like a phone or the RC 2 controller. It's mounted with `jmtpfs`, and only read from.
4. It copies new photos and videos from every `DCIM` folder into a **cache on the Pi's SD card** (`/var/lib/dji-drone/cache`). The cache holds at most **20 GB**.
5. It **checks each copy byte for byte** against the file on the drone (with `cmp`). Only if they're identical is the file **deleted from the drone**. (You can turn deleting off, see "Deleting from the drone".)
6. **If files are still on the drone** because the cache was full, the drone stays plugged in and the dock **refills** (see "Refilling the cache"): it uploads the cache, checks every 5 minutes if the cache has emptied, then copies the next batch. This repeats until the drone is empty.
7. It unmounts the drone, and the log says `the drone can be unplugged`. The drone's storage is now free.
8. It uploads what's left in the cache to Immich and adds each file to the album. Each cached file is deleted from the Pi only after Immich confirms it has it **and** it's in the album.
9. If Immich is down (or not set up yet), the files wait in the cache. A timer (`dji-drone-flush.timer`) checks every 15 minutes and uploads them as soon as Immich is back, without plugging the drone in again.

### Deleting from the drone

The installer asks if you want this. It's the `DELETE_FROM_DRONE` setting (`yes` or `no`) in `/etc/dji-drone/immich.conf`.

A file is deleted from the drone **only** when one of these is true:
- its copy in the cache on the Pi is **identical, byte for byte**, or
- it's already in Immich, and its checksum (a fingerprint of its contents) is the same as the one Immich confirmed.

Everything else stays on the drone: files that didn't fit in the cache, files whose copy failed, and a different file that happens to have the same name.

**The trade-off:** between unplugging the drone and the upload finishing, the cache on the Pi holds **the only copy**. If the Pi's SD card failed in that time, those photos would be lost. Use a good-quality SD card in the Pi, and set up Immich so the cache doesn't wait long.

Also deleted: a video's `.LRF` file (a small preview, no use without the video). **Not** deleted: `.SRT` files (flight data subtitles, small), which are never copied either.

### The 20 GB cache limit

The cache on the Pi holds at most 20 GB, counting what's already waiting in it. Change it with the `CACHE_LIMIT_GB` setting.

The Pi also always keeps **5 GB of its SD card free** for everything else (the system, the RC 2 dock, logs). Change it with `KEEP_FREE_GB`. Each batch copies whichever is smaller: the room left in the cache, or the Pi's free space right now minus that 5 GB. The free space is measured fresh before every batch, so whatever the system and the RC 2 dock are using is always counted.

### Refilling the cache

When the drone has more on it than fits in the cache, you don't need to unplug and plug it in again. Leave it plugged in and the dock does this by itself:

1. Copies a batch (up to 20 GB) and deletes it from the drone.
2. Uploads the cache to Immich.
3. Every 5 minutes (`REFILL_CHECK_MINUTES`), checks if the cache has emptied.
4. Once it has, copies the next batch, and so on, until the drone is empty.

For example, with 50 GB on the drone: batch 1 is 20 GB, batch 2 is 20 GB, batch 3 is 10 GB. The log says `round 1 done`, `refilling it from the drone (round 2)`, and at the end `everything has been copied off the drone, in 3 rounds`, then `the drone can be unplugged`.

It stops refilling, and the rest stays safely on the drone, if:
- you unplug the drone (plug it in again later to carry on),
- the cache hasn't emptied for 12 hours (`REFILL_GIVE_UP_HOURS`), for example because Immich is down or not set up yet,
- a single file is too big for the cache even when it's empty.

**While Immich isn't set up yet,** the cache can't empty by itself. You can empty it yourself by copying the files somewhere else and then deleting them from `/var/lib/dji-drone/cache`. If the drone is still plugged in, the dock notices within 5 minutes and refills.

### Storage on a 64 GB Pi

A rough budget for a Pi with a 64 GB SD card that also runs the RC 2 dock:

| What | Space |
|---|---|
| A "64 GB" SD card, usable | about 58 GB |
| Raspberry Pi OS (Lite about 3 GB, with desktop about 8 GB) | 3 - 8 GB |
| RC 2 dock (flight logs are a few MB each) | well under 1 GB |
| Drone cache, at most (`CACHE_LIMIT_GB`) | 20 GB |
| Always kept free (`KEEP_FREE_GB`) | 5 GB |
| **Left over** | **about 25 - 30 GB** |

So 20 GB is safe. Check the real numbers on your Pi with `df -h /` (the "Avail" column is the free space) and `sudo dji-drone-sync.sh --check`.

SD cards wear out with lots of writing, and this dock writes a lot (every photo and video passes through the cache). A **"high endurance"** card, made for dashcams and security cameras, lasts much longer.

### Which files are copied

| Copied | Not copied |
|---|---|
| Photos: `.JPG` `.JPEG` `.DNG` `.HEIC` `.TIF` | `.LRF` (small low-quality copies of videos, made for the DJI app) |
| Videos: `.MP4` `.MOV` | `.SRT` (flight data subtitles) |

## Hardware

- Raspberry Pi (64-bit Raspberry Pi OS Lite is best, see Troubleshooting)
- Official Pi power supply (low power causes unreliable copies)
- A USB-C cable that carries **data**, not just charge
- A good-quality SD card in the Pi, ideally "high endurance". 64 GB is plenty: see "Storage on a 64 GB Pi".

## Install

1. Update the Pi:
   ```bash
   sudo apt update && sudo apt full-upgrade -y
   ```
2. Get this repo onto the Pi and go into its folder:
   ```bash
   git clone https://github.com/mcintosh109/DJI-Drone-Dock.git
   ```
   ```bash
   cd DJI-Drone-Dock
   ```
3. Make an Immich API key (see the next section). Keep the page open, you'll paste the key in step 4.
4. Run the installer. It asks for your Immich address and API key, then checks they work:
   ```bash
   sudo ./install.sh
   ```

### Make an Immich API key

An **API key** is like a password that lets a program (this dock) use your Immich account.

1. Open Immich in a web browser.
2. Click your profile picture (top right), then **Account Settings**.
3. Open **API Keys**, then click **New API Key**.
4. Give it a name, like `drone dock`.
5. Choose its permissions. Either pick **all**, or just these four:
   - `asset.upload` (upload photos and videos)
   - `album.read` (find the album)
   - `album.create` (make the album the first time)
   - `albumAsset.create` (put photos into the album)
6. Click **Create**, and copy the key. Immich only shows it once.

### Change the settings later

The settings live in `/etc/dji-drone/immich.conf`. Only root (sudo) can read it, because it holds the API key. To edit it:

```bash
sudo nano /etc/dji-drone/immich.conf
```

It looks like this (see `examples/immich.conf.example`):

```ini
IMMICH_URL=http://192.168.1.50:2283
IMMICH_API_KEY=your-key-here
IMMICH_ALBUM=Drone Photos
DELETE_FROM_DRONE=yes
CACHE_LIMIT_GB=20
KEEP_FREE_GB=5
REFILL_CHECK_MINUTES=5
REFILL_GIVE_UP_HOURS=12
```

| Setting | What it does |
|---|---|
| `IMMICH_URL`, `IMMICH_API_KEY`, `IMMICH_ALBUM` | Where to upload (see below) |
| `DELETE_FROM_DRONE` | `yes` = delete from the drone once checked on the Pi. `no` = never delete |
| `CACHE_LIMIT_GB` | The most the cache on the Pi may hold |
| `KEEP_FREE_GB` | Space always left free on the Pi for everything else |
| `REFILL_CHECK_MINUTES` | How often to check if the cache has emptied, to refill it |
| `REFILL_GIVE_UP_HOURS` | How long to wait for the cache to empty before stopping |

`IMMICH_URL` is the address you open Immich at in your browser, including the port number (Immich's default port is 2283). Save with Ctrl+O then Enter, and exit with Ctrl+X.

Then check the settings work:

```bash
sudo dji-drone-sync.sh --check
```

It prints `OK` and the album name when everything is right, or `!!` and what's wrong. It also shows the cache limit, how much space the Pi has free, and whether files are deleted from the drone.

## Usage

1. Plug the drone into the Pi with the USB-C cable. Some drones (like the Mini 4 Pro) share their storage while switched off; others need to be switched on.
2. Watch what happens:
   ```bash
   tail -f /var/log/dji-drone-sync.log
   ```
   (Press Ctrl+C to stop watching. That doesn't stop the dock.)
3. **Wait** until the log says `the drone can be unplugged`, then unplug it. If deleting is on, it says how much was freed on the drone. With a lot on the drone this can take several rounds (see "Refilling the cache"); `round N done ... keep it plugged in` means it's still working. The upload carries on without the drone.

Run a sync by hand with:

```bash
sudo systemctl start dji-drone-sync.service
```

## Updating

After getting a new version of this repo (`git pull`), run the installer again. It keeps your Immich settings.

```bash
sudo ./install.sh
```

## Uninstall

```bash
sudo ./uninstall.sh
```

This stops the 15 minute timer and removes the installed script, services, timer, udev rule and log rotation settings. Your settings, the cache on the Pi and the log file are kept; the uninstaller lists where they are, and warns if any photos in the cache were never uploaded. **If deleting from the drone was on, those may be the only copies**, so copy them somewhere safe first.

## Tests

The tests run `dji-drone-sync.sh` against a **fake drone** and a **fake Immich**, so nothing real is touched. They need `rsync` and `jq`. GitHub runs them, and ShellCheck (a checker for common mistakes in shell scripts), on every pull request.

```bash
bash tests/test-drone-sync.sh
```

## Troubleshooting

Each problem shows the message you'll see in `/var/log/dji-drone-sync.log`.

**Nothing appears in the log after plugging in**
- Check the Pi sees the drone: run `lsusb`. You should see a line with `2ca3` (DJI's USB ID). If not, try another cable: many USB-C cables only charge.
- Check the service: `systemctl status dji-drone-sync.service`
- Full service messages: `journalctl -u dji-drone-sync.service`

**`no DCIM folder found on the drone after 120s`**
- Switch the drone on (or off, for drones that only share storage while off), then unplug it and plug it in again.
- Look at the line above it, `last mount error: ...`, for the reason.
- Make sure the USB cable carries data.

**`Immich isn't set up yet`**
- Add `IMMICH_URL` and `IMMICH_API_KEY` to `/etc/dji-drone/immich.conf` (see "Change the settings later"). Your photos wait safely in the cache until then.

**`can't reach Immich at ...`**
- Your photos are safe on the Pi, and are uploaded automatically within 15 minutes of Immich coming back. The log then says `Immich is ready again`.
- Check the address in `/etc/dji-drone/immich.conf` opens Immich in a browser.
- To see what's waiting: `sudo ls -R /var/lib/dji-drone/cache`

**`Immich rejected the API key`**
- The key is wrong, or was deleted in Immich. Make a new one and put it in `/etc/dji-drone/immich.conf`, then run `sudo dji-drone-sync.sh --check`.

**`the Immich API key is missing a permission`**
- Edit the key in Immich and add the four permissions listed in "Make an Immich API key".

**`Immich didn't accept ... - kept in the cache`**
- Immich gave the reason in brackets. The file stays in the cache and is tried again every 15 minutes. If it can never be uploaded, move it out of `/var/lib/dji-drone/cache` yourself.

**`N file(s) didn't fit in the cache on the Pi`**
- The 20 GB cache was full (or the Pi's own SD card was getting full), so only some files were copied. The rest are still on the drone, **not deleted**. If the drone stays plugged in, the dock refills the cache once it's been uploaded.
- To see how full the cache is: `sudo du -sh /var/lib/dji-drone/cache`
- To see the Pi's free space: `df -h /var/lib/dji-drone`

**`stopped refilling: N file(s) are still on the drone, because ...`**
- The reason is at the end of the line. They're safe on the drone; plug it in again later to carry on.
- `the cache on the Pi hasn't emptied for 12 hour(s)`: Immich is down or not set up, so nothing could be uploaded.
- `they're too big to fit in the cache`: raise `CACHE_LIMIT_GB`, or free up space on the Pi.
- `the cache is still full of files Immich didn't accept`: see "Immich didn't accept" above.

**`the drone was unplugged - N file(s) are still on it`**
- It was unplugged while waiting to refill. Nothing is lost: plug it in again to copy the rest.

**`NOT deleted from the drone, because ...`**
- A safety check stopped a delete: the file on the drone wasn't identical to the copy on the Pi (or in Immich). It stays on the drone. This can happen if two different files have the same name. Nothing needs doing; it's copied and checked again on a later dock.

**`could not delete from ...`**
- The drone didn't allow the delete. The file stays on the drone and the copy stays on the Pi, so nothing is lost. Check the drone's SD card isn't write-protected (a small switch on full-size card adapters).

**`not copied yet: a different file with the same name is waiting in the cache`** (that file is not deleted from the drone either)
- Happens if the drone reused a file name (e.g. after formatting the SD card) before the older file was uploaded. Once the older one is uploaded, dock again and the new one is copied.

**`an upload is already running`**
- A big upload was still going. Your new files are in the cache and are uploaded by the next 15 minute run.

**The Pi opens a window or a file manager when the drone is plugged in**
- That's the Raspberry Pi OS desktop mounting the drone by itself. It usually still works, but Raspberry Pi OS **Lite** (no desktop) avoids it.

**Checking the 15 minute timer**
- `systemctl list-timers dji-drone-flush.timer` shows when it last ran and when it runs next.

`systemctl status dji-drone-sync.service` shows **failed** when the drone couldn't be found, a copy, delete or upload failed, the API key was rejected, or the sync was stopped by its 24 hour time limit.

## Notes

- **Nothing is uploaded twice.** Before sending a file, the dock tells Immich its checksum (a fingerprint of its contents). If Immich already has it, for example from the phone app, it's just added to the album.
- The Pi remembers what it has uploaded in `/var/lib/dji-drone/imported.list` (each file's size, checksum and name), so those files aren't copied off the drone again. To upload everything on the drone again, delete that file. Immich will recognise the ones it already has.
- Immich reads each photo's real date and GPS position from the photo itself, so they show up in the right place on the timeline and map.
- The API key is never put on a command line, where anyone logged in to the Pi could see it with `ps`.
- **Only DJI devices are touched** (USB vendor ID `2ca3`), and never the RC 2 controller (`2ca3:1021`), which has its own dock. A USB stick plugged into the Pi is ignored.
- **Both docks on one Pi:** they work side by side. Avoid plugging in the drone and the RC 2 at the very same moment: the RC 2 dock picks the first MTP device it finds, which could be the drone. This dock always picks the drone by its exact USB position.
- The log file is rotated monthly, and the last 12 months are kept (`/etc/logrotate.d/dji-drone-sync`).

### Words used here, to look up

| Word | What it means |
|---|---|
| udev | Linux's system for noticing plugged-in devices |
| systemd service / timer | How Linux starts a program on an event, or on a schedule |
| mount / unmount | Connect / disconnect a drive's files to a folder on the Pi |
| MTP | "Media Transfer Protocol", how phones share files over USB |
| Mass storage | A device that acts like a normal USB drive |
| DCIM | The standard folder cameras keep photos in |
| rsync | A program that copies files safely |
| curl | A program that talks to websites and web services, like Immich |
| API key | A password for programs |
| Checksum (SHA-1) | A fingerprint of a file's contents |
| cmp | A program that compares two files byte for byte |
| Cache | A folder on the Pi where files wait to be uploaded |
