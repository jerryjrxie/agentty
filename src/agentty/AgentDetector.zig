//! AgentDetector identifies agent types and detects status from output.
//!
//! This module provides:
//!   - Agent type detection from command strings
//!   - Status detection from terminal output patterns
//!   - Attention detection (when agent needs user input)

const AgentDetector = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");

/// Patterns that indicate an agent is waiting for input
const attention_patterns = [_][]const u8{
    // Claude Code patterns
    "Do you want to",
    "Would you like to",
    "Press enter to",
    "Continue?",
    "(y/n)",
    "(Y/n)",
    "(yes/no)",
    "[Y/n]",
    "[y/N]",
    "Proceed?",

    // Common CLI patterns
    "Enter your",
    "Please provide",
    "Input required",
    "Waiting for input",
    "Press any key",

    // Aider patterns
    "Add files to the chat",
    "Would you like me to",

    // Generic patterns
    "> ",
    ">>> ",
    "? ",
};

/// Patterns that indicate an agent has completed
const completion_patterns = [_][]const u8{
    "Task completed",
    "Done!",
    "Finished",
    "Successfully completed",
    "Changes applied",
    "All done",
};

/// Patterns that indicate an agent has failed
const error_patterns = [_][]const u8{
    "Error:",
    "ERROR:",
    "Failed:",
    "FAILED:",
    "Exception:",
    "fatal:",
    "panic:",
    "Aborted",
};

/// Detect agent type from a command string
pub fn detectAgentType(command: []const u8) Config.AgentType {
    if (containsWord(command, "claude")) return .claude_code;
    if (containsWord(command, "opencode")) return .opencode;
    if (containsWord(command, "aider")) return .aider;
    return .custom;
}

/// Check if output contains any of the given patterns
fn matchesAnyPattern(output: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, output, pattern) != null) return true;
    }
    return false;
}

/// Check if the output indicates the agent needs attention
pub fn detectAttention(output: []const u8) bool {
    return matchesAnyPattern(output, &attention_patterns);
}

/// Check if the output indicates completion
pub fn detectCompletion(output: []const u8) bool {
    return matchesAnyPattern(output, &completion_patterns);
}

/// Check if the output indicates an error
pub fn detectError(output: []const u8) bool {
    return matchesAnyPattern(output, &error_patterns);
}

/// Analyze output and return detected status
pub const DetectionResult = struct {
    needs_attention: bool,
    completed: bool,
    has_error: bool,
    confidence: f32, // 0.0 to 1.0

    pub fn isActionable(self: DetectionResult) bool {
        return self.needs_attention or self.completed or self.has_error;
    }
};

pub fn analyzeOutput(output: []const u8) DetectionResult {
    const needs_attention = detectAttention(output);
    const completed = detectCompletion(output);
    const has_error = detectError(output);

    // Calculate confidence based on pattern matches
    var confidence: f32 = 0.5;
    if (needs_attention) confidence += 0.2;
    if (completed) confidence += 0.2;
    if (has_error) confidence += 0.1;

    return .{
        .needs_attention = needs_attention,
        .completed = completed,
        .has_error = has_error,
        .confidence = @min(confidence, 1.0),
    };
}

/// Check if a string contains a whole word
fn containsWord(haystack: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (i < haystack.len) {
        if (std.mem.indexOf(u8, haystack[i..], word)) |pos| {
            const abs_pos = i + pos;
            const before_ok = abs_pos == 0 or !std.ascii.isAlphanumeric(haystack[abs_pos - 1]);
            const after_pos = abs_pos + word.len;
            const after_ok = after_pos >= haystack.len or !std.ascii.isAlphanumeric(haystack[after_pos]);

            if (before_ok and after_ok) {
                return true;
            }
            i = abs_pos + 1;
        } else {
            break;
        }
    }
    return false;
}

/// Detect agent type from environment or default command
pub fn detectFromEnvironment() Config.AgentType {
    // Check common environment variables
    if (std.posix.getenv("CLAUDE_CODE")) |_| {
        return .claude_code;
    }
    if (std.posix.getenv("OPENCODE_API_KEY")) |_| {
        return .opencode;
    }
    if (std.posix.getenv("AIDER_MODEL")) |_| {
        return .aider;
    }

    return .claude_code; // Default
}

test "detectAgentType" {
    try std.testing.expectEqual(Config.AgentType.claude_code, detectAgentType("claude --help"));
    try std.testing.expectEqual(Config.AgentType.claude_code, detectAgentType("/usr/bin/claude"));
    try std.testing.expectEqual(Config.AgentType.aider, detectAgentType("aider --model gpt-4"));
    try std.testing.expectEqual(Config.AgentType.opencode, detectAgentType("opencode start"));
    try std.testing.expectEqual(Config.AgentType.custom, detectAgentType("my-custom-agent"));
}

test "detectAttention" {
    try std.testing.expect(detectAttention("Do you want to continue?"));
    try std.testing.expect(detectAttention("Continue? (y/n)"));
    try std.testing.expect(detectAttention(">>> "));
    try std.testing.expect(!detectAttention("Processing files..."));
}

test "detectCompletion" {
    try std.testing.expect(detectCompletion("Task completed successfully"));
    try std.testing.expect(detectCompletion("Done!"));
    try std.testing.expect(!detectCompletion("Still working..."));
}

test "detectError" {
    try std.testing.expect(detectError("Error: file not found"));
    try std.testing.expect(detectError("FAILED: compilation error"));
    try std.testing.expect(!detectError("Everything is fine"));
}

test "analyzeOutput" {
    const result = analyzeOutput("Do you want to continue? (y/n)");
    try std.testing.expect(result.needs_attention);
    try std.testing.expect(!result.completed);
    try std.testing.expect(result.isActionable());
}
