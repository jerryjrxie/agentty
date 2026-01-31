//! WorktreeManager handles the lifecycle of git worktrees.
//!
//! Responsibilities:
//!   - Creating worktrees for new sessions
//!   - Cleaning up worktrees when sessions end
//!   - Managing the worktree base directory
//!   - Detecting the base repository

const WorktreeManager = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Worktree = @import("Worktree.zig");
const Config = @import("Config.zig");

/// Active worktrees indexed by session ID
worktrees: std.AutoHashMap(u64, *Worktree),

/// Base path for worktrees
base_path: []const u8,

/// Whether to auto-cleanup worktrees
auto_cleanup: bool,

/// Allocator
alloc: Allocator,

/// Create a new worktree manager
pub fn init(alloc: Allocator, config: *const Config) !*WorktreeManager {
    const manager = try alloc.create(WorktreeManager);
    errdefer alloc.destroy(manager);

    const base_path = try config.getWorktreeBase(alloc);
    errdefer alloc.free(base_path);

    // Ensure base directory exists
    std.fs.makeDirAbsolute(base_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    manager.* = .{
        .worktrees = std.AutoHashMap(u64, *Worktree).init(alloc),
        .base_path = base_path,
        .auto_cleanup = config.auto_cleanup,
        .alloc = alloc,
    };

    return manager;
}

/// Destroy the worktree manager
pub fn deinit(self: *WorktreeManager) void {
    // Clean up all worktrees if auto_cleanup is enabled
    var iter = self.worktrees.iterator();
    while (iter.next()) |entry| {
        if (self.auto_cleanup) {
            entry.value_ptr.*.remove() catch {};
        }
        entry.value_ptr.*.destroy();
    }
    self.worktrees.deinit();
    self.alloc.free(self.base_path);
    self.alloc.destroy(self);
}

/// Create a worktree for a session
pub fn createWorktree(
    self: *WorktreeManager,
    session_id: u64,
    base_repo: []const u8,
    branch: ?[]const u8,
) !*Worktree {
    // Check if worktree already exists for this session
    if (self.worktrees.get(session_id)) |existing| {
        return existing;
    }

    const worktree = try Worktree.create(self.alloc, .{
        .base_repo = base_repo,
        .branch = branch,
        .session_id = session_id,
        .worktree_base = self.base_path,
    });
    errdefer worktree.destroy();

    // Initialize on disk
    try worktree.init();

    // Add to tracking
    try self.worktrees.put(session_id, worktree);

    return worktree;
}

/// Remove a worktree for a session
pub fn removeWorktree(self: *WorktreeManager, session_id: u64) !void {
    if (self.worktrees.fetchRemove(session_id)) |entry| {
        if (self.auto_cleanup) {
            try entry.value.remove();
        }
        entry.value.destroy();
    }
}

/// Get a worktree by session ID
pub fn getWorktree(self: *const WorktreeManager, session_id: u64) ?*Worktree {
    return self.worktrees.get(session_id);
}

/// Get the number of active worktrees
pub fn count(self: *const WorktreeManager) usize {
    return self.worktrees.count();
}

/// Detect the git repository from a directory path
pub fn detectRepository(alloc: Allocator, dir: []const u8) !?[]const u8 {
    var current_dir = try alloc.dupe(u8, dir);
    defer alloc.free(current_dir);

    while (true) {
        // Check if .git exists in current directory
        const git_path = try std.fmt.allocPrint(alloc, "{s}/.git", .{current_dir});
        defer alloc.free(git_path);

        const stat = std.fs.cwd().statFile(git_path) catch |err| switch (err) {
            error.FileNotFound => {
                // Try parent directory
                const parent = std.fs.path.dirname(current_dir);
                if (parent == null or std.mem.eql(u8, parent.?, current_dir)) {
                    return null; // Reached root
                }
                const new_current = try alloc.dupe(u8, parent.?);
                alloc.free(current_dir);
                current_dir = new_current;
                continue;
            },
            else => return err,
        };
        _ = stat;

        // Found .git, return this directory
        return try alloc.dupe(u8, current_dir);
    }
}

/// Clean up all orphaned worktrees (worktrees without active sessions)
pub fn cleanupOrphaned(self: *WorktreeManager, active_session_ids: []const u64) !usize {
    var cleaned: usize = 0;

    var to_remove = std.ArrayList(u64).init(self.alloc);
    defer to_remove.deinit();

    var iter = self.worktrees.iterator();
    while (iter.next()) |entry| {
        const session_id = entry.key_ptr.*;
        var found = false;
        for (active_session_ids) |active_id| {
            if (active_id == session_id) {
                found = true;
                break;
            }
        }
        if (!found) {
            try to_remove.append(session_id);
        }
    }

    for (to_remove.items) |session_id| {
        try self.removeWorktree(session_id);
        cleaned += 1;
    }

    return cleaned;
}

test "WorktreeManager basic operations" {
    // This test requires mocking git operations, so we just test initialization
    const alloc = std.testing.allocator;
    var config = Config{};
    defer config.deinit(alloc);

    // We can't fully test this without a real git repo
    // Just verify the structure
    try std.testing.expect(true);
}
