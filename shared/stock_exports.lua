-- An export of whip_chat's that stock chat also has, answered under both names: exports.whip_chat:<name> and
-- exports.chat:<name>. `provide 'chat'` lets a resource with `dependency 'chat'` start, but does not carry exports,
-- so the `chat` name is answered here through FiveM's own export event (__cfx_export_<resource>_<name>), as
-- oxmysql does for mysql-async.
function ExportAsStockChat(name, fn)
    exports(name, fn)
    AddEventHandler(('__cfx_export_chat_%s'):format(name), function(setCB) setCB(fn) end)
end
