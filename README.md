# omarchy-daikin

An [Omarchy](https://omarchy.dev) bar widget + panel for the **Daikin
BRP072A43** mini-split Wi-Fi adapter — plus a standalone CLI that powers
it. No cloud, no account: the adapter exposes an unauthenticated local
HTTP API on port 80, and this talks to it directly.

This is an independent Linux port by the author of the (private)
DaikinMiniSplit project. Protocol reference: the BRP072A43 endpoints as
documented by the [Home Assistant Daikin integration](https://www.home-assistant.io/integrations/daikin/).

## What you get

- **Bar chip** — a small fan mark (it spins while the unit runs). State
  is shown by color, keeping the taskbar clean: **grey = off, red =
  heating, blue = cooling** (dry/fan/auto get distinct tints).
  Right-click toggles power; left-click opens the panel.
- **Panel** — power switch, live indoor/outdoor/compressor readouts,
  setpoint slider (±0.5 °C buttons), mode, fan speed, swing, device
  info, and error display. Fully keyboard-navigable like other Omarchy
  panels.
- **`daikin` CLI** — shipped inside the plugin (`bin/daikin`, Python 3
  stdlib only). Also usable from a terminal:

  ```sh
  CLI=~/.config/omarchy/plugins/daikinsplit/bin/daikin
  $CLI status                       # merged device state as JSON
  $CLI set --power on --mode cool --temp 70 --fan auto --swing off
  $CLI set --power off              # partial: other values merged from device
  $CLI set --temp-c 21.5 --dry-run  # preview the request without sending
  $CLI get /aircon/get_control_info # raw endpoint response
  $CLI discover [PREFIX] [--json]   # find adapters on the LAN
  $CLI schedule                     # weekly schedule
  $CLI config show | $CLI config set <ip>
  ```

  Global options (`--ip`, `--timeout`, `--config`) are accepted before
  or after the subcommand; rightmost wins.

## Install

```sh
omarchy plugin add https://github.com/keylimesoda/omarchy-daikin
omarchy plugin enable daikinsplit
```

Only dependency: Python 3.8+ (standard library).

### First run: adapter discovery

On first run the widget finds your adapter automatically: it scans the
local subnet (a quick read-only liveness sweep, then a gentle probe of
live hosts) and, when exactly one Daikin adapter is found, saves its IP
to `~/.config/daikin/config.json`. If several are found, the panel shows
a picker (room name + IP). You can also pin an address up front:

- set the widget's **Device IP** setting, or
- `~/.config/omarchy/plugins/daikinsplit/bin/daikin config set <ip>`

## Omarchy IPC

Other widgets can drive the unit (target `daikinsplit`):

```sh
omarchy-shell daikinsplit togglePower
omarchy-shell daikinsplit setMode cool
omarchy-shell daikinsplit setTempC 21.5
omarchy-shell daikinsplit refresh
omarchy-shell daikinsplit discover
# device-safe test: prints the request it WOULD send, touches nothing
omarchy-shell daikinsplit dryRun '{"power":"on"}'
omarchy-shell daikinsplit dumpState   # inspect state + last action
```

## Safety notes

- The adapter's web server is **single-threaded**: poll at most every
  5–10 s (the widget polls every 30 s; discovery never runs in the poll
  loop).
- `/aircon/get_week_power` and `/aircon/get_year_power` **crash the
  adapter** (breaker reset required). The CLI refuses them on purpose.
- Rapid OFF→ON toggling triggers the unit's 3-minute compressor guard.
- The unit applies an internal 1 °C offset (heat +1, cool −1 on the
  wire); the CLI compensates transparently, so displayed temperatures
  match the wall display.

## Development

```sh
omarchy plugin validate .     # check the manifest against Omarchy's schema
```

The QML targets the Quickshell APIs used by current Omarchy shells
(`Process`/`StdioCollector` from `Quickshell.Io`, IPC handlers, the
`qs.Ui` toolkit).

## License

[MIT](LICENSE) © keylimesoda