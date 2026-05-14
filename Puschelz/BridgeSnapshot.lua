PUSCHELZ_RUNTIME = PUSCHELZ_RUNTIME or {}
PUSCHELZ_RUNTIME.modules = PUSCHELZ_RUNTIME.modules or {}

PuschelzBridgeSnapshot = PuschelzBridgeSnapshot or {
  deps = nil,
}

local function require_deps()
  if type(PuschelzBridgeSnapshot.deps) ~= "table" then
    error("Puschelz bridge snapshot module is not configured.")
  end

  return PuschelzBridgeSnapshot.deps
end

local function ensure_table(parent, key)
  if type(parent[key]) ~= "table" then
    parent[key] = {}
  end

  return parent[key]
end

local function validate_deps(deps)
  if type(deps) ~= "table" then
    return nil, "Puschelz bridge snapshot module is not configured."
  end

  local required_fields = {
    "ensure_export_db",
    "try_load_bridge_addon",
    "is_addon_loaded_by_name",
    "count_table_entries",
    "now_epoch_ms",
    "state",
  }

  for _, field in ipairs(required_fields) do
    if deps[field] == nil then
      return nil, string.format("Puschelz bridge snapshot module is missing dependency '%s'.", field)
    end
  end

  if type(deps.ensure_export_db) ~= "function"
    or type(deps.try_load_bridge_addon) ~= "function"
    or type(deps.is_addon_loaded_by_name) ~= "function"
    or type(deps.count_table_entries) ~= "function"
    or type(deps.now_epoch_ms) ~= "function"
    or type(deps.state) ~= "table"
  then
    return nil, "Puschelz bridge snapshot module dependencies are invalid."
  end

  return deps, nil
end

local function normalize_root()
  if type(PuschelzBridgeDB) ~= "table" then
    PuschelzBridgeDB = {}
  end

  local root = PuschelzBridgeDB
  ensure_table(root, "recipesByKey")
  ensure_table(root, "openRequests")
  ensure_table(root, "requiredAddons")
  ensure_table(root, "syncAcknowledgments")
  return root
end

function PuschelzBridgeSnapshot.configure(deps)
  local validated, error_message = validate_deps(deps)
  if not validated then
    error(error_message)
  end

  PuschelzBridgeSnapshot.deps = validated
end

function PuschelzBridgeSnapshot.ensure_loaded()
  local deps = require_deps()
  local state = deps.state or {}

  deps.ensure_export_db()

  if not state.bridgeLoadAttempted then
    local loaded, reason = deps.try_load_bridge_addon()
    state.bridgeLoadAttempted = true
    state.bridgeLoaded = loaded and true or false
    state.bridgeLoadReason = tostring(reason or "unknown")
    state.bridgeDebugSynced = false
  elseif not state.bridgeLoaded and deps.is_addon_loaded_by_name("PuschelzBridge") then
    state.bridgeLoaded = true
    state.bridgeLoadReason = "already_loaded"
    state.bridgeDebugSynced = false
  end

  return normalize_root()
end

function PuschelzBridgeSnapshot.build_debug_summary(root)
  local deps = require_deps()
  local state = deps.state or {}
  local bridge_root = root or normalize_root()

  return {
    loaded = state.bridgeLoaded and true or false,
    loadReason = tostring(state.bridgeLoadReason or "unknown"),
    addonLoaded = deps.is_addon_loaded_by_name("PuschelzBridge") and true or false,
    snapshotVersion = tonumber(bridge_root.snapshotVersion),
    requiredAddonsVersion = tonumber(bridge_root.requiredAddonsVersion),
    requiredAddonsConfiguredCount = tonumber(bridge_root.requiredAddonsConfiguredCount),
    invalidRequiredAddonCount = tonumber(bridge_root.invalidRequiredAddonCount),
    generatedAt = tonumber(bridge_root.generatedAt),
    recipeCount = deps.count_table_entries(bridge_root.recipesByKey),
    openRequestCount = #bridge_root.openRequests,
    requiredAddonCount = #bridge_root.requiredAddons,
    updatedAt = deps.now_epoch_ms(),
  }
end

function PuschelzBridgeSnapshot.get_snapshot_version(root)
  root = root or PuschelzBridgeSnapshot.ensure_loaded()
  return tonumber(root.snapshotVersion) or 0
end

function PuschelzBridgeSnapshot.get_required_addons_config(root)
  root = root or PuschelzBridgeSnapshot.ensure_loaded()
  return {
    requiredAddonsVersion = tonumber(root.requiredAddonsVersion) or 0,
    requiredAddonsConfiguredCount = tonumber(root.requiredAddonsConfiguredCount) or 0,
    invalidRequiredAddonCount = tonumber(root.invalidRequiredAddonCount) or 0,
    requiredAddons = root.requiredAddons,
  }
end

function PuschelzBridgeSnapshot.get_open_requests(root)
  root = root or PuschelzBridgeSnapshot.ensure_loaded()
  return root.openRequests
end

function PuschelzBridgeSnapshot.get_recipe_entry(key, root)
  if type(key) ~= "string" or key == "" then
    return nil
  end

  root = root or PuschelzBridgeSnapshot.ensure_loaded()
  local entry = root.recipesByKey[key]
  if type(entry) ~= "table" then
    return nil
  end

  return entry
end

function PuschelzBridgeSnapshot.consume_acknowledgments(apply_fn)
  local root = PuschelzBridgeSnapshot.ensure_loaded()
  if type(apply_fn) ~= "function" then
    return false
  end

  local changed = false
  local remaining = {}
  for key, entry in pairs(root.syncAcknowledgments) do
    if apply_fn(entry) then
      changed = true
    else
      remaining[key] = entry
    end
  end

  root.syncAcknowledgments = remaining
  return changed
end

PUSCHELZ_RUNTIME.modules.bridge_snapshot = PuschelzBridgeSnapshot
