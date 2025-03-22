const std = @import("std");
const AppMenu = @import("AppMenu.zig");
const Notifier = @import("Notifier.zig");
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

    var err: dbus.Error = undefined;
    const session = try dbus.Connection.connect(.session, &err);
    // defer session.close() catch {};

    var notifier: Notifier = undefined;
    try notifier.init(allocator, session);
    notifier.app_name = "Windchime";
    defer notifier.deinit();
    try notifier.getCapabilities();

    var menu: AppMenu = undefined;
    try menu.init(session);
    defer menu.deinit(session);

    var wayland: Wayland = undefined;
    try wayland.init();
    defer wayland.deinit();

    const notification = Notifier.Notification{
        .summary = "Time to take a break",
        .body = "Try looking at something 20 feet away for 20 seconds",
        .actions = &[_][*]const u8{
            "skip",
            "Skip this break",
            "delay",
            "Delay this break",
        },
    };

    const interlude: i64 = 60;
    var end = std.time.timestamp() + interlude;
    var activation_token: ?[:0]const u8 = null;
    while (true) {
        const current = std.time.timestamp();
        if (current >= end) {
            log.debug("Time to take a break", .{});
            _ = try notifier.notify(notification, .normal);
            end = current + interlude;
        }
        var signal = try notifier.dispatch();
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

            signal = try notifier.dispatch();
        }
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
