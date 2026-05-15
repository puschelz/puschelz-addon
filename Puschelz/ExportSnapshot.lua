PUSCHELZ_RUNTIME = PUSCHELZ_RUNTIME or {}
PUSCHELZ_RUNTIME.modules = PUSCHELZ_RUNTIME.modules or {}

PuschelzExportSnapshot = PuschelzExportSnapshot or {}

local function ensure_table(parent, key)
  if type(parent[key]) ~= "table" then
    parent[key] = {}
  end

  return parent[key]
end

function PuschelzExportSnapshot.ensure_db(schema_version, minimap_default_angle)
  if type(PuschelzDB) ~= "table" then
    PuschelzDB = {}
  end

  local db = PuschelzDB
  db.schemaVersion = schema_version
  db.updatedAt = db.updatedAt or 0

  local guild_bank = ensure_table(db, "guildBank")
  guild_bank.tabs = type(guild_bank.tabs) == "table" and guild_bank.tabs or {}
  guild_bank.tabsByIndex = type(guild_bank.tabsByIndex) == "table" and guild_bank.tabsByIndex or {}

  local calendar = ensure_table(db, "calendar")
  calendar.events = type(calendar.events) == "table" and calendar.events or {}

  local guild_orders = ensure_table(db, "guildOrders")
  guild_orders.orders = type(guild_orders.orders) == "table" and guild_orders.orders or {}

  ensure_table(db, "player")
  ensure_table(db, "requiredAddonCompliance")
  ensure_table(db, "pendingReload")
  ensure_table(db, "lastSyncedPayload")
  ensure_table(db, "guildSyncQueue")

  local ui = ensure_table(db, "ui")
  local minimap_button = ensure_table(ui, "minimapButton")
  if type(minimap_button.minimapPos) ~= "number" then
    minimap_button.minimapPos = tonumber(minimap_button.angle) or minimap_default_angle
  end
  if type(minimap_button.angle) ~= "number" then
    minimap_button.angle = tonumber(minimap_button.minimapPos) or minimap_default_angle
  end

  local logging = ensure_table(ui, "logging")
  if type(logging.autoEnableChatLog) ~= "boolean" then
    logging.autoEnableChatLog = false
  end
  if type(logging.autoEnableCombatLog) ~= "boolean" then
    logging.autoEnableCombatLog = false
  end
  if type(logging.onlyEnableCombatLogInGroupContext) ~= "boolean" then
    logging.onlyEnableCombatLogInGroupContext = false
  end
  if type(logging.stopCombatLogOnLeave) ~= "boolean" then
    logging.stopCombatLogOnLeave = false
  end
  if type(logging.showCombatLogReminder) ~= "boolean" then
    logging.showCombatLogReminder = false
  end

  return db
end

function PuschelzExportSnapshot.get_root()
  if type(PuschelzDB) ~= "table" then
    return nil
  end

  return PuschelzDB
end

PUSCHELZ_RUNTIME.modules.export_snapshot = PuschelzExportSnapshot
