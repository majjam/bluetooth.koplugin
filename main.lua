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

local ConfirmBox   = require("ui/widget/confirmbox")
local DataStorage  = require("datastorage")
local InfoMessage  = require("ui/widget/infomessage")
local LuaSettings  = require("luasettings")
local Menu         = require("ui/widget/menu")
local NetworkMgr   = require("ui/network/manager")
local UIManager    = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil      = require("ffi/util")
local logger       = require("logger")
local _            = require("gettext")

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

--- Delay in seconds before first reconnect attempt on resume
local RECONNECT_STRATEGIES = {
    {
        id    = "immediate",
        label = _("Immediately (0 s delay)"),
        delay = 0,
    },
    {
        id    = "short",
        label = _("Short delay (2 s)"),
        delay = 2,
    },
    {
        id    = "medium",
        label = _("Medium delay (5 s)"),
        delay = 5,
    },
    {
        id    = "long",
        label = _("Long delay (10 s)"),
        delay = 10,
    },
    {
        id    = "manual",
        label = _("Manual only (no auto-reconnect)"),
        delay = -1,   -- sentinel: never auto-reconnect
    },
}

local DEFAULT_STRATEGY_ID = "short"

local function strategyById(id)
    for _, s in ipairs(RECONNECT_STRATEGIES) do
        if s.id == id then return s end
    end
    return RECONNECT_STRATEGIES[2] -- fallback: short
end

-- ── Plugin definition ────────────────────────────────────────────────────────

local BluetoothPlugin = WidgetContainer:extend{
    name            = "bluetooth",
    is_doc_only     = false,

    -- runtime state
    bt_was_on_before_suspend = false,
    wifi_was_on_snapshot     = false,
    standby_prevented        = false,
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

    -- MTK BT needs WiFi stack up for coexistence firmware init
    if not NetworkMgr:isWifiOn() then
        NetworkMgr:restoreWifiAsync()
    end

    -- Kick BT-ON in a subprocess so we don't block UIManager
    UIManager:tickAfterNext(function()
        ffiutil.runInSubProcess(function()
            btTurnOn()
        end, false, true)

        -- Poll until enabled (max 3 seconds, 100 ms intervals)
        local function poll(n)
            if btIsEnabled() then
                logger.info("BluetoothPlugin: BT enabled")
                self:_restoreWifi(is_resume)
                if on_done then on_done() end
                return
            end
            if n >= 30 then
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

--- Attempt to reconnect to the last known device.
--- Uses the user-selected reconnect strategy (delay from settings).
function BluetoothPlugin:_scheduleReconnect()
    local strategy_id = self:_getSetting("reconnect_strategy", DEFAULT_STRATEGY_ID)
    local strategy    = strategyById(strategy_id)

    if strategy.delay < 0 then
        logger.dbg("BluetoothPlugin: reconnect strategy = manual, skipping")
        return
    end

    local last_addr = self:_getSetting("last_connected_address", nil)

    self:_cancelReconnectTimer()

    local function do_reconnect()
        self.reconnect_timer = nil
        if not btIsEnabled() then
            logger.warn("BluetoothPlugin: BT not enabled at reconnect time, aborting")
            return
        end
        if not last_addr then
            logger.dbg("BluetoothPlugin: no last_connected_address, skipping reconnect")
            return
        end
        logger.info("BluetoothPlugin: reconnecting to", last_addr, "strategy=", strategy.id)
        local ok = btConnect(last_addr)
        if ok then
            UIManager:show(InfoMessage:new{
                text    = _("Bluetooth reconnected."),
                timeout = 2,
            })
        else
            logger.warn("BluetoothPlugin: reconnect failed for", last_addr)
        end
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
    -- Called by KOReader BEFORE writing /sys/power/state = mem
    logger.dbg("BluetoothPlugin: onSuspend")
    self.bt_was_on_before_suspend = btIsEnabled()
    self:_cancelReconnectTimer()

    if self.bt_was_on_before_suspend then
        logger.info("BluetoothPlugin: BT on → turning off before deep sleep")
        self:_disableBT(false)
    end
    -- standby already released by _disableBT; if it was already off, just ensure:
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
    local enabled = btIsEnabled()
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
            sub_item_table = self:_buildSettingsMenu(),
        },
        -- ── Debug sub-menu ────────────────────────────────────────────
        {
            text = _("Debug / reconnect strategy"),
            sub_item_table = self:_buildDebugMenu(),
        },
    }
