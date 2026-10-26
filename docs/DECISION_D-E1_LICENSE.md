# Decision D-E1: the licence of our Swift layer (draft for the owner, 2026-10-26)

**Status: open. This is a business and legal decision that only the owner can make; this page prepares it. Nothing here is legal
advice (LIC-5, LIC-7 stay `[lawyer]` / `[manual]`).**

## Where things stand

- The repository's `LICENSE` file is **MIT** (it came with the initial commit, as a placeholder). The decisions table in
  `docs/ACCEPTANCE_CRITERIA.md` says the working default is "proprietary EULA over LGPL FFmpeg binaries". The two disagree.
  **Do not publish the repository, a release, or a package URL until this is settled**: with the MIT file in place, anyone
  could use, copy and resell the Swift layer.
- Whatever is chosen, FFmpeg (LGPL-2.1-or-later), dav1d (BSD-2-Clause), libass (ISC), FreeType (FTL), HarfBuzz (MIT) and FriBidi
  (LGPL-2.1-or-later) keep their own licences and are shipped as binaries with their notices (`third_party/NOTICES.md`,
  `MediaEngine.acknowledgements`), a source pack (`scripts/make-source-pack.sh`) and a procedure for replacing the LGPL
  frameworks (`docs/REPLACING-FFMPEG.md`). Our Swift layer links FFmpeg **dynamically**, so it can stay proprietary.

## Options

| | A. Proprietary licence (EULA), binaries and source for licensees | B. Source-available (for example a business-source or PolyForm-style licence) | C. Open source (MIT or MPL-2.0), sell support and the app |
|---|---|---|---|
| Can the engine be sold as a product (D-E4, D-E5)? | yes, per seat, per app or per company | yes, with a licence key or a trust model; terms must say what "use" means | only indirectly (support, early access, the PlayerApp) |
| Customers see the code | after signing; private repository | everyone can read; use needs a licence | everyone |
| Risk of free copying | contract only | contract; code is visible | none prevented |
| Fits the LGPL parts | yes: the EULA must not forbid replacing the LGPL frameworks or reverse engineering to debug such a modification (LIC-5) | same | yes |
| Work needed | EULA text (lawyer), `LICENSE` replaced, delivery by private repo or authenticated binary hosting (D-E2) | licence text (lawyer), a licence-key or honour system | none beyond this repo |
| Fit with "later licensed and sold to other developers" (`CLAUDE.md`) | best | possible | weak |

## Recommendation (assistant, for discussion)

**Option A**: a proprietary licence with a private repository for customers, because the stated plan is to sell the engine to
other developers, and the PlayerApp, which is ours, needs nothing from the licence. The engine is already structured for it:
LGPL parts are replaceable, notices ship at run time, the patent profiles are separate binaries so a customer can choose.
Start with a one-page licence from a template, have a lawyer review it together with the codec question (LIC-6), and keep
the engine closed until the first customer.

## What follows once you decide

1. Replace or keep `LICENSE`; add `LICENSE-THIRD-PARTY` pointing at `third_party/NOTICES.md` (generated acknowledgements already carry the texts).
2. Draft the EULA (LIC-5): the LGPL clause (no ban on replacing or debugging the LGPL frameworks), the trademark rules (FFmpeg is
   not ours, spell it "FFmpeg"), the patent statement from `docs/PATENT_PROFILES.md`, support and warranty terms.
3. Choose the delivery channel (D-E2, spike E-S5) and the selling entity and payment stack (D-E4).
4. Tick LIC-7 and mark D-E1 decided in `docs/ACCEPTANCE_CRITERIA.md`.
