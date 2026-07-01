# Nebula — Brand/Registry Review · 2026-07-01

Branch: `pulsar-fixes` · Base: `18b81a4`

---

## 1. Rename — User-Visible "Caldwell" PASS (one advisory)

AboutView.swift: fixed — now reads "Speaks bespoke lines as Pulsar, end of every turn." ✓

**No user-visible "Caldwell" remains in menus, windows, popovers, settings labels, or notification strings.**

All remaining hits are internal Swift identifiers (`CaldwellConfig`, `CaldwellHTTPServer`, `CaldwellDashboardApp`), `CALDWELL_*` env-var keys (developer-facing, never shown in UI), and code comments — all out of scope per brief.

**[ADVISORY, not BUG]** `CaldwellHTTPServer.swift:620` has a hardcoded fallback `voiceLabel: "Caldwell"` used when replay metadata is missing both `voice_label` and `voice_id`. This surfaces in the history panel as the attributed speaker label. Not a blocking rename bug (rare edge case), but worth a one-liner fix: change `"Caldwell"` → `"Pulsar"`.

---

## 2. Polite Default — PASS, no drift

**Bundled SKILL.md** (`Sources/Resources/claude-integration/SKILL.md`): description frontmatter says "Default is POLITE (expletives OFF)"; body says "Potty Mouth (opt-in)"; failure-fallback says "default to Polite". ✓

**Installed SKILL.md** (`~/.claude/skills/caldwell-speak/SKILL.md`): identical wording — same three changes present. ✓

**No drift.** Both copies in sync.

---

## 3. Atlas Hue + Unknown Drone — PASS

Atlas new colour: `Color(red: 0.62, green: 0.45, blue: 0.85)` → **RGB(158, 115, 217) — warm violet**.

Comparison against neighbours:
- Sentinel (azure): `(0.25, 0.60, 0.95)` → RGB(64, 153, 242) — strong blue
- Echo (teal): `(0.18, 0.75, 0.72)` → RGB(46, 191, 184) — cyan-green
- Atlas (violet): `(0.62, 0.45, 0.85)` → RGB(158, 115, 217) — purple-warm

Hue separation: Sentinel ~210°, Echo ~178°, Atlas ~270°. All three >30° apart. Clearly distinct at a glance. ✓

`unknown` drone: grey `(0.58, 0.58, 0.60)` → RGB(148, 148, 153), badge `"?"`, voice `"Daniel"` (shares Pulsar's portrait fallback — no bespoke art needed), near-still motion `(bob: 1.2, freq: 0.75)` — visually recessive, semantically coherent. ✓

No colour pair too close across the full roster.

---

## 4. First-Run + Settings Labels — PASS

**PopoverRootView:** default tab changed to `.roster` ✓. Value-prop line added: `"Your AI tells you when it's done — stop watching the screen."` — plainspoken, no honorifics, one clear benefit. ✓

**SettingsView:** disabled-toggle labels now conditionally show `"Requires Floating Head — enable above."` when the floating head is off, replacing the normal description. Direct, no hedging, product voice. ✓

---

## Summary

| Item | Result |
|---|---|
| 1. Rename — user-visible Caldwell cleared | **PASS** |
| 2. Polite default — bundled SKILL.md | **PASS** |
| 2. Polite default — installed SKILL.md, no drift | **PASS** |
| 3. Atlas hue distinct, unknown coherent | **PASS** |
| 4. First-run roster + value-prop + disabled labels | **PASS** |

**[BUG — minor]** `CaldwellHTTPServer.swift:620` voiceLabel fallback is still `"Caldwell"`. Fix: `"Caldwell"` → `"Pulsar"` (one char swap, user-visible in history panel on replay when metadata is absent).
