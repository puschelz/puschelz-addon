local ADDON_NAME = ...

local SCHEMA_VERSION = 13
local GUILD_BANK_SLOTS_PER_TAB = 98
local CALENDAR_MONTH_OFFSETS = { -1, 0, 1, 2 }

local function now_ms()
  return math.floor(GetServerTime() * 1000)
end

local function parse_item_id(link)
  if type(link) ~= "string" then
    return nil
  end
  local item_id = link:match("item:(%d+)")
  if not item_id then
    return nil
  end
  return tonumber(item_id)
end

local function parse_item_name(link)
  if type(link) ~= "string" then
    return nil
  end
  return link:match("%[(.-)%]")
end

local function stable_hash_number(text)
  local hash = 5381
  for i = 1, #text do
    hash = ((hash * 33) + string.byte(text, i)) % 2147483647
  end
  return math.abs(hash)
end

local function calendar_time_to_ms(calendar_time, fallback_year, fallback_month, fallback_day)
  if type(calendar_time) ~= "table" then
    return nil
  end

  local timestamp = time({
    year = calendar_time.year or fallback_year,
    month = calendar_time.month or fallback_month,
    day = calendar_time.monthDay or fallback_day,
    hour = calendar_time.hour or 0,
    min = calendar_time.minute or 0,
    sec = 0,
  })

  if not timestamp then
    return nil
  end

  return timestamp * 1000
end

local function is_raid_event(event)
  if not event then
    return false
  end

  local raid_enum = Enum and Enum.CalendarEventType and Enum.CalendarEventType.Raid
  if raid_enum and event.eventType == raid_enum then
    return true
  end

  if event.eventType == "RAID" then
    return true
  end

  return false
end

local function is_world_event(event)
  if not event then
    return false
  end

  local calendar_type = event.calendarType
  if calendar_type == "HOLIDAY" or calendar_type == "SYSTEM" then
    return true
  end

  local holiday_enum = Enum and Enum.CalendarType and Enum.CalendarType.Holiday
  local system_enum = Enum and Enum.CalendarType and Enum.CalendarType.System

  if holiday_enum and calendar_type == holiday_enum then
    return true
  end

  if system_enum and calendar_type == system_enum then
    return true
  end

  return false
end

local function classify_event(event)
  if is_raid_event(event) then
    return "raid"
  end

  if is_world_event(event) then
    return "world"
  end

  return nil
end

local function ensure_db()
  if type(PuschelzDB) ~= "table" then
    PuschelzDB = {}
  end

  PuschelzDB.schemaVersion = SCHEMA_VERSION
  PuschelzDB.updatedAt = PuschelzDB.updatedAt or 0

  if type(PuschelzDB.player) ~= "table" then
    PuschelzDB.player = {}
  end

  if type(PuschelzDB.guildBank) ~= "table" then
    PuschelzDB.guildBank = {}
  end
  if type(PuschelzDB.guildBank.tabs) ~= "table" then
    PuschelzDB.guildBank.tabs = {}
  end
  if type(PuschelzDB.guildBank.tabsByIndex) ~= "table" then
    PuschelzDB.guildBank.tabsByIndex = {}
  end

  if type(PuschelzDB.calendar) ~= "table" then
    PuschelzDB.calendar = {}
  end
  if type(PuschelzDB.calendar.events) ~= "table" then
    PuschelzDB.calendar.events = {}
  end
end

local function refresh_player_metadata()
  ensure_db()
  local character_name, realm_name = UnitFullName("player")
  local guild_name = GetGuildInfo("player")

  PuschelzDB.player.characterName = character_name
  PuschelzDB.player.realmName = realm_name
  PuschelzDB.player.guildName = guild_name
  PuschelzDB.player.faction = UnitFactionGroup("player")
  PuschelzDB.player.updatedAt = now_ms()
end

local function rebuild_ordered_tabs()
  local tab_count = GetNumGuildBankTabs() or 0
  local ordered = {}

  for tab_index = 1, tab_count do
    local tab_name = select(1, GetGuildBankTabInfo(tab_index))
    local tab_data = PuschelzDB.guildBank.tabsByIndex[tab_index - 1]
    if tab_data then
      tab_data.tabName = tab_name or tab_data.tabName
      table.insert(ordered, tab_data)
    end
  end

  PuschelzDB.guildBank.tabs = ordered
end

local function capture_bank_tab(tab_index)
  if not tab_index or tab_index < 1 then
    return
  end

  ensure_db()

  local tab_name = select(1, GetGuildBankTabInfo(tab_index))
  local tab_payload = {
    tabIndex = tab_index - 1,
    tabName = tab_name or ("Tab " .. tab_index),
    items = {},
  }

  for slot_index = 1, GUILD_BANK_SLOTS_PER_TAB do
    local texture, quantity = GetGuildBankItemInfo(tab_index, slot_index)
    local item_link = GetGuildBankItemLink(tab_index, slot_index)

    if item_link then
      local item_id = parse_item_id(item_link)
      if item_id then
        local item_name = parse_item_name(item_link) or ("Item " .. item_id)
        table.insert(tab_payload.items, {
          slotIndex = slot_index - 1,
          itemId = item_id,
          itemName = item_name,
          itemIcon = tostring(texture or ""),
          quantity = quantity and quantity > 0 and quantity or 1,
        })
      end
    end
  end

  PuschelzDB.guildBank.tabsByIndex[tab_payload.tabIndex] = tab_payload
  PuschelzDB.guildBank.lastScannedAt = now_ms()
  PuschelzDB.updatedAt = PuschelzDB.guildBank.lastScannedAt
