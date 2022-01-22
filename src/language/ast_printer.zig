// Copyright (c) 2021, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Allocator = std.mem.Allocator;

const AST = @import("./ast.zig");

const Self = @This();

const DARKGRAY = "\x1b[90m";
const GRAY = "\x1b[37m";
const GREEN = "\x1b[32m";
const ORANGE = "\x1b[33m";
const MAGENTA = "\x1b[35m";
const CYAN = "\x1b[36m";
const CLEAR = "\x1b[0m";

indent_width: usize,
branches: std.ArrayList(Branch),
current_indent: usize = 0,
is_stem: bool = false,

const Branch = struct { indent: usize, concluded: bool };

pub fn init(indent_width: usize, allocator: Allocator) Self {
    return .{
        .indent_width = indent_width,
        .branches = std.ArrayList(Branch).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.branches.deinit();
}

const StemIsLast = enum { Last, NotLast };
fn setStem(self: *Self, is_last: StemIsLast) void {
    self.is_stem = true;
    if (self.branches.items.len > 0) {
        self.branches.items[self.branches.items.len - 1].concluded = is_last == .Last;
    }
}

fn indent(self: *Self) void {
    self.branches.append(.{ .indent = self.current_indent, .concluded = false }) catch unreachable;
    self.current_indent += self.indent_width;
}

fn dedent(self: *Self) void {
    _ = self.branches.pop();
    self.current_indent -= self.indent_width;
}

fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
    const writer = std.io.getStdErr().writer();
    writer.writeAll(DARKGRAY) catch return;

    var last_indent: usize = 0;
    for (self.branches.items) |branch, i| {
        if (i + 1 == self.branches.items.len) {
            if (self.is_stem) {
                writer.writeAll(if (branch.concluded) "└" else "├") catch return;
            } else {
                writer.writeAll("│") catch return;
            }

            var stem_i: usize = 0;
            while (stem_i < self.current_indent - branch.indent - 2) : (stem_i += 1) {
                writer.writeAll(if (self.is_stem) "─" else " ") catch return;
            }
            writer.writeAll("╴") catch return;
        } else {
            writer.writeAll(if (!branch.concluded) "│" else " ") catch return;
            writer.writeByteNTimes(' ', self.indent_width - 1) catch return;
        }

        last_indent = branch.indent;
    }

    writer.writeAll(CLEAR) catch return;
    std.debug.print(fmt, args);
}

pub fn dumpScript(self: *Self, script: AST.ScriptNode) void {
    self.print(CYAN ++ "ScriptNode\n" ++ CLEAR, .{});

    self.indent();
    for (script.statements) |statement, i| {
        self.setStem(if (i == script.statements.len - 1) .Last else .NotLast);
        self.dumpStatement(statement);
    }
    self.dedent();
}

pub fn dumpStatement(self: *Self, statement: AST.StatementNode) void {
    self.print(CYAN ++ "StatementNode\n" ++ CLEAR, .{});

    self.indent();
    self.setStem(.Last);
    self.dumpExpression(statement.expression);
    self.dedent();
}

pub fn dumpExpression(self: *Self, expression: AST.ExpressionNode) void {
    self.print(CYAN ++ "ExpressionNode\n" ++ CLEAR, .{});

    self.indent();
    self.setStem(.Last);
    switch (expression) {
        .Object => |object| self.dumpObject(object.*),
        .Block => |block| self.dumpBlock(block.*),
        .Message => |message| self.dumpMessage(message.*),
        .Return => |return_node| self.dumpReturn(return_node.*),

        .Identifier => |identifier| self.dumpIdentifier(identifier),
        .String => |string| self.dumpString(string),
        .Number => |number| self.dumpNumber(number),
    }
    self.dedent();
}

pub fn dumpObject(self: *Self, object: AST.ObjectNode) void {
    self.print(CYAN ++ "ObjectNode\n" ++ CLEAR, .{});
    self.indent();

    self.setStem(.NotLast);
    self.print("slots:\n", .{});
    self.indent();
    for (object.slots) |slot, i| {
        self.setStem(if (i == object.slots.len - 1) .Last else .NotLast);
        self.dumpSlot(slot);
    }
    self.dedent();

    self.setStem(.Last);
    self.print("statements:\n", .{});
    self.indent();
    for (object.statements) |statement, i| {
        self.setStem(if (i == object.statements.len - 1) .Last else .NotLast);
        self.dumpStatement(statement);
    }
    self.dedent();

    self.dedent();
}

