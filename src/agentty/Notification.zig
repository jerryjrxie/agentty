//! Notification handles desktop and in-app notifications.
//!
//! Provides:
//!   - Desktop notification sending
//!   - Notification queue for in-app display
//!   - Rate limiting to prevent notification spam

const Notification = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");

/// Notification priority levels
pub const Priority = enum {
    low,
    normal,
    high,
    urgent,

    pub fn toUrgency(self: Priority) []const u8 {
        return switch (self) {
            .low => "low",
            .normal => "normal",
            .high => "critical",
            .urgent => "critical",
        };
    }
};

/// A notification message
pub const Message = struct {
    title: []const u8,
    body: []const u8,
    priority: Priority,
    session_id: ?u64,
    timestamp: i128,
    read: bool,

    pub fn create(alloc: Allocator, title: []const u8, body: []const u8, priority: Priority, session_id: ?u64) !*Message {
        const msg = try alloc.create(Message);
        errdefer alloc.destroy(msg);

        msg.* = .{
            .title = try alloc.dupe(u8, title),
            .body = try alloc.dupe(u8, body),
            .priority = priority,
            .session_id = session_id,
            .timestamp = std.time.nanoTimestamp(),
            .read = false,
        };

        return msg;
    }

    pub fn destroy(self: *Message, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
        alloc.destroy(self);
    }
};

/// Notification queue
queue: std.ArrayList(*Message),

/// Last notification time for rate limiting
last_notification_time: ?std.time.Instant,

/// Minimum interval between notifications (in nanoseconds)
min_interval_ns: u64,

/// Whether desktop notifications are enabled
desktop_enabled: bool,

/// Allocator
alloc: Allocator,

/// Create a new notification manager
pub fn init(alloc: Allocator, desktop_enabled: bool) Notification {
    return .{
        .queue = std.ArrayList(*Message).init(alloc),
        .last_notification_time = null,
        .min_interval_ns = 500 * std.time.ns_per_ms, // 500ms minimum between notifications
        .desktop_enabled = desktop_enabled,
        .alloc = alloc,
    };
}

/// Destroy the notification manager
pub fn deinit(self: *Notification) void {
    for (self.queue.items) |msg| {
        msg.destroy(self.alloc);
    }
    self.queue.deinit();
}

/// Send a notification
pub fn notify(
    self: *Notification,
    title: []const u8,
    body: []const u8,
    priority: Priority,
    session_id: ?u64,
) !void {
    // Create and queue the message
    const msg = try Message.create(self.alloc, title, body, priority, session_id);
    try self.queue.append(msg);

    // Send desktop notification if enabled and not rate limited
    if (self.desktop_enabled and self.shouldSendDesktop()) {
        try self.sendDesktopNotification(title, body, priority);
        self.last_notification_time = std.time.Instant.now() catch null;
    }
}

/// Notify that a session needs attention
pub fn notifyAttention(self: *Notification, session: *const Session) !void {
    const title = try std.fmt.allocPrint(self.alloc, "Agent needs attention", .{});
    defer self.alloc.free(title);

    const body = try std.fmt.allocPrint(self.alloc, "{s} is waiting for input", .{session.name});
    defer self.alloc.free(body);

    try self.notify(title, body, .high, session.id);
}

/// Notify that a session completed
pub fn notifyCompletion(self: *Notification, session: *const Session) !void {
    const title = try std.fmt.allocPrint(self.alloc, "Agent completed", .{});
    defer self.alloc.free(title);

    const body = try std.fmt.allocPrint(self.alloc, "{s} has finished", .{session.name});
    defer self.alloc.free(body);

    try self.notify(title, body, .normal, session.id);
}

/// Notify that a session failed
pub fn notifyError(self: *Notification, session: *const Session, error_msg: []const u8) !void {
    const title = try std.fmt.allocPrint(self.alloc, "Agent error", .{});
    defer self.alloc.free(title);

    const body = try std.fmt.allocPrint(self.alloc, "{s}: {s}", .{ session.name, error_msg });
    defer self.alloc.free(body);

    try self.notify(title, body, .urgent, session.id);
}

/// Check if we should send a desktop notification (rate limiting)
fn shouldSendDesktop(self: *const Notification) bool {
    if (self.last_notification_time) |last| {
        const now = std.time.Instant.now() catch return true;
        const elapsed = now.since(last);
        return elapsed >= self.min_interval_ns;
    }
    return true;
}

/// Send a desktop notification using notify-send (Linux) or osascript (macOS)
fn sendDesktopNotification(
    self: *Notification,
    title: []const u8,
    body: []const u8,
    priority: Priority,
) !void {
    _ = self;

    // Try notify-send first (Linux)
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{
            "notify-send",
            "--urgency",
            priority.toUrgency(),
            "--app-name",
            "Agentty",
            title,
            body,
        },
    }) catch |err| switch (err) {
        error.FileNotFound => {
            // notify-send not found, try osascript (macOS)
            const script = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "display notification \"{s}\" with title \"{s}\"",
                .{ body, title },
            );
            defer std.heap.page_allocator.free(script);

            _ = std.process.Child.run(.{
                .allocator = std.heap.page_allocator,
                .argv = &.{ "osascript", "-e", script },
            }) catch return;
            return;
        },
        else => return err,
    };

    std.heap.page_allocator.free(result.stdout);
    std.heap.page_allocator.free(result.stderr);
}

/// Get unread notification count
pub fn unreadCount(self: *const Notification) usize {
    var count: usize = 0;
    for (self.queue.items) |msg| {
        if (!msg.read) count += 1;
    }
    return count;
}

/// Mark all notifications as read
pub fn markAllRead(self: *Notification) void {
    for (self.queue.items) |msg| {
        msg.read = true;
    }
}

/// Get notifications for a specific session
pub fn getForSession(self: *const Notification, session_id: u64, alloc: Allocator) ![]*Message {
    var result = std.ArrayList(*Message).init(alloc);
    for (self.queue.items) |msg| {
        if (msg.session_id) |id| {
            if (id == session_id) {
                try result.append(msg);
            }
        }
    }
    return result.toOwnedSlice();
}

/// Clear old notifications (older than max_age_ns)
pub fn clearOld(self: *Notification, max_age_ns: i128) void {
    const now = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < self.queue.items.len) {
        const msg = self.queue.items[i];
        if (now - msg.timestamp > max_age_ns) {
            msg.destroy(self.alloc);
            _ = self.queue.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

test "Notification basic operations" {
    const alloc = std.testing.allocator;

    var notif = Notification.init(alloc, false);
    defer notif.deinit();

    try notif.notify("Test", "Test body", .normal, null);
    try std.testing.expectEqual(@as(usize, 1), notif.queue.items.len);
    try std.testing.expectEqual(@as(usize, 1), notif.unreadCount());

    notif.markAllRead();
    try std.testing.expectEqual(@as(usize, 0), notif.unreadCount());
}
