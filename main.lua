--[[
    bluetooth.koplugin/main.lua
    Standalone Bluetooth manager plugin for KOReader on MTK-based Kobo/Tolino devices.

    Features:
    - Enable / Disable Bluetooth
    - Scan for devices, show results, connect/disconnect
    - WiFi state preservation: saves WiFi state before BT ops, restores after
    - Suspend/Resume handling: turns BT off before deep sleep, resumes with selected reconnect strategy
    - Startup: optional auto-reconnect to known/last paired device
    - Debug mode: selectable reconnect strategy via menu

    MTK notes:
    - Deep sleep = "mem" state, no light-standby.
    - DO NOT attempt suspend while charging on MTK (kernel hang).
    - BT uses D-Bus service com.kobo.mtk.bluedroid.
    - standby prevention via UIManager:preventStandby() / allowStandby().

    Power management contract (must align with autosuspend.koplugin):
    - When BT is ON: UIManager:preventStandby() called.  Deep sleep via power button still works
      (that path bypasses autosuspend), but auto-standby timer is suppressed.
    - On Suspend event: BT is shut down BEFORE kernel writes /sys/power/state = mem.
    - On Resume event: BT is restarted according to reconnect strategy (delayed, async).
    - WiFi: MTK shares a WMT coexistence firmware between WiFi and BT.  We snapshot WiFi
      state before enabling BT and restore it afterwards so we do not permanently kill WiFi.
--]]

local Device   = require("device")

-- Guard: only available on MTK Kobo/Tolino
if not (Device:isKobo() and Device.isMTK and Device.isMTK()) then
    return { disabled = true }
end

local ConfirmBox      = require("ui/widget/confirmbox")
local DataStorage     = require("datastorage")
local InfoMessage     = require("ui/widget/infomessage")
local LuaSettings     = require("luasettings")
local Menu            = require("ui/widget/menu")
local NetworkMgr      = require("ui/network/manager")
local Screen          = require("device/screen")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil         = require("ffi/util")
local logger          = require("logger")
local _               = require("gettext")

-- ── D-Bus helpers (MTK adapter directly) ────────────────────────────────────

local DBUS_DEST = "com.kobo.mtk.bluedroid"
local DBUS_OBJ  = "/org/bluez/hci0"

local function dbus(cmd)
    local ok = os.execute(cmd .. " >/dev/null 2>&1")
    return (ok == 0)
end

local function btIsEnabled()
    local h = io.popen(
        "dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " " .. DBUS_OBJ
        .. " org.freedesktop.DBus.Properties.Get"
        .. " string:org.bluez.Adapter1 string:Powered 2>/dev/null"
    )
    if not h then return false end
    local out = h:read("*a"); h:close()
    return out and out:match("boolean%s+true") ~= nil
end

