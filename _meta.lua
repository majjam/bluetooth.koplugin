-- Plugin metadata for bluetooth.koplugin
return {
    name        = "bluetooth",
    fullname    = "",
    description = [[BlueBluetooth Managertooth enable/disable, device scan, connect/disconnect,
WiFi-coexistence handling, and suspend/resume power management
for MTK-based Kobo/Tolino devices (e.g. Tolino Shine 5, Clara BW platform).]],
    -- Only loaded on MTK Kobo devices (guard is in main.lua)
    is_doc_only = false,
}
