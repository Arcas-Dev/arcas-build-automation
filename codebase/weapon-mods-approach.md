# Weapon Mods: How We Should Build Them

Marco, this is how I think we should build the weapon mods.

Since the first version of this doc I went through the whole weapon system properly,
including opening the real assets off the build VM. **What I found changes the argument in
our favour, quite a lot.** Most of this system already exists in the project. It was built
by Bevium, it worked, and it was switched off by accident in January 2025.

Full technical detail is in `weapon-system-deepdive.md`. This doc is the short version.

## What we are trying to achieve

1. **A player equips one mod per weapon** and it changes how that weapon behaves.
2. **A mod works on many weapons.** One Double Tap, usable on any primary you own, in any
   loadout, at the same time.
3. **Adding a weapon or a mod stays cheap.** One new asset, not nine or twenty one.
4. **Designers can tune a mod in one place** instead of hunting through every weapon.
5. **It has to be correct on dedicated servers**, not just in the editor.

## The problem with the obvious approach

The obvious way is a separate weapon for every combination. A MadRifle, then a MadRifle
Double Tap, then a MadRifle High Damage. With 21 weapons and 9 mods that is **189 weapons**,
each with its own ID, Weapon Instance Blueprint, damage effect, ammo counter and reticle.

Every new weapon would cost 9 assets instead of 1. Rebalancing Double Tap would mean opening
21 files. And it would burn through the ID ranges the vault and loadout system depends on.

## The answer

**A mod should be its own item, the same way a totem is its own item.** The game combines
the two when the player equips the weapon.

That is 21 weapons plus 9 mods, so 30 assets instead of 189. A tenth mod costs one asset and
works on every weapon in the game immediately.

## The thing I did not know when we last spoke

**Bevium already built the machinery for this, and it is sitting in the project switched
off.**

There is a system that takes a list of per weapon settings, keyed by weapon ID, and applies
them to the weapon at the moment it is equipped. It changes damage, spread, recoil, movement
speed and damage falloff. It is wired into the game and it runs on every single equip.

It does nothing, because the list it reads is always empty.

Here is how that happened, from the commit history:

* **Nov 2024**, Bevium builds it. There is a temporary way to feed it: a field on the Player
  State Blueprint where a designer types the values in.
