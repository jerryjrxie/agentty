//! Monitor provides real-time status tracking for agent sessions.
//!
//! Features:
//!   - Periodic status polling
//!   - Output analysis for status detection
//!   - Callback system for status changes
//!   - Integration with notification system

const Monitor = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");
const SessionList = @import("SessionList.zig");
const AgentDetector = @import("AgentDetector.zig");
const Notification = @import("Notification.zig");
const Config = @import("Config.zig");

/// Callback type for status changes
pub const StatusChangeCallback = *const fn (session: *Session, old_status: Session.Status, new_status: Session.Status) void;

/// Callback type for attention events
pub const AttentionCallback = *const fn (session: *Session) void;

/// Output buffer for each monitored session
const OutputBuffer = struct {
    data: std.ArrayList(u8),
    last_analyzed_pos: usize,

    fn init(alloc: Allocator) OutputBuffer {
        return .{
            .data = std.ArrayList(u8).init(alloc),
            .last_analyzed_pos = 0,
        };
    }

    fn deinit(self: *OutputBuffer) void {
        self.data.deinit();
    }

    fn append(self: *OutputBuffer, bytes: []const u8) !void {
        try self.data.appendSlice(bytes);
    }

    fn getUnanalyzed(self: *const OutputBuffer) []const u8 {
        if (self.last_analyzed_pos >= self.data.items.len) {
            return "";
        }
        return self.data.items[self.last_analyzed_pos..];
    }

    fn markAnalyzed(self: *OutputBuffer) void {
        self.last_analyzed_pos = self.data.items.len;
    }

    fn clear(self: *OutputBuffer) void {
        self.data.clearRetainingCapacity();
        self.last_analyzed_pos = 0;
    }
};

/// Session monitoring state
const MonitoredSession = struct {
    session: *Session,
    output_buffer: OutputBuffer,
    last_check: i128,

    fn init(alloc: Allocator, session: *Session) MonitoredSession {
        return .{
            .session = session,
            .output_buffer = OutputBuffer.init(alloc),
            .last_check = std.time.nanoTimestamp(),
        };
    }

    fn deinit(self: *MonitoredSession) void {
        self.output_buffer.deinit();
    }
};

/// Map of session ID to monitoring state
monitored: std.AutoHashMap(u64, MonitoredSession),

/// Notification manager
notifications: Notification,

/// Status change callbacks
status_callbacks: std.ArrayList(StatusChangeCallback),

/// Attention callbacks
attention_callbacks: std.ArrayList(AttentionCallback),

/// Poll interval in nanoseconds
poll_interval_ns: u64,

/// Whether monitoring is active
active: bool,

/// Allocator
alloc: Allocator,

/// Create a new monitor
pub fn init(alloc: Allocator, config: *const Config) Monitor {
    return .{
        .monitored = std.AutoHashMap(u64, MonitoredSession).init(alloc),
        .notifications = Notification.init(alloc, config.notification_enabled),
        .status_callbacks = std.ArrayList(StatusChangeCallback).init(alloc),
        .attention_callbacks = std.ArrayList(AttentionCallback).init(alloc),
        .poll_interval_ns = 100 * std.time.ns_per_ms, // 100ms default
        .active = true,
        .alloc = alloc,
    };
}

/// Destroy the monitor
pub fn deinit(self: *Monitor) void {
    var iter = self.monitored.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.deinit();
    }
    self.monitored.deinit();
    self.notifications.deinit();
    self.status_callbacks.deinit();
    self.attention_callbacks.deinit();
}

/// Start monitoring a session
pub fn watch(self: *Monitor, session: *Session) !void {
    if (self.monitored.contains(session.id)) {
        return; // Already monitoring
    }

    try self.monitored.put(session.id, MonitoredSession.init(self.alloc, session));
}

/// Stop monitoring a session
pub fn unwatch(self: *Monitor, session_id: u64) void {
    if (self.monitored.fetchRemove(session_id)) |entry| {
        var state = entry.value;
        state.deinit();
    }
}

/// Feed output data for a session
pub fn feedOutput(self: *Monitor, session_id: u64, output: []const u8) !void {
    if (self.monitored.getPtr(session_id)) |state| {
        try state.output_buffer.append(output);
    }
}

/// Analyze all monitored sessions
pub fn analyze(self: *Monitor) !void {
    var iter = self.monitored.iterator();
    while (iter.next()) |entry| {
        try self.analyzeSession(entry.value_ptr);
    }
}

