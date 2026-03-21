local ADDON_NAME = ...

local SCHEMA_VERSION = 15
local GUILD_BANK_SLOTS_PER_TAB = 98
local CALENDAR_MONTH_OFFSETS = { -1, 0, 1, 2 }
local GUILD_ORDER_TYPE_GUILD = 1
local GUILD_ORDER_STATE_FULFILLED = 11
local GUILD_ORDER_STATE_CANCELED = 13
local GUILD_ORDER_STATE_EXPIRED = 15

local function resolve_addon_version()
  local version

  if C_AddOns and C_AddOns.GetAddOnMetadata then
    version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
  end

  if (type(version) ~= "string" or version == "") and GetAddOnMetadata then
    version = GetAddOnMetadata(ADDON_NAME, "Version")
  end

  if type(version) ~= "string" or version == "" or version == "@project-version@" then
    return "unknown"
  end

  return version
end

local ADDON_VERSION = resolve_addon_version()
local RAID_STATUS_PREFIX = "PUSCHELZSTAT"
local RAID_QUERY_COOLDOWN_MS = 8000
local RAID_REPLY_TIMEOUT_MS = 4000
local RAID_ROSTER_DEBOUNCE_SEC = 1.0
local RAID_STATUS_ROW_COUNT = 40
local CALENDAR_ATTENDEE_SCAN_TIMEOUT_SEC = 45
local CALENDAR_ATTENDEE_EVENT_OPEN_TIMEOUT_SEC = 1.5
local GUILD_ORDER_SYNC_TIMEOUT_SEC = 45

local raid_status = {
  roster = {},
  rosterByKey = {},
  responsesByKey = {},
  activeQueryId = nil,
  pendingUntilMs = 0,
  lastQueryAtMs = 0,
  queryCounter = 0,
  autoCheckScheduled = false,
  rosterRefreshScheduled = false,
  sentReplyKeys = {},
  sentReplyCount = 0,
  prefixRegistered = false,
  window = nil,
  rows = {},
}

local function now_epoch_ms()
  return math.floor(GetServerTime() * 1000)
end

local function now_runtime_ms()
  if GetTimePreciseSec then
    return math.floor(GetTimePreciseSec() * 1000)
  end

  if GetTime then
    return math.floor(GetTime() * 1000)
  end

  return now_epoch_ms()
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

local function get_fallback_event_minutes(event_type, duration_minutes)
  if duration_minutes and duration_minutes > 0 then
    return duration_minutes
  end

  if event_type == "raid" then
    return 180
  end

  return 120
end

local function normalize_end_time(start_ms, end_ms, event_type, duration_minutes)
  if not start_ms then
    return nil
  end

  if end_ms and end_ms > start_ms then
    return end_ms
  end

  local fallback_minutes = get_fallback_event_minutes(event_type, duration_minutes)
  return start_ms + (fallback_minutes * 60 * 1000)
end

local function map_calendar_invite_status(invite_status)
  if invite_status == nil then
    return nil
  end

  local status_number = tonumber(invite_status)
  if status_number then
    if status_number == 8 then
      return "tentative"
    end

    if status_number == 1 or status_number == 3 or status_number == 6 then
      return "signedUp"
    end

    return nil
  end

  local status_text = string.lower(tostring(invite_status))
  if status_text == "" then
    return nil
  end
  local status_compact = status_text:gsub("[%s_%-]+", "")

  if status_text:find("tentative", 1, true) then
    return "tentative"
  end

  if status_text:find("declin", 1, true)
    or status_text:find("standby", 1, true)
    or status_compact:find("notsigned", 1, true)
    or status_text:find("invited", 1, true)
    or status_text == "out"
  then
    return nil
  end

  if status_text:find("signed", 1, true)
    or status_text:find("signup", 1, true)
    or status_text:find("available", 1, true)
    or status_text:find("confirm", 1, true)
    or status_text:find("accept", 1, true)
  then
    return "signedUp"
  end

  return nil
end

local function get_calendar_invite_count()
  if not C_Calendar then
    return 0
  end

  if C_Calendar.EventGetNumInvites then
    return C_Calendar.EventGetNumInvites() or 0
  end

  if C_Calendar.GetNumInvites then
    return C_Calendar.GetNumInvites() or 0
  end

  return 0
end

local function get_calendar_invite_details(invite_index)
  if not C_Calendar then
    return nil, nil
  end

  if C_Calendar.EventGetInvite then
    local first, second = C_Calendar.EventGetInvite(invite_index)
    if type(first) == "table" then
      return first.name, first.inviteStatus or first.status
    end

    if type(first) == "string" then
      return first, second
    end
  end

  if C_Calendar.GetInvite then
    local name, _, _, _, invite_status = C_Calendar.GetInvite(invite_index)
    return name, invite_status
  end

  return nil, nil
end

local function collect_open_calendar_event_attendees()
  local invite_count = get_calendar_invite_count()
  local attendees = {}
  local seen = {}

  for invite_index = 1, invite_count do
    local invite_name, invite_status = get_calendar_invite_details(invite_index)
    local mapped_status = map_calendar_invite_status(invite_status)
    if mapped_status then
      local display_name = type(invite_name) == "string" and invite_name:match("^%s*(.-)%s*$") or nil
      if display_name and display_name ~= "" then
        local attendee_key = string.lower(display_name)
        if not seen[attendee_key] then
          seen[attendee_key] = true
          table.insert(attendees, {
            name = display_name,
            status = mapped_status,
          })
        end
      end
    end
  end

  table.sort(attendees, function(a, b)
    return string.lower(a.name) < string.lower(b.name)
  end)

  if #attendees == 0 then
    return nil
  end

  return attendees
end

local calendar_attendee_scan = {
  inProgress = false,
  events = nil,
  pendingRaidEvents = {},
  activeRaidEvent = nil,
  scanGeneration = 0,
  notifyOnCompletion = false,
}