local function btTurnOn()
    dbus("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " / com.kobo.bluetooth.BluedroidManager1.On")
    dbus("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " " .. DBUS_OBJ
        .. " org.freedesktop.DBus.Properties.Set"
        .. " string:org.bluez.Adapter1 string:Powered variant:boolean:true")
end

local function btTurnOff()
    dbus("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " " .. DBUS_OBJ
        .. " org.freedesktop.DBus.Properties.Set"
        .. " string:org.bluez.Adapter1 string:Powered variant:boolean:false")
    dbus("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " / com.kobo.bluetooth.BluedroidManager1.Off")
end

--- Start BT discovery (10 seconds), return raw dbus output
local function btStartScan()
    dbus("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " " .. DBUS_OBJ .. " org.bluez.Adapter1.StartDiscovery")
end

local function btStopScan()
    dbus("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " " .. DBUS_OBJ .. " org.bluez.Adapter1.StopDiscovery")
end

--- Returns list of {address, name, paired, connected} from bluez ObjectManager
local function btGetDevices()
    local h = io.popen(
        "dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " / org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null"
    )
    if not h then return {} end
    local out = h:read("*a"); h:close()

    local devices = {}
    -- Each device entry looks like: object path "/org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX"
    for path in out:gmatch('object path "/org/bluez/hci0/dev_(%w+_%w+_%w+_%w+_%w+_%w+)"') do
        local addr = path:gsub("_", ":")
        -- Extract Name near this address
        local section = out:match('dev_' .. path:gsub(":", "_") .. '"(.-)object path', 1)
                     or out:match('dev_' .. path .. '"(.-)\n%s*object path')
                     or ""
        local name = section:match('string%s+"Name"[^"]*"([^"]+)"') or addr
        local paired    = section:match('string%s+"Paired"[^"]*boolean%s+(true)') ~= nil
        local connected = section:match('string%s+"Connected"[^"]*boolean%s+(true)') ~= nil
        table.insert(devices, {
            address   = addr,
            name      = name,
            paired    = paired,
            connected = connected,
        })
    end
    return devices
end

local function btConnect(address)
    local dev_path = "/org/bluez/hci0/dev_" .. address:gsub(":", "_")
    return dbus("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " " .. dev_path .. " org.bluez.Device1.Connect")
end

local function btDisconnect(address)
    local dev_path = "/org/bluez/hci0/dev_" .. address:gsub(":", "_")
    return dbus("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " " .. dev_path .. " org.bluez.Device1.Disconnect")
end

-- ── Reconnect strategies ─────────────────────────────────────────────────────
--
-- Each strategy is a different set of D-Bus / syscall operations used to
-- restore a paired device connection after deep sleep (mem) wake-up.
-- The 'exec' field is a function(address) that performs the reconnect.
-- All strategies run asynchronously via ffiutil.runInSubProcess so they
-- never block the UIManager loop.
--
-- Strategy overview:
--   1. direct_connect      – plain Device1.Connect via D-Bus (fastest, lowest risk)
--   2. trust_connect       – set Trusted=true first, then Connect
--                            (helps if bluez dropped trust across suspend)
--   3. adapter_cycle       – power HCI adapter OFF→wait→ON, then Connect
--                            (resets adapter state without restarting daemon)
--   4. bluedroid_restart   – full MTK BluedroidManager1.Off→On, then Connect
--                            (restarts the MTK BT daemon stack; heavier but
--                             fixes cases where daemon state is stale after wake)
--   5. wmt_reload          – kill wmt_launcher/wmt_loader, restart them, then
--                            BluedroidManager1.On + Connect
--                            (reloads WMT coexistence firmware from disk;
--                             most aggressive, use if adapter_cycle still fails)
--   6. manual              – never auto-reconnect; user triggers from menu
--
-- Note: DBUS_DEST is reused inside subprocess lambdas; Lua closures capture it
-- correctly because all strategy exec functions are defined in the same file scope.

local function _dbusExec(cmd)
    return os.execute(cmd .. " >/dev/null 2>&1") == 0
end

--- Helpers used inside subprocess lambdas (file-scope, captured by closures)
local function _subBtOn()
    _dbusExec("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " / com.kobo.bluetooth.BluedroidManager1.On")
    _dbusExec("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " /org/bluez/hci0"
        .. " org.freedesktop.DBus.Properties.Set"
        .. " string:org.bluez.Adapter1 string:Powered variant:boolean:true")
end

local function _subDevConnect(dev_path)
    _dbusExec("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " " .. dev_path .. " org.bluez.Device1.Connect")
end

local function _subSetTrusted(dev_path)
    _dbusExec("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " " .. dev_path
        .. " org.freedesktop.DBus.Properties.Set"
        .. " string:org.bluez.Device1 string:Trusted variant:boolean:true")
end

local function _subAdapterPower(on)
    local val = on and "true" or "false"
    _dbusExec("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " /org/bluez/hci0"
        .. " org.freedesktop.DBus.Properties.Set"
        .. " string:org.bluez.Adapter1 string:Powered variant:boolean:" .. val)
end

local function _subBluedroidOff()
    _dbusExec("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " /org/bluez/hci0"
        .. " org.freedesktop.DBus.Properties.Set"
        .. " string:org.bluez.Adapter1 string:Powered variant:boolean:false")
    _dbusExec("dbus-send --system --print-reply --dest=" .. DBUS_DEST
        .. " / com.kobo.bluetooth.BluedroidManager1.Off")
end

local RECONNECT_STRATEGIES = {
    {
        id    = "direct_connect",
        label = _("1. Direct connect  (Device1.Connect)"),
        desc  = _("Calls org.bluez.Device1.Connect directly.\nFastest, safest — try this first."),
        delay = 1,   -- seconds to wait after BT-ON before attempting
        exec  = function(address)
            -- runs INSIDE subprocess
            local dev_path = "/org/bluez/hci0/dev_" .. address:gsub(":", "_")
            _subDevConnect(dev_path)
        end,
    },
    {
        id    = "trust_connect",
        label = _("2. Trust + connect  (set Trusted=true, then Connect)"),
        desc  = _("Sets Trusted=true on the device first, then connects.\n"
               .. "Helps if bluez dropped trust across suspend."),
        delay = 1,
        exec  = function(address)
            local dev_path = "/org/bluez/hci0/dev_" .. address:gsub(":", "_")
            _subSetTrusted(dev_path)
            ffiutil.sleep(0.3)
            _subDevConnect(dev_path)
        end,
    },
    {
        id    = "adapter_cycle",
        label = _("3. Adapter cycle  (HCI power OFF → ON → Connect)"),
        desc  = _("Powers the HCI adapter off, waits 1 s, powers it on again,\n"
               .. "then connects. Resets adapter state without restarting daemon.\n"
               .. "Good when bluez thinks the adapter is still in a bad state."),
        delay = 0,
        exec  = function(address)
            local dev_path = "/org/bluez/hci0/dev_" .. address:gsub(":", "_")
            _subAdapterPower(false)
            ffiutil.sleep(1)
            _subAdapterPower(true)
            ffiutil.sleep(1.5)
            _subDevConnect(dev_path)
        end,
    },
    {
        id    = "bluedroid_restart",
        label = _("4. Bluedroid restart  (MTK daemon Off → On → Connect)"),
        desc  = _("Calls BluedroidManager1.Off then .On (restarts MTK BT daemon),\n"
               .. "then connects. Heavier than adapter_cycle but fixes stale\n"
               .. "daemon state after wake-up."),
        delay = 0,
        exec  = function(address)
            local dev_path = "/org/bluez/hci0/dev_" .. address:gsub(":", "_")
            _subBluedroidOff()
            ffiutil.sleep(2)
            _subBtOn()
            ffiutil.sleep(2)
            _subDevConnect(dev_path)
        end,
    },
    {
        id    = "wmt_reload",
        label = _("5. WMT reload  (kill wmt_launcher, restart, then connect)"),
        desc  = _("Kills wmt_launcher and wmt_loader, restarts them to reload\n"
               .. "the WMT coexistence firmware from disk, then brings BT up.\n"
               .. "Most aggressive — use if adapter_cycle still fails after wake.\n"
               .. "WARNING: briefly disrupts WiFi coexistence firmware."),
        delay = 0,
        exec  = function(address)
            local dev_path = "/org/bluez/hci0/dev_" .. address:gsub(":", "_")
            -- stop MT stack
            _subBluedroidOff()
            ffiutil.sleep(0.5)
            -- kill WMT userland
            os.execute("killall -q wmt_launcher wmt_loader 2>/dev/null")
            ffiutil.sleep(1)
            -- restart WMT loader (loads firmware WMT_SOC.cfg / WMT_STEP.cfg)
            os.execute("/usr/bin/wmt_loader >/dev/null 2>&1 &")
            ffiutil.sleep(0.5)
            os.execute("/usr/bin/wmt_launcher >/dev/null 2>&1 &")
            ffiutil.sleep(2)
            -- bring BT stack back
            _subBtOn()
            ffiutil.sleep(2)
            _subDevConnect(dev_path)
        end,
    },
    {
        id    = "manual",
        label = _("6. Manual only  (no auto-reconnect)"),
        desc  = _("BT is re-enabled on resume but no automatic reconnect.\n"
               .. "Use 'Reconnect now' from the debug menu."),
        delay = -1,  -- sentinel: skip reconnect entirely
        exec  = nil,
    },
}

local DEFAULT_STRATEGY_ID = "direct_connect"

local function strategyById(id)
    for _, s in ipairs(RECONNECT_STRATEGIES) do
        if s.id == id then return s end
    end
    return RECONNECT_STRATEGIES[1] -- fallback: direct_connect
end

-- ── Plugin definition ────────────────────────────────────────────────────────

local BluetoothPlugin = WidgetContainer:extend{
    name            = "bluetooth",
    is_doc_only     = false,

    -- runtime state
    bt_was_on_before_suspend = false,   -- saved in onSuspend, used in onResume
    wifi_was_on_snapshot     = false,   -- WiFi state before BT enable
    standby_prevented        = false,   -- tracks UIManager:preventStandby calls
    bt_enable_pending        = false,   -- true while async _enableBT is in flight
    reconnect_timer          = nil,     -- scheduled UIManager task handle
    scan_devices             = nil,     -- last scan result cache
}

-- ── Settings helpers ─────────────────────────────────────────────────────────

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/bluetooth_plugin.lua"

function BluetoothPlugin:_loadSettings()
    if not self._settings then
        self._settings = LuaSettings:open(SETTINGS_FILE)
    end
    return self._settings
end

function BluetoothPlugin:_getSetting(key, default)
    local v = self:_loadSettings():readSetting(key)
    if v == nil then return default end
    return v
end

function BluetoothPlugin:_setSetting(key, value)
    self:_loadSettings():saveSetting(key, value)
    self:_loadSettings():flush()
end

-- ── Standby guard ────────────────────────────────────────────────────────────

function BluetoothPlugin:_preventStandby()
    if not self.standby_prevented then
        UIManager:preventStandby()
        self.standby_prevented = true
        logger.dbg("BluetoothPlugin: standby prevented")
    end
end

function BluetoothPlugin:_allowStandby()
    if self.standby_prevented then
        UIManager:allowStandby()
        self.standby_prevented = false
        logger.dbg("BluetoothPlugin: standby allowed")
    end
end

-- ── WiFi snapshot ────────────────────────────────────────────────────────────

function BluetoothPlugin:_snapshotWifi()
    self.wifi_was_on_snapshot = NetworkMgr:isWifiOn()
    logger.dbg("BluetoothPlugin: WiFi snapshot =", self.wifi_was_on_snapshot)
end

--- Restore WiFi to the state it had before we touched it.
--- Respects G_reader_settings auto_restore_wifi the same way core does.
function BluetoothPlugin:_restoreWifi(from_resume)
    if from_resume then
        -- On resume: let the standard networklistener handle it just like stock KOReader does.
        -- Only act if auto_restore_wifi is OFF (we must not leave WiFi on when user disabled it).
        if not G_reader_settings:isTrue("auto_restore_wifi") and NetworkMgr:isWifiOn() then
            logger.dbg("BluetoothPlugin: auto_restore_wifi off → disabling WiFi after resume")
            NetworkMgr:disableWifi(nil, false)
        end
    else
        -- Manual toggle: restore exactly to snapshotted state
        if not self.wifi_was_on_snapshot and NetworkMgr:isWifiOn() then
            logger.dbg("BluetoothPlugin: manual path → WiFi was OFF before, disabling now")
            NetworkMgr:disableWifi(nil, false)
        end
    end
end

-- ── Core BT operations (async-friendly) ─────────────────────────────────────

--- Enable BT in a subprocess, poll until up, then restore WiFi.
--- Sets bt_enable_pending=true for the duration so onSuspend can abort safely.
--- @param is_resume boolean   true when called from onResume
--- @param on_done   function  optional callback after BT confirmed ON
function BluetoothPlugin:_enableBT(is_resume, on_done)
    if btIsEnabled() then
        self:_preventStandby()
        if on_done then on_done() end
        return
    end

    self:_snapshotWifi()
    self:_preventStandby()
    self.bt_enable_pending = true

    -- MTK BT needs WiFi stack up for coexistence firmware init
    if not NetworkMgr:isWifiOn() then
        NetworkMgr:restoreWifiAsync()
    end

    -- Kick BT-ON in a subprocess so we don't block UIManager
    UIManager:tickAfterNext(function()
        ffiutil.runInSubProcess(function()
            btTurnOn()
        end, false, true)

        -- Poll until enabled (max 3 s, 100 ms intervals)
        local function poll(n)
            -- Abort gracefully if a suspend arrived while we were enabling
            if not self.bt_enable_pending then
                logger.info("BluetoothPlugin: enable aborted (suspend arrived)")
                return
            end
            if btIsEnabled() then
                self.bt_enable_pending = false
                logger.info("BluetoothPlugin: BT enabled")
                self:_restoreWifi(is_resume)
                if on_done then on_done() end
                return
            end
            if n >= 30 then
                self.bt_enable_pending = false
                logger.warn("BluetoothPlugin: BT enable timeout")
                self:_allowStandby()
                self:_restoreWifi(is_resume)
                UIManager:show(InfoMessage:new{
                    text    = _("Bluetooth enable timed out."),
                    timeout = 3,
                })
                return
            end
            UIManager:scheduleIn(0.1, function() poll(n + 1) end)
        end
        poll(0)
    end)
end

--- Disable BT immediately (synchronous dbus calls are fast enough).
function BluetoothPlugin:_disableBT(show_ui)
    if not btIsEnabled() then
        self:_allowStandby()
        return
    end
    btTurnOff()
    self:_allowStandby()
    if show_ui then
        UIManager:show(InfoMessage:new{
            text    = _("Bluetooth disabled."),
            timeout = 2,
        })
    end
    logger.info("BluetoothPlugin: BT disabled")
end

-- ── Reconnect-on-resume ──────────────────────────────────────────────────────

function BluetoothPlugin:_cancelReconnectTimer()
    if self.reconnect_timer then
        UIManager:unschedule(self.reconnect_timer)
        self.reconnect_timer = nil
    end
end

--- Attempt to reconnect to the last known device using the selected strategy.
--- Each strategy is a different set of D-Bus/syscall operations run in a
--- subprocess so the UIManager loop is never blocked.
function BluetoothPlugin:_scheduleReconnect()
    local strategy_id = self:_getSetting("reconnect_strategy", DEFAULT_STRATEGY_ID)
    local strategy    = strategyById(strategy_id)

    if strategy.delay < 0 or not strategy.exec then
        logger.dbg("BluetoothPlugin: reconnect strategy = manual, skipping auto-reconnect")
        return
    end

    local last_addr = self:_getSetting("last_connected_address", nil)
    if not last_addr then
        logger.dbg("BluetoothPlugin: no last_connected_address, skipping reconnect")
        return
    end

    self:_cancelReconnectTimer()

    local function do_reconnect()
        self.reconnect_timer = nil
        if not btIsEnabled() then
            logger.warn("BluetoothPlugin: BT not enabled at reconnect time, aborting")
            return
        end
        logger.info("BluetoothPlugin: reconnecting to", last_addr,
                    "using strategy:", strategy.id)
        -- Run the strategy's exec function inside a subprocess.
        -- double_fork=true → child reparented to init, no zombie collection needed.
        local addr_capture = last_addr
        local exec_capture = strategy.exec
        ffiutil.runInSubProcess(function()
            exec_capture(addr_capture)
        end, function()
            -- called back in main process after subprocess exits
            logger.info("BluetoothPlugin: reconnect subprocess finished, strategy=", strategy.id)
            -- We cannot know if it succeeded from here without polling.
            -- A follow-up poll checks Connected property.
            UIManager:scheduleIn(0.5, function()
                local devices = btGetDevices()
                local connected = false
                for _, d in ipairs(devices) do
                    if d.address:lower() == addr_capture:lower() and d.connected then
                        connected = true
                        break
                    end
                end
                if connected then
                    UIManager:show(InfoMessage:new{
                        text    = _("Bluetooth reconnected."),
                        timeout = 2,
                    })
                else
                    logger.warn("BluetoothPlugin: reconnect verify failed for", addr_capture)
                end
            end)
        end, true)
    end

    if strategy.delay == 0 then
        self.reconnect_timer = do_reconnect
        UIManager:tickAfterNext(do_reconnect)
    else
        self.reconnect_timer = do_reconnect
        UIManager:scheduleIn(strategy.delay, do_reconnect)
    end
end

-- ── Plugin lifecycle ─────────────────────────────────────────────────────────

function BluetoothPlugin:init()
    logger.info("BluetoothPlugin: init (MTK device confirmed)")

    -- startup auto-connect (if enabled and BT is already on from previous session)
    if self:_getSetting("startup_reconnect", true) then
        if btIsEnabled() then
            logger.info("BluetoothPlugin: BT already on at startup, scheduling reconnect")
            -- Small delay so UI is ready
            UIManager:scheduleIn(3, function()
                self:_scheduleReconnect()
            end)
        end
    end

    -- If BT is on at startup, prevent standby immediately
    if btIsEnabled() then
        self:_preventStandby()
    end
end

function BluetoothPlugin:onSuspend()
    -- Called by KOReader BEFORE writing /sys/power/state = mem.
    -- MTK rule: DO NOT suspend while BT or any async enable is in flight.
    logger.dbg("BluetoothPlugin: onSuspend")

    -- Abort any in-flight async enable so its poll loop exits cleanly
    self.bt_enable_pending = false

    self.bt_was_on_before_suspend = btIsEnabled()
    self:_cancelReconnectTimer()

    if self.bt_was_on_before_suspend then
        logger.info("BluetoothPlugin: BT on → turning off before deep sleep")
        self:_disableBT(false)
    end
    -- _disableBT already calls _allowStandby; guard the else-path too:
    self:_allowStandby()
end

function BluetoothPlugin:onResume()
    -- Called AFTER kernel woke up
    logger.dbg("BluetoothPlugin: onResume, bt_was_on=", self.bt_was_on_before_suspend)

    if not self.bt_was_on_before_suspend then
        return
    end

    if not self:_getSetting("auto_resume_bt", true) then
        logger.dbg("BluetoothPlugin: auto_resume_bt disabled")
        return
    end

    -- Re-enable BT asynchronously, then schedule reconnect
    self:_enableBT(true, function()
        self:_scheduleReconnect()
    end)
end

-- ── Main menu entry ──────────────────────────────────────────────────────────

function BluetoothPlugin:addToMainMenu(menu_items)
    menu_items.bluetooth = {
        text = _("Bluetooth"),
        sub_item_table = self:_buildMenu(),
    }
end

function BluetoothPlugin:_buildMenu()
    return {
        -- ── Toggle ───────────────────────────────────────────────────
        {
            text_func = function()
                return btIsEnabled()
                    and _("Bluetooth: ON  (tap to disable)")
                    or  _("Bluetooth: OFF (tap to enable)")
            end,
            checked_func = function() return btIsEnabled() end,
            callback = function(touchmenu_instance)
                if btIsEnabled() then
                    UIManager:show(ConfirmBox:new{
                        text    = _("Disable Bluetooth?"),
                        ok_text = _("Disable"),
                        ok_callback = function()
                            self:_disableBT(true)
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text    = _("Enabling Bluetooth…"),
                        timeout = 2,
                    })
                    self:_enableBT(false, function()
                        UIManager:show(InfoMessage:new{
                            text    = _("Bluetooth enabled."),
                            timeout = 2,
                        })
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end)
                end
            end,
        },
        -- ── Scan ─────────────────────────────────────────────────────
        {
            text = _("Scan for devices…"),
            enabled_func = function() return btIsEnabled() end,
            callback = function()
                self:_doScan()
            end,
        },
        -- ── Paired devices ───────────────────────────────────────────
        {
            text = _("Known / paired devices…"),
            enabled_func = function() return btIsEnabled() end,
            callback = function()
                self:_showKnownDevices()
            end,
        },
        -- separator
        { text = "───", callback = function() end, enabled_func = function() return false end },
        -- ── Settings sub-menu ────────────────────────────────────────
        {
            text = _("Bluetooth settings"),
            -- sub_item_table_func rebuilds on each open so checked_func stays fresh
            sub_item_table_func = function() return self:_buildSettingsMenu() end,
        },
        -- ── Debug sub-menu ────────────────────────────────────────────
        {
            text = _("Debug / reconnect strategy"),
            sub_item_table_func = function() return self:_buildDebugMenu() end,
        },
    }
end

-- ── Scan ─────────────────────────────────────────────────────────────────────

function BluetoothPlugin:_doScan()
    UIManager:show(InfoMessage:new{
        text    = _("Scanning for Bluetooth devices (10 s)…"),
        timeout = 1,
    })

    -- Discovery runs in a subprocess (StartDiscovery blocks for 10 s).
    -- double_fork=true so the child is reparented to init automatically.
    -- The completion callback fires in the main process once the child exits,
    -- then we read the device list via GetManagedObjects.
    ffiutil.runInSubProcess(function()
        -- child: start discovery, wait 10 s, stop
        btStartScan()
        ffiutil.sleep(10)
        btStopScan()
    end, function()
        -- main process: subprocess finished → read and display results
        local devices = btGetDevices()
        self.scan_devices = devices
        self:_showScanResults(devices)
    end, true)
end

function BluetoothPlugin:_showScanResults(devices)
    if not devices or #devices == 0 then
        UIManager:show(InfoMessage:new{
            text    = _("No Bluetooth devices found nearby."),
            timeout = 3,
        })
        return
    end

    local items = {}
    for _, dev in ipairs(devices) do
        local status = ""
        if dev.connected then
            status = " ✓"
        elseif dev.paired then
            status = " (paired)"
        end
        local d = dev  -- capture
        table.insert(items, {
            text = (dev.name or dev.address) .. status,
            callback = function()
                self:_deviceAction(d)
            end,
        })
    end

    local menu = Menu:new{
        title   = _("Scan results — select to connect/disconnect"),
        item_table = items,
        width   = math.floor(Screen:getWidth() * 0.9),
        height  = math.floor(Screen:getHeight() * 0.7),
    }
    UIManager:show(menu)
end

function BluetoothPlugin:_deviceAction(dev)
    if dev.connected then
        UIManager:show(ConfirmBox:new{
            text    = _("Disconnect from ") .. (dev.name or dev.address) .. "?",
            ok_text = _("Disconnect"),
            ok_callback = function()
                btDisconnect(dev.address)
                UIManager:show(InfoMessage:new{
                    text    = _("Disconnected."),
                    timeout = 2,
                })
            end,
        })
    else
        UIManager:show(InfoMessage:new{
            text    = _("Connecting to ") .. (dev.name or dev.address) .. "…",
            timeout = 1,
        })
        UIManager:tickAfterNext(function()
            local ok = btConnect(dev.address)
            if ok then
                -- remember this as last connected
                self:_setSetting("last_connected_address", dev.address)
                self:_setSetting("last_connected_name",    dev.name or dev.address)
                UIManager:show(InfoMessage:new{
                    text    = _("Connected to ") .. (dev.name or dev.address),
                    timeout = 3,
                })
            else
                UIManager:show(InfoMessage:new{
                    text    = _("Connection failed."),
                    timeout = 3,
                })
            end
        end)
    end
end

-- ── Known/paired devices ──────────────────────────────────────────────────────

function BluetoothPlugin:_showKnownDevices()
    local devices = btGetDevices()
    local paired  = {}
    for _, d in ipairs(devices) do
        if d.paired then table.insert(paired, d) end
    end

    if #paired == 0 then
        UIManager:show(InfoMessage:new{
            text    = _("No paired devices found."),
            timeout = 3,
        })
        return
    end

    local items = {}
    for _, dev in ipairs(paired) do
        local status = dev.connected and " ✓ connected" or " (not connected)"
        local d = dev
        table.insert(items, {
            text = (dev.name or dev.address) .. status,
            callback = function()
                self:_deviceAction(d)
            end,
        })
    end

    local menu = Menu:new{
        title      = _("Paired devices"),
        item_table = items,
        width      = math.floor(Screen:getWidth() * 0.9),
        height     = math.floor(Screen:getHeight() * 0.7),
    }
    UIManager:show(menu)
end

-- ── Settings menu ─────────────────────────────────────────────────────────────

function BluetoothPlugin:_buildSettingsMenu()
    return {
        {
            text = _("Auto-resume Bluetooth after wake"),
            checked_func = function()
                return self:_getSetting("auto_resume_bt", true)
            end,
            callback = function()
                local v = self:_getSetting("auto_resume_bt", true)
                self:_setSetting("auto_resume_bt", not v)
            end,
        },
        {
            text = _("Connect to last device on startup"),
            checked_func = function()
                return self:_getSetting("startup_reconnect", true)
            end,
            callback = function()
                local v = self:_getSetting("startup_reconnect", true)
                self:_setSetting("startup_reconnect", not v)
            end,
        },
        {
            text_func = function()
                local addr = self:_getSetting("last_connected_address")
                local name = self:_getSetting("last_connected_name")
                if addr then
                    return _("Last device: ") .. (name or addr)
                end
                return _("Last device: (none)")
            end,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text    = _("Forget last connected device?"),
                    ok_text = _("Forget"),
                    ok_callback = function()
                        self:_setSetting("last_connected_address", nil)
                        self:_setSetting("last_connected_name",    nil)
                    end,
                })
            end,
        },
    }
end

-- ── Debug / reconnect strategy menu ──────────────────────────────────────────

function BluetoothPlugin:_buildDebugMenu()
    local items = {}

    -- ── Strategy chooser sub-menu ────────────────────────────────────────
    -- Each entry shows the strategy label plus a brief description of
    -- which D-Bus / syscalls it uses, so the user can make an informed choice.
    local strategy_items = {}
    for _, s in ipairs(RECONNECT_STRATEGIES) do
        local sid   = s.id    -- capture
        local slabel = s.label
        local sdesc  = s.desc or ""
        table.insert(strategy_items, {
            text = slabel,
            checked_func = function()
                return self:_getSetting("reconnect_strategy", DEFAULT_STRATEGY_ID) == sid
            end,
            radio = true,
            callback = function()
                self:_setSetting("reconnect_strategy", sid)
                -- Show the description so the user knows what they selected
                UIManager:show(InfoMessage:new{
                    text    = slabel .. "\n\n" .. sdesc,
                    timeout = 5,
                })
            end,
        })
    end

    table.insert(items, {
        text = _("Reconnect strategy (on resume / startup)"),
        sub_item_table = strategy_items,
    })

    -- ── Strategy info ────────────────────────────────────────────────────
    table.insert(items, {
        text = _("About current strategy…"),
        callback = function()
            local sid = self:_getSetting("reconnect_strategy", DEFAULT_STRATEGY_ID)
            local s   = strategyById(sid)
            UIManager:show(InfoMessage:new{
                text    = s.label .. "\n\n" .. (s.desc or _("(no description)")),
                timeout = 8,
            })
        end,
    })

    -- ── Manual reconnect now using current strategy ──────────────────────
    table.insert(items, {
        text = _("Reconnect now (use current strategy)"),
        enabled_func = function() return btIsEnabled() end,
        callback = function()
            local addr = self:_getSetting("last_connected_address")
            if not addr then
                UIManager:show(InfoMessage:new{
                    text    = _("No known device to reconnect to."),
                    timeout = 2,
                })
                return
            end
            local sid = self:_getSetting("reconnect_strategy", DEFAULT_STRATEGY_ID)
            local s   = strategyById(sid)
            if not s.exec then
                UIManager:show(InfoMessage:new{
                    text    = _("Strategy 'manual' selected — no auto-reconnect.\nChange strategy first."),
                    timeout = 3,
                })
                return
            end
            local name = self:_getSetting("last_connected_name") or addr
            UIManager:show(InfoMessage:new{
                text    = _("Reconnecting to ") .. name .. "\n" .. _("Strategy: ") .. s.label,
                timeout = 2,
            })
            local addr_c = addr
            local exec_c = s.exec
            UIManager:tickAfterNext(function()
                ffiutil.runInSubProcess(function()
                    exec_c(addr_c)
                end, function()
                    UIManager:scheduleIn(0.5, function()
                        local devices = btGetDevices()
                        local connected = false
                        for _, d in ipairs(devices) do
                            if d.address:lower() == addr_c:lower() and d.connected then
                                connected = true; break
                            end
                        end
                        UIManager:show(InfoMessage:new{
                            text    = connected and _("Reconnected!") or _("Reconnect failed."),
                            timeout = 3,
                        })
                    end)
                end, true)
            end)
        end,
    })

    -- ── Status dump ──────────────────────────────────────────────────────
    table.insert(items, {
        text = _("Show BT status (debug info)"),
        callback = function()
            local on    = btIsEnabled()
            local addr  = self:_getSetting("last_connected_address") or "—"
            local name  = self:_getSetting("last_connected_name")    or "—"
            local sid   = self:_getSetting("reconnect_strategy", DEFAULT_STRATEGY_ID)
            local s     = strategyById(sid)
            local was   = self.bt_was_on_before_suspend and "yes" or "no"
            local sp    = self.standby_prevented        and "yes" or "no"
            local wifi  = NetworkMgr:isWifiOn()         and "ON"  or "OFF"
            UIManager:show(InfoMessage:new{
                text = string.format(
                    "BT adapter  : %s\n"
                    .. "Standby blocked: %s\n"
                    .. "Was on at suspend: %s\n"
                    .. "WiFi now    : %s\n"
                    .. "Last device : %s\n"
                    .. "            (%s)\n"
                    .. "Strategy    : %s",
                    on and "ON" or "OFF", sp, was, wifi, name, addr, s.label
                ),
                timeout = 10,
            })
        end,
    })

    -- ── Force BT off (emergency) ─────────────────────────────────────────
    table.insert(items, {
        text = _("Force BT OFF (emergency)"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text    = _("Force-disable Bluetooth immediately?\n"
                          .. "This runs BluedroidManager1.Off and allows standby."),
                ok_text = _("Force OFF"),
                ok_callback = function()
                    btTurnOff()
                    self:_allowStandby()
                    self.bt_was_on_before_suspend = false
                    UIManager:show(InfoMessage:new{
                        text    = _("Bluetooth force-disabled."),
                        timeout = 2,
                    })
                end,
            })
        end,
    })

    return items
end

return BluetoothPlugin
