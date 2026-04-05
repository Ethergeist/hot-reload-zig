const Plugin = @import("plugin").Plugin;

var instance: *Plugin = undefined;

pub export fn startup(plugin: *Plugin) callconv(.c) c_int {
    // Only the startup function really needs the plugin parameter
    // It is included in Plugin.Hook just to give the hooks a
    // consistent interface - here we save a pointer to the
    // plugin as it started up, and we can use it in the other
    // functions
    instance = plugin;
    plugin.log.info("plugin-test startup: {s}", .{plugin.name});
    return 0;
}

pub export fn shutdown(_: *Plugin) callconv(.c) c_int {
    instance.log.info("plugin-test shutdown: {s}", .{instance.name});
    return 0;
}

pub export fn update(_: *Plugin) callconv(.c) c_int {
    instance.log.info("plugin-test updated.", .{});
    return 0;
}

// Validate the exports are valid Plugin.Hook function pointers at compile time
comptime {
    const startupHook: Plugin.Hook = &startup;
    _ = startupHook;
    const shutdownHook: Plugin.Hook = &startup;
    _ = shutdownHook;
    const updateHook: Plugin.Hook = &startup;
    _ = updateHook;
}
