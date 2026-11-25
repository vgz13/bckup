# BCKUP for macOS

A native SwiftUI app for offloading camera cards safely.

- Detects camera cards when they're plugged in (Sony, Canon, Nikon, Fujifilm, Panasonic, Blackmagic, RED, ARRI, DJI, GoPro, Insta360, audio recorders and more) and shows a menu bar panel with the card's status.
- Copies to the main folder and every backup drive at once, reads each copy back from disk and checks it with xxHash64.
- Skips files that are already there (by content hash, or a quick name/size/date check), never overwrites, and says when a card is **Safe to format**.
- Project folders: `Main folder / Project + date / Video · Photo · Audio / Roll / original card structure`.
- Projects view with backup status per drive and one-click "Back up", Sort downloads into a project's Assets folder, card thumbnails, drag and drop, sharing (AirDrop, WhatsApp, Email, Google Drive link).
- Google Drive upload with MD5 check through a bundled rclone, signed in with each person's own Google account.
- Offload reports (`.txt` and `.csv`) in `_BCKUP Reports` inside each project.

## Build

Needs Swift 6 (Command Line Tools are enough; full Xcode isn't required).

```bash
./build.sh
```

The app ends up in `build/BCKUP.app`. If `rclone` is installed (`brew install rclone`), it's bundled into the app.

## Command line

The engine can be run without the window, which is how it's tested:

```bash
build/BCKUP.app/Contents/MacOS/BCKUP --cli --source /Volumes/CARD --dest "/Volumes/WORK/Jobs" --dest "/Volumes/BACKUP/Jobs" --project "Shoot" --roll "A001"
```

Options: `--fast`, `--no-skip`, `--flat`, `--catalog <path>`, `--cloud <remote:> --cloud-path <folder>`, `--hash <file>`.

## Data

Settings live in the app's user defaults (`local.bckup.app`). The catalog of what's on each drive and BCKUP's own rclone sign-in are in `~/Library/Application Support/BCKUP/`.

The Windows version is in `../windows`.
