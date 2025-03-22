const std = @import("std");
const AppMenu = @import("AppMenu.zig");
const mem = std.mem;

const log = std.log.scoped(.wayland);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const ext = wayland.client.ext;
const org = wayland.client.org;

display: *wl.Display,
shm: *wl.Shm,
compositor: *wl.Compositor,
wm_base: *xdg.WmBase,
seat: *wl.Seat,
idle_notifier: *ext.IdleNotifierV1,
app_menu: *org.KdeKwinAppmenu,
surface: *wl.Surface,
const Self = @This();

const Context = struct {
    shm: ?*wl.Shm = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    seat: ?*wl.Seat = null,
    idle_notifier: ?*ext.IdleNotifierV1 = null,
    kwin_app_menu: ?*org.KdeKwinAppmenuManager = null,
};

pub fn init(self: *Self) !void {
    self.display = try wl.Display.connect(null);
    const registry = try self.display.getRegistry();
    var context = Context{};

    registry.setListener(*Context, registryListener, &context);
    if (self.display.roundtrip() != .SUCCESS) return error.WaylandInitializationFailed;

    self.compositor = context.compositor orelse return error.WaylandNoCompositor;
    self.wm_base = context.wm_base orelse return error.WaylandNoWmBase;
    self.seat = context.seat orelse return error.WaylandNoSeat;
    self.idle_notifier = context.idle_notifier orelse return error.WaylandNoIdleNotifier;
    self.shm = context.shm orelse return error.WaylandNoShm;
    self.surface = try self.compositor.createSurface();
    const app_menu_manager = context.kwin_app_menu orelse return error.WaylandNoAppMenuManager;
    // defer app_menu_manager.release();

    self.app_menu = try app_menu_manager.create(self.surface);
    self.app_menu.setAddress(AppMenu.name, AppMenu.path);
}

pub fn deinit(self: *Self) void {
    self.app_menu.release();
    self.surface.destroy();
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                context.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                context.seat = registry.bind(global.name, wl.Seat, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, ext.IdleNotifierV1.interface.name) == .eq) {
                context.idle_notifier = registry.bind(global.name, ext.IdleNotifierV1, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, org.KdeKwinAppmenuManager.interface.name) == .eq) {
                context.kwin_app_menu = registry.bind(global.name, org.KdeKwinAppmenuManager, 1) catch return;
            }
        },
        .global_remove => |global| {
            log.warn("Global removed: {}", .{global.name});
        },
    }
}
