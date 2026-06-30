# R5 — Marcus Holm, Product Designer (UI + craft)
_Round 5 — sign-off_

---

## Verdict

I agree.

The action plan lands clean. The three principles the team ships against — observable before selectable, every silent state has a recovery path, one identity with character as the choice — are exactly the hierarchy I'd design to. They didn't need me to argue them; they came out of the convergence naturally. That's a good sign the team read the same product.

## On ship-now item #4

Persona (Polite/Potty) control above the fold — confirmed honoured. The action plan writes it without equivocation: Character is the first section in `SettingsView`, unconditional, no dependency on any other fork. That is precisely my line. The framing is exactly right: if the engine question dissolves in the bake-off, Character gets *more* room, not less. One afternoon, no blocking dependency, no ambiguity. I'll own the diff.

## One caveat worth naming, not blocking on

The open question I raised in R3 — what surfaces credit exhaustion gracefully in a toggle-invisible world — is still architecturally unresolved. The action plan defers the Section 2 IA restructure until after Sir's calls land, which is correct sequencing. But if the exhaustion state ends up in a disclosure-level banner with no container to anchor it, the IA work Yuki and I did in R2 needs a third pass. I'm flagging it, not blocking on it. The floor ships clean without it, and it's the right gate to hold.

## What I learned across five rounds

Consensus on the *surface* (the panel structure, the toggle grammar) arrived in Round 2, but it was a false convergence — the real question, whether engine is ever visible at all, had to bubble up through the story pair before the hierarchy arguments underneath it could settle.

Marcus
