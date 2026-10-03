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

### The two IPC routes are not interchangeable

Both of these look almost identical and only one of them works:

```sh
# WORKS -- omarchy's own shell methods (toggle/summon/hide)
omarchy-shell shell toggle davedes.omadoctor

# WORKS -- the plugin's own IPC handler, via qs ipc
qs ipc -p "$OMARCHY_PATH/shell" call davedes.omadoctor runFullScan

# DOES NOT WORK -- answers "unknown" and does nothing
omarchy-shell shell call davedes.omadoctor runFullScan
```

`omarchy-shell shell call` dispatches to the **shell's** methods, and a bar
widget is never registered there. The plugin's handler is reached through
`qs ipc`, where the first argument is the IPC *target*. Note the word order
differs between the two working forms: `<omarchy-shell> shell <method>` versus
`qs ipc ... call <target> <method>`.

Available plugin methods: `runFullScan`, `copyReport`, `state` (returns the
panel's live state as JSON), plus `open`, `close`, `show`, `hide` and `toggle`.

## Ask AI

The third action hands the redacted report to **your** AI and asks it to
research each finding and propose a fix. It exists because the person reading a
diagnostic report often does not already know the answer.

**It uses your assistant, not a specific one.** On startup the plugin probes
your `PATH` for `opencode`, `mods`, `llm`, `aichat`, `fabric`, `aider`,
`gemini`, `claude`, `codex` and `ollama`, in that order, and uses the first one
it finds. Anything it does not know about still works — see `askAiCommand`
below. You can see what it resolved to from the button's tooltip, or:

```sh
qs ipc -p "$OMARCHY_PATH/shell" call davedes.omadoctor state | jq .ai
```

### Nothing is sent without you saying so

This plugin's whole premise is that nothing leaves your machine, and an AI query
does. So OmaDoctor **never** sends anything on its own initiative. Pressing
**Ask AI** opens a sheet showing:

- the exact command that will run,
- whether it is a local model or a remote provider,
- a preview of the text that will be sent, put through the same redactor as the
  report.

Then **Send**, **Copy** (puts the prompt on the clipboard instead, for pasting
into anything), or **Esc**. If no supported CLI is found it says so and copies
the prompt rather than doing nothing.

The answer is written to `~/.local/state/omadoctor/ai-answer.txt` and put on
the clipboard.

### Settings

| key | default | meaning |
|---|---|---|
| `askAiCommand` | `""` | full command line, e.g. `ollama run llama3.2`. The report is fed on **stdin**. Empty means auto-detect. |
| `askAiModel` | `""` | model name, for assistants that require one. `ollama run` has no default-model mode. |

Anything not in the built-in list works through `askAiCommand`. The command line
is split into an argv and handed straight to the process — it is never passed to
a shell, so nothing in it can be interpreted as syntax.

## Settings

A bar widget's settings are the keys of its own entry in `shell.json`'s
`bar.layout.<section>`, beside the `id` — never nested under a `settings:`
sub-object, which arrives as `settings.settings.size` and silently does nothing
at every value.

```json
{ "id": "davedes.omadoctor", "pollSeconds": 300, "notifyOnProblem": false }
```

| key | default | meaning |
|---|---|---|
| `pollSeconds` | `0` | background scan interval. `0` disables it. |
| `notifyOnProblem` | `true` | notify on a worsening transition |
| `askAiCommand` | `""` | see [Ask AI](#ask-ai) |
| `askAiModel` | `""` | see [Ask AI](#ask-ai) |

The background poll defaults to **off**. A quick scan is a multi-process run of
a couple of seconds, and doing that every 30 seconds forever on every monitor,
purely to keep a bar glyph fresh, is the plugin's largest steady-state cost.
Opening the panel still runs a full scan, so the only thing lost is background
freshness.

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

## What changed

The panel shows a single line when something moved since the previous scan —
`1 new issue (Gateway) since the last scan`, or `2 issues resolved`. It is
muted unless something got worse.

It reports **status transitions only, never changed values**. Uptime ticks,
latency jitters and memory drifts on every scan; a line that always has
something to say is the same noise problem as a chatty notification. A check
whose reading moved while its status held is not news.

A check that *disappears* is deliberately not reported as resolved. That
usually means a section stopped running, and calling it fixed would be the most
misleading thing this panel could do.

Short history is kept in `~/.local/state/omadoctor/history/` so the feature
survives a shell restart — otherwise it would be silent exactly when you most
want it, right after logging in. Two deliberate limits:

- **Written on full scans only.** A quick scan runs every 30 seconds; one file
  per poll would be thousands of files a day.
- **Capped at the newest 20, ~80 KB total.** Each entry is a compact
  `{"id":"status"}` map (~1 KB), not a full scan document (~7 KB) — the diff
  only needs status, and takes titles and values from the current scan.

## Privacy

Everything runs locally. There is no telemetry and nothing is uploaded.

The copied report is redacted by default. What is replaced:

| | becomes |
|---|---|
| hostname (bare token) | `<host>` |
| username, `/home/<user>` | `<user>`, `/home/<user>` |
| `$HOME` | `~` |
| `/root` | `~` |
| `/mnt/<volume>`, `/media/<volume>` | `/mnt/<volume>` |
| IPv4 | first two octets kept: `192.168.x.x` |
| IPv6, including the zone suffix | `<ipv6>` |
| IPv6 with an embedded IPv4 tail | `<ipv6>` |
| MAC in colon, dash, Cisco, dotted-octet, underscore or bare-hex form | `<mac>` |
| filesystem UUID | `<uuid>` |
| disk / volume serial | `<serial>` |
| SSID | `<ssid>` |
| interface names (`enp0s31f6`, `wlp3s0`, or anything after `dev`) | `<iface>` |

A **dotted** token equal to the hostname is treated as a domain and left alone.
OmaDoctor's default hostname is literally `omarchy`, and the DNS evidence quotes
the public site `omarchy.org`; masking that would destroy a fact about a
website in order to redact a fact about your machine, leaving the report unable
to say which lookup failed.

Two shapes are deliberately **not** masked, because masking them was worse than
leaving them:

- `hyprland.lua:42:12` — `file:line:col`. An early IPv6 matcher accepted any
  2- or 3-group colon run as an address and printed `hyprland.lu<ipv6>`, in a
  report whose own advice is "open the file and line named in each error". An
  uncompressed IPv6 is always exactly 8 groups and every compressed form
  contains `::`, so the test is now exact.
- `08:04:18`, `1:2:3` — clock times and versions.

### When redaction cannot be complete

If the plugin cannot determine one of the identifiers it needs, the report says
so in its own header rather than quietly omitting the rule:

```
Redaction  : INCOMPLETE -- could not determine hostname. Read the report before sharing it.
```

This is not hypothetical defensive code. `HOSTNAME` is a shell variable, not an
environment variable, so it is frequently absent from the process environment —
verified on the machine this was developed on, whose shell process has no
`HOSTNAME` at all. The plugin reads the hostname from
`/proc/sys/kernel/hostname` for exactly this reason.

## Requirements

Everything below is present on a default Omarchy install, and every external
command is invoked by absolute path or through a pinned `PATH`, so a missing one
degrades a single check to `unknown` rather than breaking the scan.

| dependency | used for | if absent |
|---|---|---|
| `coreutils` (`timeout`, `head`, `tr`, `sort`, `sed`, `awk`, `grep`) | every probe | the scan cannot run |
| `jq` | history pruning and the test suite | history is not written; everything else works |
| `wl-clipboard` | **Copy report** | the report is not copied |
| a Nerd Font (JetBrains Mono Nerd Font, which Omarchy sets) | the bar glyph and panel icons | icons render as tofu |
| `ping` (iputils) | latency and packet loss | `network.latency` reports `unavailable` |

## Installing

```sh
omarchy plugin add https://github.com/Davedes83/OmaDoctor.git --enable
```

Or manually:

```sh
git clone https://github.com/Davedes83/OmaDoctor.git \
  ~/.config/omarchy/plugins/davedes.omadoctor
omarchy-shell shell rescanPlugins
```

Then add it to the right-hand side of your bar in `~/.config/omarchy/shell.json`:

```json
{ "bar": { "layout": { "right": [{ "id": "davedes.omadoctor" }] } } }
```

## The check contract

Every section emits check objects. This is the whole interface between
`backend/*.sh` and `Model.js`, and anything that does not match it is either
normalised on the way in or reported as malformed.

```jsonc
{
  "id": "display.modes",          // stable key; "what changed" diffs on this
  "category": "display",          // section; drives grouping and report order
  "title": "Modes",               // short human label for the row
  "status": "attention",          // ok | info | attention | problem
  "severity": 1,                  // 0 | 1 | 3 -- see below
  "value": "unsupported mode set",// the reading, shown in the bar/row
  "detail": "an output is running a mode it does not list as available",
  "suggestion": "This is why a display can revert after a reconnect",
  "details": ["affected: DP-2 at 1920x1080@60.00"],   // optional, multi-line evidence
  "repair": {                     // optional, ADVICE ONLY -- never executed
    "tier": "caution",            // safe | caution | manual
    "label": "Adjust the monitor rule's mode",
    "detail": "OmaDoctor never edits your monitor configuration"
  }
}
```

Two rules are load-bearing and both fail **closed**:

- **`status`** is one of the four values above. Anything else becomes `problem`.
  A malformed producer must not be able to make a finding disappear.
- **`severity`** is authoritative when it is `1` or `3`. If a producer
  contradicts itself, the more serious of the two wins. `0` means "not ranked"
  and defers to `status`.

`details` and `repair` are optional and purely additive: a check without them
normalises to `[]` and `null`, so producers and renderers interoperate.

An **empty** scan is `problem`, not `ok`. It means nothing was inspected, which
at the UI layer is indistinguishable from "nothing is wrong" — so the panel
reads `PROBLEM`, the notification is suppressed (there is no transition), and
the report says so rather than claiming all clear.

## Adding a section

Five places, across three files. Missing any of them is how a section ends up
invisible or how a scan gets killed mid-write.

1. **`backend/<name>.sh`** — emit via the `check`/`checkd`/`checkr` helpers
   from `common.sh`. Source `bootstrap.sh` *first*, then `common.sh`. Honour
   `--checks-only` by passing it through to `emit_json`.
2. **`backend/doctor.sh`** — add a deadline in `deadline_for()` and a
   `add_section <name>` call.
3. **`backend/doctor.sh`** — if the section belongs only to a full scan, add it
   next to the `network` line, which is gated on `MODE`.
4. **`Model.js`** — add the category to the `order` array in `byCategory()` if
   it should not sort last. Unlisted categories still work.
5. **`Panel.qml`** — raise `budgetFor()`. The outer `timeout` must exceed the
   **sum** of the per-section deadlines, because `doctor.sh` runs them
   sequentially. Its own comment says this; adding a section without raising it
   is how a scan is killed mid-document and arrives unparseable.

The test fixtures in `tests/backend-tests.sh` copy `doctor.sh`, `bootstrap.sh`
and `common.sh` into a temp directory. If you add a new section, the fixtures
that stub sections out do not need it, but any fixture that runs the real
dispatcher does.

## Development

```sh
tests/run-tests.sh              # shell suites + Model.js unit tests
omarchy plugin validate .       # manifest and entry-point checks
```

The suites also run under other POSIX shells:

```sh
OMC_TEST_SH="bash --posix" tests/run-tests.sh
OMC_TEST_SH="dash"           tests/run-tests.sh
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