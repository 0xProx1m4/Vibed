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

Tide also offers its own fully custom lock screen (`⌃⌥⌘L`).

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
bar simply stops showing (everything else keeps working): disable it from the menu.

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

## Settings (🌊 icon in the menu bar)

- **Artwork on the lock screen**: turns the macOS lock screen mode on or off.
- **Size / Position**: adjusts the artwork so it fits nicely between the macOS clock and player.

If the macOS player doesn't appear on the lock screen: System Settings ›
Lock Screen, and check that media controls are allowed to be shown.

Limitations: the wallpaper is only changed on the active Space (desktop) of each display.
Apple's animated ("aerial") wallpapers may not be restored identically.

## Tide screen (optional)



| Action | How |
|---|---|
| Lock | `⌃⌥⌘L`, or 🌊 icon in the menu bar → *Lock now* |
| Play / pause | `Space` or ⏯ button |
| Previous / next track | `←` / `→` or buttons |
| Seek within the track | drag on the progress bar |
| Unlock | click the background or press any other key → Touch ID / Mac password |

In the 🌊 menu: auto-lock after X minutes of inactivity, and lock when the display turns off.

## Good to know

- **Liquid Glass**: on macOS 26 (Tahoe), built with Xcode 26, Tide uses the real
  `glassEffect` material. On older versions, it imitates it (blur + highlights).
- macOS doesn't let any third-party app draw on the system's *real* lock screen.
  So Tide shows **its own screen**, on top of everything (Dock, menu bar,
  ⌘Tab and Force Quit are blocked), and only removes it with your Touch ID or password.
  It doesn't fully replace the system lock (e.g. a forced restart bypasses it):
  for maximum security, keep the macOS lock enabled as well.
- If "Lock when the display turns off" is enabled and macOS already asks for your password
  when waking from sleep, you'll have to authenticate twice. In that case, set a delay in
  System Settings → Lock Screen, or disable the option.
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
  TideApp.swift            menu bar app, shortcut, auto-lock
  WallpaperManager.swift   artwork → wallpaper (real lock screen)
  WallpaperRenderer.swift  background image generation
  LockScreenBar.swift      Liquid Glass bar on the real lock screen
  SpotifyWebAPI.swift      Spotify account connection (♥ and liked state)
  AudioOutputs.swift       audio output list and selection (CoreAudio)
  SkyLight.swift           private window server access (above the lock screen)
  LockScreenManager.swift  full-screen windows + Touch ID
  LockScreenView.swift     the screen: background, clock, artwork, player
  SpotifyController.swift  reading/controlling Spotify via AppleScript
  Glass.swift              Liquid Glass effect (native macOS 26 + imitation)
  EqualizerIcon.swift      animated now-playing indicator
  MenuContent.swift        menu bar panel
  HotKey.swift             global ⌃⌥⌘L shortcut
```
