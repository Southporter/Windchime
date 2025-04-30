const std = @import("std");
const IPC = @import("IPC.zig");
const AppMenu = @import("AppMenu.zig");
const Notification = @import("Notification.zig");
const Wayland = @import("Wayland.zig");
const dbus = @import("dbus.zig");
const log = std.log.scoped(.main);

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("Memory leak detected\n", .{});
        }
    }
    const allocator = gpa.allocator();

    var ipc: IPC = undefined;
    try ipc.init(allocator, "com.codeberg.southporter.Windchime", "/com/codeberg/southporter/Windchime");
    defer ipc.deinit();

    // var notifier: Notifier = undefined;
    // try notifier.init(allocator, session);
    // notifier.app_name = "Windchime";
    // defer notifier.deinit();
    // try notifier.getCapabilities();
    //
    // var menu: AppMenu = undefined;
    // try menu.init(session);
    // defer menu.deinit(session);
    //
    var wayland: Wayland = undefined;
    try wayland.init();
    defer wayland.deinit();

    const startup_notification = Notification{ .summary = "Windchime Starting", .body = "Windchime is starting up", .actions = &[0][*]const u8{}, .urgency = .normal };
    _ = ipc.notify(startup_notification) catch |err| {
        log.warn("Failed to send startup notification: {any}", .{err});
    };

    const notification = Notification{
        .summary = "Time to take a break",
        .body = "Try looking at something 20 feet away for 20 seconds",
        .actions = &[_][*]const u8{
            "skip",
            "Skip this break",
            "delay",
            "Delay this break",
        },
        .urgency = .normal,
    };

    const interlude: i64 = 60 * 20; // 20 minutes
    var end = std.time.timestamp() + interlude;
    var activation_token: ?[:0]const u8 = null;
    while (true) {
        const current = std.time.timestamp();
        if (current >= end) {
            log.debug("Time to take a break", .{});
            _ = try ipc.notify(notification);
            end = current + interlude;
        }
        var signal = try ipc.dispatch();
        while (signal) |sig| {
            log.debug("Received signal: {s}", .{@tagName(sig.tag)});
            switch (sig.tag) {
                .action_invoked => {
                    const kind = sig.data.action;
                    defer allocator.free(kind);
                    if (std.mem.eql(u8, kind, "skip")) {
                        log.debug("Skipping break", .{});

                        end = current + interlude;
                    } else if (std.mem.eql(u8, kind, "delay")) {
                        log.debug("Delaying break by 2 minutes", .{});
                        end += 60 * 2;
                    }
                },
                .notification_closed => {
                    log.debug("Notification closed", .{});

                    // Start Break sequence
                    if (activation_token) |token| {
                        allocator.free(token);
                    }
                    activation_token = null;
                },
                .activation_token => {
                    log.debug("Activation token received: {s}", .{sig.data.activation_token});
                    activation_token = sig.data.activation_token;
                },
            }

            signal = try ipc.dispatch();
        }
        var event = try wayland.dispatch();
        while (event) |e| {
            log.debug("Received Wayland event: {any}", .{e});
            switch (e) {
                .idle_state => |state| {
                    if (state == .active) {
                        log.debug("Wayland is active", .{});
                        end = current + interlude;
                    } else {
                        log.debug("Wayland is idle", .{});
                        end = std.math.maxInt(i64);
                    }
                },
            }
            event = try wayland.dispatch();
        }

        std.time.sleep(1 * std.time.ns_per_s);
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
