# Ghostree: Agent Orchestration for Ghostty

## Overview

This document outlines the plan to port features from [Superset](https://github.com/superset-sh/superset) to Ghostty, creating a new subsystem called **Ghostree** - a native, high-performance agent orchestration layer built on Ghostty's existing infrastructure.

### Vision

Transform Ghostty from a standalone terminal emulator into a powerful agent orchestration platform capable of managing multiple CLI-based coding agents (Claude Code, OpenCode, Aider, etc.) simultaneously with isolation, monitoring, and workflow automation.

---

## Feature Mapping: Superset → Ghostree

| Superset Feature | Ghostree Implementation | Priority |
|-----------------|------------------------|----------|
| Parallel agent execution | Multi-surface orchestration via SplitTree | P0 |
| Git worktree isolation | Native worktree manager | P0 |
| Agent status monitoring | Surface status overlay & notifications | P0 |
| Built-in diff viewer | Integrated diff surface mode | P1 |
| Workspace automation | Config-driven setup/teardown hooks | P1 |
| IDE integration | Editor launch commands | P2 |
| Keyboard navigation | Extended keybindings | P1 |
| Centralized monitoring | Dashboard surface mode | P1 |

---

## Architecture Design

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Ghostty App                              │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                     Ghostree Subsystem                       ││
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  ││
│  │  │   Session   │  │  Worktree   │  │   Agent Monitor     │  ││
│  │  │   Manager   │  │   Manager   │  │   (Status/Notify)   │  ││
│  │  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  ││
│  │         │                │                     │             ││
│  │  ┌──────┴─────────────────┴─────────────────────┴──────────┐ ││
│  │  │                   Orchestration Core                     │ ││
│  │  │  • Agent lifecycle management                            │ ││
│  │  │  • Cross-surface communication                           │ ││
│  │  │  • Hook execution engine                                 │ ││
│  │  └─────────────────────────────────────────────────────────┘ ││
│  └─────────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                 Existing Ghostty Core                        ││
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐ ││
│  │  │ SplitTree│  │ Surface  │  │ Terminal │  │ Renderer     │ ││
│  │  │ (layout) │  │ (widget) │  │ (VT emu) │  │ (Metal/GL)   │ ││
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────────┘ ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

### Component Design

#### 1. Session Manager (`src/ghostree/Session.zig`)

Manages agent sessions with lifecycle control.

```zig
pub const Session = struct {
    id: SessionId,
    name: []const u8,
    surface: *Surface,
    worktree: ?*Worktree,
    agent_type: AgentType,
    status: Status,
    created_at: i64,

    pub const Status = enum {
        initializing,
        running,
        waiting_input,    // Agent needs user attention
        completed,
        failed,
    };

    pub const AgentType = enum {
        claude_code,
        opencode,
        aider,
        custom,
    };

    pub fn spawn(config: SpawnConfig) !*Session;
    pub fn terminate(self: *Session) void;
    pub fn sendInput(self: *Session, input: []const u8) void;
    pub fn getOutput(self: *Session) []const u8;
};
```

#### 2. Worktree Manager (`src/ghostree/Worktree.zig`)

Handles git worktree creation and cleanup for agent isolation.

```zig
pub const Worktree = struct {
    path: []const u8,
    branch: []const u8,
    base_repo: []const u8,
    session_id: SessionId,

    pub fn create(repo: []const u8, branch: []const u8) !*Worktree;
    pub fn remove(self: *Worktree) void;
    pub fn getDiff(self: *Worktree) ![]const u8;
    pub fn sync(self: *Worktree) !void;
};
```

#### 3. Agent Monitor (`src/ghostree/Monitor.zig`)

Real-time monitoring and notifications.

```zig
pub const Monitor = struct {
    sessions: std.AutoHashMap(SessionId, *Session),
    notifications: NotificationQueue,

    pub fn watchSession(self: *Monitor, session: *Session) void;
    pub fn getStatusOverview(self: *Monitor) StatusOverview;
    pub fn onAgentNeedsAttention(self: *Monitor, callback: AttentionCallback) void;
};
```

#### 4. Orchestration Core (`src/ghostree/Orchestrator.zig`)

Central coordination for multi-agent workflows.

```zig
pub const Orchestrator = struct {
    app: *App,
    sessions: SessionMap,
    worktree_manager: *WorktreeManager,
    monitor: *Monitor,
    config: OrchestratorConfig,

    pub fn init(app: *App, config: OrchestratorConfig) !*Orchestrator;
    pub fn spawnAgent(self: *Orchestrator, spec: AgentSpec) !*Session;
    pub fn createLayout(self: *Orchestrator, layout: LayoutSpec) !void;
    pub fn runHook(self: *Orchestrator, hook: Hook) !void;
};
```

---

## Implementation Phases

### Phase 1: Foundation (Weeks 1-3)

**Goal:** Core infrastructure and basic session management

#### 1.1 Create Ghostree Module Structure
```
src/ghostree/
├── ghostree.zig          # Public API and module root
├── Session.zig           # Session management
├── Worktree.zig          # Git worktree handling
├── Monitor.zig           # Status monitoring
├── Orchestrator.zig      # Central coordinator
├── Config.zig            # Configuration types
├── hooks.zig             # Hook execution
└── tests/                # Unit tests
```

#### 1.2 Session Manager Implementation
- [ ] Define Session struct and lifecycle states
- [ ] Implement session creation linked to Surface
- [ ] Session termination and cleanup
- [ ] Session persistence (save/restore)

#### 1.3 Basic Agent Detection
- [ ] Detect agent type from command (claude, opencode, aider)
- [ ] Parse agent output for status detection
- [ ] Implement "waiting for input" detection patterns

#### 1.4 Integration with Existing Infrastructure
- [ ] Hook into Surface creation/destruction
- [ ] Extend App.zig with Orchestrator instance
- [ ] Add ghostree config options to Config.zig

### Phase 2: Git Worktree Isolation (Weeks 4-5)

**Goal:** Automatic worktree management for agent isolation

#### 2.1 Worktree Manager
- [ ] Worktree creation with unique branch naming
- [ ] Automatic cleanup on session end
- [ ] Worktree path resolution

#### 2.2 Repository Detection
- [ ] Auto-detect git repository from CWD
- [ ] Handle nested repositories
- [ ] Support for multiple base repositories

#### 2.3 Branch Management
- [ ] Auto-generate branch names: `ghostree/<session-id>/<task-slug>`
- [ ] Branch cleanup policies
- [ ] Conflict detection

### Phase 3: Monitoring & Notifications (Weeks 6-7)

**Goal:** Real-time status tracking and attention notifications

#### 3.1 Status Overlay
- [ ] Add status indicator to Surface (top-right corner)
- [ ] Color-coded status: 🟢 running, 🟡 waiting, 🔴 error
- [ ] Hover for details (optional)

#### 3.2 Notification System
- [ ] Desktop notifications when agent needs attention
- [ ] In-app notification queue
- [ ] Notification preferences in config

#### 3.3 Agent Output Analysis
- [ ] Pattern matching for common agent prompts
- [ ] Custom patterns per agent type
- [ ] Hook for custom detection logic

### Phase 4: Diff Viewer (Weeks 8-9)

**Goal:** Built-in diff visualization

#### 4.1 Diff Surface Mode
- [ ] New surface mode: `SurfaceMode.diff`
- [ ] Syntax-highlighted diff rendering
- [ ] Side-by-side and unified view modes

#### 4.2 Diff Integration
- [ ] One-key diff view from session (`d` in session list)
- [ ] Auto-diff on agent completion
- [ ] Diff between worktree and base

#### 4.3 Diff Navigation
- [ ] Jump between changed files
- [ ] Jump between hunks
- [ ] Keyboard shortcuts for accept/reject (future)

### Phase 5: Workspace Automation (Weeks 10-11)

**Goal:** Config-driven setup/teardown hooks

#### 5.1 Hook System
- [ ] Pre-session hooks (setup environment)
- [ ] Post-session hooks (cleanup, commit)
- [ ] On-attention hooks (custom notifications)

#### 5.2 Configuration Format
```zig
// .ghostree/config.zig or TOML
pub const Config = struct {
    hooks: struct {
        pre_session: ?[]const u8,   // "npm install"
        post_session: ?[]const u8,  // "npm run build"
        on_attention: ?[]const u8,  // Custom notification script
    },
    worktree: struct {
        base_path: ?[]const u8,     // Override worktree location
        auto_cleanup: bool,
        branch_prefix: []const u8,
    },
    agents: []AgentConfig,
};
```

#### 5.3 Environment Variables
- [ ] Pass session metadata to hooks
- [ ] GHOSTREE_SESSION_ID, GHOSTREE_WORKTREE_PATH, etc.
- [ ] Custom env vars from config

### Phase 6: Dashboard & UI (Weeks 12-14)

**Goal:** Centralized monitoring interface

#### 6.1 Dashboard Surface
- [ ] New surface type for dashboard view
- [ ] List all active sessions with status
- [ ] Quick actions (focus, terminate, diff)

#### 6.2 Layout Management
- [ ] Predefined layouts: single, side-by-side, grid
- [ ] Save/restore layouts
- [ ] Quick layout switching

#### 6.3 Keyboard Navigation
- [ ] `Ctrl+1-9` for session switching
- [ ] `Ctrl+D` for dashboard toggle
- [ ] `Ctrl+N` for new agent session

### Phase 7: IDE Integration (Weeks 15-16)

**Goal:** External editor integration

#### 7.1 Editor Launch
- [ ] Open worktree in external editor
- [ ] Support VS Code, Zed, Neovim, etc.
- [ ] Editor detection from environment

#### 7.2 File Navigation
- [ ] Open specific file from diff view
- [ ] Jump to line number
- [ ] Editor protocol support (vscode://, etc.)

---

## File Structure

```
src/
├── ghostree/
│   ├── ghostree.zig              # Module root, public API
│   ├── Session.zig               # Session management
│   ├── SessionList.zig           # Session collection
│   ├── Worktree.zig              # Git worktree management
│   ├── WorktreeManager.zig       # Worktree lifecycle
│   ├── Monitor.zig               # Status monitoring
│   ├── Orchestrator.zig          # Central coordinator
│   ├── Config.zig                # Configuration types
│   ├── Hooks.zig                 # Hook execution engine
│   ├── Notification.zig          # Notification system
│   ├── AgentDetector.zig         # Agent type/status detection
│   ├── DiffViewer.zig            # Diff rendering
│   ├── Dashboard.zig             # Dashboard UI
│   └── tests/
│       ├── session_test.zig
│       ├── worktree_test.zig
│       └── orchestrator_test.zig
├── apprt/
│   └── gtk/
│       └── class/
│           └── ghostree_dashboard.zig  # GTK dashboard widget
└── config/
    └── ghostree.zig              # Ghostree config options
```

---

## Configuration Options

Add to Ghostty's existing config system:

```
# Ghostree configuration
ghostree-enabled = true
ghostree-worktree-base = ~/.ghostree/worktrees
ghostree-auto-cleanup = true
ghostree-notification-enabled = true
ghostree-default-agent = claude-code

# Agent-specific configs
ghostree-agent-claude-code-cmd = claude
ghostree-agent-opencode-cmd = opencode
ghostree-agent-aider-cmd = aider

# Hooks
ghostree-hook-pre-session =
ghostree-hook-post-session =
ghostree-hook-on-attention =

# UI
ghostree-status-overlay = true
ghostree-dashboard-position = right
ghostree-dashboard-width = 300
```

---

## Key Bindings

| Binding | Action |
|---------|--------|
| `Ctrl+Shift+G` | Toggle Ghostree dashboard |
| `Ctrl+Shift+N` | New agent session |
| `Ctrl+Shift+1-9` | Switch to session 1-9 |
| `Ctrl+Shift+D` | Show diff for current session |
| `Ctrl+Shift+W` | Open worktree in editor |
| `Ctrl+Shift+T` | Terminate current session |

---

## Performance Considerations

### 1. Memory Efficiency
- Sessions share font cache via existing `SharedGridSet`
- Worktree paths stored as slices, not copied strings
- Lazy loading of diff content

### 2. Threading Model
- Agent output parsing on IO thread (existing termio)
- Status updates via mailbox (existing pattern)
- Hook execution on dedicated thread pool

### 3. Rendering
- Status overlay uses existing renderer infrastructure
- Dashboard reuses Surface rendering
- Diff viewer shares syntax highlighting with terminal

### 4. Git Operations
- Worktree operations are async (spawned processes)
- Diff generation cached and invalidated on file changes
- Batch cleanup operations

---

## Testing Strategy

### Unit Tests
- Session lifecycle tests
- Worktree creation/cleanup tests
- Agent detection pattern tests
- Config parsing tests

### Integration Tests
- Multi-session orchestration
- Worktree isolation verification
- Hook execution order
- Notification delivery

### Manual Testing Checklist
- [ ] Spawn 10+ agents simultaneously
- [ ] Verify worktree isolation (no cross-contamination)
- [ ] Test notification on agent attention
- [ ] Test diff viewer with large changesets
- [ ] Test hook execution order
- [ ] Test session persistence across restart

---

## Dependencies

### New Dependencies
- None required - leverages existing Zig stdlib and Ghostty infrastructure

### Existing Infrastructure Used
- `SplitTree` for layout management
- `Surface` for terminal instances
- `App` mailbox for inter-thread communication
- `Config` system for settings
- `termio` for PTY management

---

## Migration Path

1. **Phase 1-2**: No breaking changes, additive only
2. **Phase 3-4**: New config options, all optional
3. **Phase 5-7**: Full feature set, backwards compatible

---

## Success Metrics

- [ ] Can run 10+ agents simultaneously without memory bloat
- [ ] Worktree isolation prevents any cross-task interference
- [ ] Agent status correctly detected >95% of the time
- [ ] Sub-100ms latency for session switching
- [ ] Diff viewer handles 10k+ line diffs smoothly

---

## Open Questions

1. **Session persistence format**: JSON vs binary?
2. **Dashboard position**: Floating window vs split?
3. **Agent detection**: Regex patterns vs heuristics?
4. **Worktree cleanup**: Immediate vs deferred?

---

## References

- [Superset Repository](https://github.com/superset-sh/superset)
- [Ghostty SplitTree](src/datastruct/split_tree.zig)
- [Ghostty Surface](src/Surface.zig)
- [Git Worktree Documentation](https://git-scm.com/docs/git-worktree)
