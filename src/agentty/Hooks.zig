//! Hooks provides a system for executing custom commands at various lifecycle points.
//!
//! Hook types:
//!   - Pre-session: Run before a session starts
//!   - Post-session: Run after a session ends
//!   - On-attention: Run when an agent needs attention
//!
//! Environment variables are passed to hooks with session context.

const Hooks = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");
const Config = @import("Config.zig");

/// Hook execution result
pub const Result = struct {
    success: bool,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    duration_ns: u64,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

/// Hook types
pub const HookType = enum {
    pre_session,
    post_session,
    on_attention,

    pub fn envName(self: HookType) []const u8 {
        return switch (self) {
            .pre_session => "AGENTTY_HOOK_PRE_SESSION",
            .post_session => "AGENTTY_HOOK_POST_SESSION",
            .on_attention => "AGENTTY_HOOK_ON_ATTENTION",
        };
    }
};

/// Hook configuration
config: *const Config,

/// Allocator
alloc: Allocator,

/// Create a new hooks manager
pub fn init(alloc: Allocator, config: *const Config) Hooks {
    return .{
        .config = config,
        .alloc = alloc,
    };
}

/// Get the command for a hook type
pub fn getCommand(self: *const Hooks, hook_type: HookType) ?[]const u8 {
    return switch (hook_type) {
        .pre_session => self.config.hook_pre_session,
        .post_session => self.config.hook_post_session,
        .on_attention => self.config.hook_on_attention,
    };
}

/// Execute a hook for a session
pub fn execute(
    self: *const Hooks,
    hook_type: HookType,
    session: *const Session,
) !?Result {
    const command = self.getCommand(hook_type) orelse return null;

    const start_time = std.time.nanoTimestamp();

    // Build environment variables
    var env_map = try self.buildEnvironment(session);
    defer env_map.deinit();

    // Execute the command
    const result = try std.process.Child.run(.{
        .allocator = self.alloc,
        .argv = &.{ "/bin/sh", "-c", command },
        .cwd = session.working_dir,
        .env_map = &env_map,
    });

    const end_time = std.time.nanoTimestamp();
    const duration: u64 = @intCast(end_time - start_time);

    const exit_code: u8 = switch (result.term) {
        .Exited => |code| code,
        else => 255,
    };

    return Result{
        .success = exit_code == 0,
        .exit_code = exit_code,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .duration_ns = duration,
    };
}

/// Build environment variables for hook execution
fn buildEnvironment(self: *const Hooks, session: *const Session) !std.process.EnvMap {
    var env = std.process.EnvMap.init(self.alloc);
    errdefer env.deinit();

    // Copy existing environment
    const environ = std.os.environ;
    for (environ) |entry| {
        const eq_pos = std.mem.indexOf(u8, entry, "=") orelse continue;
        const key = entry[0..eq_pos];
        const value = entry[eq_pos + 1 ..];
        try env.put(key, value);
    }

    // Add agentty-specific variables
    const session_id_str = try std.fmt.allocPrint(self.alloc, "{d}", .{session.id});
    defer self.alloc.free(session_id_str);
    try env.put("AGENTTY_SESSION_ID", session_id_str);

    try env.put("AGENTTY_SESSION_NAME", session.name);
    try env.put("AGENTTY_WORKING_DIR", session.working_dir);
    try env.put("AGENTTY_COMMAND", session.command);
    try env.put("AGENTTY_AGENT_TYPE", session.agent_type.displayName());
    try env.put("AGENTTY_STATUS", session.status.displayString());

    if (session.worktree) |wt| {
        try env.put("AGENTTY_WORKTREE_PATH", wt.path);
        try env.put("AGENTTY_WORKTREE_BRANCH", wt.branch);
    }

    return env;
}

/// Execute pre-session hook
pub fn runPreSession(self: *const Hooks, session: *const Session) !?Result {
    return self.execute(.pre_session, session);
}

/// Execute post-session hook
pub fn runPostSession(self: *const Hooks, session: *const Session) !?Result {
    return self.execute(.post_session, session);
}

/// Execute on-attention hook
pub fn runOnAttention(self: *const Hooks, session: *const Session) !?Result {
    return self.execute(.on_attention, session);
}

/// Check if a hook is configured
pub fn hasHook(self: *const Hooks, hook_type: HookType) bool {
    return self.getCommand(hook_type) != null;
}

/// Validate a hook command (check if it would be executable)
pub fn validate(command: []const u8) bool {
    if (command.len == 0) return false;

    // Basic validation - check if shell is available
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "/bin/sh", "-n", "-c", command },
    }) catch return false;

    std.heap.page_allocator.free(result.stdout);
    std.heap.page_allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

test "Hooks configuration" {
    const alloc = std.testing.allocator;
    var config = Config{
        .hook_pre_session = "echo pre",
        .hook_post_session = "echo post",
    };
    defer config.deinit(alloc);

    const hooks = Hooks.init(alloc, &config);

    try std.testing.expect(hooks.hasHook(.pre_session));
    try std.testing.expect(hooks.hasHook(.post_session));
    try std.testing.expect(!hooks.hasHook(.on_attention));

    try std.testing.expectEqualStrings("echo pre", hooks.getCommand(.pre_session).?);
}

test "Hook validation" {
    try std.testing.expect(Hooks.validate("echo hello"));
    try std.testing.expect(!Hooks.validate(""));
    // Note: "invalid(((" might still pass shell syntax check on some systems
}
