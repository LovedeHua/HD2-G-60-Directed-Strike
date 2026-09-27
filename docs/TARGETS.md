# Targets and attack positions

Automatic enemy targeting is limited to these profiled variants:

| Enemy | Priority | Attack position |
| --- | --- | --- |
| Bile Titan | 10 | Below the underside centre, with a 2.5 m blast standoff |
| Dragonroach | 10 | Below the thorax sac, with a blast standoff |
| Impaler | 20 | Underside |
| Spore Charger | 30 | Head |
| Charger Behemoth (three resource variants) | 40 | Exposed rear abdomen |
| Charger | 50 | Head |

Lower priority numbers are selected first. A target already assigned to a grenade remains reserved
until that grenade disappears. A grenade redirected to a structure retains its earlier claims until disappearance.
This can leave an enemy temporarily reserved even after its grenade has changed direction.

The marked-only structure list contains thirteen exact entity resources:

- Eight normal bug-hole spawners: scavenger, spitter, warrior, hiveguard, hunter, boomer, prowler and stalker.
- The colony model used by `bug_spawner_bile_titan` (the large hole confirmed during gameplay testing).
- Shrieker Nest and ordinary/large Spore Spewer.
- Objective egg sack `embryo_01`; the aim point is the centre of its nine egg nodes, approached with a 0.9 m side offset.

Hole routes first reach the entrance side and then enter a bounded blast region. Towers use an offset
beside the measured upper structure node. Structures are never added automatically from enemy candidates.
Sample eggs, unknown aliases and the legacy `cluster_x6` resource without captured model data are excluded.
The exact resource IDs and geometry are in `compat/structure_profiles.lua` and `compat/weakpoint_profiles.lua`.

Positions are based on inspected model nodes and gameplay iteration. This is not a collision-query pathfinder;
terrain, moving targets, legs and other obstacles can still interfere. Damage and armor penetration are unchanged.
