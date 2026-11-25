# BCKUP for Windows

Tauri 2 app (Rust engine + HTML/CSS/JS UI). Same rules as the macOS app: verified copies to several drives at once (xxHash64, read back from disk), skip what's already there, reports, tray panel, Projects with backup checks, Sort downloads, sharing and Google Drive through rclone.

## Build the Windows installer on a Mac

Tools (one time):

```bash
brew install rustup makensis lld
rustup default stable && rustup target add x86_64-pc-windows-msvc
cargo install --locked cargo-xwin
npm install
```

Build (`cargo-xwin` downloads the MSVC CRT and Windows SDK, which means accepting Microsoft's license for them):

```bash
export PATH=/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
LC_ALL=en_US.UTF-8 XWIN_ACCEPT_LICENSE=1 npx tauri build --runner cargo-xwin --target x86_64-pc-windows-msvc
```

`LC_ALL=en_US.UTF-8` matters: Homebrew's makensis crashes (`std::bad_alloc`) without a UTF-8 locale.

The installer ends up in `src-tauri/target/x86_64-pc-windows-msvc/release/bundle/nsis/` (published as `BCKUP-Setup.exe`).

The installer is one-click: `src-tauri/windows/installer.nsi` is Tauri's own NSIS template (from @tauri-apps/cli 2.9.6) with two changes, marked `BCKUP:`. It skips every page and only shows progress, and it opens BCKUP when it's done. `/S` still installs silently.

## Build on a Windows PC

Install Rust (rustup), Node.js and the Visual Studio C++ build tools, then:

```bash
npm install
npm run build
```

## Google Drive

Put `rclone.exe` (from rclone.org, windows-amd64) in `src-tauri/resources/` before building and it ships inside the app. Without it, BCKUP looks for an rclone installed on the PC. Each person signs in with their own Google account from Settings → Google Drive; the sign-in is stored in BCKUP's own rclone config, separate from any other rclone setup.

## Differences from the macOS app

- No AirDrop (Apple only). Sharing offers Copy files (paste anywhere), WhatsApp, Email, a Google Drive link and Show in Explorer.
- "Open side by side" opens two Explorer windows; snap them with Win+Left / Win+Right.
- Ejecting uses Windows' own Eject; close any Explorer window showing the card first.
- Video thumbnails show for MP4/MOV the WebView can play; RAW photos show as a list only.

## Testing on a Mac

`npx tauri build --debug --bundles app` builds a Mac version of the same app. Environment variables for testing:

- `BCKUP_DATA_DIR`: use a separate settings/catalog folder (keeps the real app's data untouched).
- `BCKUP_TEST_DOWNLOADS`: list this folder in Sort downloads.
- `BCKUP_TEST_AUTO=1`: open the first card, check and copy it without clicks.
