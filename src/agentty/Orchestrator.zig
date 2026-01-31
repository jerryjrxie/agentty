//! Orchestrator is the central coordinator for the Agentty subsystem.
//!
//! It manages:
//!   - Session lifecycle (creation, monitoring, termination)
//!   - Worktree management for isolation
//!   - Hook execution at lifecycle points
//!   - Coordination between all Agentty components

const Orchestrator = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");
const SessionList = @import("SessionList.zig");
const Worktree = @import("Worktree.zig");
const WorktreeManager = @import("WorktreeManager.zig");
const Monitor = @import("Monitor.zig");
const Hooks = @import("Hooks.zig");
const Config = @import("Config.zig");
const Notification = @import("Notification.zig");
const AgentDetector = @import("AgentDetector.zig");

const log = std.log.scoped(.agentty);

/// Active sessions
sessions: SessionList,

/// Worktree manager
worktree_manager: ?*WorktreeManager,

/// Status monitor
monitor: Monitor,

/// Hooks executor
hooks: Hooks,

/// Configuration
config: Config,

/// Allocator
alloc: Allocator,

/// Whether the orchestrator is running
running: bool,

/// Specification for spawning a new agent
pub const AgentSpec = struct {
    /// Name for the session (auto-generated if null)
    name: ?[]const u8 = null,

    /// Type of agent to spawn
    agent_type: Config.AgentType = .claude_code,

    /// Working directory
    working_dir: []const u8,

    /// Command to execute (uses agent default if null)
    command: ?[]const u8 = null,

    /// Whether to create an isolated worktree
    use_worktree: bool = true,

    /// Custom branch name (auto-generated if null)
    branch: ?[]const u8 = null,

    /// Task description (used for branch naming)
    task_slug: ?[]const u8 = null,
};

/// Create a new orchestrator
pub fn init(alloc: Allocator, config: Config) !*Orchestrator {
    const orch = try alloc.create(Orchestrator);
    errdefer alloc.destroy(orch);

    // Initialize worktree manager if enabled
    var worktree_manager: ?*WorktreeManager = null;
    if (config.enabled) {
        worktree_manager = WorktreeManager.init(alloc, &config) catch |err| blk: {
            log.warn("Failed to initialize worktree manager: {}", .{err});
            break :blk null;
        };
    }

    orch.* = .{
        .sessions = SessionList.init(alloc),
        .worktree_manager = worktree_manager,
        .monitor = Monitor.init(alloc, &config),
        .hooks = Hooks.init(alloc, &config),
        .config = config,
        .alloc = alloc,
        .running = true,
    };

    return orch;
}

/// Destroy the orchestrator and clean up all resources
pub fn deinit(self: *Orchestrator) void {
    self.running = false;

    // Terminate all sessions
    const session_ids = self.alloc.alloc(u64, self.sessions.count()) catch {
        log.err("Failed to allocate memory for session cleanup", .{});
        return;
    };
    defer self.alloc.free(session_ids);

    var i: usize = 0;
    for (self.sessions.all()) |session| {
        session_ids[i] = session.id;
        i += 1;
    }

    for (session_ids) |id| {
        self.terminateSession(id) catch |err| {
            log.warn("Failed to terminate session {x}: {}", .{ id, err });
        };
    }

    // Clean up components
    self.sessions.deinit();
    self.monitor.deinit();

    if (self.worktree_manager) |wm| {
        wm.deinit();
    }

    self.config.deinit(self.alloc);
    self.alloc.destroy(self);
}

/// Spawn a new agent session
pub fn spawnAgent(self: *Orchestrator, spec: AgentSpec) !*Session {
    if (!self.running) {
        return error.OrchestratorNotRunning;
    }

    // Detect repository if worktree is requested
    var base_repo: ?[]const u8 = null;
    if (spec.use_worktree) {
        base_repo = try WorktreeManager.detectRepository(self.alloc, spec.working_dir);
    }
    defer if (base_repo) |repo| self.alloc.free(repo);

    // Create worktree if we have a repo and worktree manager
    var worktree: ?*Worktree = null;
    if (base_repo != null and self.worktree_manager != null) {
        // Generate branch name
        const branch = if (spec.branch) |b|
            b
        else if (spec.task_slug) |slug|
            try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.config.branch_prefix, slug })
        else
            null;
        defer if (branch != null and spec.branch == null) self.alloc.free(branch.?);

        // Create session first to get ID
        const temp_session = try Session.create(self.alloc, .{
            .name = spec.name,
            .agent_type = spec.agent_type,
            .working_dir = spec.working_dir,
            .command = spec.command,
            .worktree = null,
        });

        worktree = self.worktree_manager.?.createWorktree(
            temp_session.id,
            base_repo.?,
            branch,
        ) catch |err| blk: {
            log.warn("Failed to create worktree: {}, continuing without isolation", .{err});
            break :blk null;
        };

        // Update session with worktree
        if (worktree) |wt| {
            // Re-create session with worktree
            temp_session.destroy();
            const session = try Session.create(self.alloc, .{
                .name = spec.name,
                .agent_type = spec.agent_type,
                .working_dir = wt.path,
                .command = spec.command,
                .worktree = wt,
            });

            return self.finishSpawn(session);
        } else {
            return self.finishSpawn(temp_session);
        }
    }

    // Create session without worktree
    const session = try Session.create(self.alloc, .{
        .name = spec.name,
        .agent_type = spec.agent_type,
        .working_dir = spec.working_dir,
        .command = spec.command,
        .worktree = null,
    });

    return self.finishSpawn(session);
}

