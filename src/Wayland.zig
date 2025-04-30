const std = @import("std");
const AppMenu = @import("AppMenu.zig");
const mem = std.mem;

const log = std.log.scoped(.wayland);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const ext = wayland.client.ext;
const org = wayland.client.org;

const Event = union(enum) {
    idle_state: enum { idle, active },
};

fn FixedRingBuffer(size: usize) type {
    return struct {
        data: [size]Event = undefined,
        read_index: usize = 0,
        write_index: usize = 0,

        const FRBSelf = @This();
        pub const empty: FRBSelf = .{
            .data = undefined,
            .read_index = 0,
            .write_index = 0,
        };

        pub fn isEmpty(self: *FRBSelf) bool {
            return self.read_index == self.write_index;
        }

        pub fn isFull(self: *FRBSelf) bool {
            return (self.write_index + 1) % size == self.read_index;
        }

        pub fn read(self: *FRBSelf) ?Event {
            if (self.isEmpty()) {
                return null;
            }
            const event = self.data[self.read_index];
            self.read_index = (self.read_index + 1) % size;
            return event;
        }
        pub fn write(self: *FRBSelf, event: Event) !void {
            if (self.isFull()) {
                return error.WaylandRingBufferFull;
            }
            self.data[self.write_index] = event;
            self.write_index = (self.write_index + 1) % size;
        }
    };
}

display: *wl.Display,
shm: *wl.Shm,
compositor: *wl.Compositor,
wm_base: *xdg.WmBase,
seat: *wl.Seat,
idle_notifier: *ext.IdleNotifierV1,
idle_notification: *ext.IdleNotificationV1,
app_menu: ?*org.KdeKwinAppmenu = null,
surface: *wl.Surface,
events: FixedRingBuffer(32) = .empty,
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
    self.events = .empty;
    self.display = try wl.Display.connect(null);
    const registry = try self.display.getRegistry();
    var context = Context{};

    registry.setListener(*Context, registryListener, &context);
    if (self.display.roundtrip() != .SUCCESS) return error.WaylandInitializationFailed;

    self.compositor = context.compositor orelse return error.WaylandNoCompositor;
    self.wm_base = context.wm_base orelse return error.WaylandNoWmBase;
    self.seat = context.seat orelse return error.WaylandNoSeat;
    self.idle_notifier = context.idle_notifier orelse return error.WaylandNoIdleNotifier;
    const min_idle_timeout = 1000 * 60 * 5; // 5 minutes in msecs
    self.idle_notification = try self.idle_notifier.getIdleNotification(min_idle_timeout, self.seat);
    self.idle_notification.setListener(*Self, idleListener, self);

    self.shm = context.shm orelse return error.WaylandNoShm;
    self.surface = try self.compositor.createSurface();
    if (context.kwin_app_menu) |app_menu_manager| {
        self.app_menu = try app_menu_manager.create(self.surface);
        self.app_menu.?.setAddress(AppMenu.name, AppMenu.path);
    } else {
        self.app_menu = null;
    }
}

pub fn deinit(self: *Self) void {
    if (self.app_menu) |app_menu| {
        app_menu.release();
    }
    self.surface.destroy();
    self.idle_notification.destroy();
    self.idle_notifier.destroy();
}

pub fn dispatch(self: *Self) !?Event {
    if (!self.events.isEmpty()) {
        return self.events.read();
    }

    const cb = try self.display.sync();
    defer cb.destroy();

    var done = false;
    cb.setListener(*bool, doneListener, &done);

    while (!done) {
        const result = self.display.dispatch();
        if (result != .SUCCESS) {
            return error.WaylandDispatchFailed;
        }
    }

    return null;
}

fn doneListener(_: *wl.Callback, event: wl.Callback.Event, context: *bool) void {
    switch (event) {
        .done => {
            context.* = true;
        },
    }
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

fn idleListener(notification: *ext.IdleNotificationV1, event: ext.IdleNotificationV1.Event, context: *Self) void {
    _ = notification;

    const new_state = switch (event) {
        .idled => Event{
            .idle_state = .idle,
        },
        .resumed => Event{
            .idle_state = .active,
        },
    };
    context.events.write(new_state) catch {
        log.err("Failed to write event to ring buffer", .{});
        std.posix.exit(12);
    };
}