/// Analyze a single session
fn analyzeSession(self: *Monitor, state: *MonitoredSession) !void {
    const unanalyzed = state.output_buffer.getUnanalyzed();
    if (unanalyzed.len == 0) {
        return;
    }

    const result = AgentDetector.analyzeOutput(unanalyzed);
    state.output_buffer.markAnalyzed();
    state.last_check = std.time.nanoTimestamp();

    const session = state.session;
    const old_status = session.status;

    // Update status based on detection
    if (result.has_error and session.status.isActive()) {
        session.setStatus(.failed);
        try self.notifications.notifyError(session, "An error was detected");
    } else if (result.completed and session.status.isActive()) {
        session.setStatus(.completed);
        try self.notifications.notifyCompletion(session);
    } else if (result.needs_attention and session.status == .running) {
        session.markAttention();
        try self.notifications.notifyAttention(session);

        // Trigger attention callbacks
        for (self.attention_callbacks.items) |callback| {
            callback(session);
        }
    }

    // Trigger status change callbacks
    if (old_status != session.status) {
        for (self.status_callbacks.items) |callback| {
            callback(session, old_status, session.status);
        }
    }
}

/// Register a status change callback
pub fn onStatusChange(self: *Monitor, callback: StatusChangeCallback) !void {
    try self.status_callbacks.append(callback);
}

/// Register an attention callback
pub fn onAttention(self: *Monitor, callback: AttentionCallback) !void {
    try self.attention_callbacks.append(callback);
}

/// Get status overview
pub const StatusOverview = struct {
    total: usize,
    running: usize,
    waiting: usize,
    completed: usize,
    failed: usize,
};

pub fn getStatusOverview(self: *const Monitor) StatusOverview {
    var overview = StatusOverview{
        .total = 0,
        .running = 0,
        .waiting = 0,
        .completed = 0,
        .failed = 0,
    };

    var iter = self.monitored.iterator();
    while (iter.next()) |entry| {
        overview.total += 1;
        switch (entry.value_ptr.session.status) {
            .running, .initializing => overview.running += 1,
            .waiting_input => overview.waiting += 1,
            .completed => overview.completed += 1,
            .failed, .terminating => overview.failed += 1,
        }
    }

    return overview;
}

/// Get all sessions waiting for attention
pub fn getWaitingSessions(self: *const Monitor, alloc: Allocator) ![]*Session {
    var waiting = std.ArrayList(*Session).init(alloc);
    errdefer waiting.deinit();

    var iter = self.monitored.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.session.status == .waiting_input) {
            try waiting.append(entry.value_ptr.session);
        }
    }

    return waiting.toOwnedSlice();
}

/// Pause monitoring
pub fn pause(self: *Monitor) void {
    self.active = false;
}

/// Resume monitoring
pub fn resume(self: *Monitor) void {
    self.active = true;
}

/// Check if a session is being monitored
pub fn isMonitored(self: *const Monitor, session_id: u64) bool {
    return self.monitored.contains(session_id);
}

test "Monitor basic operations" {
    const alloc = std.testing.allocator;
    var config = Config{};
    defer config.deinit(alloc);

    var monitor = Monitor.init(alloc, &config);
    defer monitor.deinit();

    // Create a test session
    const session = try Session.create(alloc, .{
        .working_dir = "/tmp/test",
    });
    defer session.destroy();

    try monitor.watch(session);
    try std.testing.expect(monitor.isMonitored(session.id));

    // Feed some output and analyze
    session.setStatus(.running);
    try monitor.feedOutput(session.id, "Processing...");
    try monitor.analyze();

    // Verify status overview
    const overview = monitor.getStatusOverview();
    try std.testing.expectEqual(@as(usize, 1), overview.total);
    try std.testing.expectEqual(@as(usize, 1), overview.running);
}

test "Monitor attention detection" {
    const alloc = std.testing.allocator;
    var config = Config{ .notification_enabled = false };
    defer config.deinit(alloc);

    var monitor = Monitor.init(alloc, &config);
    defer monitor.deinit();

    const session = try Session.create(alloc, .{
        .working_dir = "/tmp/test",
    });
    defer session.destroy();

    try monitor.watch(session);
    session.setStatus(.running);

    // Feed output that triggers attention
    try monitor.feedOutput(session.id, "Do you want to continue? (y/n)");
    try monitor.analyze();

    try std.testing.expectEqual(Session.Status.waiting_input, session.status);
}
