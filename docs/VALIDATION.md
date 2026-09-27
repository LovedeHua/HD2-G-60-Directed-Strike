# Validation boundaries

The original 0.1 beta published the unchanged 0.5.19 runtime payload. `evidence/tested-payload.json` preserves those hashes.
Beta.1 changes only entry logging and the runtime version. `evidence/release-payload.json` records the new release hashes;
`evidence/logging-windows-validation.json` records its isolated Windows results. Portable tests cover failed log creation,
write/flush/close failures and absent logging service. The beta.1 change has not been retested in a live game.
The private development suite passed 535 checks across Lua/LuaJIT and Python; `evidence/development-validation.json`
records that historical result. The portable public subset is rerun by `scripts/check.py`; it has its own count.
Windows fixture results are in `evidence/windows-validation.json`.

The author confirmed during gameplay iteration:

- Small-enemy exclusion and reacquisition of a supported heavy entering range.
- Tuned enemy attack positions, automatic enemy ordering and exclusive target assignment.
- Ordinary bug-hole explosions after the entrance tolerance adjustment.
- Large colony bug-hole explosions after adding the missing exact resource.

Objective egg targeting, Shrieker Nest destruction and Spore Spewer destruction do not yet have separate gameplay confirmation.
No exhaustive multiplayer, moving-target, terrain or game-version matrix is claimed.
The promotional covers are edited artwork from the author's recording, not test evidence.

The native call path remains explicitly experimental. Build signatures, ownership, identities and observation checks remain enabled,
but stable observations do not prove a native lifetime lease. `native_lifetime_verified=false` is intentional.
The disabled verified-lease path must not be enabled by replacing its evidence checks with constants.
