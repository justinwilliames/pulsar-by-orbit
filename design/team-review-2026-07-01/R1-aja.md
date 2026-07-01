# R1 — Aja Williams (Creative Direction: brand + narrative)

## Verdict
Mechanically it's a place-swap; emotionally it's a colour-swap. The cast has a bible but no performance — six siblings who differ in hue and voice but move, glow, and pop *identically*. Fix the character, not the chrome.

## Top 3 findings

**1. The siblings are recolours where it counts most — motion.** `DroneRegistry.swift` defines role + colour + voice beautifully (explorer/reviewer/builder/artist/writer/generalist). But in `FloatingDronePortraitView.swift` every drone shares one bob formula (`sin(time*0.9)`, `cos(time*0.7)`), one `activeScale` (2.4), one `radiusFactor` (0.28), one glow recipe. Voyager the *explorer* should drift wider and restless; Sentinel the *reviewer* should hold dead-still and precise; Nova the *builder* should have a busier, bouncier idle. Right now the role exists in the data model and nowhere the eye can see it. A character you can't tell apart with the sound off isn't a character.

**2. The swap reads as a crossfade, not a trade of places.** `centreOccupant` keys on `.id(drone)` with `.transition(.opacity.combined(with: .scale(0.85)))` — so the outgoing Pulsar dissolves while the incoming drone fades up *in the same spot*. That's a dissolve, not a swap. The signature moment — "my sibling steps up, I step aside" — needs the two to physically pass each other: drone arcs *in* from its orbit slot to centre as Pulsar arcs *out* to that vacated slot, matched-motion, same spring. The data's already there (`orbitList` pins Pulsar's slot). The choreography isn't.

**3. The name-card is a system label, not a cast credit.** `droneNameCard` renders `VOYAGER` in heavy rounded caps on a coloured pill — competent, but it's a status badge, not a nameplate. No role, no signature. "VOYAGER · EXPLORER" (or an iconographic role mark per drone) turns a tag into a character introduction. Right now a viewer learns the colour, never the *who*.

## Single highest-impact fix
**Make the swap a genuine pass-the-baton, and give each drone one signature motion trait.** Concretely, tonight: (a) animate the centre↔orbit transition as matched arcs — incoming drone travels its orbit→centre path while Pulsar travels centre→its pinned orbit slot on the same `.spring(0.5, 0.72)`, replacing the opacity crossfade in `centreOccupant`; (b) drive bob amplitude/frequency and `activeScale` from a per-drone constant in `DroneRegistry` (e.g. `motion: .restless/.still/.bouncy`) so explorer ≠ reviewer at a glance. One is the *only-ever-Pulsar* moment; the other is what stops the cast being a swatch book. Both are small diffs against files already structured for them.

## The one-move-only-Pulsar test
The trade-places *is* the candidate signature — nobody else's robot steps aside for its own sub-agents and lets them wear the crown. But the feature is currently *describing* that move (swap the data, recolour the rim) without *performing* it (the physical pass). Land finding #2 and this becomes ownable. Until then it's a generic speaker-carousel with a good backstory.

## One question for another lens (UX — Yuki)
When 4–6 drones orbit a 240pt zone on `arcStart 20°–arcEnd 160°`, does a swap mid-line read as "Sentinel handed to Nova" — or as visual chaos the user can't parse fast enough to follow *who* is now speaking? Is there a legibility ceiling on simultaneous drones before we should cap or queue?
