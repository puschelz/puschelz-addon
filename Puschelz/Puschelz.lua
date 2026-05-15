local ADDON_NAME = ...

assert(PuschelzExportSnapshot, "Puschelz export snapshot module missing")
assert(PuschelzBridgeSnapshot, "Puschelz bridge snapshot module missing")

local SCHEMA_VERSION = 18
local GUILD_BANK_SLOTS_PER_TAB = 98
local CALENDAR_MONTH_OFFSETS = { -1, 0, 1, 2 }
local GUILD_ORDER_TYPE_GUILD = 1
local GUILD_ORDER_STATE_FULFILLED = 11
local GUILD_ORDER_STATE_CANCELED = 13
local GUILD_ORDER_STATE_EXPIRED = 15
local MINIMAP_BUTTON_DEFAULT_ANGLE = 220
local MINIMAP_LDB_NAME = "Puschelz"
local MINIMAP_ICON_PATH = "Interface\\AddOns\\Puschelz\\Media\\puschelz-logo.png"

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
local CRAFT_REQUEST_PREFIX = "PUSCHELZREQ"
local CRAFT_REQUEST_MAX_MESSAGE_LENGTH = 240
local CRAFT_REQUEST_CHUNK_TTL_MS = 30000
local RAID_QUERY_COOLDOWN_MS = 8000
local RAID_REPLY_TIMEOUT_MS = 4000
local RAID_ROSTER_DEBOUNCE_SEC = 1.0
local RAID_STATUS_ROW_COUNT = 40
local CALENDAR_ATTENDEE_SCAN_TIMEOUT_SEC = 45
local CALENDAR_ATTENDEE_EVENT_OPEN_TIMEOUT_SEC = 1.5
local CALENDAR_SYNC_BUTTON_RESET_DELAY_SEC = 4
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

local sync_queue = {
  prefix = "PUSCHELZSYNC",
  ttlMs = 24 * 60 * 60 * 1000,
  scopeOrder = { "calendar", "guildOrders", "simc" },
  scopeLabels = {
    calendar = "calendar",
    guildOrders = "orders",
    simc = "simc",
  },
  prefixRegistered = false,
}

local normalize_player_name
local local_player_identity
local refresh_sync_state_visuals
local refresh_minimap_pending_state

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
  requestPending = false,
  requestGeneration = 0,
  pendingNotifyOnCompletion = false,
  notifyOnCompletion = false,
}

local calendar_sync_ui = {
  button = nil,
  filterButton = nil,
  buttonHooksInstalled = false,
  state = "idle",
  stateGeneration = 0,
}

local minimap_ui = {
  button = nil,
  dataObject = nil,
  ldb = LibStub and LibStub("LibDataBroker-1.1", true),
  iconLib = LibStub and LibStub("LibDBIcon-1.0", true),
  menuFrame = nil,
  menuButtons = nil,
  pendingDot = nil,
}

local auto_logging = {
  evaluationScheduled = false,
  combatLogAutoStarted = false,
  reminderFrame = nil,
  lastReminderAtMs = 0,
}

local guild_order_sync = {
  active = false,
  notifyOnCompletion = false,
  requestGeneration = 0,
  collectedByOrderId = {},
  profession = nil,
  buttons = {},
  professionsFrameHooked = false,
  customerOrdersHooked = false,
}

local craft_request_bridge = {
  prefixRegistered = false,
  lastBroadcastSnapshotVersion = nil,
  seenBroadcasts = {},
  seenBroadcastCount = 0,
  pendingChunks = {},
  formInitHooked = false,
  recipeSelectionHooked = false,
  selectionGeneration = 0,
  selectedSpellId = nil,
  selectedItemId = nil,
  widgetContainer = nil,
  widget = nil,
  lastWidgetRecipeKey = nil,
  lastWidgetStateKey = nil,
  bridgeLoadAttempted = false,
  bridgeLoaded = false,
  bridgeLoadReason = "not_attempted",
  bridgeDebugSynced = false,
  requiredAddonSummaryKey = nil,
}

local refresh_place_order_status_widget
local reset_minimum_quality_status
local extract_recipe_context
local ensure_minimap_button
local refresh_minimap_button_position
local trim_text

local function set_selected_bridge_recipe(spell_id, item_id, source)
  craft_request_bridge.selectionGeneration = (craft_request_bridge.selectionGeneration or 0) + 1
  craft_request_bridge.selectedSpellId = tonumber(spell_id)
  craft_request_bridge.selectedItemId = tonumber(item_id)
  craft_request_bridge.lastWidgetRecipeKey = nil
  craft_request_bridge.lastWidgetStateKey = nil
end

local function schedule_craft_request_widget_refresh()
  if not refresh_place_order_status_widget then
    return
  end

  refresh_place_order_status_widget()

  if not C_Timer or type(C_Timer.After) ~= "function" then
    return
  end

  local generation = craft_request_bridge.selectionGeneration or 0
  local delays = { 0, 0.05, 0.2, 0.5 }
  for _, delay in ipairs(delays) do
    C_Timer.After(delay, function()
      if (craft_request_bridge.selectionGeneration or 0) ~= generation then
        return
      end

      if refresh_place_order_status_widget then
        refresh_place_order_status_widget()
      end
    end)
  end
end

local function ensure_db()
  return PuschelzExportSnapshot.ensure_db(SCHEMA_VERSION, MINIMAP_BUTTON_DEFAULT_ANGLE)
end

do
  local reminder_duration_sec = 3
  local function print_logging_message(message)
    if DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
      DEFAULT_CHAT_FRAME:AddMessage(message)
      return
    end

    print(message)
  end

  local function ensure_logging_settings()
    ensure_db()
    return PuschelzDB.ui.logging
  end

  local function is_in_combat_log_group_context()
    local in_instance = false
    local instance_type = nil
    if type(IsInInstance) == "function" then
      in_instance, instance_type = IsInInstance()
    end

    local in_raid_group = type(IsInRaid) == "function" and IsInRaid() or false
    local in_instance_group = false
    if type(IsInGroup) == "function" then
      if LE_PARTY_CATEGORY_INSTANCE then
        in_instance_group = IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
      else
        in_instance_group = IsInGroup()
      end
    end

    local in_group_instance = in_instance and (instance_type == "party" or instance_type == "raid")
    return in_raid_group or in_instance_group or in_group_instance
  end

  local function is_chat_logging_enabled()
    return type(LoggingChat) == "function" and LoggingChat() and true or false
  end

  local function is_combat_logging_enabled()
    return type(LoggingCombat) == "function" and LoggingCombat() and true or false
  end

  local function set_chat_logging_enabled(enabled, reason)
    if type(LoggingChat) ~= "function" then
      return false
    end

    if is_chat_logging_enabled() == enabled then
      return false
    end

    LoggingChat(enabled and true or false)
    print_logging_message(
      string.format(
        "Puschelz: chat logging %s%s.",
        enabled and "enabled" or "disabled",
        reason and reason ~= "" and (" (" .. reason .. ")") or ""
      )
    )
    return true
  end

  local function set_combat_logging_enabled(enabled, reason)
    if type(LoggingCombat) ~= "function" then
      return false
    end

    if is_combat_logging_enabled() == enabled then
      return false
    end

    LoggingCombat(enabled and true or false)
    print_logging_message(
      string.format(
        "Puschelz: combat logging %s%s.",
        enabled and "enabled" or "disabled",
        reason and reason ~= "" and (" (" .. reason .. ")") or ""
      )
    )
    return true
  end

  local function ensure_combat_log_reminder_frame()
    if auto_logging.reminderFrame then
      return auto_logging.reminderFrame
    end

    local frame = CreateFrame("Frame", "PuschelzCombatLogReminderFrame", UIParent)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetSize(520, 44)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -180)
    frame:Hide()

    frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    frame.text:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.text:SetTextColor(1, 0.82, 0)
    frame.text:SetJustifyH("CENTER")
    frame.text:SetText("Enable Live Log in Warcraft Logs if you want live uploads.")

    auto_logging.reminderFrame = frame
    return frame
  end

  local function show_combat_log_reminder()
    local now = now_runtime_ms()
    if now - (auto_logging.lastReminderAtMs or 0) < 10000 then
      return
    end

    auto_logging.lastReminderAtMs = now

    if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo.RAID_WARNING then
      RaidNotice_AddMessage(
        RaidWarningFrame,
        "Puschelz: Enable Live Log in Warcraft Logs if you want live uploads.",
        ChatTypeInfo.RAID_WARNING
      )
    end

    local frame = ensure_combat_log_reminder_frame()
    frame.text:SetText("Enable Live Log in Warcraft Logs if you want live uploads.")
    frame.expiresAt = GetTime() + reminder_duration_sec
    frame:SetScript("OnUpdate", function(self)
      if GetTime() >= (self.expiresAt or 0) then
        self:SetScript("OnUpdate", nil)
        self:Hide()
      end
    end)
    frame:Show()
  end

  local function evaluate_auto_logging()
    local settings = ensure_logging_settings()

    if settings.autoEnableChatLog then
      set_chat_logging_enabled(true, "auto")
    end

    if not settings.autoEnableCombatLog then
      auto_logging.combatLogAutoStarted = false
      return
    end

    local should_gate_on_group_context = settings.onlyEnableCombatLogInGroupContext
    local in_group_context = is_in_combat_log_group_context()

    if should_gate_on_group_context and not in_group_context then
      if settings.stopCombatLogOnLeave and auto_logging.combatLogAutoStarted and is_combat_logging_enabled() then
        if set_combat_logging_enabled(false, "left raid or instance context") then
          auto_logging.combatLogAutoStarted = false
        end
      end
      return
    end

    local changed = set_combat_logging_enabled(
      true,
      should_gate_on_group_context and "entered raid or instance context" or "auto"
    )
    if changed then
      auto_logging.combatLogAutoStarted = true
      if settings.showCombatLogReminder then
        show_combat_log_reminder()
      end
    end
  end

  auto_logging.ensure_settings = ensure_logging_settings
  auto_logging.is_in_group_context = is_in_combat_log_group_context
  auto_logging.is_chat_logging_enabled = is_chat_logging_enabled
  auto_logging.is_combat_logging_enabled = is_combat_logging_enabled
  auto_logging.set_chat_logging_enabled = set_chat_logging_enabled
  auto_logging.set_combat_logging_enabled = set_combat_logging_enabled
  auto_logging.schedule_evaluation = function()
    if auto_logging.evaluationScheduled then
      return
    end

    if not C_Timer or type(C_Timer.After) ~= "function" then
      evaluate_auto_logging()
      return
    end

    auto_logging.evaluationScheduled = true
    C_Timer.After(0.2, function()
      auto_logging.evaluationScheduled = false
      evaluate_auto_logging()
    end)
  end
end

function sync_queue.normalize_scope_list(raw_scopes)
  local seen = {}
  local normalized = {}

  local function add_scope(scope)
    if type(scope) ~= "string" then
      return
    end
    for _, candidate in ipairs(sync_queue.scopeOrder) do
      if candidate == scope and not seen[candidate] then
        seen[candidate] = true
        table.insert(normalized, candidate)
        return
      end
    end
  end

  if type(raw_scopes) == "string" then
    add_scope(raw_scopes)
  elseif type(raw_scopes) == "table" then
    for _, scope in ipairs(raw_scopes) do
      add_scope(scope)
    end
  end

  return normalized
end

function sync_queue.merge_scope_lists(existing_scopes, additional_scopes)
  local merged = {}
  local seen = {}

  for _, scope in ipairs(sync_queue.normalize_scope_list(existing_scopes)) do
    if not seen[scope] then
      seen[scope] = true
      table.insert(merged, scope)
    end
  end

  for _, scope in ipairs(sync_queue.normalize_scope_list(additional_scopes)) do
    if not seen[scope] then
      seen[scope] = true
      table.insert(merged, scope)
    end
  end

  return merged
end

function sync_queue.scope_list_to_csv(scopes)
  return table.concat(sync_queue.normalize_scope_list(scopes), ",")
end

function sync_queue.scope_csv_to_list(text)
  local scopes = {}
  if type(text) ~= "string" or text == "" then
    return scopes
  end

  for token in string.gmatch(text, "([^,]+)") do
    table.insert(scopes, token)
  end

  return sync_queue.normalize_scope_list(scopes)
end

function sync_queue.format_scope_labels(scopes)
  local labels = {}
  for _, scope in ipairs(sync_queue.normalize_scope_list(scopes)) do
    table.insert(labels, sync_queue.scopeLabels[scope] or scope)
  end

  if #labels == 0 then
    return "none"
  end

  return table.concat(labels, ", ")
end

function sync_queue.sanitize_field(value)
  local text = tostring(value or "")
  text = string.gsub(text, "|", "/")
  text = string.gsub(text, "[\r\n]", " ")
  return text
end