local guild_order_sync = {
  active = false,
  notifyOnCompletion = false,
  requestGeneration = 0,
  collectedByOrderId = {},
  profession = nil,
  buttons = {},
}

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

  if type(PuschelzDB.guildOrders) ~= "table" then
    PuschelzDB.guildOrders = {}
  end
  if type(PuschelzDB.guildOrders.orders) ~= "table" then
    PuschelzDB.guildOrders.orders = {}
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
  PuschelzDB.player.updatedAt = now_epoch_ms()
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
  PuschelzDB.guildBank.lastScannedAt = now_epoch_ms()
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
  local seen = {}
  local pending_raid_events = {}

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
                local raw_end_ms = calendar_time_to_ms(
                  event.endTime,
                  month_info.year,
                  month_info.month,
                  month_day
                )
                local end_ms = normalize_end_time(
                  start_ms,
                  raw_end_ms,
                  event_type,
                  event.duration
                )

                local source_event_id = tonumber(event.eventID)
                local wow_event_id = source_event_id
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

                local title = event.title or "Untitled Event"
                local dedupe_key = string.format(
                  "%s|%s|%s|%s|%s",
                  tostring(wow_event_id),
                  tostring(start_ms),
                  tostring(end_ms),
                  tostring(event_type),
                  tostring(title)
                )

                if not seen[dedupe_key] then
                  seen[dedupe_key] = true
                  local event_payload = {
                    wowEventId = wow_event_id,
                    title = title,
                    eventType = event_type,
                    startTime = start_ms,
                    endTime = end_ms,
                  }

                  if event_type == "raid" then
                    table.insert(pending_raid_events, {
                      monthOffset = month_offset,
                      monthDay = month_day,
                      eventIndex = event_index,
                      sourceEventId = source_event_id,
                      expectedStartTimeMs = start_ms,
                      eventPayload = event_payload,
                    })
                  end

                  table.insert(events, event_payload)
                end
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

  return events, pending_raid_events
end

local function finalize_calendar_capture(events)
  ensure_db()
  PuschelzDB.calendar.events = events or {}
  PuschelzDB.calendar.lastScannedAt = now_epoch_ms()
  PuschelzDB.updatedAt = PuschelzDB.calendar.lastScannedAt
end

local function reset_calendar_attendee_scan_state()
  calendar_attendee_scan.inProgress = false
  calendar_attendee_scan.events = nil
  calendar_attendee_scan.pendingRaidEvents = {}
  calendar_attendee_scan.activeRaidEvent = nil
  calendar_attendee_scan.notifyOnCompletion = false
end

local function print_calendar_scan_complete(events)
  local event_count = 0
  local raid_event_count = 0
  local events_with_attendees = 0
  local attendee_total = 0

  for _, event in ipairs(events or {}) do
    event_count = event_count + 1
    if event.eventType == "raid" then
      raid_event_count = raid_event_count + 1
      local attendees = event.attendees or {}
      local attendee_count = #attendees
      if attendee_count > 0 then
        events_with_attendees = events_with_attendees + 1
        attendee_total = attendee_total + attendee_count
      end
    end
  end

  print(
    string.format(
      "Puschelz: calendar scan complete (%d events, %d raids, %d raids with attendees, %d attendees total).",
      event_count,
      raid_event_count,
      events_with_attendees,
      attendee_total
    )
  )
end

local function complete_calendar_attendee_scan()
  local events = calendar_attendee_scan.events or {}
  local notify_on_completion = calendar_attendee_scan.notifyOnCompletion
  reset_calendar_attendee_scan_state()
  finalize_calendar_capture(events)
  if notify_on_completion then
    print_calendar_scan_complete(events)
  end
end

local function process_next_calendar_attendee_event()
  if not calendar_attendee_scan.inProgress then
    return
  end

  if not C_Calendar or not C_Calendar.OpenEvent then
    complete_calendar_attendee_scan()
    return
  end

  local next_raid_event = table.remove(calendar_attendee_scan.pendingRaidEvents, 1)
  if not next_raid_event then
    complete_calendar_attendee_scan()
    return
  end

  calendar_attendee_scan.activeRaidEvent = next_raid_event
  next_raid_event.openRequestedAtMs = now_runtime_ms()
  C_Calendar.OpenEvent(
    next_raid_event.monthOffset,
    next_raid_event.monthDay,
    next_raid_event.eventIndex
  )
end

local function finish_active_calendar_event_attendee_capture(expected_raid_event)
  if not calendar_attendee_scan.inProgress then
    return
  end

  local active_raid_event = calendar_attendee_scan.activeRaidEvent
  if not active_raid_event then
    return
  end

  if expected_raid_event and active_raid_event ~= expected_raid_event then
    -- Timer callbacks can fire after scan has advanced to another event.
    return
  end

  local attendees = collect_open_calendar_event_attendees()
  if attendees then
    active_raid_event.eventPayload.attendees = attendees
  end

  if C_Calendar and C_Calendar.CloseEvent then
    C_Calendar.CloseEvent()
  end

  calendar_attendee_scan.activeRaidEvent = nil
  process_next_calendar_attendee_event()
end

local function calendar_open_event_matches_active(active_raid_event, month_offset, month_day, event_index)
  if active_raid_event.openRequestedAtMs then
    local elapsed_since_open_ms = now_runtime_ms() - active_raid_event.openRequestedAtMs
    if elapsed_since_open_ms > (CALENDAR_ATTENDEE_SCAN_TIMEOUT_SEC * 1000) then
      return false
    end
  end

  if type(month_offset) ~= "number" then
    month_offset = nil
  end

  if month_offset and (type(month_day) ~= "number" or type(event_index) ~= "number") then
    month_offset = nil
  end

  if month_offset then
    if active_raid_event.monthOffset ~= month_offset
      or active_raid_event.monthDay ~= month_day
      or active_raid_event.eventIndex ~= event_index
    then
      return false
    end
  end

  if not C_Calendar or not C_Calendar.EventGetInfo then
    return true
  end

  local opened_event_info = C_Calendar.EventGetInfo()
  if type(opened_event_info) ~= "table" then
    return true
  end

  local opened_event_id = tonumber(opened_event_info.eventID or opened_event_info.eventId)
  if active_raid_event.sourceEventId and opened_event_id then
    if active_raid_event.sourceEventId ~= opened_event_id then
      return false
    end
  end

  local month_info = C_Calendar.GetMonthInfo and C_Calendar.GetMonthInfo(active_raid_event.monthOffset)
  local opened_start_ms = calendar_time_to_ms(
    opened_event_info.startTime,
    month_info and month_info.year,
    month_info and month_info.month,
    active_raid_event.monthDay
  )
  if opened_start_ms and active_raid_event.expectedStartTimeMs then
    if opened_start_ms ~= active_raid_event.expectedStartTimeMs then
      return false
    end
  end

  local opened_title = type(opened_event_info.title) == "string" and opened_event_info.title or nil
  local expected_title = active_raid_event.eventPayload and active_raid_event.eventPayload.title
  if opened_title and opened_title ~= "" and type(expected_title) == "string" and expected_title ~= "" then
    if opened_title ~= expected_title then
      return false
    end
  end

  return true