end

-- ── Scan ─────────────────────────────────────────────────────────────────────

function BluetoothPlugin:_doScan()
    UIManager:show(InfoMessage:new{
        text    = _("Scanning for Bluetooth devices (10 s)…"),
        timeout = 1,
    })

    -- Scan in subprocess so UI stays responsive
    local scan_done = false
    ffiutil.runInSubProcess(function()
        btStartScan()
        ffiutil.sleep(10)
        btStopScan()
    end, function()
        -- sub-process finished callback (called in main process)
        scan_done = true
    end, true)

    -- poll for scan completion, then show results
    local function poll_scan(n)
        if scan_done or n >= 120 then -- max 12 s
            local devices = btGetDevices()
            self.scan_devices = devices
            self:_showScanResults(devices)
            return
        end
        UIManager:scheduleIn(0.1, function() poll_scan(n + 1) end)
    end
    UIManager:scheduleIn(10.2, function()
        local devices = btGetDevices()
        self.scan_devices = devices
        self:_showScanResults(devices)
    end)
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

    -- Reconnect strategy chooser
    local strategy_items = {}
    for _, s in ipairs(RECONNECT_STRATEGIES) do
        local sid = s.id  -- capture
        table.insert(strategy_items, {
            text = s.label,
            checked_func = function()
                return self:_getSetting("reconnect_strategy", DEFAULT_STRATEGY_ID) == sid
            end,
            radio = true,
            callback = function()
                self:_setSetting("reconnect_strategy", sid)
                UIManager:show(InfoMessage:new{
                    text    = _("Reconnect strategy set to: ") .. s.label,
                    timeout = 2,
                })
            end,
        })
    end

    table.insert(items, {
        text = _("Reconnect strategy (on resume)"),
        sub_item_table = strategy_items,
    })

    -- Manual reconnect now
    table.insert(items, {
        text = _("Reconnect now (manual)"),
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
            UIManager:show(InfoMessage:new{
                text    = _("Reconnecting…"),
                timeout = 1,
            })
            UIManager:tickAfterNext(function()
                local ok = btConnect(addr)
                UIManager:show(InfoMessage:new{
                    text    = ok and _("Reconnected!") or _("Reconnect failed."),
                    timeout = 2,
                })
            end)
        end,
    })

    -- Status dump
    table.insert(items, {
        text = _("Show BT status (debug)"),
        callback = function()
            local on   = btIsEnabled()
            local addr = self:_getSetting("last_connected_address") or "—"
            local name = self:_getSetting("last_connected_name")    or "—"
            local strat = self:_getSetting("reconnect_strategy", DEFAULT_STRATEGY_ID)
            local was   = self.bt_was_on_before_suspend and "yes" or "no"
            local sp    = self.standby_prevented and "yes" or "no"
            UIManager:show(InfoMessage:new{
                text = string.format(
                    "BT: %s\nStandby prevented: %s\nWas on at suspend: %s\n"
                    .. "Reconnect strategy: %s\nLast device: %s (%s)",
                    on and "ON" or "OFF", sp, was, strat, name, addr
                ),
                timeout = 8,
            })
        end,
    })

    -- Force BT off (emergency)
    table.insert(items, {
        text = _("Force BT OFF (emergency)"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text    = _("Force-disable Bluetooth immediately?"),
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