pub fn dumpSlot(self: *Self, slot: AST.SlotNode) void {
    const is_mutable_string: []const u8 = if (slot.is_mutable) GREEN ++ "mutable" ++ CLEAR else GRAY ++ "not mutable" ++ CLEAR;
    const is_parent_string: []const u8 = if (slot.is_parent) GREEN ++ "parent" ++ CLEAR else GRAY ++ "not parent" ++ CLEAR;
    const is_argument_string: []const u8 = if (slot.is_argument) GREEN ++ "argument" ++ CLEAR else GRAY ++ "not argument" ++ CLEAR;
    self.print(
        CYAN ++ "SlotNode" ++ CLEAR ++ " ({s}, {s}, {s})\n",
        .{ is_mutable_string, is_parent_string, is_argument_string },
    );
    self.indent();

    self.setStem(.NotLast);
    self.print("name: " ++ GREEN ++ "\"{s}\"\n" ++ CLEAR, .{slot.name});
    self.setStem(.NotLast);
    self.print("arguments: " ++ GREEN, .{});
    for (slot.arguments) |argument, i| {
        if (i != 0) std.debug.print(", ", .{});
        std.debug.print("\"{s}\"", .{argument});
    }
    std.debug.print("\n" ++ CLEAR, .{});

    self.setStem(.Last);
    self.print("value:\n", .{});
    self.indent();
    self.setStem(.Last);
    self.dumpExpression(slot.value);
    self.dedent();

    self.dedent();
}

pub fn dumpBlock(self: *Self, block: AST.BlockNode) void {
    self.print(CYAN ++ "BlockNode\n" ++ CLEAR, .{});
    self.indent();

    self.setStem(.NotLast);
    self.print("slots:\n", .{});
    self.indent();
    for (block.slots) |slot, i| {
        self.setStem(if (i == block.slots.len - 1) .Last else .NotLast);
        self.dumpSlot(slot);
    }
    self.dedent();

    self.setStem(.Last);
    self.print("statements:\n", .{});
    self.indent();
    for (block.statements) |statement, i| {
        self.setStem(if (i == block.statements.len - 1) .Last else .NotLast);
        self.dumpStatement(statement);
    }
    self.dedent();

    self.dedent();
}

pub fn dumpIdentifier(self: *Self, identifier: AST.IdentifierNode) void {
    self.print(CYAN ++ "IdentifierNode " ++ GREEN ++ "\"{s}\"\n" ++ CLEAR, .{identifier.value});
}

pub fn dumpMessage(self: *Self, message: AST.MessageNode) void {
    const message_type: []const u8 = blk: {
        if (message.arguments.len == 0) {
            break :blk GREEN ++ "unary" ++ CLEAR;
        } else if (message.arguments.len == 1 and !std.ascii.isAlpha(message.message_name[0]) and message.message_name[0] != '_') {
            break :blk MAGENTA ++ "binary" ++ CLEAR;
        } else {
            break :blk ORANGE ++ "keyword" ++ CLEAR;
        }
    };

    self.print(CYAN ++ "MessageNode" ++ CLEAR ++ " ({s})\n", .{message_type});
    self.indent();

    self.setStem(.NotLast);
    self.print("receiver:\n", .{});
    self.indent();
    self.setStem(.Last);
    self.dumpExpression(message.receiver);
    self.dedent();

    self.setStem(if (message.arguments.len == 0) .Last else .NotLast);
    self.print("name: " ++ GREEN ++ "\"{s}\"\n" ++ CLEAR, .{message.message_name});

    if (message.arguments.len > 0) {
        self.setStem(.Last);
        self.print("arguments:\n", .{});
        self.indent();
        for (message.arguments) |argument, i| {
            self.setStem(if (i == message.arguments.len - 1) .Last else .NotLast);
            self.dumpExpression(argument);
        }
        self.dedent();
    }

    self.dedent();
}

pub fn dumpReturn(self: *Self, return_node: AST.ReturnNode) void {
    self.print(CYAN ++ "ReturnNode\n" ++ CLEAR, .{});
    self.indent();

    self.setStem(.Last);
    self.dumpExpression(return_node.expression);

    self.dedent();
}

pub fn dumpString(self: *Self, string: AST.StringNode) void {
    self.print(CYAN ++ "StringNode" ++ CLEAR ++ " (" ++ GREEN ++ "{}" ++ CLEAR ++ " bytes)\n", .{string.value.len});
    self.indent();

    self.setStem(.Last);
    self.print("content: \"{s}", .{string.value[0..std.math.min(200, string.value.len)]});
    if (string.value.len > 200) {
        std.debug.print("...", .{});
    }
    std.debug.print("\"\n", .{});

    self.dedent();
}

pub fn dumpNumber(self: *Self, number: AST.NumberNode) void {
    self.print(CYAN ++ "NumberNode " ++ CLEAR, .{});
    switch (number.value) {
        .Integer => |integer| std.debug.print("{}\n", .{integer}),
        .FloatingPoint => |floating_point| std.debug.print("{}\n", .{floating_point}),
    }
}
