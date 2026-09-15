# Max Yari's Script Services (MSS)

Shared engine reads for OpenMW Lua mods. When several mods read the same thing, such as equipment,
active effects, the interaction ray, combat targets or health, they read it once through MSS and share
the result.

MSS only caches what the engine returns. It doesn't interpret it: working out what the data means is up
to each mod. Nothing is read until a mod asks; until then MSS only counts frames and sums `dt`.

## Installing and depending on MSS

MSS is a mod of its own: add its folder as a data path and enable `MaxYariScriptServices.omwscripts`,
ideally before the mods that use it. It declares its one script itself:

```
NPC, CREATURE, PLAYER: scripts/MaxYari/MSS/actor.lua
```

Mods using MSS don't declare anything. They check once, in a player script when it loads, that MSS is
enabled, and tell the user if it isn't:

```lua
if not core.contentFiles.has("MaxYariScriptServices.omwscripts") then
    print("[My Mod] ERROR: critical dependency is missing: Max Yari's Script Services (MSS). Please install it.")
    ui.showMessage("My Mod: Critical dependency is missing, please install Max Yari's Script Services (MSS)")
end
```

**Look `I.MSS` up lazily** (in a handler, or on first use), not at the top of a script, and register
listeners in `onActive` rather than `onInit`/`onLoad`. An object's interfaces appear one script at a
time, in load order, and `onInit`/`onLoad` run as each script is attached, so a script loaded before MSS
doesn't see it yet. `onActive` is queued until all of the object's scripts exist.

Check `I.MSS.version` if you rely on something newer than version 1.

## Caching rules

`maxAge` is in seconds:

- `nil` or `0`: the engine is read at most once per frame, shared by all callers.
- `> 0`: the value is reused until it's that old.
- `< 0`: always read from the engine, which also refreshes the cache for everyone else.

The frame counter and the time advance in `onFrame` on the player, which the engine runs before any
script's `onUpdate`, and in `onUpdate` on other actors. On an NPC, a script whose `onUpdate` runs before
MSS's can get the previous frame's values.

Time is the sum of `dt`, which is 0 while paused. When a pause starts and when it ends, every cache
with a `maxAge` expires, so a change made in a menu (an item equipped in the inventory) is seen on the
first frame after it.

## I.MSS on every actor (NPC, creature, player)

| Method | Returns |
|---|---|
| `version` | The MSS version. |
| `getPosition()` | `self.position`, read once per frame. |
| `getCell()` | `self.cell`, read once per frame. |
| `getEquipment(slot, maxAge)` | `types.Actor.getEquipment(self, slot)`. |
| `getEquipmentInfo(slot, maxAge)` | `{ item, recordId, type, record }`, or nil for an empty slot. See below. |
| `getActiveEffect(effectId, maxAge, extraParam)` | This actor's `activeEffects():getEffect(effectId, extraParam).magnitude`, or nil when there's no such effect. The magnitude is kept rather than the effect, so reading it again costs no engine call. |
| `addDamageListener(fn)` / `removeDamageListener(fn)` | `fn(e)` for every health decrease of this actor. See below. |

**`getEquipmentInfo`**: the fields are the item, its `recordId`, `type` and `type.record(item)`, read
only when the item changes. It's the same table until then, so `info ~= lastInfo` means the item
changed.

**Health decreases.** Event `e`: `actor`, `actorId`, `previousHealth`, `health`, `baseHealth`, and `hit`:
the `I.Combat` AttackInfo of the successful hit noted just before the decrease, nil when there was none.

- **Only read while needed.** Health is read once per update while this actor has a listener, and
  never otherwise. The health handle and the hit handler are only created on first use.
- **Other actors' decreases on the player.** MSS doesn't send anything to the player. A mod that needs
  this adds a listener from its own actor script and sends the player what it needs.
- **Every decrease is reported as is,** including health falling because the maximum was lowered. The
  listener decides what counts as damage.
- **One event per decrease.** Spells don't go through `I.Combat` onHit, so health has to be read. A
  successful hit is only noted, and the next decrease (within 2 updates) carries it as `hit`, so a hit
  never produces a second event.
- **Paused updates** read nothing; a decrease meanwhile is reported on the next update.
- **Increases** aren't reported.

## I.MSS on NPCs and creatures only

| Method | Returns |
|---|---|
| `getCombatTargets()` | This actor's own combat targets, or nil when it has none. Use it instead of calling `I.AI.getTargets("Combat")` on the actor. |

The first call reads `I.AI.getTargets("Combat")` once. After that, the player sends this actor its own
targets whenever they change (see below). To be told of changes, handle the event
`MSS_CombatTargets { targets }` in your own script.

## I.MSS on the player only

| Method | Returns |
|---|---|
| `getInteractionTarget(maxAge)` | The ray result as `{ hit, hitObject, hitPos }`, or `{ hit = false }`. See below. |
| `getCombatTargetsOther(actorId)` | Another actor's combat targets as last reported, or nil when it has none. |

**`getInteractionTarget`**: a `castRenderingRay` from the camera through the screen center, over
`iMaxActivateDist` plus the third-person camera distance, with nothing filtered out.

## Combat targets come from the engine's music events

`I.AI` only exists in each actor's own scripts. OpenMW's built-in music script
(`scripts/omw/music/actor.lua`) runs on every NPC and creature, polls `AI.getTargets("Combat")` on its
own actor, and sends every change to the player as `OMWMusicCombatTargetsChanged`. That polling runs
anyway for the combat music. MSS's player script stores each change and always sends it back to the
actor it belongs to. MSS itself never polls AI (beyond each actor's first read).

**If that script is missing.** When the player script loads, it checks once that the file exists and
still contains `OMWMusicCombatTargetsChanged`. If not, it prints an error in the console and shows on
screen that combat target events weren't found. Combat targets then don't update, and mods relying on
them won't work correctly. There's no fallback.

**Things that don't affect the events:** turning combat music off in the settings, disabled sound, and
mods replacing the player-side `music.lua`.

**Limits of the events:**

- They only cover Combat packages, not Pursue.
- An actor is only reported once it has a weapon drawn or a spell readied.
- They aren't saved with the game.

## Engine calls MSS makes

| Feature | Calls | When |
|---|---|---|
| Frame clock | none | – |
| `getPosition` / `getCell` | `self.position` / `self.cell` | first call each frame |
| Equipment | `Actor.getEquipment`; plus `item.type`, `item.recordId`, `type.record` | per frame or `maxAge`; the extras only when the item changed |
| Effects | `Actor.activeEffects` once, then `getEffect` and `.magnitude` | per frame or `maxAge`, per effect |
| Interaction ray | `camera.getPosition`, `viewportToWorldVector`, `getThirdPersonDistance`, `castRenderingRay` | per frame or `maxAge` |
| Own combat targets | `I.AI.getTargets` | once per actor per load, on first use |
| Combat targets | `actor.id`, `sendEvent` back to that actor | per change |
| Health | `health.current`; `health.base` only on a decrease | each update, only while someone listens |
| Music script check | `vfs.fileExists`, `vfs.open` | once, when the player script loads |
