//! Session represents a single agent session.
//!
//! Each session encapsulates:
//!   - A unique session ID
//!   - The agent type (Claude Code, OpenCode, etc.)
//!   - Current status (running, waiting, completed, etc.)
//!   - Associated worktree (if isolation is enabled)
//!   - Reference to the terminal surface
//!
//! Sessions are managed by the Orchestrator and monitored by the Monitor.

const Session = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const Worktree = @import("Worktree.zig");
const agentty = @import("main.zig");

/// Unique session identifier
id: u64,

/// Human-readable session name
name: []const u8,

/// The type of agent running in this session
agent_type: Config.AgentType,

/// Current session status
status: Status,

/// Associated git worktree for isolation (optional)
worktree: ?*Worktree,

/// Working directory for this session
working_dir: []const u8,

/// Command being executed
command: []const u8,

/// Timestamp when session was created (nanoseconds)
created_at: i128,

/// Timestamp when status last changed (nanoseconds)
status_changed_at: i128,

/// Number of times the agent has requested attention
attention_count: u32,

/// Whether the session is marked for cleanup
marked_for_cleanup: bool,

/// Allocator used for this session
alloc: Allocator,

/// Session status
pub const Status = enum {
    /// Session is being set up
    initializing,

    /// Agent is actively running/processing
    running,

    /// Agent is waiting for user input
    waiting_input,

    /// Agent has completed its task successfully
    completed,

    /// Agent encountered an error or was terminated
    failed,

    /// Session is being cleaned up
    terminating,

    /// Returns true if the session is in a terminal state
    pub fn isTerminal(self: Status) bool {
        return self == .completed or self == .failed;
    }

    /// Returns true if the session is active (not terminal, not terminating)
    pub fn isActive(self: Status) bool {
        return self != .completed and self != .failed and self != .terminating;
    }

    /// Returns a display string for the status
    pub fn displayString(self: Status) []const u8 {
        return switch (self) {
            .initializing => "Initializing",
            .running => "Running",
            .waiting_input => "Waiting for input",
            .completed => "Completed",
            .failed => "Failed",
            .terminating => "Terminating",
        };
    }

    /// Returns a short status indicator
    pub fn indicator(self: Status) []const u8 {
        return switch (self) {
            .initializing => "[...]",
            .running => "[>>>]",
            .waiting_input => "[???]",
            .completed => "[OK]",
            .failed => "[ERR]",
            .terminating => "[...]",
        };
    }
};

/// Configuration for creating a new session
pub const CreateConfig = struct {
    name: ?[]const u8 = null,
    agent_type: Config.AgentType = .claude_code,
    working_dir: []const u8,
    command: ?[]const u8 = null,
    worktree: ?*Worktree = null,
};

/// Create a new session
pub fn create(alloc: Allocator, config: CreateConfig) !*Session {
    const session = try alloc.create(Session);
    errdefer alloc.destroy(session);

    const now = std.time.nanoTimestamp();
    const id = agentty.generateSessionId();

    // Generate default name if not provided
    const name = if (config.name) |n|
        try alloc.dupe(u8, n)
    else blk: {
        const id_str = agentty.formatSessionId(id);
        break :blk try std.fmt.allocPrint(alloc, "{s}-{s}", .{
            config.agent_type.displayName(),
            id_str[0..8],
        });
    };
    errdefer alloc.free(name);

    const working_dir = try alloc.dupe(u8, config.working_dir);
    errdefer alloc.free(working_dir);

    const command = if (config.command) |cmd|
        try alloc.dupe(u8, cmd)
    else
        try alloc.dupe(u8, config.agent_type.defaultCommand());
    errdefer alloc.free(command);

    session.* = .{
        .id = id,
        .name = name,
        .agent_type = config.agent_type,
        .status = .initializing,
        .worktree = config.worktree,
        .working_dir = working_dir,
        .command = command,
        .created_at = now,
        .status_changed_at = now,
        .attention_count = 0,
        .marked_for_cleanup = false,
        .alloc = alloc,
    };

    return session;
}

/// Destroy the session and free all resources
pub fn destroy(self: *Session) void {
    const alloc = self.alloc;
    alloc.free(self.name);
    alloc.free(self.working_dir);
    alloc.free(self.command);
    alloc.destroy(self);
}

/// Update the session status
pub fn setStatus(self: *Session, new_status: Status) void {
    if (self.status != new_status) {
        self.status = new_status;
        self.status_changed_at = std.time.nanoTimestamp();
    }
}

/// Mark that the agent needs attention
pub fn markAttention(self: *Session) void {
    if (self.status == .running) {
        self.setStatus(.waiting_input);
        self.attention_count += 1;
    }
}

/// Get the duration since session creation
pub fn getDuration(self: *const Session) i128 {
    return std.time.nanoTimestamp() - self.created_at;
}

/// Get the duration since last status change
pub fn getTimeSinceStatusChange(self: *const Session) i128 {
    return std.time.nanoTimestamp() - self.status_changed_at;
}

/// Format the session ID as a short string
pub fn formatId(self: *const Session) [16]u8 {
    return agentty.formatSessionId(self.id);
}

/// Get a summary of the session for display
pub fn getSummary(self: *const Session, buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s} {s} - {s}", .{
        self.status.indicator(),
        self.name,
        self.working_dir,
    });
}

/// Error type for session operations
pub const Error = Allocator.Error;

test "Session creation" {
    const alloc = std.testing.allocator;

    const session = try Session.create(alloc, .{
        .working_dir = "/tmp/test",
        .agent_type = .claude_code,
    });
    defer session.destroy();

    try std.testing.expectEqual(Status.initializing, session.status);
    try std.testing.expectEqual(Config.AgentType.claude_code, session.agent_type);
    try std.testing.expectEqualStrings("/tmp/test", session.working_dir);
}

test "Session status transitions" {
    const alloc = std.testing.allocator;

    const session = try Session.create(alloc, .{
        .working_dir = "/tmp/test",
    });
    defer session.destroy();

    try std.testing.expect(session.status.isActive());
    try std.testing.expect(!session.status.isTerminal());

    session.setStatus(.running);
    try std.testing.expectEqual(Status.running, session.status);

    session.markAttention();
    try std.testing.expectEqual(Status.waiting_input, session.status);
    try std.testing.expectEqual(@as(u32, 1), session.attention_count);

    session.setStatus(.completed);
    try std.testing.expect(session.status.isTerminal());
    try std.testing.expect(!session.status.isActive());
}