end

local function on_calendar_open_event(month_offset, month_day, event_index)
  if not calendar_attendee_scan.inProgress then
    return
  end

  local active_raid_event = calendar_attendee_scan.activeRaidEvent
  if not active_raid_event then
    return
  end

  if not calendar_open_event_matches_active(active_raid_event, month_offset, month_day, event_index) then
    return
  end

  active_raid_event.openedAtMs = now_runtime_ms()

  if not C_Timer or not C_Timer.After then
    finish_active_calendar_event_attendee_capture(active_raid_event)
    return
  end

  local scan_generation = calendar_attendee_scan.scanGeneration
  C_Timer.After(CALENDAR_ATTENDEE_EVENT_OPEN_TIMEOUT_SEC, function()
    if not calendar_attendee_scan.inProgress or calendar_attendee_scan.scanGeneration ~= scan_generation then
      return
    end

    finish_active_calendar_event_attendee_capture(active_raid_event)
  end)
end

local function on_calendar_update_invite_list()
  if not calendar_attendee_scan.inProgress then
    return
  end

  local active_raid_event = calendar_attendee_scan.activeRaidEvent
  if not active_raid_event or not active_raid_event.openedAtMs then
    return
  end

  finish_active_calendar_event_attendee_capture(active_raid_event)
end

local function capture_calendar(notify_on_completion)
  if calendar_attendee_scan.inProgress then
    if notify_on_completion then
      calendar_attendee_scan.notifyOnCompletion = true
    end
    return
  end

  local events, pending_raid_events = build_calendar_payload()
  if #pending_raid_events == 0 then
    finalize_calendar_capture(events)
    if notify_on_completion then
      print_calendar_scan_complete(events)
    end
    return
  end

  calendar_attendee_scan.inProgress = true
  calendar_attendee_scan.events = events
  calendar_attendee_scan.pendingRaidEvents = pending_raid_events
  calendar_attendee_scan.activeRaidEvent = nil
  calendar_attendee_scan.notifyOnCompletion = notify_on_completion == true
  calendar_attendee_scan.scanGeneration = calendar_attendee_scan.scanGeneration + 1
  local scan_generation = calendar_attendee_scan.scanGeneration

  if C_Timer and C_Timer.After then
    C_Timer.After(CALENDAR_ATTENDEE_SCAN_TIMEOUT_SEC, function()
      if calendar_attendee_scan.inProgress and calendar_attendee_scan.scanGeneration == scan_generation then
        complete_calendar_attendee_scan()
      end
    end)
  end

  process_next_calendar_attendee_event()
end

local function request_calendar_scan(notify_on_completion)
  if not C_Calendar or not C_Calendar.OpenCalendar then
    if notify_on_completion then
      print("Puschelz: calendar scan is unavailable right now.")
    end
    return
  end
  C_Calendar.OpenCalendar()
  capture_calendar(notify_on_completion)
end

local function trim_string(value)
  if type(value) ~= "string" then
    return nil
  end

  local trimmed = value:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return nil
  end

  return trimmed
end

local function normalize_epoch_ms(value)
  local numeric = tonumber(value)
  if not numeric or numeric <= 0 then
    return nil
  end

  if numeric < 100000000000 then
    return numeric * 1000
  end

  return numeric
end

local function sorted_guild_orders_from_map(order_map)
  local orders = {}
  for _, order in pairs(order_map or {}) do
    table.insert(orders, order)
  end

  table.sort(orders, function(a, b)
    local expiration_a = tonumber(a.expirationTime) or 0
    local expiration_b = tonumber(b.expirationTime) or 0
    if expiration_a == expiration_b then
      return (tonumber(a.orderId) or 0) < (tonumber(b.orderId) or 0)
    end
    return expiration_a < expiration_b
  end)

  return orders
end

local function guild_order_is_open(order)
  if type(order) ~= "table" then
    return false
  end

  local order_state = tonumber(order.orderState)
  if order_state == GUILD_ORDER_STATE_FULFILLED
    or order_state == GUILD_ORDER_STATE_CANCELED
    or order_state == GUILD_ORDER_STATE_EXPIRED
  then
    return false
  end

  local expiration_time = tonumber(order.expirationTime)
  if expiration_time and expiration_time > 0 and expiration_time <= now_epoch_ms() then
    return false
  end

  return true
end

local function normalize_guild_order(raw_order)
  if type(raw_order) ~= "table" then
    return nil
  end

  local order_type = tonumber(raw_order.orderType)
  if order_type ~= GUILD_ORDER_TYPE_GUILD then
    return nil
  end

  local order_id = tonumber(raw_order.orderID or raw_order.orderId)
  local item_id = tonumber(raw_order.itemID or raw_order.itemId)
  local spell_id = tonumber(raw_order.spellID or raw_order.spellId)
  local order_state = tonumber(raw_order.orderState)
  local expiration_time = normalize_epoch_ms(raw_order.expirationTime)
  if not order_id or not item_id or not spell_id or not order_state or not expiration_time then
    return nil
  end

  return {
    orderId = order_id,
    itemId = item_id,
    spellId = spell_id,
    orderType = "guild",
    orderState = order_state,
    expirationTime = expiration_time,
    claimEndTime = normalize_epoch_ms(raw_order.claimEndTime),
    minQuality = tonumber(raw_order.minQuality) or nil,
    tipAmount = tonumber(raw_order.tipAmount) or nil,
    consortiumCut = tonumber(raw_order.consortiumCut) or nil,
    isRecraft = raw_order.isRecraft == true,
    isFulfillable = raw_order.isFulfillable == true,
    reagentState = tonumber(raw_order.reagentState) or nil,
    customerGuid = trim_string(raw_order.customerGuid),
    customerName = trim_string(raw_order.customerName),
    crafterGuid = trim_string(raw_order.crafterGuid),
    crafterName = trim_string(raw_order.crafterName),
    customerNotes = trim_string(raw_order.customerNotes),
    outputItemHyperlink = trim_string(raw_order.outputItemHyperlink),
    recraftItemHyperlink = trim_string(raw_order.recraftItemHyperlink),
  }