* **28 Nov 2024**, they fix a real bug in it ("stats are reset after reselecting the
  weapon"). You only write that fix if you are watching it work in game.
* **31 Jan 2025**, a cleanup commit removes that temporary field, because a comment next to
  it said to. The real replacement, feeding it from the backend, was never built.
* **Jan 2026**, the Bevium contract ends.

So since 31 January 2025 the list has been permanently empty, and everything downstream has
been running and doing nothing in every build we have shipped.

**This is the weapon tuning feature from the Game Bible** (the Damage and Accuracy sliders,
the Handling and Range sliders). The runtime half is finished. Only the data source is gone.

Mods need exactly the same thing: change some numbers on a weapon, when it is equipped,
based on what the player chose.

## And they had already designed the mod system

`TuningTableModSlotButton` is a real class in the project, created October 2024. It is
empty. Its entire contents are two commented out lines:

```
// Call SetItem function to set the image and use the set mod to store the mod struct,
// probably FMod or FWeaponMod

// override the on clicked function to set the active mod of the weapon, broadcast an
// event or call something in the subsystem to save it
```

A mod struct, stored per weapon, chosen from the Tuning Table, saved through a subsystem.
That is the design in this document, written down by the previous team almost two years ago.

## What exists and what is missing

| Piece | What it does | Status | Built by |
|---|---|---|---|
| Fresh weapon copy on equip | The game spawns a new copy of `B_WeaponInstance_*` every time you draw a weapon, so it can be changed safely | **Done**, core engine | Epic (Lyra) |
| Equip time stat pass | Applies per weapon settings to that copy, keyed by weapon ID | **Done but switched off** since 31 Jan 2025 | Bevium |
| Damage multiplier | A multiplier on the weapon copy that is applied to every damage, heal and utility result. Designed range 0.5x to 2.0x | **Done and live** | Bevium |
| Magazine size | A value on the item that the shared Reload ability reads to know how full the mag should be | **Done and live** | Lyra plus our weapon assets |
| Ability and effect granting on equip | Everything a weapon grants is added on equip and removed automatically on holster | **Done**, core engine | Epic (Lyra) |
| Item driven ability granting | Read a settings block off a chosen item and grant what it carries | **Done and live, for totems** | Bevium |
| Tuning Table UI | The whole widget family, including the stat display | **Done**, currently shows default values | Bevium (Sabrina) |
| Mod slot button | The widget you click to choose a mod | **Empty stub**, with the design in comments | Bevium (Sabrina) |
| Weapon mastery trials UI | Widgets exist for the Bible's trials | **Stub** | Bevium (Sabrina) |
| **Mod asset type** | One asset per mod holding its slot, numbers, effects and icon | **Missing** | us |
| **Mod stored on the loadout** | Which mod is on which weapon, saved to the backend | **Missing** | us |
| **Client side application** | The fix so mods work on dedicated servers, not just in the editor | **Missing** | us |
| **The nine mod assets** | Double Tap, High Damage Rounds, and so on | **Missing** | you |
| Mod icons | All nine | **Done**, shipped 29 July | you and ElTraktor |

Read the bold rows: that is the actual work. Everything above them already exists.

## Why the approach works

`ID_MadRifle` is a fixed asset and never changes while the game is running. That is why
"make another one per mod" feels like the only option.

But `ID_MadRifle` is not what the player is holding. On equip, the game **spawns a fresh
copy of `B_WeaponInstance_MadRifle`** for that player, for that one equip. That copy is a
live object and is free to be different from the asset it came from.

You already edit values on those instance Blueprints. `BulletsPerCartridge`,
`MaxDamageRange` and `MaxTraceRange` all live there, and you tuned `MaxTraceRange` across 23
of them in July. Anything you can set in that Blueprint, the game can change at the moment
of equip. Because the copy is fresh every draw, there is nothing to undo when you holster.

## The nine mods, and what each actually needs

| Mod | How it works | Work needed |
|---|---|---|
| **High Damage Rounds** | Set the damage multiplier that already exists to 1.5. Its designed range is 0.5x to 2.0x, so this is well inside what it was built for | none beyond the mod pass |
| **High Capacity Mag** | Add to the Magazine Size value on the item. The Reload ability already reads it | none beyond the mod pass |
| **Double Tap** | Change bullets per shot on the weapon copy from 1 to 2 | none beyond the mod pass |
| **Lucky Strike** | Luck x1.5 | one Gameplay Effect |
| **Berserk Boost** | Agility x1.5 | one Gameplay Effect |
| **Resourceful** | Intelligence x1.5 | one Gameplay Effect |
| **Fire Rounds** | Damage over time after the hit | real design work |
| **Healing Rounds** | Heals teammates and structures | real design work |
| **Demolition Rounds** | Damages structures | real design work |

The first three need **no new mechanism at all**. The next three are one Gameplay Effect
each. Only the last three need genuine design and Blueprint work.

There is a good chance those last three are partly built too. Bevium wrote three custom
effect classes called Heal, Custom Power and Blind, in February 2025, and the Blind effect
is already on the rocket launcher. That looks like the start of the utility rounds system.
**Worth an hour finding out how far they got before we design them from scratch.**

## What you would make, per mod

One folder per mod, laid out like a totem folder:

```
WeaponMods/ID_Mod_DoubleTap.uasset
WeaponMods/ID_Mod_FireRounds.uasset
WeaponMods/GameplayEffects/GE_Mod_HighDamage.uasset
WeaponMods/GameplayAbilities/GA_Mod_FireRounds.uasset
WeaponMods/DT_WeaponModsId.uasset
```

Inside `ID_Mod_DoubleTap`, one settings block:

* **Slot:** Primary, Utility or Melee
* **Number changes:** bullets per shot x2, everything else x1
* **Effects:** empty for Double Tap, filled in for the others
* **Icon:** the one you already made

Double Tap is literally that and nothing else.

## One slot per weapon

Each weapon has **one mod slot**, and there are **three mods available per weapon class**.
The player picks one of three for their primary, one of three for their utility, one of three
for their melee. Three real choices per loadout.

Giving every weapon all three mods of its class would mean no decision at all, just a
permanent buff everyone has.

A mod is owned once and usable everywhere. Own Double Tap and you can run it on your MadRifle
in one loadout and your Pistol in another, at the same time. It is not consumed and not tied
to one weapon. Same idea as the skins.

## The one real risk, and it is already in the project

The switched off system has a bug. It only applies its changes **on the server**. But three
of the five things it changes (spread, recoil and movement speed) are only used **on the
player's own machine**.

In the editor, where you are the server and the player at once, it looks perfect. On a real
dedicated server it would half work. Nobody has ever seen this because the system has been
doing nothing since January 2025.

Bullets per shot has the same problem, so Double Tap would hit it too.

The fix is straightforward and needs no new networking: the loadout is already known on both
sides, so both sides can work out the same answer. We just have to remember to do it. I am
flagging it because it is the kind of thing that gets found in a playtest three weeks after
we ship it.

## What I need from you

1. **Sign off on the approach**, or tell me where it clashes with how you want to author
   these.

2. **Is the mod list 9 or 12?** The Game Bible says "an initial pool of 12 mods" and then
   lists 9. Nine have icons. Were three dropped, or still to be designed?

3. **Half an hour in the editor** would close four open questions: the ID number on each
   weapon asset, the min and max ranges in `DA_MinMaxWeaponsStatsSettings`, the magazine
   sizes, and whether every weapon actually has its Min Max asset filled in. The build VM is
   up right now.

4. **An hour on the utility rounds question.** How much of Fire, Healing and Demolition
   already exists in those Customizable effect classes. This is the only unknown that can
   move the schedule.

5. **Melee mods buff champion stats, not weapon stats** (Luck, Agility, Intelligence x1.5).
   I think they should apply only while the melee is actually in your hands, not permanently.
   That is what the engine gives us for free, it makes them a real choice, and it gives you a
   reason to pull out your melee. Worth a conversation, because it changes how strong they
   should be.

## The cheapest way to settle this

Before we build anything, **switch the old system back on for one weapon.**

Re add the one line that was deleted in January 2025, type a damage value into the Player
State Blueprint for the MadRifle, and see whether the damage actually changes on a dedicated
server.

That is a few hours, it touches nothing permanent, and it proves or disproves the whole
approach in one test. If Bevium's pipeline works when you feed it, mods are mostly a data
problem. If it does not, we find out exactly why before committing to anything.
