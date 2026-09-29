# ![ratoncito](docs/banner.svg)

Remaps mouse buttons on macOS — e.g. make the back button act as left click when a
mouse's left switch is failing, without running the vendor's software. Remapped
buttons support drag and double/triple-click. Requires macOS 14+.

It's a single small binary using a `CGEventTap`: button events are rewritten in place,
with no dependencies.

## Usage

Mappings are stored in a JSON config file and managed with subcommands:

```sh
ratoncito map back left     # back button acts as left click
ratoncito map 5 middle      # forward button acts as middle click
ratoncito block left        # ignore the physical left button
ratoncito list
```

Buttons are numbered from 1 (left, right, middle, back, forward are aliases for 1–5).
Commands that change the config restart the installed agent. If you edit the file by
hand, run `ratoncito restart`. See `ratoncito --help` for everything else.

## Build and install

```sh
make install
```

This builds with `swift build -c release`, signs the binary (see [Code signing](#code-signing)),
copies it to `~/.local/bin`, and loads a LaunchAgent that starts it at login.
Pass install options through `ARGS`, e.g. `make install ARGS="--verbose"`.

To try it without installing, run it in the foreground:

```sh
swift build -c release
.build/release/ratoncito map back left
.build/release/ratoncito --verbose
```

To remove it:

```sh
ratoncito uninstall
```

## Permissions

ratoncito needs **Accessibility** permission (System Settings → Privacy & Security →
Accessibility). On first run it triggers the system prompt, prints what to enable and
exits non-zero; grant it and start it again.

macOS attributes the permission to the *responsible* process:

- Run from a shell, that's your terminal app (Terminal, iTerm, …), not ratoncito.
- Run by the LaunchAgent, it's the installed binary itself, e.g. `~/.local/bin/ratoncito`.

After granting the LaunchAgent's binary, run `ratoncito restart`. Logs go to
`~/Library/Logs/ratoncito.log`.

## Code signing

macOS ties the Accessibility grant to the binary's code signature. `swift build`
signs ad-hoc, and an ad-hoc signature changes with every build, so **after a rebuild
the old grant silently stops working**: ratoncito still appears enabled in System
Settings but isn't trusted. Fix it by removing the entry with "−" and adding it again.

To avoid this, sign with a stable self-signed certificate. `make sign` / `make install`
use a certificate named `ratoncito-codesign` if one exists (override with
`make install CERT=...`), and fall back to ad-hoc with a warning otherwise.

To create the certificate:

1. Open **Keychain Access** → menu **Keychain Access → Certificate Assistant →
   Create a Certificate…**
2. Name: `ratoncito-codesign`, Identity Type: **Self Signed Root**,
   Certificate Type: **Code Signing**. Click Create.
3. Check it's visible: `security find-identity -p codesigning` should list it.

The first `codesign` with it may ask for keychain access — choose **Always Allow**.
Grant Accessibility once to the certificate-signed binary; later rebuilds installed
to the same path keep the grant.

## Caveats

- Mappings and blocks apply to every pointing device: event taps can't tell which
  device an event came from. Blocking `left` also blocks trackpad clicks, and mapping
  a button affects every mouse that has it.
- A mapped button loses its original function (e.g. back/forward navigation).
