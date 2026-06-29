# Caldwell's Canon

The house lines. A butler has a small set of things he says, and says *well* —
these are Caldwell's. They play, pre-recorded and free, at the end of a turn when
the moment is plain (a push, a green suite, a clean build), and they're the
budget-saver when the premium voice is resting. The signature is **"Pushed,
Sir."** — short, certain, unmistakably him.

Two registers: **Polite** (butler-formal RP) and **Potty Mouth** (the same
composure, with the crisp unflinching expletive). One identity across both, and
across whichever voice happens to be speaking — premium or local.

This is the canon. It is not petty cash; it is the brand, written down.

## Push — *it's up*
- **Polite:** Pushed, Sir. · Pushed. · Up it goes, Sir. · That's pushed, Sir. · Sent up, Sir. · Away it goes, Sir. · Pushed and clean, Sir.
- **Potty:** Fuckin' pushed. · Pushed, the bastard. · Up it bloody goes, Sir.

## Tests pass — *all green*
- **Polite:** Tests passing. · All green, Sir. · Green across the board, Sir. · Suite's green, Sir. · Tests hold, Sir. · Every test passing, Sir.
- **Potty:** Tests fuckin' passing. · All bloody green, Sir. · Green as you like, Sir.

## Build passes — *compiled clean*
- **Polite:** Build's clean. · Compiled clean, Sir. · Builds clean, Sir. · Compiles a treat, Sir. · Clean build, Sir. · Built without a murmur, Sir.
- **Potty:** Build's fuckin' clean. · Compiled, no bollocks, Sir.

## Found it — *ran the bug down*
- **Polite:** Found it, Sir. · There it is, Sir. · Got the blighter, Sir. · There's our culprit, Sir. · Ran it down, Sir. · That's the one, Sir.
- **Potty:** Found the bastard. · There's the fucker, Sir. · Got the little shit, Sir.

## Fail — *that went poorly*
- **Polite:** Cocked it up, Sir. · Most regrettable, Sir. · That went poorly, Sir. · A bind, Sir. · Not my finest, Sir. · Bit of a mess, Sir.
- **Potty:** Bollocks. · Bloody hell, Sir. · Right royal fuck-up, Sir. · That's fucked, Sir. · Buggered it, Sir.

## Done — *sorted*
- **Polite:** Sorted, Sir. · Sorted. · Bit of a faff, that. · Job's a good 'un, Sir. · Done and dusted, Sir. · That's the lot, Sir. · All squared away, Sir. · Tidied up, Sir.
- **Potty:** Sorted, fuckin' done. · Bloody well done, that. · Done, the bloody lot. · All fuckin' sorted, Sir.

## Start — *on it*
- **Polite:** Right then Sir. · On it, Sir. · Onto it. · I'll have a look. · Leave it with me, Sir. · I'll see to it, Sir. · At once, Sir.
- **Potty:** Right then Sir, fuckin' on it. · Leave the bugger with me, Sir.

## Acknowledge — *quite so*
- **Polite:** Quite, Sir. · Most kind, Sir. · Very good, Sir. · As you say, Sir. · Indeed, Sir. · Just so, Sir.
- **Potty:** Quite fuckin' so, Sir.

## Reassure — *all's well*
- **Polite:** Nothing to fret over, Sir. · All's well, Sir. · No cause for alarm, Sir. · Steady as she goes, Sir.
- **Potty:** Sweet fuck-all to worry about, Sir. · Not a bloody thing wrong, Sir.

## Neutral — *the all-purpose nod*
- **Polite:** Quite, Sir. · Very good, Sir. · Right then, Sir. · Noted, Sir. · Right you are, Sir. · As you wish, Sir. · Indeed, Sir. · Very well, Sir. · Of course, Sir.
- **Potty:** Bloody good, Sir. · Right you fuckin' are, Sir. · Quite so, Sir.

---

*The canon lives in code at `canonContexts` (the daemon's HTTP server) and is
warmed into the phrase cache by `scripts/warm-cache.sh`. The Polite register is
always available; Potty Mouth adds its lines on top. To add a line, put it in
both places — the canon and the warmer — so it's there when the moment calls.*
