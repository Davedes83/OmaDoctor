# OmaDoctor TODO

Tracked improvements for the OmaDoctor Omarchy plugin.

## Items

- [x] Show all checks (collapsed/expandable section) - Panel.qml + Model.js
  - allFindingRows() added to Model.js; showAllChecks toggle in Panel.qml settings; tests added.
  - SECURITY FIX: all FindingRow Text elements now use Text.PlainText so attacker-controlled
    device names (from wpctl/audio parsing) cannot be interpreted as AutoText image tags.

- [x] Scan on resume/unlock via Omarchy hook - hooks + Panel.qml
  - hooks/wake-scan.sh created; README documents how to install as a wake hook and wire to systemd-sleep / Hyprland unlock.

- [x] User-scope failed units + journalctl -p 3 -b - backend/sysinfo.sh
  - Report user-scoped systemd units that failed, and pull boot-time priority-3 journal messages via journalctl.

- [x] Network semantics (attention not problem for missing route; ping -w; NM gate) - backend/network.sh
  - Treat missing route as attention rather than problem, add bounded ping with -w, and gate checks behind NetworkManager availability.

- [x] Trim duplicate work (df twice per fs; jstr/jnum forks) - backend/*.sh, common.sh
  - Eliminate repeated df calls per filesystem and reduce jstr/jnum subprocess forks across backend scripts. Done: check_fs uses the df line it already has; jnum is now a case pattern; root/home share-dev guard added.

- [x] Regression tests for fixed bugs - tests/
  - Add test coverage for previously fixed bugs to prevent regressions. Covered: svc_state "failed failed", jstr newline, json_fragment_ok wrapped-section, severity_for_pct info, buildReport null scan, disabled-output line counting.

- [x] Settings discoverability UI (poll/notify toggles) - Panel.qml
  - Added settings section with polling, notifications, and show-all-checks toggles; togglePolling/toggleNotifications now wired to UI.

- [ ] Marketplace verification - omacom/omarchy-plugin-marketplace#14273
  - Validation passed; security baseline returned review-required with Conditional Medium finding on AutoText in FindingRow. Fix the AutoText issue, push new commit, create new verification issue.
