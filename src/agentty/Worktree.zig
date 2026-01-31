//! Worktree represents a git worktree for agent isolation.
//!
//! Each agent session can have its own isolated worktree, allowing:
//!   - Independent file modifications without conflicts
//!   - Easy diff viewing between worktree and base
//!   - Clean rollback by simply deleting the worktree

const Worktree = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Unique worktree identifier
id: u64,

/// Path to the worktree directory
path: []const u8,

/// Branch name for this worktree
branch: []const u8,

/// Path to the base repository
base_repo: []const u8,

/// Session ID this worktree is associated with
session_id: u64,

/// Whether the worktree has been created on disk
created: bool,

/// Allocator used for this worktree
alloc: Allocator,

/// Configuration for creating a new worktree
pub const CreateConfig = struct {
    base_repo: []const u8,
    branch: ?[]const u8 = null,
    session_id: u64,
    worktree_base: []const u8,
};

/// Create a new worktree instance (does not create on disk yet)
pub fn create(alloc: Allocator, config: CreateConfig) !*Worktree {
    const worktree = try alloc.create(Worktree);
    errdefer alloc.destroy(worktree);

    // Generate unique ID
    var rng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch {
            seed = @intCast(std.time.milliTimestamp());
        };
        break :blk seed;
    });
    const id = rng.random().int(u64);

    // Generate branch name if not provided
    const branch = if (config.branch) |b|
        try alloc.dupe(u8, b)
    else
        try std.fmt.allocPrint(alloc, "agentty/{x:0>16}", .{config.session_id});
    errdefer alloc.free(branch);

    // Generate worktree path
    const path = try std.fmt.allocPrint(alloc, "{s}/{x:0>16}", .{
        config.worktree_base,
        config.session_id,
    });
    errdefer alloc.free(path);

    const base_repo = try alloc.dupe(u8, config.base_repo);
    errdefer alloc.free(base_repo);

    worktree.* = .{
        .id = id,
        .path = path,
        .branch = branch,
        .base_repo = base_repo,
        .session_id = config.session_id,
        .created = false,
        .alloc = alloc,
    };

    return worktree;
}

/// Destroy the worktree instance (does not remove from disk)
pub fn destroy(self: *Worktree) void {
    const alloc = self.alloc;
    alloc.free(self.path);
    alloc.free(self.branch);
    alloc.free(self.base_repo);
    alloc.destroy(self);
}

/// Initialize the worktree on disk
pub fn init(self: *Worktree) !void {
    if (self.created) return;

    // Create the worktree directory
    std.fs.makeDirAbsolute(self.path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Run git worktree add
    const result = try runGitCommand(self.alloc, self.base_repo, &.{
        "worktree",
        "add",
        "-b",
        self.branch,
        self.path,
    });
    defer self.alloc.free(result.stdout);
    defer self.alloc.free(result.stderr);

    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => 255,
    };

    if (exit_code != 0) {
        // Check if branch already exists, try without -b
        const result2 = try runGitCommand(self.alloc, self.base_repo, &.{
            "worktree",
            "add",
            self.path,
            self.branch,
        });
        defer self.alloc.free(result2.stdout);
        defer self.alloc.free(result2.stderr);

        const exit_code2 = switch (result2.term) {
            .Exited => |code| code,
            else => 255,
        };

        if (exit_code2 != 0) {
            return error.WorktreeCreationFailed;
        }
    }

    self.created = true;
}

/// Remove the worktree from disk
pub fn remove(self: *Worktree) !void {
    if (!self.created) return;

    // Run git worktree remove
    const result = try runGitCommand(self.alloc, self.base_repo, &.{
        "worktree",
        "remove",
        "--force",
        self.path,
    });
    defer self.alloc.free(result.stdout);
    defer self.alloc.free(result.stderr);

    // Also try to delete the branch
    _ = runGitCommand(self.alloc, self.base_repo, &.{
        "branch",
        "-D",
        self.branch,
    }) catch {};

    self.created = false;
}

/// Get the diff between worktree and base
pub fn getDiff(self: *const Worktree, alloc: Allocator) ![]const u8 {
    if (!self.created) return try alloc.dupe(u8, "");

    const result = try runGitCommand(alloc, self.path, &.{
        "diff",
        "HEAD",
    });
    defer alloc.free(result.stderr);

    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => 255,
    };

    if (exit_code != 0) {
        alloc.free(result.stdout);
        return try alloc.dupe(u8, "");
    }

    return result.stdout;
}

/// Get list of changed files
pub fn getChangedFiles(self: *const Worktree, alloc: Allocator) ![][]const u8 {
    if (!self.created) return try alloc.alloc([]const u8, 0);

    const result = try runGitCommand(alloc, self.path, &.{
        "diff",
        "--name-only",
        "HEAD",
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => 255,
    };

    if (exit_code != 0) {
        return try alloc.alloc([]const u8, 0);
    }

    // Split by newlines
    var files = std.ArrayList([]const u8).init(alloc);
    errdefer {
        for (files.items) |f| alloc.free(f);
        files.deinit();
    }

    var iter = std.mem.splitScalar(u8, result.stdout, '\n');
    while (iter.next()) |line| {
        if (line.len > 0) {
            try files.append(try alloc.dupe(u8, line));
        }
    }

    return files.toOwnedSlice();
}

/// Get the current commit hash
pub fn getCurrentCommit(self: *const Worktree, alloc: Allocator) ![]const u8 {
    if (!self.created) return try alloc.dupe(u8, "");

    const result = try runGitCommand(alloc, self.path, &.{
        "rev-parse",
        "HEAD",
    });
    defer alloc.free(result.stderr);

    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => 255,
    };

    if (exit_code != 0) {
        alloc.free(result.stdout);
        return try alloc.dupe(u8, "");
    }

    // Trim trailing newline
    const stdout = std.mem.trimRight(u8, result.stdout, "\n");
    const commit = try alloc.dupe(u8, stdout);
    alloc.free(result.stdout);
    return commit;
}

/// Run a git command in a directory
fn runGitCommand(alloc: Allocator, cwd: []const u8, args: []const []const u8) !std.process.Child.RunResult {
    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();

    try argv.append("git");
    try argv.appendSlice(args);

    return std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv.items,
        .cwd = cwd,
    });
}

/// Error type for worktree operations
pub const Error = error{
    WorktreeCreationFailed,
    WorktreeNotFound,
    GitCommandFailed,
} || Allocator.Error || std.fs.File.OpenError || std.process.Child.RunError;

test "Worktree creation" {
    const alloc = std.testing.allocator;

    const worktree = try Worktree.create(alloc, .{
        .base_repo = "/tmp/test-repo",
        .session_id = 12345,
        .worktree_base = "/tmp/worktrees",
    });
    defer worktree.destroy();

    try std.testing.expect(!worktree.created);
    try std.testing.expectEqual(@as(u64, 12345), worktree.session_id);
    try std.testing.expect(std.mem.startsWith(u8, worktree.branch, "agentty/"));
}
