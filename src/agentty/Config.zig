//! Agentty configuration types.
//!
//! These types define the configuration options for the agent orchestration
//! subsystem. They integrate with Ghostty's existing configuration system.

const Config = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Whether agentty features are enabled
enabled: bool = false,

/// Base path for worktrees
worktree_base: ?[]const u8 = null,

/// Whether to automatically cleanup worktrees on session end
auto_cleanup: bool = true,

/// Whether desktop notifications are enabled
notification_enabled: bool = true,

/// Default agent type for new sessions
default_agent: AgentType = .claude_code,

/// Show status overlay on surfaces
status_overlay: bool = true,

/// Dashboard position
dashboard_position: DashboardPosition = .right,

/// Dashboard width in pixels
dashboard_width: u16 = 300,

/// Pre-session hook command
hook_pre_session: ?[]const u8 = null,

/// Post-session hook command
hook_post_session: ?[]const u8 = null,

/// Hook to run when agent needs attention
hook_on_attention: ?[]const u8 = null,

/// Agent-specific command overrides
agent_claude_code_cmd: []const u8 = "claude",
agent_opencode_cmd: []const u8 = "opencode",
agent_aider_cmd: []const u8 = "aider",

/// Branch prefix for auto-generated branches
branch_prefix: []const u8 = "agentty",

/// Supported agent types
pub const AgentType = enum {
    claude_code,
    opencode,
    aider,
    custom,

    pub fn defaultCommand(self: AgentType) []const u8 {
        return switch (self) {
            .claude_code => "claude",
            .opencode => "opencode",
            .aider => "aider",
            .custom => "",
        };
    }

    pub fn displayName(self: AgentType) []const u8 {
        return switch (self) {
            .claude_code => "Claude Code",
            .opencode => "OpenCode",
            .aider => "Aider",
            .custom => "Custom",
        };
    }
};

/// Dashboard position options
pub const DashboardPosition = enum {
    left,
    right,
    top,
    bottom,
    floating,
};

/// Get the effective worktree base path
pub fn getWorktreeBase(self: *const Config, alloc: Allocator) ![]const u8 {
    if (self.worktree_base) |base| {
        return try alloc.dupe(u8, base);
    }

    // Default to ~/.agentty/worktrees
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return try std.fmt.allocPrint(alloc, "{s}/.agentty/worktrees", .{home});
}

/// Get the command for a specific agent type
pub fn getAgentCommand(self: *const Config, agent_type: AgentType) []const u8 {
    return switch (agent_type) {
        .claude_code => self.agent_claude_code_cmd,
        .opencode => self.agent_opencode_cmd,
        .aider => self.agent_aider_cmd,
        .custom => "",
    };
}

/// Clone the config with a new allocator
pub fn clone(self: *const Config, alloc: Allocator) !Config {
    var new_config = self.*;

    if (self.worktree_base) |base| {
        new_config.worktree_base = try alloc.dupe(u8, base);
    }
    if (self.hook_pre_session) |hook| {
        new_config.hook_pre_session = try alloc.dupe(u8, hook);
    }
    if (self.hook_post_session) |hook| {
        new_config.hook_post_session = try alloc.dupe(u8, hook);
    }
    if (self.hook_on_attention) |hook| {
        new_config.hook_on_attention = try alloc.dupe(u8, hook);
    }

    return new_config;
}

/// Free any allocated memory
pub fn deinit(self: *Config, alloc: Allocator) void {
    if (self.worktree_base) |base| alloc.free(base);
    if (self.hook_pre_session) |hook| alloc.free(hook);
    if (self.hook_post_session) |hook| alloc.free(hook);
    if (self.hook_on_attention) |hook| alloc.free(hook);
    self.* = undefined;
}

test "Config defaults" {
    const config = Config{};
    try std.testing.expect(!config.enabled);
    try std.testing.expect(config.auto_cleanup);
    try std.testing.expectEqual(AgentType.claude_code, config.default_agent);
}

test "AgentType commands" {
    try std.testing.expectEqualStrings("claude", AgentType.claude_code.defaultCommand());
    try std.testing.expectEqualStrings("aider", AgentType.aider.defaultCommand());
}