end

local pending_bank_tabs = {}

local function queue_all_bank_tabs()
  local tab_count = GetNumGuildBankTabs() or 0
  if tab_count <= 0 then
    return
  end

  for tab_index = 1, tab_count do
    pending_bank_tabs[tab_index] = true
  end
end

local function query_next_bank_tab()
  for tab_index, is_pending in pairs(pending_bank_tabs) do
    if is_pending then
      if QueryGuildBankTab then
        QueryGuildBankTab(tab_index)
      end
      return
    end
  end

  rebuild_ordered_tabs()
end

local function on_bank_slots_changed()
  local current_tab = GetCurrentGuildBankTab()
  if current_tab then
    capture_bank_tab(current_tab)
  end

  if current_tab and pending_bank_tabs[current_tab] then
    pending_bank_tabs[current_tab] = nil
    query_next_bank_tab()
  end
end

local function build_calendar_payload()
  local events = {}

  for _, month_offset in ipairs(CALENDAR_MONTH_OFFSETS) do
    local month_info = C_Calendar.GetMonthInfo(month_offset)
    if month_info and month_info.numDays then
      for month_day = 1, month_info.numDays do
        local day_events = C_Calendar.GetNumDayEvents(month_offset, month_day) or 0
        for event_index = 1, day_events do
          local event = C_Calendar.GetDayEvent(month_offset, month_day, event_index)
          if event then
            local event_type = classify_event(event)
            if event_type then
              local start_ms = calendar_time_to_ms(
                event.startTime,
                month_info.year,
                month_info.month,
                month_day
              )

              if start_ms then
                local end_ms = calendar_time_to_ms(
                  event.endTime,
                  month_info.year,
                  month_info.month,
                  month_day
                )

                if not end_ms then
                  local fallback_minutes = event.duration and event.duration > 0 and event.duration or 120
                  end_ms = start_ms + (fallback_minutes * 60 * 1000)
                end

                local wow_event_id = tonumber(event.eventID)
                if not wow_event_id then
                  wow_event_id = stable_hash_number(
                    string.format(
                      "%s|%s|%s|%s|%s",
                      tostring(event.title or ""),
                      tostring(start_ms),
                      tostring(event_type),
                      tostring(month_offset),
                      tostring(event_index)
                    )
                  )
                end

                table.insert(events, {
                  wowEventId = wow_event_id,
                  title = event.title or "Untitled Event",
                  eventType = event_type,
                  startTime = start_ms,
                  endTime = end_ms,
                })
              end
            end
          end
        end
      end
    end
  end

  table.sort(events, function(a, b)
    if a.startTime == b.startTime then
      return a.wowEventId < b.wowEventId
    end
    return a.startTime < b.startTime
  end)

  return events
end

local function capture_calendar()
  ensure_db()

  local events = build_calendar_payload()
  PuschelzDB.calendar.events = events
  PuschelzDB.calendar.lastScannedAt = now_ms()
  PuschelzDB.updatedAt = PuschelzDB.calendar.lastScannedAt
end

local function request_calendar_scan()
  if not C_Calendar or not C_Calendar.OpenCalendar then
    return
  end
  C_Calendar.OpenCalendar()
  capture_calendar()
end

local function print_status()
  ensure_db()

  local bank_tabs = PuschelzDB.guildBank.tabs or {}
  local calendar_events = PuschelzDB.calendar.events or {}

  local bank_scan = PuschelzDB.guildBank.lastScannedAt
  local calendar_scan = PuschelzDB.calendar.lastScannedAt

  print(
    string.format(
      "Puschelz: tabs=%d, events=%d, bankScan=%s, calendarScan=%s",
      #bank_tabs,
      #calendar_events,
      bank_scan and date("%Y-%m-%d %H:%M", math.floor(bank_scan / 1000)) or "never",
      calendar_scan and date("%Y-%m-%d %H:%M", math.floor(calendar_scan / 1000)) or "never"
    )
  )
end

SLASH_PUSCHELZ1 = "/puschelz"
SLASH_PUSCHELZ2 = "/pz"
SlashCmdList.PUSCHELZ = function(msg)
  local command = msg and msg:match("^(%S+)") or ""

  if command == "scan" then
    if GuildBankFrame and GuildBankFrame:IsShown() then
      queue_all_bank_tabs()
      query_next_bank_tab()
    else
      print("Puschelz: open the guild bank first to scan bank tabs.")
    end

    request_calendar_scan()
    print("Puschelz: scan triggered.")
    return
  end

  if command == "status" or command == "" then
    print_status()
    return
  end

  print("Puschelz usage: /puschelz status | /puschelz scan")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("GUILDBANKFRAME_OPENED")
frame:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
frame:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    ensure_db()
    refresh_player_metadata()
    request_calendar_scan()
    return
  end

  if event == "PLAYER_GUILD_UPDATE" then
    refresh_player_metadata()
    return
  end

  if event == "GUILDBANKFRAME_OPENED" then
    queue_all_bank_tabs()
    query_next_bank_tab()
    return
  end

  if event == "GUILDBANKBAGSLOTS_CHANGED" then
    on_bank_slots_changed()
    return
  end

  if event == "CALENDAR_UPDATE_EVENT_LIST" then
    capture_calendar()
    return
  end

  if event == "PLAYER_LOGOUT" then
    ensure_db()
    PuschelzDB.updatedAt = now_ms()
  end
end)
