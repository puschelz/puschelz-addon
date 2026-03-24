# Puschelz WoW Addon (V15)

Retail WoW addon bundle for guild sync. The release ships as one user-facing install package, but it contains two addon folders internally:

- `Puschelz/` for in-game data capture and UI
- `PuschelzBridge/` for desktop-written bridge data

Users should treat this as a single addon install/update source. Do not install `PuschelzBridge` separately.

## Install

1. Download the published `Puschelz-<version>.zip` release asset.
2. Extract the zip into your WoW AddOns folder so both folders land side-by-side:
   - `World of Warcraft/_retail_/Interface/AddOns/Puschelz`
   - `World of Warcraft/_retail_/Interface/AddOns/PuschelzBridge`
3. Treat that zip as one addon package. Do not install or update `PuschelzBridge` separately.
4. Start WoW and enable the addon in the AddOns list.
5. Log in on a guild character.

## Install via WoWUp

1. Open WoWUp.
2. Add an addon source from GitHub URL (in most clients this is `Get Addons` -> `Install from URL`).
3. Paste: `https://github.com/puschelz/puschelz-addon`.
4. Install/update it as one addon source. The repo/release package contains both `Puschelz` and `PuschelzBridge`, and WoWUp should place both folders for you.

If your WoWUp build does not show `Install from URL`, install from the published GitHub release zip and keep this repo as your update source.

### WoWUp GitHub auth note

In some WoWUp setups, GitHub installs for this repo only worked after adding a GitHub Personal Access Token (PAT) in WoWUp.

If install fails with:
- `Addon Installation Failed`
- `end of central directory record signature not found`

Then configure a GitHub PAT in WoWUp and retry install/update.

## Capture flow

1. Open the guild bank and browse tabs (the addon queues all tabs and captures slot data).
2. Calendar data is scanned on login and on calendar updates.
3. Open either the crafter or customer crafting-orders UI to passively snapshot currently visible guild orders; the addon prints a chat line when that passive snapshot discovers new order ids.
4. Use the `Sync Guild Orders` button on either professions/orders window to actively request and capture visible guild orders from both the crafter and `My Orders` views.
5. Matching open guild orders are printed into chat on login for the current character until they disappear from a later open-order scan.
6. Required raid addons from the website bridge are checked against active addon folders on login or `/reload`; missing entries print red chat warnings once per changed bridge/missing set.
7. Raid addon coverage checks auto-refresh on raid roster changes.
8. Run `/reload` (or log out) to flush SavedVariables to disk.
9. Inspect `WTF/Account/<ACCOUNT>/SavedVariables/Puschelz.lua`.

## Slash commands

- `/puschelz status` (or `/pz`) shows captured counts and last scan times.
- `/puschelz addons` prints the current required-addon compliance summary and missing entries.
- `/puschelz scan` triggers a manual bank + calendar scan.
- `/puschelz orders` reprints open guild-order reminders that match the current character.
- `/puschelz syncorders` runs a full guild-order sync request.
- `/puschelz check` triggers a manual raid addon handshake in the current raid (regular or instance raid/LFR).
- `/puschelz raidstatus` toggles the raid status window (Installed/Missing/Pending + version per raid member).

## SavedVariables shape

```lua
PuschelzDB = {
  schemaVersion = 15,
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
        attendees = {
          { name = "Fluffybear-Blackhand", status = "signedUp" },
          { name = "Magebro-Blackhand", status = "tentative" },
        },
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
  guildOrders = {
    lastScannedAt = 1739407200000,
    orders = {
      {
        orderId = 12345,
        itemId = 225646,
        spellId = 447379,
        orderType = "guild",
        orderState = 2,
        expirationTime = 1739493600000,
        minQuality = 3,
        tipAmount = 150000,
        consortiumCut = 0,
        isRecraft = false,
        isFulfillable = true,
        reagentState = 0,
        customerName = "Requester-Blackhand",
        customerNotes = "Need for raid",
        outputItemHyperlink = "|cff0070dd|Hitem:225646::::::::80:::::|h[Blessed Weapon Grip]|h|r",
      },
    },
  },
}
```

The `tabs[*].items[*]`, `calendar.events[*]`, optional `calendar.events[*].attendees[*]`, and `guildOrders.orders[*]` fields are intentionally aligned to the website backend payload contract used by `/api/addon-sync`.

## Parser fixtures (for V15)

- `fixtures/Puschelz.sample.lua`: sample SavedVariables file.
- `fixtures/Puschelz.sample.expected.json`: expected parsed object for desktop-client tests.

## Releases

See `RELEASE_CHECKLIST.md` for the repeatable version bump + tag + release flow. The published release zip is the single user-facing install artifact and must always contain both `Puschelz/` and `PuschelzBridge/`.

## Interface compatibility

If WoW marks the addon as incompatible after a major patch/pre-patch, update:

- `Puschelz/Puschelz.toc` -> `## Interface: ...`

Get the current interface number in-game with:

- `/run print(select(4, GetBuildInfo()))`

Keep supported interfaces comma-separated (example: `110200,120000`).
