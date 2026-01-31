//! SessionList manages a collection of agent sessions.
//!
//! Provides efficient lookup by ID, iteration, and filtering by status.

const SessionList = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");
const Config = @import("Config.zig");

/// Internal storage for sessions
sessions: std.AutoArrayHashMap(u64, *Session),

/// Allocator
alloc: Allocator,

/// Create a new session list
pub fn init(alloc: Allocator) SessionList {
    return .{
        .sessions = std.AutoArrayHashMap(u64, *Session).init(alloc),
        .alloc = alloc,
    };
}

/// Destroy the session list and all contained sessions
pub fn deinit(self: *SessionList) void {
    // Destroy all sessions
    for (self.sessions.values()) |session| {
        session.destroy();
    }
    self.sessions.deinit();
}

/// Add a session to the list
pub fn add(self: *SessionList, session: *Session) !void {
    try self.sessions.put(session.id, session);
}

/// Remove a session from the list by ID
pub fn remove(self: *SessionList, id: u64) ?*Session {
    if (self.sessions.fetchSwapRemove(id)) |entry| {
        return entry.value;
    }
    return null;
}

/// Get a session by ID
pub fn get(self: *const SessionList, id: u64) ?*Session {
    return self.sessions.get(id);
}

/// Check if a session exists
pub fn contains(self: *const SessionList, id: u64) bool {
    return self.sessions.contains(id);
}

/// Get the number of sessions
pub fn count(self: *const SessionList) usize {
    return self.sessions.count();
}

/// Check if empty
pub fn isEmpty(self: *const SessionList) bool {
    return self.sessions.count() == 0;
}

/// Get all sessions as a slice
pub fn all(self: *const SessionList) []*Session {
    return self.sessions.values();
}

/// Iterator for sessions
pub const Iterator = struct {
    inner: std.AutoArrayHashMap(u64, *Session).Iterator,

    pub fn next(self: *Iterator) ?*Session {
        if (self.inner.next()) |entry| {
            return entry.value_ptr.*;
        }
        return null;
    }
};

/// Get an iterator over all sessions
pub fn iterator(self: *const SessionList) Iterator {
    return .{ .inner = self.sessions.iterator() };
}

/// Count sessions by status
pub fn countByStatus(self: *const SessionList, status: Session.Status) usize {
    var count_val: usize = 0;
    for (self.sessions.values()) |session| {
        if (session.status == status) {
            count_val += 1;
        }
    }
    return count_val;
}

/// Get all active sessions
pub fn getActive(self: *const SessionList, alloc: Allocator) ![]*Session {
    var active = std.ArrayList(*Session).init(alloc);
    errdefer active.deinit();

    for (self.sessions.values()) |session| {
        if (session.status.isActive()) {
            try active.append(session);
        }
    }

    return active.toOwnedSlice();
}

/// Get all sessions waiting for input
pub fn getWaiting(self: *const SessionList, alloc: Allocator) ![]*Session {
    var waiting = std.ArrayList(*Session).init(alloc);
    errdefer waiting.deinit();

    for (self.sessions.values()) |session| {
        if (session.status == .waiting_input) {
            try waiting.append(session);
        }
    }

    return waiting.toOwnedSlice();
}

/// Get sessions by agent type
pub fn getByAgentType(
    self: *const SessionList,
    alloc: Allocator,
    agent_type: Config.AgentType,
) ![]*Session {
    var result = std.ArrayList(*Session).init(alloc);
    errdefer result.deinit();

    for (self.sessions.values()) |session| {
        if (session.agent_type == agent_type) {
            try result.append(session);
        }
    }

    return result.toOwnedSlice();
}

/// Find the oldest session that needs attention
pub fn findOldestWaiting(self: *const SessionList) ?*Session {
    var oldest: ?*Session = null;
    var oldest_time: i128 = std.math.maxInt(i128);

    for (self.sessions.values()) |session| {
        if (session.status == .waiting_input and session.status_changed_at < oldest_time) {
            oldest = session;
            oldest_time = session.status_changed_at;
        }
    }

    return oldest;
}

test "SessionList operations" {
    const alloc = std.testing.allocator;

    var list = SessionList.init(alloc);
    defer list.deinit();

    // Create and add sessions
    const session1 = try Session.create(alloc, .{
        .working_dir = "/tmp/test1",
        .agent_type = .claude_code,
    });
    try list.add(session1);

    const session2 = try Session.create(alloc, .{
        .working_dir = "/tmp/test2",
        .agent_type = .aider,
    });
    try list.add(session2);

    try std.testing.expectEqual(@as(usize, 2), list.count());
    try std.testing.expect(list.contains(session1.id));
    try std.testing.expect(list.contains(session2.id));

    // Test status filtering
    session1.setStatus(.running);
    session2.setStatus(.waiting_input);

    try std.testing.expectEqual(@as(usize, 1), list.countByStatus(.running));
    try std.testing.expectEqual(@as(usize, 1), list.countByStatus(.waiting_input));

    // Test removal
    const removed = list.remove(session1.id);
    try std.testing.expect(removed != null);
    try std.testing.expectEqual(@as(usize, 1), list.count());

    // Clean up removed session manually since it's no longer in the list
    removed.?.destroy();
}
