# Tide 🌊

Shows what you're listening to on **Spotify** on the **real macOS lock screen**:
the artwork enlarged and blurred as the background, the sharp artwork in the center, and on top
of it the native macOS clock and Liquid Glass player.

### How it works

macOS doesn't let any app draw directly on the lock screen. But since Sonoma, that screen
uses **the desktop wallpaper**, and macOS itself displays the clock and the "Now Playing"
player (heart, ⏮ ⏸ ⏭, AirPlay) for Spotify on it.

So for each track, Tide prepares an image (blurred artwork + artwork in the center) and
**only applies it the moment you lock your Mac**. As soon as you unlock, your original
wallpaper comes back exactly as before (including aerial/dynamic wallpapers):
nothing changes on your desktop. The native macOS player on the lock screen lets you
pause, skip to the next track and see the progress bar.

## Installation

You need a Mac with Xcode (or the Command Line Tools) installed.

```bash
git clone <this-repo> && cd Vibed
./build.sh
open build/Tide.app
```

On first launch, macOS asks for permission to control **Spotify**: accept.
(If you declined: System Settings → Privacy & Security → Automation → Tide → Spotify.)

### Liquid Glass bar on the lock screen

Tide also shows its own playback bar (title, draggable progress bar, ⏮ ⏯ ⏭) below
the artwork, directly on the real lock screen. macOS provides no official API
for this: Tide uses a private window server function (SkyLight), the same
technique used by other menu bar apps. If a macOS update breaks it, the
bar simply stops showing (everything else keeps working).

#### Instant track changes

- **Background prepared ahead of time**: the wallpaper for upcoming tracks is rendered as soon as
  their artwork is cached; when the track changes, all that's left is handing it to macOS.
- **Tide background (disabled)**: on the lock screen, loginwindow draws the background in the same
  window as the clock and password (level 2004). A Tide window below it is hidden;
  above it, it hides the clock. To try it anyway:
  `defaults write app.tide.lockscreen instantBackground -bool true` (level adjustable with
  `lockBackgroundWindowLevel`). A list of on-screen windows is written on every lock to
  `~/Library/Application Support/Tide/lock-diagnostic.txt`.
- **Preloaded artwork**: with your Spotify account connected, Tide keeps the artwork of the
  next 5 tracks in the queue ready: on launch all 5 are downloaded in
  parallel, then on each track the next artwork is already there (shown instantly) and only
  the newcomer at the end of the queue is downloaded in the background. (If you were connected before this version, the menu
  asks you to reconnect once to grant that permission.)

Bar buttons: **♥**, **⏮ ⏯ ⏭**, and **💻 audio output** (Mac speakers, Bluetooth
headphones, AirPlay…).

#### The ♥ (Liked Songs)

For the heart to be **filled when the track is already liked**, Tide needs to read your library
through the Spotify Web API (it's the only source of that information). One time only:

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) → **Create app**.
2. Redirect URI: `http://127.0.0.1:43821/callback` — check **Web API** — save.
3. Copy the **Client ID** into the 🌊 menu › Spotify account, then **Connect to Spotify**.

OAuth "PKCE" login: no password or secret is stored; only a refresh token
is kept in `~/Library/Application Support/Tide/spotify-token` (readable by
you only). Without a connected account, the ♥ sends the Spotify shortcut ⌥⇧B (Accessibility
permission), but Tide then can't know whether a track is already liked.

## Settings (hidden for now)

These settings are hidden from the 🌊 menu: set `showsCustomization` to `true` in
`Sources/Tide/MenuContent.swift` and rebuild to bring them back.

- **Artwork on the lock screen**: turns the macOS lock screen mode on or off.
- **Size / Position**: adjusts the artwork so it fits nicely between the macOS clock and player.

If the macOS player doesn't appear on the lock screen: System Settings ›
Lock Screen, and check that media controls are allowed to be shown.

Limitations: the wallpaper is only changed on the active Space (desktop) of each display.
Apple's animated ("aerial") wallpapers may not be restored identically.

## Good to know

- **Liquid Glass**: on macOS 26 (Tahoe), built with Xcode 26, Tide uses the real
  `glassEffect` material. On older versions, it imitates it (blur + highlights).
- Because the app is ad-hoc signed, macOS may ask for the Spotify permission again after each rebuild.

## Troubleshooting: "Nothing playing"

1. Open the 🌊 menu: if it shows an orange warning, click the suggested button.
2. Check that System Settings › Privacy & Security › Automation › **Tide** › **Spotify** is checked.
3. If nothing shows up or it gets stuck after a rebuild, reset the permission and relaunch Tide:

   ```bash
   tccutil reset AppleEvents app.tide.lockscreen
   ```

Even without this permission, Tide shows the track as soon as you change tracks or
play/pause (Spotify broadcasts the info), but the buttons won't work.

## Structure

```
Sources/Tide/
  TideApp.swift            menu bar app
  WallpaperManager.swift   artwork → wallpaper (real lock screen)
  WallpaperRenderer.swift  background image generation
  LockScreenBar.swift      Liquid Glass bar on the real lock screen
  LockBackground.swift     experimental instant lock screen background (disabled)
  SpotifyWebAPI.swift      Spotify account connection (♥, liked state, queue)
  AudioOutputs.swift       audio output list and selection (CoreAudio)
  SkyLight.swift           private window server access (above the lock screen)
  SpotifyController.swift  reading/controlling Spotify via AppleScript
  Glass.swift              Liquid Glass effect (native macOS 26 + imitation)
  EqualizerIcon.swift      animated now-playing indicator
  MenuContent.swift        menu bar panel
  MenuBarIcon.swift        menu bar icon (sound wave shaped like a tide)
```