/// Complete session spawn process
fn finishSpawn(self: *Orchestrator, session: *Session) !*Session {
    // Add to session list
    try self.sessions.add(session);
    errdefer _ = self.sessions.remove(session.id);

    // Start monitoring
    try self.monitor.watch(session);

    // Run pre-session hook
    if (self.hooks.runPreSession(session)) |result_opt| {
        if (result_opt) |*result| {
            defer result.deinit(self.alloc);
            if (!result.success) {
                log.warn("Pre-session hook failed with exit code {}", .{result.exit_code});
            }
        }
    } else |err| {
        log.warn("Pre-session hook error: {}", .{err});
    }

    // Mark session as running
    session.setStatus(.running);

    log.info("Spawned agent session: {s} (id={x})", .{ session.name, session.id });

    return session;
}

/// Terminate a session
pub fn terminateSession(self: *Orchestrator, session_id: u64) !void {
    const session = self.sessions.get(session_id) orelse return error.SessionNotFound;

    // Mark as terminating
    session.setStatus(.terminating);

    // Run post-session hook
    if (self.hooks.runPostSession(session)) |result_opt| {
        if (result_opt) |*result| {
            defer result.deinit(self.alloc);
            if (!result.success) {
                log.warn("Post-session hook failed with exit code {}", .{result.exit_code});
            }
        }
    } else |err| {
        log.warn("Post-session hook error: {}", .{err});
    }

    // Stop monitoring
    self.monitor.unwatch(session_id);

    // Clean up worktree
    if (self.worktree_manager) |wm| {
        wm.removeWorktree(session_id) catch |err| {
            log.warn("Failed to remove worktree: {}", .{err});
        };
    }

    // Remove from session list (this destroys the session)
    if (self.sessions.remove(session_id)) |removed| {
        log.info("Terminated session: {s} (id={x})", .{ removed.name, removed.id });
        removed.destroy();
    }
}

/// Get a session by ID
pub fn getSession(self: *const Orchestrator, session_id: u64) ?*Session {
    return self.sessions.get(session_id);
}

/// Get all active sessions
pub fn getActiveSessions(self: *const Orchestrator) ![]*Session {
    return self.sessions.getActive(self.alloc);
}

/// Get sessions waiting for input
pub fn getWaitingSessions(self: *const Orchestrator) ![]*Session {
    return self.sessions.getWaiting(self.alloc);
}

/// Feed output from a session for monitoring
pub fn feedSessionOutput(self: *Orchestrator, session_id: u64, output: []const u8) !void {
    try self.monitor.feedOutput(session_id, output);
}

/// Tick the orchestrator (call periodically for monitoring)
pub fn tick(self: *Orchestrator) !void {
    if (!self.running) return;

    // Analyze monitored sessions
    try self.monitor.analyze();

    // Clean up completed sessions if auto-cleanup is enabled
    if (self.config.auto_cleanup) {
        var to_cleanup = std.ArrayList(u64).init(self.alloc);
        defer to_cleanup.deinit();

        for (self.sessions.all()) |session| {
            if (session.status.isTerminal() and session.marked_for_cleanup) {
                try to_cleanup.append(session.id);
            }
        }

        for (to_cleanup.items) |id| {
            self.terminateSession(id) catch |err| {
                log.warn("Failed to cleanup session {x}: {}", .{ id, err });
            };
        }
    }
}

/// Get status overview
pub fn getStatusOverview(self: *const Orchestrator) Monitor.StatusOverview {
    return self.monitor.getStatusOverview();
}

/// Get notification manager
pub fn getNotifications(self: *Orchestrator) *Notification {
    return &self.monitor.notifications;
}

/// Pause all monitoring
pub fn pause(self: *Orchestrator) void {
    self.monitor.pause();
}

/// Resume monitoring
pub fn resume(self: *Orchestrator) void {
    self.monitor.resume();
}

/// Get session count
pub fn sessionCount(self: *const Orchestrator) usize {
    return self.sessions.count();
}

/// Check if enabled
pub fn isEnabled(self: *const Orchestrator) bool {
    return self.config.enabled;
}

/// Error types
pub const Error = error{
    OrchestratorNotRunning,
    SessionNotFound,
    WorktreeCreationFailed,
} || Allocator.Error || Session.Error || WorktreeManager.Error;

test "Orchestrator basic operations" {
    const alloc = std.testing.allocator;

    var config = Config{ .enabled = false }; // Disable worktrees for testing
    const orch = try Orchestrator.init(alloc, config);
    defer orch.deinit();

    try std.testing.expect(orch.running);
    try std.testing.expectEqual(@as(usize, 0), orch.sessionCount());
}

test "Orchestrator spawn session" {
    const alloc = std.testing.allocator;

    var config = Config{ .enabled = false };
    const orch = try Orchestrator.init(alloc, config);
    defer orch.deinit();

    const session = try orch.spawnAgent(.{
        .working_dir = "/tmp/test",
        .agent_type = .claude_code,
        .use_worktree = false,
    });

    try std.testing.expectEqual(@as(usize, 1), orch.sessionCount());
    try std.testing.expectEqual(Session.Status.running, session.status);
    try std.testing.expect(orch.monitor.isMonitored(session.id));
}
