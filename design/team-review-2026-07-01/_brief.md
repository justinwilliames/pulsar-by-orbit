# Team Review Brief — Pulsar "sub-agent drones" UX

## What you're reviewing
A macOS menu-bar app (`~/code/caldwell-speak/macos/CaldwellDashboard`). The main
character is **Pulsar**, a friendly indigo AI robot whose animated head floats on
screen and speaks (lip-synced TTS) during Claude Code sessions. New feature: when
the session spawns **sub-agents**, each in-flight one appears as a colour-coded
**sibling "drone" robot** orbiting Pulsar. When a drone is the **active speaker**
it **swaps into Pulsar's central position at full Pulsar size + full glow**, its
colour themes the **subtitle bubble + glow**, a **name-card pill** shows its name,
and it **lip-syncs**; Pulsar swaps out to an orbit slot. Only in-flight drones show.

The 6 drones (locked): voyager (amber, explorer), sentinel (cyan, reviewer), nova
(green, builder), nebula (magenta, artist), echo (teal, writer), atlas (slate,
generalist). Each has a distinct humanoid macOS voice. Robots are premium 3D-
rendered characters.

## Recently fixed (factor in, don't re-litigate)
- Lip-sync **frame jitter** — frames are now ECC-aligned so only the mouth moves.
- Drones **disappearing before finishing speaking** — now persist for the full line.
- **True place-swap** — was: Pulsar shrank into the background; now the drone takes
  the centre seat at full size and Pulsar moves to orbit.

## Read first (read, don't dump)
- `macos/CaldwellDashboard/Sources/Views/Floating/FloatingHeadsView.swift` — place-swap, orbit layout, name card, theming
- `macos/CaldwellDashboard/Sources/Views/Floating/FloatingDronePortraitView.swift` — orbiting drone portrait, pop/swap
- `macos/CaldwellDashboard/Sources/Views/Floating/SubtitleBubbleView.swift` — subtitle bubble + colour
- `macos/CaldwellDashboard/Sources/Views/Shared/PortraitView.swift` — per-drone frame lip-sync
- `macos/CaldwellDashboard/Sources/Models/DroneRegistry.swift` — taxonomy, colours, voices

## Focus — interaction design + visual elegance (this is the point)
- Is the **trade-places** mechanic elegant? How should the swap *animate/feel*?
- **Orbit layout** with up to ~6 drones + Pulsar — legible, or cluttered/colliding?
- **Name-card / label** placement + style.
- The **per-speaker colour system** — coherent? accessible? premium or cheap?
- Do these read as **distinct, characterful siblings**, not recolours?
- Transition/animation polish; anything that reads cheap vs premium.

## Your Round-1 output (save to `R1-<yourname>.md` AND return it as your final message)
- **Verdict** — one line, hard call.
- **Top 3 findings** — your lens specifically. Be concrete (file/behaviour).
- **The single highest-impact fix** you'd ship for this feature.
- **One question** for another lens.
Keep it ≤ 550 words. Voice held. This is an autonomous overnight polish pass — make
findings ACTIONABLE (a dev will implement them tonight), not abstract.
