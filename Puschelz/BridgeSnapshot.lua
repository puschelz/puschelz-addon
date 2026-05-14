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
  PuschelzBridgeSnapshot.deps = deps or {}
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

function PuschelzBridgeSnapshot.get_snapshot_version()
  local root = PuschelzBridgeSnapshot.ensure_loaded()
  return tonumber(root.snapshotVersion) or 0
end

function PuschelzBridgeSnapshot.get_required_addons_config()
  local root = PuschelzBridgeSnapshot.ensure_loaded()
  return {
    requiredAddonsVersion = tonumber(root.requiredAddonsVersion) or 0,
    requiredAddonsConfiguredCount = tonumber(root.requiredAddonsConfiguredCount) or 0,
    invalidRequiredAddonCount = tonumber(root.invalidRequiredAddonCount) or 0,
    requiredAddons = root.requiredAddons,
  }
end

function PuschelzBridgeSnapshot.get_open_requests()
  local root = PuschelzBridgeSnapshot.ensure_loaded()
  return root.openRequests
end

function PuschelzBridgeSnapshot.get_recipe_entry(key)
  if type(key) ~= "string" or key == "" then
    return nil
  end

  local root = PuschelzBridgeSnapshot.ensure_loaded()
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