end

local function finalize_guild_orders_capture(orders)
  ensure_db()
  PuschelzDB.guildOrders.orders = orders or {}
  PuschelzDB.guildOrders.lastScannedAt = now_epoch_ms()
  PuschelzDB.updatedAt = PuschelzDB.guildOrders.lastScannedAt
end

local function collect_guild_orders_into_map(raw_orders, by_order_id)
  if type(raw_orders) ~= "table" then
    return
  end

  for _, raw_order in ipairs(raw_orders) do
    local normalized = normalize_guild_order(raw_order)
    if normalized then
      by_order_id[normalized.orderId] = normalized
    end
  end
end

local function collect_visible_guild_orders()
  if not C_CraftingOrders then
    return nil
  end

  local by_order_id = {}
  local has_supported_source = false

  if C_CraftingOrders.GetCrafterOrders then
    has_supported_source = true
    collect_guild_orders_into_map(C_CraftingOrders.GetCrafterOrders(), by_order_id)
  end

  if C_CraftingOrders.GetMyOrders then
    has_supported_source = true
    collect_guild_orders_into_map(C_CraftingOrders.GetMyOrders(), by_order_id)
  end

  if not has_supported_source then
    return nil
  end

  return sorted_guild_orders_from_map(by_order_id)
end

local function count_new_guild_orders(existing_orders, captured_orders)
  local existing_by_order_id = {}
  for _, order in ipairs(existing_orders or {}) do
    local order_id = tonumber(type(order) == "table" and order.orderId or nil)
    if order_id then
      existing_by_order_id[order_id] = true
    end
  end

  local new_count = 0
  for _, order in ipairs(captured_orders or {}) do
    local order_id = tonumber(type(order) == "table" and order.orderId or nil)
    if order_id and not existing_by_order_id[order_id] then
      new_count = new_count + 1
    end
  end

  return new_count
end

