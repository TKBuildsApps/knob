# Knob

**Volume keys for your monitor's speakers.** A tiny Mac menu bar app that comes on when your screen
connects and goes away when you unplug it.

When sound goes to a monitor over Thunderbolt, USB-C, DisplayPort or HDMI (its own speakers, or speakers
plugged into its headphone or line-out jack), macOS can't change the volume. The volume keys show a
crossed-out speaker and the balance slider is greyed out. Knob gives you both back.

It can also open apps that belong with the screen: for example **Logi Tune** for a Logitech webcam
plugged into the monitor, straight into the menu bar with no window, and quit them again when you unplug.

Pick either one or both during setup.

## What you get

- **Volume keys work again** while the monitor is your sound output: up, down and mute. Hold
  Shift-Option for finer steps. With any other output (AirPods, the Mac's speakers), the keys work as usual.
- **Volume, balance and mute** in the menu bar, plus a small level indicator while you press the keys.
- **Speakers the wrong way round?** Turn on **Swap Left and Right** in the menu. Each side then plays on the
  other speaker, and the balance slider follows what you hear. No need to rewire anything.
- **Your levels come back** every time you reconnect, and so does the swap.
- **Nothing runs while the screen is unplugged** over Thunderbolt or DisplayPort: macOS starts Knob when
  the screen appears. Over HDMI, Knob starts at login and sleeps until the screen appears: no CPU and
  about 8 MB of memory.
- **Light:** nothing at all while idle, about 1% CPU while sound plays, 15 to 25 MB of memory, and about
  11 ms of added delay, so video stays in sync.

## Requirements

- A Mac with Apple silicon and macOS 15 or later (built and tested on macOS 26; Intel Macs untested)
- Apple's command line tools, for building: `xcode-select --install`
- A screen connected over Thunderbolt, USB-C, DisplayPort or HDMI. Knob is measured over Thunderbolt;
  HDMI uses the same sound path but is less tested.

## Install

Connect your screen, then paste this into Terminal:

```sh
zsh -c "$(curl -fsSL https://raw.githubusercontent.com/TKBuildsApps/knob/main/get.sh)"
```

It downloads Knob to `~/knob`, builds it and runs the installer. Run the same line again to update.
To do it by hand instead:

```sh
git clone https://github.com/TKBuildsApps/knob.git ~/knob
cd ~/knob
./install.sh
```

Setup finds your screen and asks:

1. **Control the screen's sound?** (volume keys, volume and balance)
2. **Open Logi Tune with the screen?** (only asked if Logi Tune is installed)
3. **Any other apps to open with the screen?** Type their names, or press Return to skip.

On first use macOS asks for two permissions. Both are needed only for sound control:

- **Accessibility**, to catch the volume keys.
- **System Audio Recording**, to change the level of the sound on its way to the screen. Knob doesn't
  record, keep or send anything, and has no network code at all.

Knob is installed in `~/Applications`. If you have an Apple Development certificate, it's used for
signing, which keeps the permissions across reinstalls. Without one, each reinstall needs the permissions
again; if the volume keys stay silent after a reinstall, remove Knob from Accessibility and add it back.

## Change or remove

```sh
~/knob/install.sh --setup      # pick the screen, sound control and apps again
~/knob/install.sh --uninstall  # remove Knob, its setup and its saved levels
```

## How it works

- **Starting and stopping.** Setup writes a rule that recognises your screen: its Thunderbolt hub, or
  its DisplayPort link when there is no hub. A LaunchAgent starts Knob when the rule matches, and Knob
  quits when that same thing disappears. An HDMI screen has neither, so the LaunchAgent starts Knob at
  login instead, and Knob watches for the screen by name: it opens the apps and shows its icon when the
  screen appears, and quits the apps and hides the icon 5 seconds after it goes (screens on HDMI can
  drop off for a moment around sleep).
- **Sound.** A muted Core Audio process tap takes what every app sends to the screen. Knob applies your
  volume, balance and the left/right swap, and plays the result back through a private aggregate device.
  At 100% volume and centred balance, the output matches the input sample for sample (with the swap on,
  the two sides trade places, still sample for sample).
- **Sleeping.** The audio path runs only while an app is sending sound to the screen, and sleeps
  3 seconds after the last one stops. Waking takes about 17 ms, so a sound that starts after a silence
  can lose its very first moment.

Measured on an M5 MacBook Pro with macOS 26 and a Thunderbolt 4 monitor:

| | |
|---|---|
| Added delay while playing | ~11 ms (two 256-frame audio cycles) |
| Wake-up after silence | ~17 ms |
| CPU while idle | 0% |
| CPU while sound plays | ~0.1% in Knob, plus ~0.8% in macOS's audio service |
| Memory | ~15 MB at start, ~24 MB once sound has played |

## Troubleshooting

- **What is Knob set up for, and is the screen connected?**
  `~/Applications/Knob.app/Contents/MacOS/Knob --check`
- **Volume keys do nothing:** check that the monitor is the selected sound output, and that Knob is on in
  System Settings > Privacy & Security > Accessibility. If it is on but the keys still do nothing (after a
  reinstall without a developer certificate), remove it from the list and add it back.
- **Left and right are the wrong way round** (balance to the left plays on the right speaker): turn on
  Swap Left and Right in the Knob menu.
- **The menu says Knob needs System Audio Recording:** allow it in System Settings > Privacy &
  Security > Screen & System Audio Recording.
- **Logs:** `log show --last 1h --predicate 'subsystem == "local.knob"'`

## License

[MIT](LICENSE)
