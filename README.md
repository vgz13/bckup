# BCKUP

Verified camera card offloads for macOS and Windows.

Plug in a card and BCKUP checks whether its contents are already on your drives. It copies to the main folder and every backup drive at once, reads each copy back from disk and checks it with xxHash64, skips files that are already there, and tells you when a card is **Safe to format**.

| | macOS | Windows |
|---|---|---|
| Folder | [`mac/`](mac) | [`windows/`](windows) |
| Built with | Swift / SwiftUI | Tauri 2 (Rust + HTML/JS) |
| Build | `cd mac && ./build.sh` | see [`windows/README.md`](windows/README.md) |
| Download | Releases: `BCKUP-mac-*.zip` | Releases: `BCKUP_*_x64-setup.exe` |

Both apps share the same rules and folder layout, so a drive filled by one is understood by the other:

```
Main folder / Project + date / Video · Photo · Audio / Roll / original card structure
                             / _BCKUP Reports / <roll> <date>.txt + .csv
```

## Features

- Card detection (Sony, Canon, Nikon, Fujifilm, Panasonic, Blackmagic, RED, ARRI, DJI, GoPro, Insta360, audio recorders and more) with a menu bar / tray panel
- Copy to several drives at once, verified with xxHash64; nothing half-copied ever has its real name
- Skip what's already there by content hash (or a quick name/size/date check); existing files are never overwritten
- Projects view with backup status per drive and one-click backup
- Sort downloads into a project's Assets folder
- Card thumbnails, drag and drop, filterable file lists
- Sharing: WhatsApp, Email, Google Drive link (plus AirDrop on macOS)
- Google Drive upload with MD5 check through rclone, signed in with each person's own Google account

## Downloads

Installers are attached to the GitHub Releases. Neither is code-signed yet:

- macOS: right-click `BCKUP.app` → Open the first time.
- Windows: if SmartScreen says "Windows protected your PC", click More info → Run anyway.
