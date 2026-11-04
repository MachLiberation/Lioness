# Lioness

Mountain Lion's Aqua on modern macOS. Lioness draws AppKit's controls with Mountain Lion's real artwork and frameworks, running on Apple Silicon with no Rosetta.

A tweak loaded into each app sends AppKit's CoreUI requests to a daemon, `appkitd`. The daemon runs Mountain Lion's own CoreUI, HIToolbox and AppKit (x86-64) under a built-in JIT and interpreter, and sends back bitmaps.

## What it changes

- Controls, windows, title bars and toolbars
- Menus: shape, shadow, selection and submenu arrows
- The menu bar: background, selection and status items
- Fonts, system colours and many symbols, using Mountain Lion's equivalents

## Requirements

- Apple Silicon, on at least macOS 27 (the only version tested)
- SIP off, with the `-arm64e_preview_abi` boot argument
- [Ammonia, the updated fork](https://github.com/MachLiberation/Ammonia)

Lioness hooks private APIs in nearly every app, so expect it to break between macOS releases.

## Install

Build the package (see below) and open `build/Lioness-2.0.0.pkg`. It's unsigned.

The package contains none of Apple's files. On the Mountain Lion Image page, choose one:

- **Download the official image from Apple:** 4.4 GB, and it needs 11 GB free while it unpacks. It continues in the background and notifies you when it's ready.
- **Use an image you already have:** `InstallMacOSX.dmg` from [Apple's download page](https://support.apple.com/en-us/106387). It needs 7 GB free. Only the 10.8.5 image is accepted.
- **Keep the files already installed:** offered if an earlier install left a good copy.

Nothing from the image runs natively, and it's not installed as a system. Its files are copied to `/Library/Lioness/ml-root` and run only inside the engine.

Relaunch apps to pick up the tweak. To restyle the menu bar straight away:

```bash
pkill -x MenuBarAgent
```

## Uninstall

```bash
sudo /Library/Lioness/Uninstall.sh
```

To set the image up again after installing, run `sudo /Library/Lioness/LionessSetup.sh download`, or pass the path to a DMG instead of `download`.

## Build

Building needs the Xcode tools, CMake, Ninja and a network connection for Dobby. Installing needs none of them.

```bash
Scripts/ExtractImage.sh path/to/InstallMacOSX.dmg
```

```bash
cmake -S . -B build -G Ninja
```

```bash
cmake --build build
```

```bash
Scripts/BuildPackage.sh
```

To try a build without installing, run `Scripts/Appkitd.sh start`, then `Scripts/Gallery.sh out.png`, which draws every control to a PNG.

## Credits

- [MacOSXArt](https://github.com/schm1dtmac/MacOSXArt) by schm1dtmac, for layout hooks (MIT, see `ThirdParty/MacOSXArt/LICENSE`)
- [Snow Leopard Menu Bar Tweak](https://github.com/JesseAnguiano/Snow-Leopard-Menu-Bar-Tweak), for the approach to menu shape, shadow and arrows (MIT, Copyright (c) 2026 Snow Leopard Menu Bar Tweak contributors)
- [Dobby](https://github.com/jmpews/Dobby) by jmpews, fetched at build time (Apache-2.0)

Mountain Lion's files belong to Apple and aren't part of this repository or the package.

## License

[MIT](LICENSE)