local function capture_visible_guild_orders(notify_on_completion)
  if guild_order_sync.active then
    return false
  end

  local orders = collect_visible_guild_orders()
  if not orders then
    return false
  end

  ensure_db()
  if #orders == 0 and #(PuschelzDB.guildOrders.orders or {}) > 0 then
    return false
  end

  local new_order_count = count_new_guild_orders(PuschelzDB.guildOrders.orders, orders)
  finalize_guild_orders_capture(orders)
  if notify_on_completion then
    print(string.format("Puschelz: captured %d visible guild order(s).", #orders))
  elseif new_order_count > 0 then
    print(string.format(
      "Puschelz: found %d new guild order(s) from the currently visible orders.",
      new_order_count
    ))
  end
  return true
end

local function merge_visible_guild_orders_into_sync_state()
  local orders = collect_visible_guild_orders()
  if not orders then
    return
  end

  for _, order in ipairs(orders) do
    guild_order_sync.collectedByOrderId[order.orderId] = order
  end
end

local function current_profession_enum()
  if not C_TradeSkillUI or not C_TradeSkillUI.GetBaseProfessionInfo then
    return nil
  end

  local info = C_TradeSkillUI.GetBaseProfessionInfo()
  if type(info) ~= "table" then
    return nil
  end

  local profession = tonumber(info.profession)
  if profession and profession >= 0 then
    return profession
  end

  return nil
end

local function crafting_order_request_succeeded(result)
  if type(result) ~= "number" then
    return false
  end

  local ok_result = Enum and Enum.CraftingOrderResult and Enum.CraftingOrderResult.Ok
  if type(ok_result) == "number" then
    return result == ok_result
  end

  return result == 0
end

local function guild_order_request_sort_info()
  return {
    primarySort = {
      sortType = (Enum and Enum.CraftingOrderSortType and Enum.CraftingOrderSortType.TimeRemaining) or 6,
      reversed = false,
    },
    secondarySort = {
      sortType = (Enum and Enum.CraftingOrderSortType and Enum.CraftingOrderSortType.ItemName) or 0,
      reversed = false,
    },
  }
end

local function set_guild_order_sync_button_busy(is_busy)
  for _, button in pairs(guild_order_sync.buttons) do
    button:SetEnabled(not is_busy)
    button:SetText(is_busy and "Syncing..." or "Sync Guild Orders")
  end
end

local function reset_full_guild_order_sync_state()
  guild_order_sync.active = false
  guild_order_sync.notifyOnCompletion = false
  guild_order_sync.collectedByOrderId = {}
  guild_order_sync.profession = nil
  set_guild_order_sync_button_busy(false)
end

local function finalize_full_guild_order_sync(notify_on_completion)
  local orders = sorted_guild_orders_from_map(guild_order_sync.collectedByOrderId)
  reset_full_guild_order_sync_state()
  finalize_guild_orders_capture(orders)

  if notify_on_completion then
    print(string.format("Puschelz: full guild order sync complete (%d order(s)).", #orders))
  end
end

local function abort_full_guild_order_sync(message)
  reset_full_guild_order_sync_state()
  if type(message) == "string" and message ~= "" then
    print(message)
  end
end

local function request_full_guild_order_sync_source(source_name, offset, generation)
  if not guild_order_sync.active or guild_order_sync.requestGeneration ~= generation then
    return
  end

  if not C_CraftingOrders then
    abort_full_guild_order_sync("Puschelz: guild order sync is unavailable right now.")
    return
  end

  if source_name == nil then
    finalize_full_guild_order_sync(guild_order_sync.notifyOnCompletion)
    return
  end

  if source_name == "crafter" then
    if not C_CraftingOrders.RequestCrafterOrders or guild_order_sync.profession == nil then
      request_full_guild_order_sync_source("myOrders", 0, generation)
      return
    end

    local function handle_result(result, _, _, expect_more_rows, next_offset)
      if not guild_order_sync.active or guild_order_sync.requestGeneration ~= generation then
        return
      end

      if crafting_order_request_succeeded(result) then
        merge_visible_guild_orders_into_sync_state()
      end

      if crafting_order_request_succeeded(result) and expect_more_rows and type(next_offset) == "number" then
        request_full_guild_order_sync_source("crafter", next_offset, generation)
        return
      end

      request_full_guild_order_sync_source("myOrders", 0, generation)
    end

    local callback = handle_result
    if C_FunctionContainers and C_FunctionContainers.CreateCallback then
      callback = C_FunctionContainers.CreateCallback(handle_result)
    end

    local sort_info = guild_order_request_sort_info()
    local request = {
      orderType = GUILD_ORDER_TYPE_GUILD,
      profession = guild_order_sync.profession,
      searchFavorites = false,
      initialNonPublicSearch = true,
      primarySort = sort_info.primarySort,
      secondarySort = sort_info.secondarySort,
      forCrafter = true,
      offset = offset or 0,
      callback = callback,
    }

    C_CraftingOrders.RequestCrafterOrders(request)
    return
  end

  if source_name ~= "myOrders" then
    finalize_full_guild_order_sync(guild_order_sync.notifyOnCompletion)
    return
  end

  if not C_CraftingOrders.ListMyOrders then
    finalize_full_guild_order_sync(guild_order_sync.notifyOnCompletion)
    return
  end

  local function handle_result(result, expect_more_rows, next_offset)
    if not guild_order_sync.active or guild_order_sync.requestGeneration ~= generation then
      return
    end

    if crafting_order_request_succeeded(result) then
      merge_visible_guild_orders_into_sync_state()
    end

    if crafting_order_request_succeeded(result) and expect_more_rows and type(next_offset) == "number" then
      request_full_guild_order_sync_source("myOrders", next_offset, generation)
      return
    end

    finalize_full_guild_order_sync(guild_order_sync.notifyOnCompletion)
  end

  local callback = handle_result
  if C_FunctionContainers and C_FunctionContainers.CreateCallback then
    callback = C_FunctionContainers.CreateCallback(handle_result)
  end

  local sort_info = guild_order_request_sort_info()
  local request = {
    primarySort = sort_info.primarySort,
    secondarySort = sort_info.secondarySort,
    offset = offset or 0,
    callback = callback,
  }

  C_CraftingOrders.ListMyOrders(request)
end

local function begin_full_guild_order_sync(notify_on_completion)
  if guild_order_sync.active then
    return
  end

  guild_order_sync.active = true
  guild_order_sync.notifyOnCompletion = notify_on_completion == true
  guild_order_sync.requestGeneration = guild_order_sync.requestGeneration + 1
  guild_order_sync.collectedByOrderId = {}
  guild_order_sync.profession = current_profession_enum()
  local generation = guild_order_sync.requestGeneration
  set_guild_order_sync_button_busy(true)

  if C_Timer and C_Timer.After then
    C_Timer.After(GUILD_ORDER_SYNC_TIMEOUT_SEC, function()
      if guild_order_sync.active and guild_order_sync.requestGeneration == generation then
        finalize_full_guild_order_sync(guild_order_sync.notifyOnCompletion)
      end
    end)
  end

  request_full_guild_order_sync_source("crafter", 0, generation)
end

local function current_character_knows_spell(spell_id)
  if type(spell_id) ~= "number" or spell_id <= 0 then
    return false
  end

  if IsSpellKnownOrOverridesKnown then
    return IsSpellKnownOrOverridesKnown(spell_id)
  end

  if IsPlayerSpell then
    return IsPlayerSpell(spell_id)
  end

  if IsSpellKnown then
    return IsSpellKnown(spell_id)
  end

  return false
end

local function copper_to_money_label(copper)
  copper = tonumber(copper) or 0
  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  local remainder = copper % 100
  local parts = {}

  if gold > 0 then
    table.insert(parts, tostring(gold) .. "g")
  end
  if silver > 0 then
    table.insert(parts, tostring(silver) .. "s")
  end
  if remainder > 0 or #parts == 0 then
    table.insert(parts, tostring(remainder) .. "c")
  end

  return table.concat(parts, " ")
end

local function print_matching_guild_order_reminders()
  ensure_db()
  local matching_orders = {}

  for _, order in ipairs(PuschelzDB.guildOrders.orders or {}) do
    if guild_order_is_open(order) and current_character_knows_spell(tonumber(order.spellId)) then
      table.insert(matching_orders, order)
    end
  end

  if #matching_orders == 0 then
    return
  end

  table.sort(matching_orders, function(a, b)
    return (tonumber(a.orderId) or 0) < (tonumber(b.orderId) or 0)
  end)

  print(string.format("Puschelz: %d open guild order(s) match this character.", #matching_orders))
  for _, order in ipairs(matching_orders) do
    local item_name = parse_item_name(order.outputItemHyperlink or order.recraftItemHyperlink)
      or ("Item " .. tostring(order.itemId or "?"))
    local quality_text = ""
    if tonumber(order.minQuality) and tonumber(order.minQuality) > 0 then
      quality_text = string.format(" q%d", tonumber(order.minQuality))
    end
    local tip_text = ""
    if tonumber(order.tipAmount) and tonumber(order.tipAmount) > 0 then
      tip_text = string.format(" tip %s", copper_to_money_label(order.tipAmount))
    end

    print(string.format(
      "Puschelz: open guild order #%d for %s%s%s",
      tonumber(order.orderId) or 0,
      item_name,
      quality_text,
      tip_text
    ))
  end
end

local function get_professions_host_frames()
  local hosts = {}
  local seen = {}

  local function add_host_frame(frame)
    if type(frame) == "table" and not seen[frame] then
      seen[frame] = true
      table.insert(hosts, frame)
    end
  end

  add_host_frame(ProfessionsFrame)
  add_host_frame(ProfessionsCustomerOrdersFrame)
  add_host_frame(TradeSkillFrame)

  return hosts
end

local function ensure_guild_order_sync_buttons()
  for _, host_frame in ipairs(get_professions_host_frames()) do
    if not guild_order_sync.buttons[host_frame] then
      local button = CreateFrame("Button", nil, host_frame, "UIPanelButtonTemplate")
      button:SetSize(140, 22)
      button:SetPoint("TOPRIGHT", host_frame, "TOPRIGHT", -36, -28)
      button:SetText("Sync Guild Orders")
      button:SetScript("OnClick", function()
        begin_full_guild_order_sync(true)
      end)
      guild_order_sync.buttons[host_frame] = button
    end
  end

  set_guild_order_sync_button_busy(guild_order_sync.active)
end

local function schedule_passive_guild_order_capture()
  ensure_guild_order_sync_buttons()

  if C_Timer and C_Timer.After then
    C_Timer.After(0.5, function()
      ensure_guild_order_sync_buttons()
      capture_visible_guild_orders(false)
    end)
  else
    ensure_guild_order_sync_buttons()
    capture_visible_guild_orders(false)
  end
end

local function normalized_realm_name()
  if GetNormalizedRealmName then
    local realm_name = GetNormalizedRealmName()
    if type(realm_name) == "string" and realm_name ~= "" then
      return realm_name
    end
  end

  local realm_name = GetRealmName()
  if type(realm_name) == "string" and realm_name ~= "" then
    return realm_name:gsub("%s+", "")
  end

  return nil
end

local function normalize_player_name(raw_name)
  if type(raw_name) ~= "string" then
    return nil, nil
  end

  local trimmed = raw_name:match("^%s*(.-)%s*$")
  if not trimmed or trimmed == "" then
    return nil, nil
  end

  local character_name, realm_name = trimmed:match("^([^%-]+)%-(.+)$")
  if not character_name then
    character_name = trimmed
    realm_name = normalized_realm_name()
  end

  if type(realm_name) == "string" and realm_name ~= "" then
    realm_name = realm_name:gsub("%s+", "")
    trimmed = character_name .. "-" .. realm_name
  else
    trimmed = character_name
  end

  return string.lower(trimmed), trimmed
end

local function local_player_identity()
  local character_name, realm_name = UnitFullName("player")
  if type(character_name) ~= "string" or character_name == "" then
    return nil, nil
  end

  local full_name = character_name
  if type(realm_name) == "string" and realm_name ~= "" then
    full_name = character_name .. "-" .. realm_name:gsub("%s+", "")
  end

  return normalize_player_name(full_name)
end

local function register_raid_status_prefix()
  if raid_status.prefixRegistered then
    return true
  end

  if not C_ChatInfo or not C_ChatInfo.RegisterAddonMessagePrefix then
    return false
  end

  raid_status.prefixRegistered = C_ChatInfo.RegisterAddonMessagePrefix(RAID_STATUS_PREFIX) and true or false
  return raid_status.prefixRegistered
end

local function build_raid_roster_state()
  raid_status.roster = {}
  raid_status.rosterByKey = {}

  if not IsInRaid() then
    return
  end

  local member_count = GetNumGroupMembers() or 0
  for index = 1, member_count do
    local name, _, subgroup, _, _, class_file = GetRaidRosterInfo(index)
    local member_key, full_name = normalize_player_name(name)
    if member_key and not raid_status.rosterByKey[member_key] then
      local entry = {
        key = member_key,
        fullName = full_name,
        subgroup = subgroup or 0,
        classFile = class_file,
      }
      raid_status.rosterByKey[member_key] = entry
      table.insert(raid_status.roster, entry)
    end
  end

  table.sort(raid_status.roster, function(a, b)
    if a.subgroup == b.subgroup then
      return a.fullName < b.fullName
    end
    return a.subgroup < b.subgroup
  end)
end

local function clear_raid_presence_data()
  raid_status.roster = {}
  raid_status.rosterByKey = {}
  raid_status.responsesByKey = {}
  raid_status.activeQueryId = nil
  raid_status.pendingUntilMs = 0
  raid_status.lastQueryAtMs = 0
  raid_status.autoCheckScheduled = false
end

local function keep_local_player_response(target_map)
  local response_map = target_map or raid_status.responsesByKey
  local player_key = select(1, local_player_identity())
  if player_key then
    response_map[player_key] = ADDON_VERSION
  end
end

local function get_member_presence(member_key)
  local version = raid_status.responsesByKey[member_key]
  if version then
    return "installed", version
  end

  if raid_status.pendingUntilMs > now_runtime_ms() then
    return "pending", nil
  end

  return "missing", nil
end

local function format_presence_text(status, version)
  if status == "installed" then
    return string.format("|cff00ff00Installed|r (%s)", version or "unknown")
  end

  if status == "pending" then
    return "|cffffff00Pending|r"
  end

  return "|cffff4040Missing|r"
end

local function class_color(class_file)
  if RAID_CLASS_COLORS and class_file and RAID_CLASS_COLORS[class_file] then
    return RAID_CLASS_COLORS[class_file]
  end
  return NORMAL_FONT_COLOR
end

local function ensure_raid_status_window()
  if raid_status.window then
    return raid_status.window
  end

  local window = CreateFrame("Frame", "PuschelzRaidStatusWindow", UIParent, "BasicFrameTemplateWithInset")
  window:SetSize(430, 590)
  window:SetPoint("CENTER")
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", function(self)
    self:StartMoving()
  end)
  window:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
  end)
  window:Hide()

  local title = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if window.TitleBg then
    title:SetPoint("TOP", window.TitleBg, "TOP", 0, -5)
  else
    title:SetPoint("TOP", window, "TOP", 0, -8)
  end
  title:SetText("Puschelz Raid Addon Status")
  window.title = title

  local summary = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  summary:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -36)
  summary:SetJustifyH("LEFT")
  summary:SetText("Not in a raid group.")
  window.summary = summary

  local name_header = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  name_header:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -56)
  name_header:SetText("Player")

  local status_header = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status_header:SetPoint("TOPRIGHT", window, "TOPRIGHT", -16, -56)
  status_header:SetText("Addon")

  for row_index = 1, RAID_STATUS_ROW_COUNT do
    local row = CreateFrame("Frame", nil, window)
    row:SetSize(398, 12)
    row:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -74 - ((row_index - 1) * 12))

    local name_font = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name_font:SetPoint("LEFT", row, "LEFT", 0, 0)
    name_font:SetWidth(235)
    name_font:SetJustifyH("LEFT")

    local status_font = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status_font:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    status_font:SetWidth(155)
    status_font:SetJustifyH("RIGHT")

    row.name = name_font
    row.status = status_font
    row:Hide()

    raid_status.rows[row_index] = row
  end

  raid_status.window = window
  return window
end

local function refresh_raid_status_window()
  local window = raid_status.window
  if not window then
    return
  end

  if not IsInRaid() or #raid_status.roster == 0 then
    window.summary:SetText("|cffff4040Not in a raid group.|r")

    local row = raid_status.rows[1]
    if row then
      row.name:SetText("Join a raid to check addon coverage.")
      row.name:SetTextColor(1, 1, 1)
      row.status:SetText("")
      row:Show()
    end

    for row_index = 2, RAID_STATUS_ROW_COUNT do
      local extra_row = raid_status.rows[row_index]
      if extra_row then
        extra_row:Hide()
      end
    end
    return
  end

  local installed_count = 0
  local pending_count = 0
  local missing_count = 0
  local row_index = 1

  for _, member in ipairs(raid_status.roster) do
    local row = raid_status.rows[row_index]
    if row then
      local status, version = get_member_presence(member.key)
      if status == "installed" then
        installed_count = installed_count + 1
      elseif status == "pending" then
        pending_count = pending_count + 1
      else
        missing_count = missing_count + 1
      end

      local color = class_color(member.classFile)
      row.name:SetText(member.fullName)
      row.name:SetTextColor(color.r or 1, color.g or 1, color.b or 1)
      row.status:SetText(format_presence_text(status, version))
      row:Show()
    end
    row_index = row_index + 1
  end

  for hidden_index = row_index, RAID_STATUS_ROW_COUNT do
    local hidden_row = raid_status.rows[hidden_index]
    if hidden_row then
      hidden_row:Hide()
    end
  end

  window.summary:SetText(
    string.format(
      "Raid members: %d  Installed: %d  Missing: %d  Pending: %d",
      #raid_status.roster,
      installed_count,
      missing_count,
      pending_count
    )
  )
end

local function toggle_raid_status_window()
  local window = ensure_raid_status_window()
  refresh_raid_status_window()
  if window:IsShown() then
    window:Hide()
    return
  end
  window:Show()
end

local function build_raid_message(message_type, query_id, version)
  return string.format("%s|%s|%s", tostring(message_type or ""), tostring(query_id or ""), tostring(version or ""))
end

local function parse_raid_message(message)
  if type(message) ~= "string" then
    return nil
  end

  local message_type, query_id, version = message:match("^([QR])|([^|]+)|?(.*)$")
  if not message_type or not query_id or query_id == "" then
    return nil
  end

  if message_type == "Q" then
    return {
      messageType = message_type,
      queryId = query_id,
    }
  end

  if type(version) ~= "string" or version == "" then
    version = "unknown"
  end

  return {
    messageType = message_type,
    queryId = query_id,
    version = version,
  }
end

local function resolve_raid_distribution()
  if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    return "INSTANCE_CHAT"
  end

  if IsInRaid() then
    return "RAID"
  end

  return nil
end

local function send_raid_message(payload, distribution_override)
  if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then
    return false
  end

  local distribution = distribution_override
  if distribution ~= "RAID" and distribution ~= "INSTANCE_CHAT" then
    distribution = resolve_raid_distribution()
  end

  if not distribution then
    return false
  end

  C_ChatInfo.SendAddonMessage(RAID_STATUS_PREFIX, payload, distribution)
  return true
end

local function mark_reply_sent(sender_key, query_id)
  local dedupe_key = string.format("%s|%s", tostring(sender_key), tostring(query_id))
  if raid_status.sentReplyKeys[dedupe_key] then
    return false
  end

  raid_status.sentReplyKeys[dedupe_key] = now_runtime_ms()
  raid_status.sentReplyCount = raid_status.sentReplyCount + 1

  if raid_status.sentReplyCount > 300 then
    local cutoff_ms = now_runtime_ms() - (10 * 60 * 1000)
    local kept = 0
    for key, seen_at in pairs(raid_status.sentReplyKeys) do
      if seen_at and seen_at >= cutoff_ms then
        kept = kept + 1
      else
        raid_status.sentReplyKeys[key] = nil
      end
    end
    raid_status.sentReplyCount = kept
  end

  return true
end

local begin_raid_presence_check

local function schedule_auto_check_after(delay_ms)
  if raid_status.autoCheckScheduled or not C_Timer or not C_Timer.After then
    return
  end

  raid_status.autoCheckScheduled = true
  C_Timer.After(math.max(delay_ms / 1000, 0.2), function()
    raid_status.autoCheckScheduled = false
    if IsInRaid() then
      begin_raid_presence_check("auto")
    end
  end)
end

begin_raid_presence_check = function(trigger_source)
  build_raid_roster_state()

  if not IsInRaid() then
    clear_raid_presence_data()
    refresh_raid_status_window()
    if trigger_source == "manual" then
      print("Puschelz: join a raid to run addon checks.")
    end
    return false
  end

  keep_local_player_response()

  local now = now_runtime_ms()
  local elapsed_ms = now - (raid_status.lastQueryAtMs or 0)
  if raid_status.lastQueryAtMs > 0 and elapsed_ms < RAID_QUERY_COOLDOWN_MS then
    local remaining_ms = RAID_QUERY_COOLDOWN_MS - elapsed_ms
    if trigger_source == "auto" then
      schedule_auto_check_after(remaining_ms + 100)
    elseif trigger_source == "manual" then
      print(string.format("Puschelz: raid addon check on cooldown (%ds).", math.ceil(remaining_ms / 1000)))
    end
    refresh_raid_status_window()
    return false
  end

  if not register_raid_status_prefix() then
    if trigger_source == "manual" then
      print("Puschelz: addon chat prefix registration failed.")
    end
    refresh_raid_status_window()
    return false
  end

  raid_status.queryCounter = raid_status.queryCounter + 1
  local query_id = string.format("%d-%d", now, raid_status.queryCounter)
  local payload = build_raid_message("Q", query_id, ADDON_VERSION)

  if not send_raid_message(payload) then
    if trigger_source == "manual" then
      print("Puschelz: unable to send raid addon check message.")
    end
    refresh_raid_status_window()
    return false
  end

  raid_status.responsesByKey = {}
  keep_local_player_response()
  raid_status.activeQueryId = query_id
  raid_status.pendingUntilMs = now + RAID_REPLY_TIMEOUT_MS
  raid_status.lastQueryAtMs = now

  refresh_raid_status_window()

  if C_Timer and C_Timer.After then
    C_Timer.After((RAID_REPLY_TIMEOUT_MS / 1000) + 0.1, function()
      if raid_status.activeQueryId == query_id then
        refresh_raid_status_window()
      end
    end)
  end

  if trigger_source == "manual" then
    print("Puschelz: raid addon check triggered.")
  end

  return true
end

local function handle_raid_addon_message(prefix, message, channel, sender)
  if prefix ~= RAID_STATUS_PREFIX then
    return
  end

  local payload = parse_raid_message(message)
  if not payload then
    return
  end

  local sender_key = select(1, normalize_player_name(sender))
  local player_key = select(1, local_player_identity())
  if not sender_key or (player_key and sender_key == player_key) then
    return
  end

  if payload.messageType == "Q" then
    if not mark_reply_sent(sender_key, payload.queryId) then
      return
    end

    local function send_reply()
      send_raid_message(build_raid_message("R", payload.queryId, ADDON_VERSION), channel)
    end

    if C_Timer and C_Timer.After then
      local delay = math.random(5, 35) / 100
      C_Timer.After(delay, send_reply)
    else
      send_reply()
    end
    return
  end

  if payload.messageType == "R" and payload.queryId == raid_status.activeQueryId then
    if raid_status.rosterByKey[sender_key] then
      raid_status.responsesByKey[sender_key] = payload.version
      refresh_raid_status_window()
    end
  end
end

local function on_group_roster_update()
  raid_status.rosterRefreshScheduled = false
  if not IsInRaid() then
    clear_raid_presence_data()
    refresh_raid_status_window()
    return
  end

  begin_raid_presence_check("auto")
end

local function schedule_group_roster_update()
  if raid_status.rosterRefreshScheduled then
    return
  end

  raid_status.rosterRefreshScheduled = true
  if C_Timer and C_Timer.After then
    C_Timer.After(RAID_ROSTER_DEBOUNCE_SEC, on_group_roster_update)
  else
    on_group_roster_update()
  end
end

local function seed_raid_random_delay()
  local seed = now_runtime_ms()
  local player_guid = UnitGUID("player")
  if type(player_guid) == "string" and player_guid ~= "" then
    seed = (seed + stable_hash_number(player_guid)) % 2147483647
  end
  math.randomseed(seed)
  math.random()
  math.random()
  math.random()
end

local function print_status()
  ensure_db()

  local bank_tabs = PuschelzDB.guildBank.tabs or {}
  local calendar_events = PuschelzDB.calendar.events or {}
  local guild_orders = PuschelzDB.guildOrders.orders or {}

  local bank_scan = PuschelzDB.guildBank.lastScannedAt
  local calendar_scan = PuschelzDB.calendar.lastScannedAt
  local guild_order_scan = PuschelzDB.guildOrders.lastScannedAt

  print(
    string.format(
      "Puschelz: tabs=%d, events=%d, guildOrders=%d, bankScan=%s, calendarScan=%s, guildOrderScan=%s",
      #bank_tabs,
      #calendar_events,
      #guild_orders,
      bank_scan and date("%Y-%m-%d %H:%M", math.floor(bank_scan / 1000)) or "never",
      calendar_scan and date("%Y-%m-%d %H:%M", math.floor(calendar_scan / 1000)) or "never",
      guild_order_scan and date("%Y-%m-%d %H:%M", math.floor(guild_order_scan / 1000)) or "never"
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

    request_calendar_scan(true)
    print("Puschelz: scan triggered.")
    return
  end

  if command == "orders" then
    print_matching_guild_order_reminders()
    return
  end

  if command == "syncorders" then
    begin_full_guild_order_sync(true)
    return
  end

  if command == "check" then
    begin_raid_presence_check("manual")
    return
  end

  if command == "raidstatus" then
    toggle_raid_status_window()
    return
  end

  if command == "status" or command == "" then
    print_status()
    return
  end

  print("Puschelz usage: /puschelz status | /puschelz scan | /puschelz orders | /puschelz syncorders | /puschelz check | /puschelz raidstatus")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("CRAFTINGORDERS_SHOW_CRAFTER")
frame:RegisterEvent("CRAFTINGORDERS_SHOW_CUSTOMER")
frame:RegisterEvent("GUILDBANKFRAME_OPENED")
frame:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
frame:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
frame:RegisterEvent("CALENDAR_OPEN_EVENT")
frame:RegisterEvent("CALENDAR_UPDATE_INVITE_LIST")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    ensure_db()
    refresh_player_metadata()
    request_calendar_scan(false)
    print_matching_guild_order_reminders()
    seed_raid_random_delay()
    register_raid_status_prefix()
    schedule_group_roster_update()
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

  if event == "TRADE_SKILL_SHOW"
    or event == "CRAFTINGORDERS_SHOW_CRAFTER"
    or event == "CRAFTINGORDERS_SHOW_CUSTOMER"
  then
    schedule_passive_guild_order_capture()
    return
  end

  if event == "GUILDBANKBAGSLOTS_CHANGED" then
    on_bank_slots_changed()
    return
  end

  if event == "CALENDAR_OPEN_EVENT" then
    on_calendar_open_event(...)
    return
  end

  if event == "CALENDAR_UPDATE_INVITE_LIST" then
    on_calendar_update_invite_list()
    return
  end

  if event == "CALENDAR_UPDATE_EVENT_LIST" then
    if not calendar_attendee_scan.inProgress then
      capture_calendar(false)
    end
    return
  end

  if event == "PLAYER_ENTERING_WORLD" then
    schedule_group_roster_update()
    return
  end

  if event == "GROUP_ROSTER_UPDATE" then
    schedule_group_roster_update()
    return
  end

  if event == "CHAT_MSG_ADDON" then
    local prefix, message, channel, sender = ...
    if channel == "RAID" or channel == "INSTANCE_CHAT" then
      handle_raid_addon_message(prefix, message, channel, sender)
    end
    return
  end

  if event == "PLAYER_LOGOUT" then
    ensure_db()
    PuschelzDB.updatedAt = now_epoch_ms()
  end
end)
