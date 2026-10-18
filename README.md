# display_control

Disconnect and reconnect displays on macOS from the command line, including the built-in panel.

Two optional diagnostic tools are included: `probe` and `lid_watch`. Neither one changes display state.

## Installation

Requires macOS with the Xcode Command Line Tools:

```bash
xcode-select --install
```

Build:

```bash
swiftc -O display_control.swift -o display_control
swiftc -O probe.swift           -o probe        # optional
swiftc -O lid_watch.swift       -o lid_watch    # optional
```

Optionally put `display_control` on your `PATH`:

```bash
sudo mkdir -p /usr/local/bin
sudo install -m 755 display_control /usr/local/bin/
```

To uninstall, delete the binary.

## display_control

```
display_control list                 List displays and available actions
display_control off [ID|builtin]     Disconnect a display
display_control on  [ID|all]         Reconnect a display, or all of them
```

- With no argument, `off` and `on` show a numbered menu of the displays you can act on.
- `builtin` means the built-in panel. `all` reconnects every display that can be reconnected.
- At least one display always stays connected. Mirrored displays cannot be disconnected.

Example:

```text
$ display_control list
Displays (live scan):
  [1] Built-in Retina Display (built-in)  connected  1470x956
  [2] ARZOPA  connected  2560x1600  main
Can disconnect: 2, 1
Can reconnect:  none

$ display_control off 1
Disconnected [1] Built-in Retina Display (built-in)

$ display_control on 2
Reconnected [1] Built-in Retina Display (built-in)
```

A disconnected display stays off until you run `on`, log out or reboot. Closing and reopening the lid does not bring it back, and neither does unplugging and replugging the cable.

**If no screen is visible**, log out or reboot. All displays come back after that.

## probe (for debug)

Prints what macOS reports about each display: display lists, details for each display ID, and hardware entries.

```bash
./probe [extra IDs ...]
```

Compare the output before and after a disconnect:

```bash
./probe > before.txt
display_control off 2
./probe > after.txt
display_control on 2
diff before.txt after.txt
```

## lid_watch (for future improvement)

Prints events with timestamps as they happen: lid open and close, system sleep and wake, and displays being added, removed, enabled or disabled.

```bash
./lid_watch | tee lid.log    # Ctrl+C to quit
```

Close and reopen the lid while it runs, then check `lid.log`.
