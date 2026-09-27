# Compatibility and troubleshooting

This release requires Bingus Shared Loader API 1 with addon discovery (v15+) and a compatible Windows x64 game runtime.
Development gameplay was tested under Proton. Native layouts and instruction signatures are tied to the inspected game build;
a game update can make activation or an operation refuse to run. Do not remove guards to force compatibility.

The log is `G60SmartTargeting.log` under:

- Windows: `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs`
- Proton: your Steam library's `steamapps/compatdata/553850/pfx/drive_c/users/steamuser/AppData/Local/CowboyBingus/Helldivers2/Logs`

Beta.1 reports `version=0.5.20-experimental` with `marked_structures=true`.
Logging is optional: an unavailable log service or a failed file operation does not disable targeting.
If a marked structure does not attract a grenade, look for `structure_mark`, `structure_unavailable` or `structure_stalled`.
`RESOURCE_NOT_SUPPORTED` means its exact entity resource is outside the whitelist. `NO_ENTITY_MARK` means no valid entity was identified.
`NATIVE_TARGET_INVALID` can mean the target has already been destroyed. Pose/read failures refuse the action.

Only the local player's supported entity marks count. Ground pings do not identify a structure.
Targets beyond the 200 m observation/guidance bound are not accepted. Normal enemy targeting depends on available game candidates.
If another live grenade owns the target reservation, the remaining grenades will not also attack it.

When reporting a problem, include the package version, game version, target type, what happened and the relevant log lines.
Check that only one G-60 version is deployed. Never post credentials, full memory captures or game binaries.
