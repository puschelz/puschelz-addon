local ADDON_NAME = ...

local SCHEMA_VERSION = 13
local GUILD_BANK_SLOTS_PER_TAB = 98
local CALENDAR_MONTH_OFFSETS = { -1, 0, 1, 2 }

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
                  table.insert(events, {
                    wowEventId = wow_event_id,
                    title = title,
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
  PuschelzDB.calendar.lastScannedAt = now_epoch_ms()
  PuschelzDB.updatedAt = PuschelzDB.calendar.lastScannedAt
end

local function request_calendar_scan()
  if not C_Calendar or not C_Calendar.OpenCalendar then
    return
  end
  C_Calendar.OpenCalendar()
  capture_calendar()
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

  print("Puschelz usage: /puschelz status | /puschelz scan | /puschelz check | /puschelz raidstatus")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("GUILDBANKFRAME_OPENED")
frame:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
frame:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    ensure_db()
    refresh_player_metadata()
    request_calendar_scan()
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

  if event == "GUILDBANKBAGSLOTS_CHANGED" then
    on_bank_slots_changed()
    return
  end

  if event == "CALENDAR_UPDATE_EVENT_LIST" then
    capture_calendar()
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
