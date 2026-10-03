# OmaDoctor

A diagnostics panel for [Omarchy](https://omarchy.dev). It runs read-only health
checks across system, audio, storage and network, explains what each finding
means, and produces a redacted report you can paste into a bug report.

It is deliberately **not** another system monitor. It does not graph anything or
sit there collecting history. It answers one question: *what is wrong with this
machine right now, and what do I do about it?*

## What it checks

| Section     | Checks                                                                                         |
|-------------|------------------------------------------------------------------------------------------------|
| `system`    | OS, architecture, kernel, uptime, load, memory, swap, failed units, pending updates             |
| `services`  | PipeWire, WirePlumber, desktop portals, NetworkManager, Bluetooth — each at its real scope       |
| `hyprland`  | compositor version, monitor count, and every configuration error with its file and line          |
| `display`   | attached vs disabled outputs, mode support, mirroring, scale and rotation                            |
| `audio`     | server state, default output/input, volume and mute, device count                                    |
| `storage`   | root and home filesystems, inode usage, root writability, largest directories                        |
| `network`   | interfaces, default route, IPv4/IPv6, DNS config and resolution, gateway, reachability, latency |

`quick` runs the local sections only (system, services, hyprland, display,
audio, storage). `full` adds the network section.

Two details about `services` are worth knowing, because getting them wrong
produces confident nonsense. `NetworkManager` and `bluetooth` are **system**
units — asking `systemctl --user` for them returns `not-found`, so a
user-only list would report two perfectly healthy daemons as missing. And a
unit that simply is not installed is reported as `not installed`, never as a
problem: a laptop with no bluetooth hardware is not broken.

`hyprland` reports configuration errors verbatim — file, line and the
compositor's own wording — because that is the information users otherwise
have to dig out of a terminal. When no Hyprland instance is reachable (a TTY,
a test harness, a nested session) every check reports `unknown`, never a
failure.

`display` answers one question: is the current display configuration
internally consistent? It is not a monitor manager — it never writes a rule
and never reloads Hyprland. Notably it does **not** read `monitors.lua`,
because that file is Lua rather than the classic `monitor=` syntax, and
guessing at it would put a config-parsing failure on the path of a health
verdict. It compares Hyprland's own reported state against itself, which
covers the failures users actually hit: a display that reverts after a
reconnect because its mode is not one the output lists, and a stale rule for
hardware that is not currently attached (a *disabled* output, which is why
this section queries `monitors all` rather than `monitors`).

Two of its checks deliberately report **nothing wrong**. A fractional scale
and a rotated or mirrored panel are choices, not faults; both are surfaced as
informational because each is a frequent cause of "something looks wrong"
that the user cannot otherwise explain. A check that cries wolf on every
scan gets ignored, which costs more than not having the check.

Every check reports one of four states, and the overall verdict is **worst-wins**
rather than an average — one unreadable thing is more actionable than a blended
score:

| State        | Meaning                        |
|--------------|--------------------------------|
| `ok`         | passed                         |
| `info`       | passed, worth knowing           |
| `attention`  | worth a look                   |
| `problem`    | something is actually wrong    |

A section that fails, times out, or produces no output is reported as an
explicit `problem` check. A check that could not be read never reads as healthy.

## Usage

Click the bar icon to open the panel. Left-click opens and closes it, and
right-click re-runs a full diagnosis without opening anything.

Inside the panel:

- **Run full diagnosis** — includes the network section.
- **Copy report** — puts the redacted plain-text report on your clipboard.
- `Esc` closes, `Tab` moves to the next panel, `j`/`k` and the arrow keys move
  between the actions, `Enter` activates.

The bar shows the current state as a glyph and re-runs a quick scan every 30
seconds so the icon is current even when you never open the panel.

### Keyboard shortcut

OmaDoctor is keyboard-first, so a bind is worth setting up. Add this to
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + D", "OmaDoctor", "omarchy-shell shell toggle davedes.omadoctor")
```

`omarchy-shell shell toggle <plugin-id>` is the shell's own method: it opens
the panel if it is closed and hides it if it is open. `SUPER + D` is already
taken by the dictionary lookup on some setups — check with
`omarchy menu keybindings --print` and pick a free combination.

To re-run a full diagnosis without opening anything, invoke the plugin's IPC
handler directly:

```lua
o.bind("SUPER + SHIFT + D", "Diagnose now",
  "quickshell ipc -p $OMARCHY_PATH/shell call davedes.omadoctor runFullScan")
```

Note that `omarchy-shell shell call ...` does **not** reach a plugin's own IPC
handler — it answers `unknown` and does nothing. The `toggle` method above is
different: that one belongs to the shell itself, which is why it works.

### Notifications

OmaDoctor notifies only when the machine gets **worse**, never when it gets
better, and never about a scan you asked for:

| Transition                        | Notification |
|-----------------------------------|--------------|
| healthy → attention / problem     | yes, once    |
| attention → problem               | yes, once    |
| problem stays problem             | no — repeating an unacknowledged warning just trains you to ignore it |
| anything → healthy                | no — you already know you fixed it |
| first scan after login            | no — a baseline is not a transition; this would report the state you have been living with |
| any scan you triggered yourself   | no — the result is already on screen |

The policy is `Model.shouldNotify` in [`Model.js`](Model.js), which is
unit-tested as a truth table because a notification rule can otherwise only be
verified by waiting for something to go wrong.

## Privacy

Everything runs locally. There is no telemetry and nothing is uploaded.

The copied report is redacted by default: hostname, username and home path are
replaced, IPv4 addresses keep only the first two octets (`192.168.x.x`), MAC
addresses become `<mac>`, and IPv6 addresses become `<ipv6>`. The redaction
tests in `tests/model-tests.js` cover the awkward cases — IPv4-mapped addresses
(`::ffff:192.168.1.1`), bare loopback (`::1`), and fully expanded addresses —
along with the false positives that matter, so a timestamp or an uptime string
is never mistaken for an address.

## Installing

```sh
git clone https://github.com/Davedes83/OmaDoctor.git \
  ~/.config/omarchy/plugins/davedes.omadoctor
omarchy-shell shell rescanPlugins
```

Then add it to the right-hand side of your bar in `~/.config/omarchy/shell.json`:

```json
{ "bar": { "layout": { "right": [{ "id": "davedes.omadoctor" }] } } }
```

## Development

```sh
tests/run-tests.sh              # shell suites + Model.js unit tests
omarchy plugin validate .       # manifest and entry-point checks
```

The split is deliberate: `backend/*.sh` emit JSON, `Model.js` does all the
parsing, roll-up, redaction and report rendering, and `Panel.qml` only spawns
the scanner and draws the result. `Model.js` is a QML `.pragma library` with no
QML dependency, so the interesting logic is testable headlessly under `node`.

Parsing third-party tool output is kept as pure functions so it can be pinned
with fixtures instead of only being observed on one live machine — see
`backend/wpctl-parse.sh` with `tests/wpctl-tests.sh`, and
`backend/hyprctl-parse.sh` with `tests/hyprctl-tests.sh`.

The hazard is the same in both cases, and it is not hypothetical. `wpctl` has
no `get-default-sink` subcommand: calling one prints a usage banner whose first
line is `Usage:`, and the audio section once reported that string as a healthy
device name. `hyprctl` is worse in three ways — an unknown subcommand answers
`unknown request`, a missing compositor answers `HYPRLAND_INSTANCE_SIGNATURE
not set!`, and **all of these exit 0**, so the exit status says nothing.
Every parser therefore requires a positive structural token before returning a
reading, and yields nothing otherwise. A check that read nothing is reported as
`unknown`, which is the honest answer and never a fault.

That is also why the spawner passes exactly two extra variables.
`HYPRLAND_INSTANCE_SIGNATURE` names the compositor's per-instance socket and
`XDG_RUNTIME_DIR` is the user runtime directory; without the first, `hyprctl`
cannot work at all, and without the second `systemctl --user` cannot reach the
user bus — both print an error and exit 0. They grant no capability beyond
talking to your own session, so the hardened environment is otherwise
unchanged: a fixed root-owned `PATH`, a pinned locale, and nothing inherited.

Every helper is spawned through a hard deadline:

```
timeout -k 2 N /bin/sh backend/run-capped.sh /bin/sh backend/doctor.sh <mode>
```

`run-capped.sh` caps stdout at 1 MB, and the process runs with a cleared
environment and a fixed `PATH` so nothing inherited from the shell can
influence it. Because `doctor.sh` runs its sections sequentially behind
per-section deadlines, the outer budget must exceed their sum — see
`budgetFor()` in `Panel.qml`.

## Status

Read-only by design. It diagnoses and explains; it does not repair anything.
A finding may describe what a fix *would* be — its risk tier and a one-line
label — but OmaDoctor never runs it, never restarts a service, and never edits
your configuration. The report says so whenever a finding carries one.

## License

MIT — see [LICENSE](LICENSE).