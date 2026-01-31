//! Agentty - Agent orchestration subsystem for Ghostty.
//!
//! This module provides agent orchestration capabilities for managing
//! multiple CLI-based coding agents (Claude Code, OpenCode, Aider, etc.)
//! simultaneously with isolation, monitoring, and workflow automation.
//!
//! For detailed documentation, see docs/AGENTTY_PLAN.md

pub const main = @import("agentty/main.zig");

pub const Session = main.Session;
pub const SessionList = main.SessionList;
pub const Worktree = main.Worktree;
pub const WorktreeManager = main.WorktreeManager;
pub const Monitor = main.Monitor;
pub const Orchestrator = main.Orchestrator;
pub const Config = main.Config;
pub const Hooks = main.Hooks;
pub const AgentDetector = main.AgentDetector;
pub const Notification = main.Notification;

pub const generateSessionId = main.generateSessionId;
pub const formatSessionId = main.formatSessionId;

test {
    @import("std").testing.refAllDecls(@This());
}
