# Puschelz WoW Addon (V13)

Retail WoW addon that captures guild bank and calendar data and writes it to `SavedVariables/Puschelz.lua`.

## Install

1. Copy `Puschelz/` into your WoW AddOns folder:
   - `World of Warcraft/_retail_/Interface/AddOns/Puschelz`
2. Start WoW and enable the addon in the AddOns list.
3. Log in on a guild character.

## Install via WoWUp

1. Open WoWUp.
2. Add an addon source from GitHub URL (in most clients this is `Get Addons` -> `Install from URL`).
3. Paste: `https://github.com/puschelz/addon`.
4. Select the Retail addon entry and install/update normally via WoWUp.

If your WoWUp build does not show `Install from URL`, install from the published GitHub release zip and keep this repo as your update source.

## Capture flow

1. Open the guild bank and browse tabs (the addon queues all tabs and captures slot data).
2. Calendar data is scanned on login and on calendar updates.
3. Run `/reload` (or log out) to flush SavedVariables to disk.
4. Inspect `WTF/Account/<ACCOUNT>/SavedVariables/Puschelz.lua`.

## Slash commands

- `/puschelz status` (or `/pz`) shows captured counts and last scan times.
- `/puschelz scan` triggers a manual bank + calendar scan.

## SavedVariables shape

```lua
PuschelzDB = {
  schemaVersion = 13,
  updatedAt = 1739400000000,
  player = {
    characterName = "Fluffybear",
    realmName = "Blackhand",
    guildName = "The Puschelz",
    faction = "Horde",
    updatedAt = 1739400000000,
  },
  guildBank = {
    lastScannedAt = 1739400000000,
    tabs = {
      {
        tabIndex = 0,
        tabName = "Consumables",
        items = {
          {
            slotIndex = 0,
            itemId = 191381,
            itemName = "Phial of Tepid Versatility",
            itemIcon = "134829",
            quantity = 20,
          },
        },
      },
    },
  },
  calendar = {
    lastScannedAt = 1739400000000,
    events = {
      {
        wowEventId = 4242,
        title = "Guild Raid",
        eventType = "raid",
        startTime = 1739443200000,
        endTime = 1739450400000,
      },
      {
        wowEventId = 9901,
        title = "Darkmoon Faire",
        eventType = "world",
        startTime = 1739600000000,
        endTime = 1739686400000,
      },
    },
  },
}
```

The `tabs[*].items[*]` and `calendar.events[*]` fields are intentionally aligned to the website backend payload contract used by `/api/addon-sync`.

## Parser fixtures (for V14)

- `fixtures/Puschelz.sample.lua`: sample SavedVariables file.
- `fixtures/Puschelz.sample.expected.json`: expected parsed object for desktop-client tests.

## Releases

See `RELEASE_CHECKLIST.md` for the repeatable version bump + tag + release flow.