function sync_queue.append_hashed_field(parts, value)
  local text = tostring(value or "")
  table.insert(parts, tostring(#text))
  table.insert(parts, ":")
  table.insert(parts, text)
  table.insert(parts, ";")
end

function sync_queue.current_subject_key()
  local subject_key, subject_name = local_player_identity()
  return subject_key, subject_name
end

function sync_queue.normalize_subject_key(value)
  local subject_key, subject_name = normalize_player_name(value)
  if not subject_key then
    return nil, nil
  end
  return subject_key, subject_name
end

function sync_queue.queue_item_is_expired(item, now_ms)
  if type(item) ~= "table" then
    return true
  end

  local payload_version = tonumber(item.payloadVersion) or 0
  if payload_version <= 0 then
    return true
  end

  local last_broadcast_at = tonumber(item.lastBroadcastAt) or 0
  local updated_at = tonumber(item.updatedAt) or 0
  local freshness_at = math.max(last_broadcast_at, updated_at)
  if freshness_at <= 0 then
    return true
  end

  return freshness_at + sync_queue.ttlMs <= (tonumber(now_ms) or now_epoch_ms())
end

function sync_queue.prune_guild_queue()
  ensure_db()
  local now_ms = now_epoch_ms()
  local local_subject_key = select(1, sync_queue.current_subject_key())
  local rebuilt = {}

  for subject_key, item in pairs(PuschelzDB.guildSyncQueue) do
    local normalized_key = sync_queue.normalize_subject_key(subject_key)
    local remove_item = normalized_key == nil
      or sync_queue.queue_item_is_expired(item, now_ms)
      or (local_subject_key ~= nil and normalized_key == local_subject_key)

    if not remove_item then
      item.changedScopes = sync_queue.normalize_scope_list(item.changedScopes)
      item.payloadVersion = tonumber(item.payloadVersion) or 0
      item.createdAt = tonumber(item.createdAt) or now_ms
      item.updatedAt = tonumber(item.updatedAt) or item.createdAt
      item.lastBroadcastAt = tonumber(item.lastBroadcastAt) or item.updatedAt
      item.subjectKey = normalized_key
      rebuilt[normalized_key] = item
    end
  end

  PuschelzDB.guildSyncQueue = rebuilt
end

function sync_queue.sorted_guild_queue_items()
  sync_queue.prune_guild_queue()

  local items = {}
  for _, item in pairs(PuschelzDB.guildSyncQueue) do
    if type(item) == "table" and (tonumber(item.payloadVersion) or 0) > 0 then
      table.insert(items, item)
    end
  end

  table.sort(items, function(a, b)
    local a_broadcast = tonumber(a.lastBroadcastAt) or 0
    local b_broadcast = tonumber(b.lastBroadcastAt) or 0
    if a_broadcast == b_broadcast then
      return tostring(a.subjectName or a.subjectKey or "") < tostring(b.subjectName or b.subjectKey or "")
    end
    return a_broadcast > b_broadcast
  end)

  return items
end

function sync_queue.current_local_pending_reload()
  ensure_db()
  local pending = PuschelzDB.pendingReload
  if type(pending) ~= "table" then
    return nil
  end

  if (tonumber(pending.payloadVersion) or 0) <= 0 then
    return nil
  end

  local subject_key = sync_queue.normalize_subject_key(pending.subjectKey)
  if not subject_key then
    return nil
  end

  pending.subjectKey = subject_key
  pending.changedScopes = sync_queue.normalize_scope_list(pending.changedScopes)
  return pending
end

function sync_queue.build_calendar_signature()
  ensure_db()
  local parts = {}

  for _, event in ipairs(PuschelzDB.calendar.events or {}) do
    sync_queue.append_hashed_field(parts, event.wowEventId)
    sync_queue.append_hashed_field(parts, event.title)
    sync_queue.append_hashed_field(parts, event.eventType)
    sync_queue.append_hashed_field(parts, event.startTime)
    sync_queue.append_hashed_field(parts, event.endTime)

    for _, attendee in ipairs(event.attendees or {}) do
      sync_queue.append_hashed_field(parts, attendee.name)
      sync_queue.append_hashed_field(parts, attendee.status)
    end
  end

  return tostring(stable_hash_number(table.concat(parts)))
end

function sync_queue.build_guild_orders_signature()
  ensure_db()
  local parts = {}

  for _, order in ipairs(PuschelzDB.guildOrders.orders or {}) do
    sync_queue.append_hashed_field(parts, order.orderId)
    sync_queue.append_hashed_field(parts, order.itemId)
    sync_queue.append_hashed_field(parts, order.spellId)
    sync_queue.append_hashed_field(parts, order.orderState)
    sync_queue.append_hashed_field(parts, order.expirationTime)
    sync_queue.append_hashed_field(parts, order.claimEndTime)
    sync_queue.append_hashed_field(parts, order.minQuality)
    sync_queue.append_hashed_field(parts, order.tipAmount)
    sync_queue.append_hashed_field(parts, order.consortiumCut)
    sync_queue.append_hashed_field(parts, order.isRecraft == true and "1" or "0")
    sync_queue.append_hashed_field(parts, order.isFulfillable == true and "1" or "0")
    sync_queue.append_hashed_field(parts, order.reagentState)
    sync_queue.append_hashed_field(parts, order.customerGuid)
    sync_queue.append_hashed_field(parts, order.customerName)
    sync_queue.append_hashed_field(parts, order.crafterGuid)
    sync_queue.append_hashed_field(parts, order.crafterName)
    sync_queue.append_hashed_field(parts, order.customerNotes)
    sync_queue.append_hashed_field(parts, order.outputItemHyperlink)
    sync_queue.append_hashed_field(parts, order.recraftItemHyperlink)
  end

  return tostring(stable_hash_number(table.concat(parts)))
end

function sync_queue.build_simc_signature()
  ensure_db()
  local request = type(PuschelzDB.simcRequest) == "table" and PuschelzDB.simcRequest or nil
  if not request then
    return "0"
  end

  local parts = {}
  sync_queue.append_hashed_field(parts, request.requestId)
  sync_queue.append_hashed_field(parts, request.requestedAt)
  sync_queue.append_hashed_field(parts, request.characterName)
  sync_queue.append_hashed_field(parts, request.realmName)
  sync_queue.append_hashed_field(parts, request.runDroptimizerNow == true and "1" or "0")
  sync_queue.append_hashed_field(parts, request.profileText)

  return tostring(stable_hash_number(table.concat(parts)))
end

function sync_queue.current_scope_signatures()
  return {
    calendar = sync_queue.build_calendar_signature(),
    guildOrders = sync_queue.build_guild_orders_signature(),
    simc = sync_queue.build_simc_signature(),
  }
end

function sync_queue.current_payload_fingerprint()
  local signatures = sync_queue.current_scope_signatures()
  return table.concat({
    "calendar:" .. tostring(signatures.calendar or "0"),
    "guildOrders:" .. tostring(signatures.guildOrders or "0"),
    "simc:" .. tostring(signatures.simc or "0"),
  }, "|"), signatures
end

function sync_queue.clear_local_pending_reload(subject_key, payload_version, acknowledged_at)
  ensure_db()
  local pending = sync_queue.current_local_pending_reload()
  if not pending then
    return false
  end

  local normalized_subject_key = sync_queue.normalize_subject_key(subject_key)
  if not normalized_subject_key or normalized_subject_key ~= pending.subjectKey then
    return false
  end

  local acknowledged_version = tonumber(payload_version) or 0
  local pending_version = tonumber(pending.payloadVersion) or 0
  if acknowledged_version < pending_version then
    return false
  end

  PuschelzDB.lastSyncedPayload = {
    subjectKey = pending.subjectKey,
    subjectName = pending.subjectName,
    payloadVersion = pending_version,
    payloadFingerprint = pending.payloadFingerprint,
    scopeSignatures = pending.scopeSignatures,
    acknowledgedAt = tonumber(acknowledged_at) or now_epoch_ms(),
  }
  PuschelzDB.pendingReload = {}
  PuschelzDB.updatedAt = now_epoch_ms()
  return true
end

function sync_queue.clear_guild_queue_subject(subject_key, payload_version)
  ensure_db()
  local normalized_subject_key = sync_queue.normalize_subject_key(subject_key)
  if not normalized_subject_key then
    return false
  end

  local item = PuschelzDB.guildSyncQueue[normalized_subject_key]
  if type(item) ~= "table" then
    return false
  end

  if (tonumber(payload_version) or 0) < (tonumber(item.payloadVersion) or 0) then
    return false
  end

  PuschelzDB.guildSyncQueue[normalized_subject_key] = nil
  PuschelzDB.updatedAt = now_epoch_ms()
  return true
end

function sync_queue.apply_bridge_acknowledgment(raw_entry)
  if type(raw_entry) ~= "table" then
    return false
  end

  local subject_key = sync_queue.normalize_subject_key(raw_entry.subjectKey or raw_entry.subjectName)
  local payload_version = tonumber(raw_entry.payloadVersion) or 0
  if not subject_key or payload_version <= 0 then
    return false
  end

  local acknowledged_at = tonumber(raw_entry.acknowledgedAt) or tonumber(raw_entry.updatedAt) or now_epoch_ms()
  local changed = false
  if sync_queue.clear_local_pending_reload(subject_key, payload_version, acknowledged_at) then
    changed = true
  end
  if sync_queue.clear_guild_queue_subject(subject_key, payload_version) then
    changed = true
  end

  return changed
end

function sync_queue.consume_bridge_acknowledgments()
  local changed = PuschelzBridgeSnapshot.consume_acknowledgments(sync_queue.apply_bridge_acknowledgment)
  if changed and refresh_sync_state_visuals then
    refresh_sync_state_visuals()
  end
end

function sync_queue.parse_message(message)
  if type(message) ~= "string" then
    return nil
  end

  local fields = {}
  local field_start = 1
  while true do
    local separator_start, separator_end = string.find(message, "|", field_start, true)
    if not separator_start then
      table.insert(fields, string.sub(message, field_start))
      break
    end

    table.insert(fields, string.sub(message, field_start, separator_start - 1))
    field_start = separator_end + 1
  end

  if fields[1] ~= "PENDING" or #fields < 7 then
    return nil
  end

  local subject_key, _ = sync_queue.normalize_subject_key(fields[2])
  local payload_version = tonumber(fields[4]) or 0
  if not subject_key or payload_version <= 0 then
    return nil
  end

  return {
    subjectKey = subject_key,
    subjectName = fields[3],
    payloadVersion = payload_version,
    createdAt = tonumber(fields[5]) or 0,
    updatedAt = tonumber(fields[6]) or 0,
    changedScopes = sync_queue.scope_csv_to_list(fields[7]),
  }
end

function sync_queue.register_prefix()
  if sync_queue.prefixRegistered then
    return true
  end
  if not C_ChatInfo or not C_ChatInfo.RegisterAddonMessagePrefix then
    return false
  end

  sync_queue.prefixRegistered = C_ChatInfo.RegisterAddonMessagePrefix(sync_queue.prefix) and true or false
  return sync_queue.prefixRegistered
end

function sync_queue.broadcast_local_pending_reload()
  local pending = sync_queue.current_local_pending_reload()
  if not pending or not C_ChatInfo or not C_ChatInfo.SendAddonMessage then
    return false
  end
  if not sync_queue.register_prefix() then
    return false
  end
  if not IsInGuild or not IsInGuild() then
    return false
  end

  pending.lastBroadcastAt = now_epoch_ms()
  local payload = table.concat({
    "PENDING",
    sync_queue.sanitize_field(pending.subjectKey),
    sync_queue.sanitize_field(pending.subjectName),
    tostring(tonumber(pending.payloadVersion) or 0),
    tostring(tonumber(pending.createdAt) or 0),
    tostring(tonumber(pending.updatedAt) or 0),
    sync_queue.scope_list_to_csv(pending.changedScopes),
  }, "|")

  C_ChatInfo.SendAddonMessage(sync_queue.prefix, payload, "GUILD")
  PuschelzDB.updatedAt = now_epoch_ms()
  return true
end

function sync_queue.mark_local_pending_reload(changed_scopes, should_broadcast)
  ensure_db()
  local subject_key, subject_name = sync_queue.current_subject_key()
  if not subject_key or not subject_name then
    return nil
  end

  local fingerprint, scope_signatures = sync_queue.current_payload_fingerprint()
  local baseline = type(PuschelzDB.lastSyncedPayload) == "table" and PuschelzDB.lastSyncedPayload or {}
  local pending = sync_queue.current_local_pending_reload()
  local now_ms = now_epoch_ms()

  if pending and pending.subjectKey ~= subject_key then
    pending = nil
    PuschelzDB.pendingReload = {}
  end
  if baseline.subjectKey ~= subject_key then
    baseline = {}
  end

  local current_version = pending and (tonumber(pending.payloadVersion) or 0) or (tonumber(baseline.payloadVersion) or 0)
  local current_fingerprint = pending and pending.payloadFingerprint or baseline.payloadFingerprint
  local reference_scope_signatures = type(pending and pending.scopeSignatures) == "table"
    and pending.scopeSignatures
    or (type(baseline.scopeSignatures) == "table" and baseline.scopeSignatures or {})

  if current_fingerprint == fingerprint and not pending then
    if refresh_sync_state_visuals then
      refresh_sync_state_visuals()
    end
    return nil
  end

  if type(pending) ~= "table" then
    pending = {}
  end

  local effective_scopes = {}
  for _, scope in ipairs(sync_queue.normalize_scope_list(changed_scopes)) do
    if scope_signatures[scope] ~= reference_scope_signatures[scope] then
      table.insert(effective_scopes, scope)
    end
  end

  local merged_scopes = sync_queue.merge_scope_lists(pending.changedScopes, effective_scopes)
  local payload_changed = current_fingerprint ~= fingerprint
  if payload_changed then
    current_version = current_version + 1
  end

  if current_version <= 0 then
    current_version = 1
  end

  pending.subjectKey = subject_key
  pending.subjectName = subject_name
  pending.payloadVersion = current_version
  pending.payloadFingerprint = fingerprint
  pending.scopeSignatures = scope_signatures
  pending.changedScopes = merged_scopes
  pending.createdAt = tonumber(pending.createdAt) or now_ms
  if payload_changed then
    pending.updatedAt = now_ms
  else
    pending.updatedAt = tonumber(pending.updatedAt) or now_ms
  end

  PuschelzDB.pendingReload = pending
  PuschelzDB.updatedAt = now_ms

  if should_broadcast then
    sync_queue.broadcast_local_pending_reload()
  end

  if refresh_sync_state_visuals then
    refresh_sync_state_visuals()
  end

  return pending
end

function sync_queue.handle_addon_message(prefix, message, channel, sender)
  if prefix ~= sync_queue.prefix or channel ~= "GUILD" then
    return
  end

  local sender_key, sender_name = sync_queue.normalize_subject_key(sender)
  if not sender_key then
    return
  end

  local local_subject_key = select(1, sync_queue.current_subject_key())
  if sender_key and local_subject_key and sender_key == local_subject_key then
    return
  end

  local parsed = sync_queue.parse_message(message)
  if not parsed then
    return
  end

  if parsed.subjectKey ~= sender_key then
    return
  end

  parsed.subjectName = sender_name or parsed.subjectName

  if local_subject_key and parsed.subjectKey == local_subject_key then
    return
  end

  ensure_db()
  sync_queue.prune_guild_queue()

  local now_ms = now_epoch_ms()
  local existing = PuschelzDB.guildSyncQueue[parsed.subjectKey]
  if type(existing) ~= "table" then
    PuschelzDB.guildSyncQueue[parsed.subjectKey] = {
      subjectKey = parsed.subjectKey,
      subjectName = parsed.subjectName,
      payloadVersion = parsed.payloadVersion,
      changedScopes = parsed.changedScopes,
      createdAt = parsed.createdAt > 0 and parsed.createdAt or now_ms,
      updatedAt = parsed.updatedAt > 0 and parsed.updatedAt or now_ms,
      lastBroadcastAt = now_ms,
    }
    PuschelzDB.updatedAt = now_ms
    if refresh_sync_state_visuals then
      refresh_sync_state_visuals()
    end
    return
  end

  local existing_version = tonumber(existing.payloadVersion) or 0
  if parsed.payloadVersion < existing_version then
    return
  end

  existing.subjectName = parsed.subjectName ~= "" and parsed.subjectName or existing.subjectName
  existing.lastBroadcastAt = now_ms

  if parsed.payloadVersion == existing_version then
    existing.changedScopes = sync_queue.merge_scope_lists(existing.changedScopes, parsed.changedScopes)
    existing.createdAt = tonumber(existing.createdAt) or (parsed.createdAt > 0 and parsed.createdAt or now_ms)
    existing.updatedAt = math.max(tonumber(existing.updatedAt) or 0, parsed.updatedAt)
  else
    existing.payloadVersion = parsed.payloadVersion
    existing.changedScopes = parsed.changedScopes
    existing.createdAt = parsed.createdAt > 0 and parsed.createdAt or now_ms
    existing.updatedAt = parsed.updatedAt > 0 and parsed.updatedAt or now_ms
  end

  PuschelzDB.updatedAt = now_ms
  if refresh_sync_state_visuals then
    refresh_sync_state_visuals()
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
  sync_queue.mark_local_pending_reload({ "calendar" }, true)
end

local function set_calendar_sync_button_state(state)
  calendar_sync_ui.state = state or "idle"

  local button = calendar_sync_ui.button
  if not button then
    return
  end

  if calendar_sync_ui.state == "syncing" then
    button:SetEnabled(false)
    button:SetText("Syncing...")
    return
  end

  button:SetEnabled(true)
  if calendar_sync_ui.state == "done" then
    button:SetText("Synced")
    return
  end

  button:SetText("Sync Calendar")
end

local function begin_calendar_sync_feedback()
  calendar_sync_ui.stateGeneration = calendar_sync_ui.stateGeneration + 1
  set_calendar_sync_button_state("syncing")
end

local function finish_calendar_sync_feedback()
  calendar_sync_ui.stateGeneration = calendar_sync_ui.stateGeneration + 1
  local state_generation = calendar_sync_ui.stateGeneration
  set_calendar_sync_button_state("done")

  if not C_Timer or not C_Timer.After then
    set_calendar_sync_button_state("idle")
    return
  end

  C_Timer.After(CALENDAR_SYNC_BUTTON_RESET_DELAY_SEC, function()
    if calendar_sync_ui.stateGeneration ~= state_generation then
      return
    end

    if calendar_attendee_scan.inProgress or calendar_attendee_scan.requestPending then
      return
    end

    set_calendar_sync_button_state("idle")
  end)
end

local function reset_calendar_attendee_scan_state()
  calendar_attendee_scan.inProgress = false
  calendar_attendee_scan.events = nil
  calendar_attendee_scan.pendingRaidEvents = {}
  calendar_attendee_scan.activeRaidEvent = nil
  calendar_attendee_scan.requestPending = false
  calendar_attendee_scan.pendingNotifyOnCompletion = false
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
  finish_calendar_sync_feedback()
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

local refresh_calendar_sync_button
local request_calendar_scan
local try_load_addon_by_name

local function is_frame_widget(value)
  return type(value) == "table" and type(value.GetObjectType) == "function"
end

local function is_visible_button_widget(value)
  return is_frame_widget(value)
    and value:GetObjectType() == "Button"
    and type(value.IsShown) == "function"
    and value:IsShown()
end

local function calendar_frame_is_visible()
  return type(CalendarFrame) == "table"
    and type(CalendarFrame.IsShown) == "function"
    and CalendarFrame:IsShown()
end

local function open_calendar_frame()
  if calendar_frame_is_visible() then
    return true
  end

  try_load_addon_by_name("Blizzard_Calendar")

  if calendar_frame_is_visible() then
    return true
  end

  if type(ToggleCalendar) == "function" then
    ToggleCalendar()
  elseif type(CalendarFrame) == "table" then
    if type(ShowUIPanel) == "function" then
      ShowUIPanel(CalendarFrame)
    elseif type(CalendarFrame.Show) == "function" then
      CalendarFrame:Show()
    end
  end

  return calendar_frame_is_visible()
end

local function get_calendar_filter_button()
  if type(CalendarFrame) ~= "table" then
    return nil
  end

  local explicit_candidates = {}
  local function add_explicit_candidate(candidate)
    if candidate ~= nil then
      table.insert(explicit_candidates, candidate)
    end
  end

  add_explicit_candidate(CalendarFrame.FilterButton)
  add_explicit_candidate(CalendarFrame.EventFilterButton)
  add_explicit_candidate(_G and _G.CalendarFilterButton)
  add_explicit_candidate(_G and _G.CalendarFrameFilterButton)
  add_explicit_candidate(_G and _G.CalendarEventFilterButton)

  for index = 1, #explicit_candidates do
    local candidate = explicit_candidates[index]
    if is_visible_button_widget(candidate) then
      return candidate
    end
  end

  local queue = { CalendarFrame }
  local seen = { [CalendarFrame] = true }
  while #queue > 0 do
    local current = table.remove(queue, 1)
    if is_visible_button_widget(current) then
      local name = current.GetName and current:GetName() or nil
      local label = current.GetText and current:GetText() or nil
      if type(name) == "string" and string.find(string.lower(name), "filter", 1, true) then
        return current
      end
      if type(label) == "string" and string.find(string.lower(label), "filter", 1, true) then
        return current
      end
    end

    if is_frame_widget(current) then
      for _, child in ipairs({ current:GetChildren() }) do
        if is_frame_widget(child) and not seen[child] then
          seen[child] = true
          table.insert(queue, child)
        end
      end
    end
  end

  return nil
end

local function anchor_calendar_sync_button(button, filter_button)
  button:ClearAllPoints()
  button:SetPoint("RIGHT", filter_button, "LEFT", -4, 0)
end

local function ensure_calendar_sync_button()
  if type(CalendarFrame) ~= "table" then
    return nil
  end

  if not calendar_sync_ui.button then
    local button = CreateFrame("Button", nil, CalendarFrame, "UIPanelButtonTemplate")
    button:SetSize(110, 22)
    button:SetText("Sync Calendar")
    button:SetScript("OnClick", function()
      request_calendar_scan(true)
    end)
    calendar_sync_ui.button = button
    set_calendar_sync_button_state(calendar_sync_ui.state)
  end

  if not calendar_sync_ui.buttonHooksInstalled and type(CalendarFrame.HookScript) == "function" then
    CalendarFrame:HookScript("OnShow", function()
      if refresh_calendar_sync_button then
        refresh_calendar_sync_button()
      end
    end)
    calendar_sync_ui.buttonHooksInstalled = true
  end

  return calendar_sync_ui.button
end

refresh_calendar_sync_button = function()
  local button = ensure_calendar_sync_button()
  local filter_button = get_calendar_filter_button()
  if not button or not filter_button or not calendar_frame_is_visible() then
    if button then
      button:Hide()
    end
    return
  end

  calendar_sync_ui.filterButton = filter_button
  anchor_calendar_sync_button(button, filter_button)
  set_calendar_sync_button_state(calendar_sync_ui.state)
  button:Show()
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
    finish_calendar_sync_feedback()
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

local function consume_pending_calendar_request(notify_on_completion)
  local merged_notify = notify_on_completion or calendar_attendee_scan.pendingNotifyOnCompletion
  calendar_attendee_scan.requestPending = false
  calendar_attendee_scan.pendingNotifyOnCompletion = false
  capture_calendar(merged_notify)
end

request_calendar_scan = function(notify_on_completion)
  if not C_Calendar or not C_Calendar.OpenCalendar then
    if notify_on_completion then
      print("Puschelz: calendar scan is unavailable right now.")
    end
    return
  end

  if calendar_attendee_scan.inProgress then
    if notify_on_completion then
      calendar_attendee_scan.notifyOnCompletion = true
    end
    begin_calendar_sync_feedback()
    return
  end

  begin_calendar_sync_feedback()

  if calendar_frame_is_visible() then
    if calendar_attendee_scan.requestPending then
      consume_pending_calendar_request(notify_on_completion)
    else
      capture_calendar(notify_on_completion)
    end
    return
  end

  calendar_attendee_scan.requestPending = true
  calendar_attendee_scan.requestGeneration = calendar_attendee_scan.requestGeneration + 1
  if notify_on_completion then
    calendar_attendee_scan.pendingNotifyOnCompletion = true
  end
  local request_generation = calendar_attendee_scan.requestGeneration

  open_calendar_frame()
  C_Calendar.OpenCalendar()
  if C_Timer and C_Timer.After then
    C_Timer.After(1.5, function()
      if not calendar_attendee_scan.requestPending or calendar_attendee_scan.requestGeneration ~= request_generation then
        return
      end

      local pending_notify = calendar_attendee_scan.pendingNotifyOnCompletion
      calendar_attendee_scan.requestPending = false
      calendar_attendee_scan.pendingNotifyOnCompletion = false
      capture_calendar(pending_notify)
    end)
  end
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

local function finalize_guild_orders_capture(orders, should_broadcast)
  ensure_db()
  PuschelzDB.guildOrders.orders = orders or {}
  PuschelzDB.guildOrders.lastScannedAt = now_epoch_ms()
  PuschelzDB.updatedAt = PuschelzDB.guildOrders.lastScannedAt
  sync_queue.mark_local_pending_reload({ "guildOrders" }, should_broadcast == true)
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
  finalize_guild_orders_capture(orders, false)
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

local refresh_guild_order_sync_buttons
local schedule_passive_guild_order_capture

local function customer_orders_mode_orders()
  if type(ProfessionsCustomerOrdersMode) == "table" then
    return ProfessionsCustomerOrdersMode.Orders
  end

  return nil
end

local function is_customer_my_orders_view_active(frame)
  if type(frame) ~= "table" or not frame.IsShown or not frame:IsShown() then
    return false
  end

  if type(frame.Form) == "table" and frame.Form.IsShown and frame.Form:IsShown() then
    return false
  end

  if type(frame.MyOrdersPage) == "table" and frame.MyOrdersPage.IsShown and frame.MyOrdersPage:IsShown() then
    return true
  end

  if frame.currentPage and frame.currentPage == frame.MyOrdersPage then
    return true
  end

  local orders_mode = customer_orders_mode_orders()
  if orders_mode ~= nil and frame.currentPage and frame.currentPage.mode == orders_mode then
    return true
  end

  return false
end

local function is_crafter_orders_view_active(frame)
  if type(frame) ~= "table" or not frame.IsShown or not frame:IsShown() then
    return false
  end

  if type(frame.GetTab) == "function" and type(frame.craftingOrdersTabID) == "number" then
    local current_tab = frame:GetTab()
    if current_tab == frame.craftingOrdersTabID then
      return true
    end
  end

  if type(frame.OrdersPage) == "table" and frame.OrdersPage.IsShown and frame.OrdersPage:IsShown() then
    return true
  end

  return false
end

local function should_show_guild_order_sync_button(host_frame)
  if host_frame == ProfessionsCustomerOrdersFrame then
    return is_customer_my_orders_view_active(host_frame)
  end

  return is_crafter_orders_view_active(host_frame)
end

local function is_any_guild_order_view_active()
  return should_show_guild_order_sync_button(ProfessionsFrame)
    or should_show_guild_order_sync_button(TradeSkillFrame)
    or should_show_guild_order_sync_button(ProfessionsCustomerOrdersFrame)
end

local function anchor_guild_order_sync_button(button, host_frame)
  button:ClearAllPoints()
  button:SetPoint("TOP", host_frame, "TOP", 0, -28)
end

local function install_guild_order_sync_hooks()
  if not guild_order_sync.professionsFrameHooked
    and type(ProfessionsFrame) == "table"
    and hooksecurefunc
    and type(ProfessionsFrame.SetTab) == "function"
  then
    hooksecurefunc(ProfessionsFrame, "SetTab", function(frame, tab_id)
      refresh_guild_order_sync_buttons()

      if type(frame) == "table"
        and type(frame.craftingOrdersTabID) == "number"
        and tab_id == frame.craftingOrdersTabID
      then
        schedule_passive_guild_order_capture()
      end
    end)

    guild_order_sync.professionsFrameHooked = true
  end

  if not guild_order_sync.customerOrdersHooked
    and type(ProfessionsCustomerOrdersFrame) == "table"
    and hooksecurefunc
  then
    if not craft_request_bridge.formInitHooked
      and type(ProfessionsCustomerOrdersFrame.Form) == "table"
      and type(ProfessionsCustomerOrdersFrame.Form.Init) == "function"
    then
      hooksecurefunc(ProfessionsCustomerOrdersFrame.Form, "Init", function(_, order)
        if type(order) == "table" then
          local spell_id, item_id = extract_recipe_context(order)
          set_selected_bridge_recipe(spell_id, item_id, "formInit")
          schedule_craft_request_widget_refresh()
        end
      end)

      craft_request_bridge.formInitHooked = true
    end

    if not craft_request_bridge.recipeSelectionHooked
      and type(EventRegistry) == "table"
      and type(EventRegistry.RegisterCallback) == "function"
    then
      EventRegistry:RegisterCallback("ProfessionsCustomerOrders.RecipeSelected", function(_, item_id, spell_id)
        set_selected_bridge_recipe(spell_id, item_id, "recipeSelectedEvent")
        schedule_craft_request_widget_refresh()
      end, craft_request_bridge)

      craft_request_bridge.recipeSelectionHooked = true
    end

    if type(ProfessionsCustomerOrdersFrame.SelectMode) == "function" then
      hooksecurefunc(ProfessionsCustomerOrdersFrame, "SelectMode", function(_, mode)
        refresh_guild_order_sync_buttons()

        if mode == customer_orders_mode_orders() then
          schedule_passive_guild_order_capture()
        end
      end)
    end

    if type(ProfessionsCustomerOrdersFrame.ShowCurrentPage) == "function" then
      hooksecurefunc(ProfessionsCustomerOrdersFrame, "ShowCurrentPage", function()
        refresh_guild_order_sync_buttons()

        if is_customer_my_orders_view_active(ProfessionsCustomerOrdersFrame) then
          schedule_passive_guild_order_capture()
        end
      end)
    end

    if type(ProfessionsCustomerOrdersFrame.Form) == "table"
      and type(ProfessionsCustomerOrdersFrame.Form.HookScript) == "function"
    then
      ProfessionsCustomerOrdersFrame.Form:HookScript("OnShow", function()
        refresh_guild_order_sync_buttons()
        schedule_craft_request_widget_refresh()
      end)

      ProfessionsCustomerOrdersFrame.Form:HookScript("OnHide", function()
        refresh_guild_order_sync_buttons()
        reset_minimum_quality_status(ProfessionsCustomerOrdersFrame.Form)
        if craft_request_bridge.widgetContainer then
          craft_request_bridge.widgetContainer:Hide()
        elseif craft_request_bridge.widget then
          craft_request_bridge.widget:Hide()
        end
        craft_request_bridge.lastWidgetRecipeKey = nil
        craft_request_bridge.lastWidgetStateKey = nil

        if is_customer_my_orders_view_active(ProfessionsCustomerOrdersFrame) then
          schedule_passive_guild_order_capture()
        end
      end)
    end

    guild_order_sync.customerOrdersHooked = true
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
  finalize_guild_orders_capture(orders, true)

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
  install_guild_order_sync_hooks()

  for _, host_frame in ipairs(get_professions_host_frames()) do
    if not guild_order_sync.buttons[host_frame] then
      local button = CreateFrame("Button", nil, host_frame, "UIPanelButtonTemplate")
      button:SetSize(140, 22)
      anchor_guild_order_sync_button(button, host_frame)
      button:SetText("Sync Guild Orders")
      button:SetScript("OnClick", function()
        begin_full_guild_order_sync(true)
      end)
      guild_order_sync.buttons[host_frame] = button
    end
  end

  refresh_guild_order_sync_buttons()
  set_guild_order_sync_button_busy(guild_order_sync.active)
end

refresh_guild_order_sync_buttons = function()
  for host_frame, button in pairs(guild_order_sync.buttons) do
    if should_show_guild_order_sync_button(host_frame) then
      anchor_guild_order_sync_button(button, host_frame)
      button:Show()
    else
      button:Hide()
    end
  end
end

schedule_passive_guild_order_capture = function()
  ensure_guild_order_sync_buttons()

  if not is_any_guild_order_view_active() then
    return
  end

  if C_Timer and C_Timer.After then
    C_Timer.After(0.5, function()
      ensure_guild_order_sync_buttons()

      if is_any_guild_order_view_active() then
        capture_visible_guild_orders(false)
      end
    end)
  else
    ensure_guild_order_sync_buttons()

    if is_any_guild_order_view_active() then
      capture_visible_guild_orders(false)
    end
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

normalize_player_name = function(raw_name)
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

local_player_identity = function()
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

local function red_chat_message(message)
  if type(message) ~= "string" or message == "" then
    return
  end

  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(message, 1, 0.2, 0.2)
    return
  end

  print(message)
end

local function count_table_entries(value)
  if type(value) ~= "table" then
    return 0
  end

  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  return count
end

local function colorize_status_text(text, color)
  if type(text) ~= "string" then
    return ""
  end

  local red = math.max(0, math.min(255, math.floor(((color and color[1]) or 1) * 255)))
  local green = math.max(0, math.min(255, math.floor(((color and color[2]) or 1) * 255)))
  local blue = math.max(0, math.min(255, math.floor(((color and color[3]) or 1) * 255)))
  return string.format("|cff%02x%02x%02x%s|r", red, green, blue, text)
end

local function is_addon_loaded_by_name(addon_name)
  if C_AddOns and C_AddOns.IsAddOnLoaded then
    return C_AddOns.IsAddOnLoaded(addon_name)
  end

  if IsAddOnLoaded then
    return IsAddOnLoaded(addon_name)
  end

  return false
end

try_load_addon_by_name = function(addon_name)
  if type(addon_name) ~= "string" or addon_name == "" then
    return false, "missing_name"
  end

  local was_loaded = is_addon_loaded_by_name(addon_name)
  if was_loaded then
    return true, "already_loaded"
  end

  local loaded, reason
  if C_AddOns and C_AddOns.LoadAddOn then
    loaded, reason = C_AddOns.LoadAddOn(addon_name)
    if loaded == nil then
      loaded = is_addon_loaded_by_name(addon_name)
    end
    return loaded and true or false, tostring(reason or "unknown")
  end

  if LoadAddOn then
    loaded, reason = LoadAddOn(addon_name)
    if loaded == nil then
      loaded = is_addon_loaded_by_name(addon_name)
    end
    return loaded and true or false, tostring(reason or "unknown")
  end

  return false, "load_api_unavailable"
end

local function try_load_bridge_addon()
  return try_load_addon_by_name("PuschelzBridge")
end

local function get_simulationcraft_exporter()
  local addon_names = {
    "SimulationCraft",
    "Simulationcraft",
  }

  for _, addon_name in ipairs(addon_names) do
    if not is_addon_loaded_by_name(addon_name) then
      try_load_addon_by_name(addon_name)
    end
  end

  if type(SimulationCraft) == "table" and type(SimulationCraft.GetSimcProfile) == "function" then
    return SimulationCraft, SimulationCraft.GetSimcProfile
  end

  if type(Simulationcraft) == "table" and type(Simulationcraft.GetSimcProfile) == "function" then
    return Simulationcraft, Simulationcraft.GetSimcProfile
  end

  if LibStub then
    local ace_addon = LibStub("AceAddon-3.0", true)
    if ace_addon and type(ace_addon.GetAddon) == "function" then
      local addon_object = ace_addon:GetAddon("Simulationcraft", true)
      if type(addon_object) == "table" and type(addon_object.GetSimcProfile) == "function" then
        return addon_object, addon_object.GetSimcProfile
      end
    end
  end

  if type(SimulationcraftAPI) == "table" and type(SimulationcraftAPI.GetSimcProfile) == "function" then
    if type(SimulationCraft) == "table" then
      return SimulationCraft, SimulationcraftAPI.GetSimcProfile
    end

    if type(Simulationcraft) == "table" then
      return Simulationcraft, SimulationcraftAPI.GetSimcProfile
    end

    if LibStub then
      local ace_addon = LibStub("AceAddon-3.0", true)
      if ace_addon and type(ace_addon.GetAddon) == "function" then
        local addon_object = ace_addon:GetAddon("Simulationcraft", true)
        if type(addon_object) == "table" then
          return addon_object, SimulationcraftAPI.GetSimcProfile
        end
      end
    end
  end

  return nil, nil
end

local function has_simulationcraft_exporter()
  local exporter, getter = get_simulationcraft_exporter()
  return exporter ~= nil and getter ~= nil
end

local function build_simc_request_id()
  local guid = UnitGUID and UnitGUID("player") or "player"
  local sanitized_guid = tostring(guid or "player"):gsub("[^%w]", "")
  return string.format("simc-%s-%d-%04d", sanitized_guid, now_epoch_ms(), math.random(0, 9999))
end

local function capture_current_simc_profile()
  local exporter, getter = get_simulationcraft_exporter()
  if not exporter or not getter then
    return nil, "SimulationCraft addon is required for SimC sync."
  end

  local ok, profile, simc_error
  if getter == exporter.GetSimcProfile then
    ok, profile, simc_error = pcall(function()
      return exporter:GetSimcProfile(false, true, false, false)
    end)
  else
    ok, profile, simc_error = pcall(
      getter,
      exporter,
      false,
      true,
      false,
      false
    )
  end

  if not ok then
    return nil, tostring(profile or "SimulationCraft export failed.")
  end

  local trimmed_profile = trim_text(profile)
  if not trimmed_profile then
    local trimmed_error = trim_text(simc_error)
    if trimmed_error then
      return nil, trimmed_error
    end
    return nil, "SimulationCraft did not return a SimC profile."
  end

  return trimmed_profile, nil
end

local function queue_simc_profile_request(run_droptimizer_now)
  ensure_db()
  refresh_player_metadata()

  local profile_text, profile_error = capture_current_simc_profile()
  if not profile_text then
    red_chat_message(string.format("Puschelz: %s", tostring(profile_error or "SimC export failed.")))
    return false
  end

  local requested_at = now_epoch_ms()
  local character_name = trim_text(PuschelzDB.player.characterName) or trim_text(UnitName and UnitName("player"))
  local realm_name = trim_text(PuschelzDB.player.realmName) or trim_text(GetRealmName and GetRealmName())
  if not character_name or not realm_name then
    red_chat_message("Puschelz: could not resolve the current character for SimC sync.")
    return false
  end

  PuschelzDB.simcRequest = {
    requestId = build_simc_request_id(),
    requestedAt = requested_at,
    characterName = character_name,
    realmName = realm_name,
    profileText = profile_text,
    runDroptimizerNow = run_droptimizer_now == true,
  }
  PuschelzDB.updatedAt = requested_at
  local pending = sync_queue.mark_local_pending_reload({ "simc" }, true)

  if not pending then
    red_chat_message("Puschelz: SimC export captured, but pending reload was not created. Try /reload if the desktop client does not pick it up.")
    return false
  end

  if run_droptimizer_now then
    print(
      string.format(
        "Puschelz: queued SimC export and marked pending reload v%d (simc). Run /reload or log out so the desktop client can upload it and start a Mythic Droptimizer run.",
        tonumber(pending.payloadVersion) or 0
      )
    )
  else
    print(
      string.format(
        "Puschelz: queued SimC export and marked pending reload v%d (simc). Run /reload or log out so the desktop client can upload it.",
        tonumber(pending.payloadVersion) or 0
      )
    )
  end

  return true
end

local function refresh_bridge_debug_snapshot()
  ensure_db()
  PuschelzDB.bridgeDebug = PuschelzBridgeSnapshot.build_debug_summary()
  craft_request_bridge.bridgeDebugSynced = true
end

PuschelzBridgeSnapshot.configure({
  ensure_export_db = ensure_db,
  try_load_bridge_addon = try_load_bridge_addon,
  is_addon_loaded_by_name = is_addon_loaded_by_name,
  count_table_entries = count_table_entries,
  now_epoch_ms = now_epoch_ms,
  state = craft_request_bridge,
})

local function ensure_bridge_db()
  PuschelzBridgeSnapshot.ensure_loaded()
  if not craft_request_bridge.bridgeDebugSynced then
    refresh_bridge_debug_snapshot()
  end

  sync_queue.consume_bridge_acknowledgments()
end

trim_text = function(value)
  if type(value) ~= "string" then
    return nil
  end

  local trimmed = value:match("^%s*(.-)%s*$")
  if not trimmed or trimmed == "" then
    return nil
  end

  return trimmed
end

local function normalize_addon_folder_name(value)
  local trimmed = trim_text(value)
  if not trimmed then
    return nil
  end

  return string.lower(trimmed)
end

local function get_addon_count()
  if C_AddOns and C_AddOns.GetNumAddOns then
    local count = C_AddOns.GetNumAddOns()
    if type(count) == "number" then
      return count
    end
  end

  if GetNumAddOns then
    local count = GetNumAddOns()
    if type(count) == "number" then
      return count
    end
  end

  return 0
end

local function get_addon_name_by_index(index)
  if C_AddOns and C_AddOns.GetAddOnInfo then
    local info = C_AddOns.GetAddOnInfo(index)
    if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
      return info.name
    end
    if type(info) == "string" and info ~= "" then
      return info
    end
  end

  if GetAddOnInfo then
    local name = GetAddOnInfo(index)
    if type(name) == "string" and name ~= "" then
      return name
    end
  end

  return nil
end

local function is_addon_enabled_by_name(addon_name)
  if type(addon_name) ~= "string" or addon_name == "" then
    return false
  end

  if C_AddOns and C_AddOns.GetAddOnEnableState then
    local state = C_AddOns.GetAddOnEnableState(addon_name)
    if type(state) == "number" then
      return state > 0
    end
    if state ~= nil then
      return state and true or false
    end
  end

  if GetAddOnEnableState then
    local character_name = UnitName and UnitName("player") or nil
    local state = GetAddOnEnableState(character_name, addon_name)
    if type(state) == "number" then
      return state > 0
    end
    if state ~= nil then
      return state and true or false
    end
  end

  return is_addon_loaded_by_name(addon_name)
end

local function build_active_addon_lookup()
  local active = {}
  local count = get_addon_count()

  for index = 1, count do
    local addon_name = get_addon_name_by_index(index)
    local normalized_name = normalize_addon_folder_name(addon_name)
    if normalized_name and is_addon_enabled_by_name(addon_name) then
      active[normalized_name] = true
    end
  end

  return active
end

local function collect_required_addon_aliases(match_folder_names)
  if type(match_folder_names) ~= "table" then
    return {}, {}
  end

  local normalized = {}
  local display = {}
  local seen = {}
  for _, raw_name in ipairs(match_folder_names) do
    local trimmed = trim_text(raw_name)
    local normalized_name = normalize_addon_folder_name(raw_name)
    if trimmed and normalized_name and not seen[normalized_name] then
      seen[normalized_name] = true
      table.insert(normalized, normalized_name)
      table.insert(display, trimmed)
    end
  end

  return normalized, display
end

local function summarize_required_addon_compliance()
  local bridge_config = PuschelzBridgeSnapshot.get_required_addons_config()

  local active_addons = build_active_addon_lookup()
  local missing = {}
  local required_count = 0
  local configured_count = bridge_config.requiredAddonsConfiguredCount
  local invalid_configured_count = bridge_config.invalidRequiredAddonCount

  for _, addon in ipairs(bridge_config.requiredAddons) do
    if type(addon) == "table" and type(addon.name) == "string" then
      local normalized_aliases, display_aliases = collect_required_addon_aliases(addon.matchFolderNames)
      if #normalized_aliases > 0 then
        required_count = required_count + 1

        local matched = false
        for _, alias in ipairs(normalized_aliases) do
          if active_addons[alias] then
            matched = true
            break
          end
        end

        if not matched then
          table.insert(missing, {
            addonId = tostring(addon.addonId or addon.name),
            name = addon.name,
            description = addon.description,
            matchFolderNames = display_aliases,
          })
        end
      end
    end
  end

  table.sort(missing, function(left, right)
    return string.lower(left.name) < string.lower(right.name)
  end)

  local hash_parts = {
    tostring(bridge_config.requiredAddonsVersion),
    tostring(configured_count),
    tostring(invalid_configured_count),
  }
  for _, addon in ipairs(missing) do
    table.insert(hash_parts, addon.addonId)
    table.insert(hash_parts, table.concat(addon.matchFolderNames, ","))
  end

  return {
    requiredAddonsVersion = bridge_config.requiredAddonsVersion,
    configuredCount = configured_count,
    invalidConfiguredCount = invalid_configured_count,
    requiredCount = required_count,
    missingCount = #missing,
    satisfiedCount = required_count - #missing,
    missing = missing,
    summaryKey = tostring(stable_hash_number(table.concat(hash_parts, "|"))),
  }
end

local function format_required_addon_entry(addon)
  if type(addon) ~= "table" then
    return "unknown"
  end

  local alias_text = ""
  if type(addon.matchFolderNames) == "table" and #addon.matchFolderNames > 0 then
    alias_text = string.format(" [%s]", table.concat(addon.matchFolderNames, " / "))
  end

  return string.format("%s%s", tostring(addon.name or "unknown"), alias_text)
end

local function print_required_addon_status(verbose)
  local summary = summarize_required_addon_compliance()
  local version_text = summary.requiredAddonsVersion > 0 and tostring(summary.requiredAddonsVersion) or "n/a"

  if summary.requiredCount == 0 then
    print(
      string.format(
        "Puschelz: requiredAddons=0, missing=0, invalidBridgeConfigs=%d, bridgeVersion=%s",
        summary.invalidConfiguredCount,
        version_text
      )
    )
    if summary.invalidConfiguredCount > 0 then
      print("Puschelz: required addon definitions are misconfigured on the website. Missing bridge folder names.")
    end
    return summary
  end

  print(
    string.format(
      "Puschelz: requiredAddons=%d, satisfied=%d, missing=%d, invalidBridgeConfigs=%d, bridgeVersion=%s",
      summary.requiredCount,
      summary.satisfiedCount,
      summary.missingCount,
      summary.invalidConfiguredCount,
      version_text
    )
  )

  if summary.invalidConfiguredCount > 0 then
    print(
      string.format(
        "Puschelz: bridge skipped %d required addon definition(s) with missing folder names.",
        summary.invalidConfiguredCount
      )
    )
  end

  if summary.missingCount == 0 then
    if verbose then
      print("Puschelz: all required addons are active.")
    end
    return summary
  end

  for _, addon in ipairs(summary.missing) do
    print(string.format("Puschelz: missing required addon %s", format_required_addon_entry(addon)))
  end

  return summary
end

local function warn_missing_required_addons_if_needed()
  local summary = summarize_required_addon_compliance()
  craft_request_bridge.requiredAddonSummaryKey = summary.summaryKey

  if summary.invalidConfiguredCount == 0 and (summary.requiredCount == 0 or summary.missingCount == 0) then
    return
  end

  ensure_db()
  local persisted = PuschelzDB.requiredAddonCompliance
  local version_text = tostring(summary.requiredAddonsVersion)
  if persisted.lastWarnedSummaryKey == summary.summaryKey and persisted.lastWarnedVersion == version_text then
    return
  end

  persisted.lastWarnedSummaryKey = summary.summaryKey
  persisted.lastWarnedVersion = version_text
  persisted.updatedAt = now_epoch_ms()

  if summary.invalidConfiguredCount > 0 then
    red_chat_message(
      string.format(
        "Puschelz: %d required addon definition(s) are misconfigured on the website and skipped. Use /puschelz addons.",
        summary.invalidConfiguredCount
      )
    )
  end

  if summary.missingCount > 0 then
    red_chat_message(
      string.format(
        "Puschelz: %d required addon(s) missing. Use /puschelz addons for details.",
        summary.missingCount
      )
    )
  end

  for _, addon in ipairs(summary.missing) do
    red_chat_message(string.format("Puschelz: missing %s", format_required_addon_entry(addon)))
  end
end

local function recipe_bridge_key(spell_id, item_id)
  spell_id = tonumber(spell_id)
  item_id = tonumber(item_id)
  if not spell_id or not item_id then
    return nil
  end
  return tostring(spell_id) .. ":" .. tostring(item_id)
end

local function bridge_current_character_key()
  return local_player_identity()
end

local function bridge_character_matches(matched_keys, current_key)
  if type(current_key) ~= "string" or current_key == "" then
    return false
  end
  if type(matched_keys) ~= "table" then
    return false
  end

  for _, candidate_key in ipairs(matched_keys) do
    if type(candidate_key) == "string" and string.lower(candidate_key) == current_key then
      return true
    end
  end

  return false
end

local function active_bridge_requests_for_character()
  local current_key = bridge_current_character_key()
  if not current_key then
    return {}
  end

  local now_ms = now_epoch_ms()
  local matches = {}
  for _, request in ipairs(PuschelzBridgeSnapshot.get_open_requests()) do
    if type(request) == "table"
      and (request.status == "pending_web" or request.status == "open_ingame")
      and tonumber(request.expiresAt)
      and tonumber(request.expiresAt) > now_ms
      and bridge_character_matches(request.matchedCharacterKeys, current_key)
    then
      table.insert(matches, request)
    end
  end

  table.sort(matches, function(a, b)
    return tostring(a.itemName or "") < tostring(b.itemName or "")
  end)
  return matches
end

local function print_matching_bridge_requests()
  local matching_requests = active_bridge_requests_for_character()
  for _, request in ipairs(matching_requests) do
    local request_id = tostring(request.requestId or "?")
    local item_name = tostring(request.itemName or ("Item " .. tostring(request.itemId or "?")))
    local requester = tostring(request.requesterCharacterName or "?")
    local realm_name = tostring(request.requesterRealmName or "")
    if realm_name ~= "" then
      requester = requester .. "-" .. realm_name
    end
    red_chat_message(string.format("Puschelz: open craft request %s from %s for %s", request_id, requester, item_name))
  end
end

local function register_craft_request_prefix()
  if craft_request_bridge.prefixRegistered then
    return true
  end
  if not C_ChatInfo or not C_ChatInfo.RegisterAddonMessagePrefix then
    return false
  end

  craft_request_bridge.prefixRegistered =
    C_ChatInfo.RegisterAddonMessagePrefix(CRAFT_REQUEST_PREFIX) and true or false
  return craft_request_bridge.prefixRegistered
end

local function send_craft_request_message(payload)
  if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then
    return false
  end
  if not register_craft_request_prefix() then
    return false
  end
  if not IsInGuild or not IsInGuild() then
    return false
  end

  C_ChatInfo.SendAddonMessage(CRAFT_REQUEST_PREFIX, payload, "GUILD")
  return true
end

local function sanitize_craft_request_field(value)
  local text = tostring(value or "")
  text = string.gsub(text, "|", "/")
  text = string.gsub(text, "[\r\n]", " ")
  return text
end

local function prune_seen_craft_request_broadcasts()
  if craft_request_bridge.seenBroadcastCount <= 300 then
    return
  end

  local cutoff_ms = now_runtime_ms() - (10 * 60 * 1000)
  local kept = 0
  for key, seen_at in pairs(craft_request_bridge.seenBroadcasts) do
    if seen_at and seen_at >= cutoff_ms then
      kept = kept + 1
    else
      craft_request_bridge.seenBroadcasts[key] = nil
    end
  end
  craft_request_bridge.seenBroadcastCount = kept
end

local function remember_seen_craft_request_broadcast(key)
  if craft_request_bridge.seenBroadcasts[key] then
    return false
  end
  craft_request_bridge.seenBroadcasts[key] = now_runtime_ms()
  craft_request_bridge.seenBroadcastCount = craft_request_bridge.seenBroadcastCount + 1
  prune_seen_craft_request_broadcasts()
  return true
end

local function prune_pending_craft_request_chunks()
  local cutoff_ms = now_runtime_ms() - CRAFT_REQUEST_CHUNK_TTL_MS
  for key, entry in pairs(craft_request_bridge.pendingChunks) do
    if type(entry) ~= "table" or not entry.receivedAtMs or entry.receivedAtMs < cutoff_ms then
      craft_request_bridge.pendingChunks[key] = nil
    end
  end
end

local function payload_length_for_chunk(base_fields, chunk_index, chunk_count, key_text)
  local fields = {
    base_fields[1],
    base_fields[2],
    base_fields[3],
    base_fields[4],
    base_fields[5],
    base_fields[6],
    base_fields[7],
    base_fields[8],
    base_fields[9],
    tostring(chunk_index),
    tostring(chunk_count),
    key_text or "",
  }
  return string.len(table.concat(fields, "|"))
end

local function build_craft_request_payloads(snapshot_version, request)
  if type(request) ~= "table" or type(request.matchedCharacterKeys) ~= "table" then
    return {}
  end

  local base_fields = {
    "OPEN",
    tostring(snapshot_version),
    sanitize_craft_request_field(request.requestId),
    tostring(request.spellId),
    tostring(request.itemId),
    sanitize_craft_request_field(request.itemName),
    sanitize_craft_request_field(request.requesterCharacterName),
    sanitize_craft_request_field(request.requesterRealmName),
    tostring(request.expiresAt or 0),
  }

  local chunked_keys = {}
  local current_keys = {}

  local function flush_current_keys()
    if #current_keys == 0 then
      return
    end
    table.insert(chunked_keys, current_keys)
    current_keys = {}
  end

  for _, raw_key in ipairs(request.matchedCharacterKeys) do
    local key = sanitize_craft_request_field(raw_key)
    if key ~= "" then
      local candidate_keys = {}
      for index, existing_key in ipairs(current_keys) do
        candidate_keys[index] = existing_key
      end
      table.insert(candidate_keys, key)
      local candidate_text = table.concat(candidate_keys, ",")
      if #current_keys > 0
        and payload_length_for_chunk(base_fields, 99, 99, candidate_text) > CRAFT_REQUEST_MAX_MESSAGE_LENGTH
      then
        flush_current_keys()
        table.insert(current_keys, key)
      else
        current_keys = candidate_keys
      end
    end
  end
  flush_current_keys()

  local payloads = {}
  local chunk_count = #chunked_keys
  for chunk_index, keys in ipairs(chunked_keys) do
    local key_text = table.concat(keys, ",")
    if payload_length_for_chunk(base_fields, chunk_index, chunk_count, key_text) <= CRAFT_REQUEST_MAX_MESSAGE_LENGTH then
      table.insert(payloads, table.concat({
        base_fields[1],
        base_fields[2],
        base_fields[3],
        base_fields[4],
        base_fields[5],
        base_fields[6],
        base_fields[7],
        base_fields[8],
        base_fields[9],
        tostring(chunk_index),
        tostring(chunk_count),
        key_text,
      }, "|"))
    end
  end

  return payloads
end

local function broadcast_open_bridge_requests()
  local bridge_root = PuschelzBridgeSnapshot.ensure_loaded()
  local snapshot_version = PuschelzBridgeSnapshot.get_snapshot_version(bridge_root)
  if not snapshot_version or snapshot_version <= 0 then
    return
  end
  if craft_request_bridge.lastBroadcastSnapshotVersion == snapshot_version then
    return
  end

  for _, request in ipairs(PuschelzBridgeSnapshot.get_open_requests(bridge_root)) do
    if type(request) == "table"
      and (request.status == "pending_web" or request.status == "open_ingame")
      and type(request.requestId) == "string"
      and type(request.itemName) == "string"
      and tonumber(request.spellId)
      and tonumber(request.itemId)
      and type(request.requesterCharacterName) == "string"
      and type(request.requesterRealmName) == "string"
      and type(request.matchedCharacterKeys) == "table"
      and #request.matchedCharacterKeys > 0
    then
      for _, payload in ipairs(build_craft_request_payloads(snapshot_version, request)) do
        send_craft_request_message(payload)
      end
    end
  end

  craft_request_bridge.lastBroadcastSnapshotVersion = snapshot_version
end

local function parse_craft_request_message(message)
  if type(message) ~= "string" then
    return nil
  end

  local fields = {}
  local field_start = 1
  while true do
    local separator_start, separator_end = string.find(message, "|", field_start, true)
    if not separator_start then
      table.insert(fields, string.sub(message, field_start))
      break
    end
    table.insert(fields, string.sub(message, field_start, separator_start - 1))
    field_start = separator_end + 1
  end

  if fields[1] ~= "OPEN" or #fields < 12 then
    return nil
  end

  return {
    messageType = fields[1],
    snapshotVersion = tonumber(fields[2]) or 0,
    requestId = fields[3],
    spellId = tonumber(fields[4]),
    itemId = tonumber(fields[5]),
    itemName = fields[6],
    requesterCharacterName = fields[7],
    requesterRealmName = fields[8],
    expiresAt = tonumber(fields[9]) or 0,
    chunkIndex = tonumber(fields[10]) or 1,
    chunkCount = tonumber(fields[11]) or 1,
    matchedCharacterKeys = fields[12] or "",
  }
end

local function split_comma_text(value)
  local out = {}
  if type(value) ~= "string" or value == "" then
    return out
  end
  for token in string.gmatch(value, "([^,]+)") do
    table.insert(out, token)
  end
  return out
end

local function handle_craft_request_addon_message(prefix, message, channel, sender)
  if prefix ~= CRAFT_REQUEST_PREFIX then
    return
  end

  local sender_key = select(1, normalize_player_name(sender))
  local current_key = bridge_current_character_key()
  if sender_key and current_key and sender_key == current_key then
    return
  end

  local parsed = parse_craft_request_message(message)
  if not parsed or not parsed.requestId or not parsed.spellId or not parsed.itemId then
    return
  end

  if parsed.expiresAt <= now_epoch_ms() then
    return
  end

  prune_pending_craft_request_chunks()
  if parsed.chunkCount > 1 then
    local chunk_key = tostring(parsed.snapshotVersion) .. "|" .. tostring(parsed.requestId)
    local entry = craft_request_bridge.pendingChunks[chunk_key]
    if type(entry) ~= "table" or tonumber(entry.chunkCount) ~= parsed.chunkCount then
      entry = {
        chunkCount = parsed.chunkCount,
        chunks = {},
      }
      craft_request_bridge.pendingChunks[chunk_key] = entry
    end
    entry.receivedAtMs = now_runtime_ms()
    entry.chunks[parsed.chunkIndex] = parsed.matchedCharacterKeys or ""

    local chunk_text = {}
    for index = 1, parsed.chunkCount do
      if entry.chunks[index] == nil then
        return
      end
      if entry.chunks[index] ~= "" then
        table.insert(chunk_text, entry.chunks[index])
      end
    end

    craft_request_bridge.pendingChunks[chunk_key] = nil
    parsed.matchedCharacterKeys = table.concat(chunk_text, ",")
  end

  if not current_key then
    return
  end

  local dedupe_key = tostring(parsed.snapshotVersion) .. "|" .. tostring(parsed.requestId)
  if not remember_seen_craft_request_broadcast(dedupe_key) then
    return
  end

  if not bridge_character_matches(split_comma_text(parsed.matchedCharacterKeys), current_key) then
    return
  end

  local requester = tostring(parsed.requesterCharacterName or "?")
  if parsed.requesterRealmName and parsed.requesterRealmName ~= "" then
    requester = requester .. "-" .. parsed.requesterRealmName
  end

  red_chat_message(
    string.format(
      "Puschelz: open craft request %s from %s for %s",
      tostring(parsed.requestId),
      requester,
      tostring(parsed.itemName or ("Item " .. tostring(parsed.itemId)))
    )
  )
end

extract_recipe_context = function(candidate)
  if type(candidate) ~= "table" then
    return nil, nil
  end

  local spell_id = tonumber(candidate.spellId or candidate.spellID or candidate.recipeID or candidate.recipeId)
  local item_id =
    tonumber(candidate.itemId or candidate.itemID or candidate.outputItemID or candidate.outputItemId)

  if not item_id and type(candidate.outputItem) == "table" then
    item_id = tonumber(candidate.outputItem.itemID or candidate.outputItem.itemId)
  end

  if spell_id and item_id then
    return spell_id, item_id
  end

  return nil, nil
end

local function resolve_place_order_recipe_context(form)
  if type(form) ~= "table" then
    return nil, nil
  end

  if craft_request_bridge.selectedSpellId and craft_request_bridge.selectedItemId then
    return craft_request_bridge.selectedSpellId, craft_request_bridge.selectedItemId
  end

  return nil, nil
end

local function ensure_craft_request_status_widget()
  if craft_request_bridge.widget then
    return craft_request_bridge.widget
  end

  if type(ProfessionsCustomerOrdersFrame) ~= "table"
    or type(ProfessionsCustomerOrdersFrame.Form) ~= "table"
    or type(ProfessionsCustomerOrdersFrame.Form.CreateFontString) ~= "function"
  then
    return nil
  end

  local form = ProfessionsCustomerOrdersFrame.Form
  local container = CreateFrame("Frame", nil, form)
  container:SetFrameStrata("HIGH")
  container:SetFrameLevel((form.GetFrameLevel and form:GetFrameLevel() or 0) + 20)
  container:SetSize(148, 14)

  local widget = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  widget:SetJustifyH("RIGHT")
  widget:SetWidth(148)
  widget:SetPoint("CENTER", container, "CENTER", 0, 0)
  container:Hide()
  craft_request_bridge.widgetContainer = container
  craft_request_bridge.widget = widget

  if type(form.HookScript) == "function" then
    form:HookScript("OnUpdate", function(self, elapsed)
      self._puschelzCraftRequestElapsed = (self._puschelzCraftRequestElapsed or 0) + (elapsed or 0)
      if self._puschelzCraftRequestElapsed < 0.25 then
        return
      end
      self._puschelzCraftRequestElapsed = 0
      if self.IsShown and self:IsShown() then
        -- refreshed by the helper below; safe to call frequently
        if refresh_place_order_status_widget then
          refresh_place_order_status_widget()
        end
      end
    end)
  elseif type(form.SetScript) == "function" then
    form:SetScript("OnUpdate", function(self, elapsed)
      self._puschelzCraftRequestElapsed = (self._puschelzCraftRequestElapsed or 0) + (elapsed or 0)
      if self._puschelzCraftRequestElapsed < 0.25 then
        return
      end
      self._puschelzCraftRequestElapsed = 0
      if self.IsShown and self:IsShown() then
        if refresh_place_order_status_widget then
          refresh_place_order_status_widget()
        end
      end
    end)
  end

  return widget
end

local function update_place_order_status_anchor(form, container, visible)
  if type(form) ~= "table" then
    return
  end

  local anchor_to = nil
  local target_visible = type(form.OrderRecipientTarget) == "table"
    and type(form.OrderRecipientTarget.IsShown) == "function"
    and form.OrderRecipientTarget:IsShown()

  if target_visible and type(form.OrderRecipientTarget) == "table" then
    anchor_to = form.OrderRecipientTarget
  elseif type(form.OrderRecipientDropdown) == "table" then
    anchor_to = form.OrderRecipientDropdown
  end

  if container then
    container:ClearAllPoints()
    if anchor_to then
      container:SetPoint("TOPRIGHT", anchor_to, "BOTTOMRIGHT", 0, -4)
    else
      container:SetPoint("TOPRIGHT", form, "TOPRIGHT", -12, -30)
    end
  end

  if type(form.MinimumQuality) == "table" and type(form.MinimumQuality.SetPoint) == "function" then
    if visible and anchor_to then
      form.MinimumQuality:ClearAllPoints()
      local y_ofs = target_visible and -12 or -22
      form.MinimumQuality:SetPoint("TOPRIGHT", anchor_to, "BOTTOMRIGHT", 0, y_ofs)
    elseif type(form.UpdateMinimumQualityAnchor) == "function" then
      form:UpdateMinimumQualityAnchor()
    end
  end
end

reset_minimum_quality_status = function(form)
  if type(form) ~= "table"
    or type(form.MinimumQuality) ~= "table"
  then
    return
  end

  if type(form.MinimumQuality.SetHeight) == "function" then
    form.MinimumQuality:SetHeight(20)
  end
  if type(form.MinimumQuality.Text) == "table"
    and type(form.MinimumQuality.Text.SetHeight) == "function"
  then
    form.MinimumQuality.Text:SetHeight(20)
  end
  if type(form.MinimumQuality.Text) == "table"
    and type(form.MinimumQuality.Text.SetText) == "function"
  then
    form.MinimumQuality.Text:SetText(PROFESSIONS_CRAFTING_FORM_MIN_QUALITY)
  end
  if type(form.MinimumQuality.PuschelzStatusText) == "table" then
    form.MinimumQuality.PuschelzStatusText:Hide()
  end
  if type(form.UpdateMinimumQualityAnchor) == "function" then
    form:UpdateMinimumQualityAnchor()
  end
end

local function apply_minimum_quality_status(form, status_text, color)
  if type(form) ~= "table"
    or type(form.MinimumQuality) ~= "table"
    or type(form.MinimumQuality.IsShown) ~= "function"
    or not form.MinimumQuality:IsShown()
  then
    return false
  end

  if type(form.MinimumQuality.PuschelzStatusText) ~= "table"
    and type(form.MinimumQuality.CreateFontString) == "function"
  then
    local status_font = form.MinimumQuality:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status_font:SetJustifyH("RIGHT")
    status_font:SetWidth(250)
    status_font:SetPoint("TOPRIGHT", form.MinimumQuality.Text or form.MinimumQuality, "BOTTOMRIGHT", 0, 2)
    form.MinimumQuality.PuschelzStatusText = status_font
  end

  if type(form.MinimumQuality.SetHeight) == "function" then
    form.MinimumQuality:SetHeight(32)
  end
  if type(form.MinimumQuality.Text) == "table"
    and type(form.MinimumQuality.Text.SetHeight) == "function"
  then
    form.MinimumQuality.Text:SetHeight(20)
  end
  if type(form.MinimumQuality.Text) == "table"
    and type(form.MinimumQuality.Text.SetText) == "function"
  then
    form.MinimumQuality.Text:SetText(PROFESSIONS_CRAFTING_FORM_MIN_QUALITY)
  end
  if type(form.MinimumQuality.PuschelzStatusText) == "table" then
    form.MinimumQuality.PuschelzStatusText:SetText(colorize_status_text(status_text, color))
    form.MinimumQuality.PuschelzStatusText:Show()
  end
  if type(form.UpdateMinimumQualityAnchor) == "function" then
    form:UpdateMinimumQualityAnchor()
  end
  return true
end

refresh_place_order_status_widget = function()
  local widget = ensure_craft_request_status_widget()
  local container = craft_request_bridge.widgetContainer
  local form = type(ProfessionsCustomerOrdersFrame) == "table" and ProfessionsCustomerOrdersFrame.Form or nil
  if not widget or type(form) ~= "table" or not form.IsShown or not form:IsShown() then
    if container then
      container:Hide()
    end
    return
  end

  local is_personal_order = type(form.OrderRecipientTarget) == "table"
    and type(form.OrderRecipientTarget.IsShown) == "function"
    and form.OrderRecipientTarget:IsShown()
  if is_personal_order then
    reset_minimum_quality_status(form)
    update_place_order_status_anchor(form, container, false)
    if container then
      container:Hide()
    else
      widget:Hide()
    end
    craft_request_bridge.lastWidgetRecipeKey = nil
    craft_request_bridge.lastWidgetStateKey = nil
    return
  end

  local spell_id, item_id = resolve_place_order_recipe_context(form)
  local key = recipe_bridge_key(spell_id, item_id)
  local bridge_root = PuschelzBridgeSnapshot.ensure_loaded()
  local snapshot_version = PuschelzBridgeSnapshot.get_snapshot_version(bridge_root)

  local state_key = nil
  local text = nil
  local color = { 1, 0.82, 0.3 }
  local recipe_entry = key and PuschelzBridgeSnapshot.get_recipe_entry(key, bridge_root) or nil
  if snapshot_version <= 0 then
    text = "No data"
  elseif recipe_entry then
    local crafter_count = tonumber(recipe_entry.crafterCount) or 0
    text = string.format("Guild craftable (%d)", crafter_count)
    color = { 0.3, 1, 0.4 }
    state_key = key .. "|yes"
  elseif key then
    text = "No guild craft"
    color = { 1, 0.5, 0.5 }
    state_key = key .. "|no"
  end

  if not text then
    reset_minimum_quality_status(form)
    update_place_order_status_anchor(form, container, false)
    if container then
      container:Hide()
    else
      widget:Hide()
    end
    return
  end

  if apply_minimum_quality_status(form, text, color) then
    if container then
      container:Hide()
    else
      widget:Hide()
    end
    craft_request_bridge.lastWidgetRecipeKey = key
    craft_request_bridge.lastWidgetStateKey = state_key
    return
  end

  reset_minimum_quality_status(form)

  if state_key ~= nil
    and craft_request_bridge.lastWidgetStateKey == state_key
    and craft_request_bridge.lastWidgetRecipeKey == key
  then
    update_place_order_status_anchor(form, container, true)
    widget:SetText(text)
    widget:SetTextColor(color[1], color[2], color[3])
    if container then
      widget:Show()
      container:Show()
    else
      widget:Show()
    end
    return
  end

  widget:SetText(text)
  widget:SetTextColor(color[1], color[2], color[3])
  update_place_order_status_anchor(form, container, true)
  if container then
    widget:Show()
    container:Show()
  else
    widget:Show()
  end
  craft_request_bridge.lastWidgetRecipeKey = key
  craft_request_bridge.lastWidgetStateKey = state_key
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

  if type(math.randomseed) == "function" then
    math.randomseed(seed)
    math.random()
    math.random()
    math.random()
    return
  end

  -- Retail seeds the RNG for us; advance it a small player-specific amount
  -- so the follow-up raid jitter does not stay perfectly aligned.
  local warmup_rolls = (seed % 5) + 3
  for _ = 1, warmup_rolls do
    math.random()
  end
end

refresh_minimap_button_position = function()
  ensure_db()
  if not minimap_ui.iconLib or not minimap_ui.iconLib.IsRegistered or not minimap_ui.iconLib:IsRegistered(MINIMAP_LDB_NAME) then
    return
  end

  PuschelzDB.ui.minimapButton.angle = tonumber(PuschelzDB.ui.minimapButton.minimapPos)
    or tonumber(PuschelzDB.ui.minimapButton.angle)
    or MINIMAP_BUTTON_DEFAULT_ANGLE
  PuschelzDB.ui.minimapButton.minimapPos = PuschelzDB.ui.minimapButton.angle
  minimap_ui.iconLib:Refresh(MINIMAP_LDB_NAME, PuschelzDB.ui.minimapButton)
  minimap_ui.button = minimap_ui.iconLib:GetMinimapButton(MINIMAP_LDB_NAME)
  if refresh_minimap_pending_state then
    refresh_minimap_pending_state()
  end
end

local function update_minimap_menu_frame()
  local frame = minimap_ui.menuFrame
  local buttons = minimap_ui.menuButtons
  if not frame or not buttons then
    return
  end

  local has_simc = has_simulationcraft_exporter()
  local simc_label = has_simc
    and "Sync SimC + Run Droptimizer"
    or "Sync SimC + Run Droptimizer (requires SimulationCraft)"

  buttons.calendar:SetText("Sync Calendar")
  buttons.calendar:Enable()

  buttons.simc:SetText(simc_label)
  if has_simc then
    buttons.simc:Enable()
  else
    buttons.simc:Disable()
  end

  local settings = auto_logging.ensure_settings()
  buttons.autoChatLog:SetChecked(settings.autoEnableChatLog)
  buttons.autoCombatLog:SetChecked(settings.autoEnableCombatLog)
  buttons.combatLogOnlyInGroupContext:SetChecked(settings.onlyEnableCombatLogInGroupContext)
  buttons.stopCombatLogOnLeave:SetChecked(settings.stopCombatLogOnLeave)
  buttons.showCombatLogReminder:SetChecked(settings.showCombatLogReminder)

  local combat_enabled = settings.autoEnableCombatLog
  local contextual_enabled = combat_enabled and settings.onlyEnableCombatLogInGroupContext

  local function set_toggle_enabled(toggle, enabled)
    local color = enabled and toggle.enabledColor or toggle.disabledColor
    if enabled then
      toggle:Enable()
    else
      toggle:Disable()
    end

    if toggle.label and color then
      toggle.label:SetTextColor(color[1], color[2], color[3], color[4] or 1)
    end
  end

  set_toggle_enabled(buttons.combatLogOnlyInGroupContext, combat_enabled)
  set_toggle_enabled(buttons.stopCombatLogOnLeave, contextual_enabled)
  set_toggle_enabled(buttons.showCombatLogReminder, combat_enabled)

  frame:SetHeight(318)
end

local function ensure_minimap_menu_frame()
  if minimap_ui.menuFrame then
    update_minimap_menu_frame()
    return minimap_ui.menuFrame
  end

  local frame = CreateFrame("Frame", "PuschelzMinimapMenuFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(320, 318)
  frame:SetFrameStrata("DIALOG")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()

  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if frame.TitleBg then
    frame.title:SetPoint("CENTER", frame.TitleBg, "CENTER", 0, 0)
  else
    frame.title:SetPoint("TOP", frame, "TOP", 0, -16)
  end
  frame.title:SetText("Puschelz")

  local function create_menu_button(name, label, offset_y, on_click)
    local button = CreateFrame("Button", name, frame, "UIPanelButtonTemplate")
    button:SetSize(200, 24)
    button:SetPoint("TOP", frame, "TOP", 0, offset_y)
    button:SetText(label)
    button:SetScript("OnClick", function()
      frame:Hide()
      on_click()
    end)
    return button
  end

  local function create_menu_toggle(name, label, offset_y, on_click, tooltip_lines, options)
    options = options or {}
    local toggle = CreateFrame("CheckButton", name, frame, "UICheckButtonTemplate")
    toggle:SetPoint("TOPLEFT", frame, "TOPLEFT", options.indentX or 18, offset_y)
    toggle:SetScript("OnClick", on_click)
    if options.scale then
      toggle:SetScale(options.scale)
    end

    local label_font = _G[toggle:GetName() .. "Text"]
    if label_font then
      label_font:SetText(label)
      label_font:SetWidth(options.labelWidth or 250)
      label_font:SetJustifyH("LEFT")
      if options.fontObject then
        label_font:SetFontObject(options.fontObject)
      end
      label_font:SetTextColor(1, 0.82, 0)
    end
    toggle.label = label_font
    toggle.enabledColor = options.enabledColor or { 1, 0.82, 0, 1 }
    toggle.disabledColor = options.disabledColor or { 0.5, 0.5, 0.5, 1 }

    toggle:SetScript("OnEnter", function(self)
      if not tooltip_lines or not GameTooltip then
        return
      end

      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:ClearLines()
      for _, line in ipairs(tooltip_lines) do
        GameTooltip:AddLine(line.text, line.r or 1, line.g or 1, line.b or 1, line.wrap and true or false)
      end
      GameTooltip:Show()
    end)
    toggle:SetScript("OnLeave", function()
      if GameTooltip then
        GameTooltip:Hide()
      end
    end)

    return toggle
  end

  local buttons = {
    calendar = create_menu_button(
      "PuschelzMinimapMenuCalendarButton",
      "Sync Calendar",
      -38,
      function()
        request_calendar_scan(true)
      end
    ),
    simc = create_menu_button(
      "PuschelzMinimapMenuSimcButton",
      "Sync SimC + Run Droptimizer",
      -70,
      function()
        queue_simc_profile_request(true)
      end
    ),
    close = create_menu_button(
      "PuschelzMinimapMenuCloseButton",
      "Close",
      -102,
      function()
      end
    ),
    autoChatLog = create_menu_toggle(
      "PuschelzMinimapMenuAutoChatLogToggle",
      "Auto enable chat log",
      -110,
      function(self)
        auto_logging.ensure_settings().autoEnableChatLog = self:GetChecked() and true or false
        auto_logging.set_chat_logging_enabled(self:GetChecked() and true or false, "manual toggle")
        auto_logging.schedule_evaluation()
        update_minimap_menu_frame()
      end,
      {
        { text = "Keeps WoW chat logging enabled so the desktop client can read addon chat messages from WoWChatLog.txt.", wrap = true },
        { text = "Recommended if you want reliable addon-to-desktop chatlog communication.", r = 0.8, g = 0.8, b = 0.8, wrap = true },
      }
    ),
    autoCombatLog = create_menu_toggle(
      "PuschelzMinimapMenuAutoCombatLogToggle",
      "Auto enable combat log",
      -138,
      function(self)
        local enabled = self:GetChecked() and true or false
        local settings = auto_logging.ensure_settings()
        settings.autoEnableCombatLog = enabled

        if enabled then
          if settings.onlyEnableCombatLogInGroupContext and not auto_logging.is_in_group_context() then
            auto_logging.combatLogAutoStarted = false
            if DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
              DEFAULT_CHAT_FRAME:AddMessage("Puschelz: combat logging armed and waiting for raid or instance group context.")
            else
              print("Puschelz: combat logging armed and waiting for raid or instance group context.")
            end
          else
            auto_logging.set_combat_logging_enabled(true, "manual toggle")
            auto_logging.combatLogAutoStarted = true
          end
        else
          auto_logging.set_combat_logging_enabled(false, "manual toggle")
          auto_logging.combatLogAutoStarted = false
        end

        auto_logging.schedule_evaluation()
        update_minimap_menu_frame()
      end,
      {
        { text = "Automatically turns on WoWCombatLog.txt for you.", wrap = true },
        { text = "Useful quality-of-life if you want live Warcraft Logs, but not required for desktop client chatlog communication.", r = 0.8, g = 0.8, b = 0.8, wrap = true },
      }
    ),
    combatLogOnlyInGroupContext = create_menu_toggle(
      "PuschelzMinimapMenuCombatLogGroupContextToggle",
      "Only auto enable in raid or instance groups",
      -176,
      function(self)
        auto_logging.ensure_settings().onlyEnableCombatLogInGroupContext = self:GetChecked() and true or false
        if not self:GetChecked() then
          auto_logging.ensure_settings().stopCombatLogOnLeave = false
        end
        auto_logging.schedule_evaluation()
        update_minimap_menu_frame()
      end,
      {
        { text = "Waits to start combat logging until you are in a raid, party instance, or instance group context.", wrap = true },
        { text = "This avoids generating extra logs outside relevant content.", r = 0.8, g = 0.8, b = 0.8, wrap = true },
      },
      {
        indentX = 34,
        labelWidth = 225,
        scale = 0.92,
        fontObject = GameFontHighlightSmall,
      }
    ),
    stopCombatLogOnLeave = create_menu_toggle(
      "PuschelzMinimapMenuCombatLogStopToggle",
      "Auto stop after leaving raid or instance groups",
      -200,
      function(self)
        auto_logging.ensure_settings().stopCombatLogOnLeave = self:GetChecked() and true or false
        auto_logging.schedule_evaluation()
        update_minimap_menu_frame()
      end,
      {
        { text = "Only stops combat logging if Puschelz started it automatically.", wrap = true },
        { text = "Manual combat logging stays under user control.", r = 0.8, g = 0.8, b = 0.8, wrap = true },
      },
      {
        indentX = 34,
        labelWidth = 225,
        scale = 0.92,
        fontObject = GameFontHighlightSmall,
      }
    ),
    showCombatLogReminder = create_menu_toggle(
      "PuschelzMinimapMenuCombatLogReminderToggle",
      "Show Live Log reminder",
      -224,
      function(self)
        auto_logging.ensure_settings().showCombatLogReminder = self:GetChecked() and true or false
        update_minimap_menu_frame()
      end,
      {
        { text = "Shows an on-screen reminder when Puschelz auto-starts combat logging.", wrap = true },
        { text = "Useful if you want to remember enabling Live Log in the Warcraft Logs desktop app.", r = 0.8, g = 0.8, b = 0.8, wrap = true },
      },
      {
        indentX = 34,
        labelWidth = 225,
        scale = 0.92,
        fontObject = GameFontHighlightSmall,
      }
    ),
  }

  buttons.close:ClearAllPoints()
  buttons.close:SetPoint("TOP", frame, "TOP", 0, -270)

  minimap_ui.menuFrame = frame
  minimap_ui.menuButtons = buttons
  update_minimap_menu_frame()
  return frame
end

local function show_minimap_menu()
  local frame = ensure_minimap_menu_frame()
  if not frame then
    return
  end

  if frame:IsShown() then
    frame:Hide()
    return
  end

  frame:ClearAllPoints()
  if minimap_ui.button and minimap_ui.button:IsShown() then
    frame:SetPoint("TOPRIGHT", minimap_ui.button, "BOTTOMLEFT", -8, -8)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER")
  end
  frame:Show()
  frame:Raise()
end

local function add_sync_tooltip_lines(tooltip)
  if not tooltip or type(tooltip.AddLine) ~= "function" then
    return
  end

  local pending = sync_queue.current_local_pending_reload()
  local guild_items = sync_queue.sorted_guild_queue_items()

  tooltip:ClearLines()
  tooltip:AddLine("Puschelz", 1, 0.82, 0, true)
  tooltip:AddLine(" ")

  if pending then
    tooltip:AddLine(
      string.format("You: pending %s", sync_queue.format_scope_labels(pending.changedScopes)),
      1,
      0.2,
      0.2,
      true
    )
  else
    tooltip:AddLine("You: no pending reload", 0.55, 0.85, 0.55, true)
  end

  if #guild_items > 0 then
    tooltip:AddLine(
      string.format("Guild: %d pending", #guild_items),
      1,
      0.2,
      0.2,
      true
    )

    local next_item = guild_items[1]
    if next_item then
      tooltip:AddLine(
        string.format(
          "Next: %s (%s)",
          tostring(next_item.subjectName or next_item.subjectKey or "?"),
          sync_queue.format_scope_labels(next_item.changedScopes)
        ),
        0.82,
        0.82,
        0.82,
        true
      )
    end
  else
    tooltip:AddLine("Guild: queue empty", 0.55, 0.85, 0.55, true)
  end

  tooltip:AddLine(" ")
  tooltip:AddLine(
    string.format("Chat log: %s", auto_logging.is_chat_logging_enabled() and "on" or "off"),
    0.82,
    0.82,
    0.82,
    true
  )
  tooltip:AddLine(
    string.format("Combat log: %s", auto_logging.is_combat_logging_enabled() and "on" or "off"),
    0.82,
    0.82,
    0.82,
    true
  )
  tooltip:AddLine(" ")
  tooltip:AddLine("Click to open the sync menu.", 0.8, 0.8, 0.8)
end

local function show_addon_compartment_tooltip(button)
  if not button then
    return
  end

  GameTooltip:SetOwner(button, "ANCHOR_LEFT")
  add_sync_tooltip_lines(GameTooltip)
  GameTooltip:Show()
end

local function hide_addon_compartment_tooltip()
  GameTooltip:Hide()
end

function PuschelzAddonCompartment_Click(_, button_name)
  if type(button_name) ~= "string" or button_name == "" then
    button_name = "LeftButton"
  end
  show_minimap_menu()
end

function PuschelzAddonCompartment_OnEnter(_, button)
  show_addon_compartment_tooltip(button)
end

function PuschelzAddonCompartment_OnLeave()
  hide_addon_compartment_tooltip()
end

refresh_minimap_pending_state = function()
  local pending = sync_queue.current_local_pending_reload()
  local has_pending = pending ~= nil or #sync_queue.sorted_guild_queue_items() > 0
  local button = minimap_ui.button

  if not button and ensure_minimap_button then
    button = ensure_minimap_button()
  end

  if not button then
    return
  end

  if not minimap_ui.pendingDot then
    local dot = button:CreateTexture(nil, "OVERLAY")
    dot:SetSize(10, 10)
    dot:SetTexture("Interface\\COMMON\\Indicator-Red")
    dot:SetPoint("TOPRIGHT", button, "TOPRIGHT", 2, 1)
    dot:Hide()
    minimap_ui.pendingDot = dot
  end

  if has_pending then
    minimap_ui.pendingDot:Show()
  else
    minimap_ui.pendingDot:Hide()
  end
end

refresh_sync_state_visuals = function()
  sync_queue.prune_guild_queue()
  if refresh_minimap_pending_state then
    refresh_minimap_pending_state()
  end
end

ensure_minimap_button = function()
  if not minimap_ui.ldb or not minimap_ui.iconLib then
    return nil
  end

  if minimap_ui.button and minimap_ui.iconLib.IsRegistered and minimap_ui.iconLib:IsRegistered(MINIMAP_LDB_NAME) then
    refresh_minimap_button_position()
    return minimap_ui.button
  end

  ensure_db()

  if not minimap_ui.dataObject then
    minimap_ui.dataObject = minimap_ui.ldb:NewDataObject(MINIMAP_LDB_NAME, {
      type = "launcher",
      text = "Puschelz",
      icon = MINIMAP_ICON_PATH,
      OnClick = function(_, button_name)
        if type(button_name) ~= "string" or button_name == "" then
          button_name = "LeftButton"
        end
        show_minimap_menu()
      end,
      OnTooltipShow = function(tooltip)
        add_sync_tooltip_lines(tooltip)
      end,
    })
  end

  if not minimap_ui.iconLib:IsRegistered(MINIMAP_LDB_NAME) then
    minimap_ui.iconLib:Register(MINIMAP_LDB_NAME, minimap_ui.dataObject, PuschelzDB.ui.minimapButton)
  end

  refresh_minimap_button_position()
  minimap_ui.button = minimap_ui.iconLib:GetMinimapButton(MINIMAP_LDB_NAME)
  if refresh_minimap_pending_state then
    refresh_minimap_pending_state()
  end
  return minimap_ui.button
end

local function print_status()
  ensure_db()
  sync_queue.prune_guild_queue()

  local bank_tabs = PuschelzDB.guildBank.tabs or {}
  local calendar_events = PuschelzDB.calendar.events or {}
  local guild_orders = PuschelzDB.guildOrders.orders or {}
  local simc_request = type(PuschelzDB.simcRequest) == "table" and PuschelzDB.simcRequest or nil
  local required_addon_summary = summarize_required_addon_compliance()
  local pending_reload = sync_queue.current_local_pending_reload()
  local guild_queue_items = sync_queue.sorted_guild_queue_items()
  local bridge_acknowledgments = PuschelzBridgeSnapshot.get_sync_acknowledgments()

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

  if simc_request and type(simc_request.requestId) == "string" and simc_request.requestId ~= "" then
    local simc_request_at = tonumber(simc_request.requestedAt)
    local simc_mode = simc_request.runDroptimizerNow and "droptimizer" or "upload"
    print(
      string.format(
        "Puschelz: pendingSimC=%s (%s, %s)",
        simc_request.requestId,
        simc_mode,
        simc_request_at and date("%Y-%m-%d %H:%M", math.floor(simc_request_at / 1000)) or "unknown"
      )
    )
  end

  if pending_reload then
    print(string.format(
      "Puschelz: pendingReload=v%d (%s)",
      tonumber(pending_reload.payloadVersion) or 0,
      sync_queue.format_scope_labels(pending_reload.changedScopes)
    ))
  end

  if #guild_queue_items > 0 then
    print(string.format("Puschelz: guildSyncQueue=%d", #guild_queue_items))
  end

  local bridge_ack_count = count_table_entries(bridge_acknowledgments)
  if bridge_ack_count > 0 then
    local current_subject_key = select(1, sync_queue.current_subject_key())
    local current_ack = current_subject_key and bridge_acknowledgments[current_subject_key] or nil
    if type(current_ack) == "table" then
      print(string.format(
        "Puschelz: bridgeAcknowledgments=%d, current=v%d",
        bridge_ack_count,
        tonumber(current_ack.payloadVersion) or 0
      ))
    else
      print(string.format("Puschelz: bridgeAcknowledgments=%d", bridge_ack_count))
    end
  end

  local version_text = required_addon_summary.requiredAddonsVersion > 0
    and tostring(required_addon_summary.requiredAddonsVersion)
    or "n/a"
  print(
    string.format(
      "Puschelz: requiredAddons=%d, satisfied=%d, missing=%d, invalidBridgeConfigs=%d, bridgeVersion=%s",
      required_addon_summary.requiredCount,
      required_addon_summary.satisfiedCount,
      required_addon_summary.missingCount,
      required_addon_summary.invalidConfiguredCount,
      version_text
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

  if command == "addons" then
    print_required_addon_status(true)
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

  print("Puschelz usage: /puschelz status | /puschelz scan | /puschelz orders | /puschelz addons | /puschelz syncorders | /puschelz check | /puschelz raidstatus")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
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
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_DIFFICULTY_CHANGED")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    local addon_name = ...
    if addon_name == "Blizzard_Calendar" then
      refresh_calendar_sync_button()
    end
    return
  end

  if event == "PLAYER_LOGIN" then
    ensure_db()
    ensure_bridge_db()
    refresh_player_metadata()
    ensure_minimap_button()
    print_matching_guild_order_reminders()
    print_matching_bridge_requests()
    warn_missing_required_addons_if_needed()
    seed_raid_random_delay()
    register_raid_status_prefix()
    register_craft_request_prefix()
    sync_queue.register_prefix()
    broadcast_open_bridge_requests()
    schedule_group_roster_update()
    refresh_sync_state_visuals()
    auto_logging.schedule_evaluation()
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
    refresh_calendar_sync_button()
    if calendar_attendee_scan.requestPending then
      consume_pending_calendar_request(false)
    end
    return
  end

  if event == "PLAYER_ENTERING_WORLD" then
    refresh_minimap_button_position()
    schedule_group_roster_update()
    auto_logging.schedule_evaluation()
    return
  end

  if event == "GROUP_ROSTER_UPDATE" then
    schedule_group_roster_update()
    auto_logging.schedule_evaluation()
    return
  end

  if event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_DIFFICULTY_CHANGED" then
    auto_logging.schedule_evaluation()
    return
  end

  if event == "CHAT_MSG_ADDON" then
    local prefix, message, channel, sender = ...
    if channel == "RAID" or channel == "INSTANCE_CHAT" then
      handle_raid_addon_message(prefix, message, channel, sender)
    end
    if channel == "GUILD" then
      sync_queue.handle_addon_message(prefix, message, channel, sender)
      handle_craft_request_addon_message(prefix, message, channel, sender)
    end
    return
  end

  if event == "PLAYER_LOGOUT" then
    ensure_db()
    PuschelzDB.ui.minimapButton.angle = tonumber(PuschelzDB.ui.minimapButton.minimapPos)
      or tonumber(PuschelzDB.ui.minimapButton.angle)
      or MINIMAP_BUTTON_DEFAULT_ANGLE
    PuschelzDB.updatedAt = now_epoch_ms()
  end
end)
