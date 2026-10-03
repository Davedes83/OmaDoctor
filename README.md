# OmaDoctor

A diagnostics panel for [Omarchy](https://omarchy.dev). It runs read-only health
checks across system, audio, storage and network, explains what each finding
means, and produces a redacted report you can paste into a bug report.

It is deliberately **not** another system monitor. It does not graph anything or
sit there collecting history. It answers one question: *what is wrong with this
machine right now, and what do I do about it?*

## What it checks

| Section   | Checks                                                                                     |
|-----------|--------------------------------------------------------------------------------------------|
| `system`  | OS, architecture, kernel, uptime, load, memory, swap, failed units, pending updates           |
| `audio`   | server state, default output/input, volume and mute, device count                            |
| `storage` | root and home filesystems, inode usage, root writability, largest directories                |
| `network` | interfaces, default route, IPv4/IPv6, DNS config and resolution, gateway, reachability, latency |

`quick` runs the local sections only (system, audio, storage). `full` adds the
network section.

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
`backend/wpctl-parse.sh` and `tests/wpctl-tests.sh`. A command that answers an
unknown subcommand with a usage banner, or an error message that happens to
contain digits, must never be scraped for a reading; the audio checks are the
worked example of a check that once displayed "Usage:" as a healthy device.

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

## License

MIT — see [LICENSE](LICENSE).