//! Agentty is the agent orchestration subsystem for Ghostty.
//!
//! It provides functionality for:
//!   - Managing multiple agent sessions (Claude Code, OpenCode, Aider, etc.)
//!   - Git worktree isolation for each agent
//!   - Real-time status monitoring and notifications
//!   - Workspace automation with hooks
//!
//! This module is designed to integrate with Ghostty's existing infrastructure,
//! leveraging Surface, SplitTree, and the mailbox system.

const std = @import("std");

pub const Session = @import("Session.zig");
pub const SessionList = @import("SessionList.zig");
pub const Worktree = @import("Worktree.zig");
pub const WorktreeManager = @import("WorktreeManager.zig");
pub const Monitor = @import("Monitor.zig");
pub const Orchestrator = @import("Orchestrator.zig");
pub const Config = @import("Config.zig");
pub const Hooks = @import("Hooks.zig");
pub const AgentDetector = @import("AgentDetector.zig");
pub const Notification = @import("Notification.zig");

/// Generate a unique session ID
pub fn generateSessionId() u64 {
    var rng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch {
            seed = @intCast(std.time.milliTimestamp());
        };
        break :blk seed;
    });
    return rng.random().int(u64);
}

/// Format a session ID as a short string for display
pub fn formatSessionId(id: u64) [16]u8 {
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>16}", .{id}) catch unreachable;
    return buf;
}

test {
    std.testing.refAllDecls(@This());
}
