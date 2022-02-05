// Copyright (c) 2021, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Allocator = std.mem.Allocator;

const Heap = @import("./heap.zig");
const Value = @import("./value.zig").Value;
const Activation = @import("./activation.zig");
const interpreter = @import("./interpreter.zig");

const Self = @This();

/// The types of completion that can happen.
pub const CompletionData = union(enum) {
    /// A normal completion which returns a simple value.
    Normal: Value,
    /// A non-local return, which will rise through the call stack until it
    /// reaches the method in which the block was defined, where it will become
    /// a normal completion.
    NonlocalReturn: NonlocalReturnCompletionData,
    /// A runtime error.
    RuntimeError: []const u8,
    /// A completion telling the current method or block to restart its execution
    /// from the first statement.
    Restart: void,
};

/// The data that's required to perform a nonlocal return.
pub const NonlocalReturnCompletionData = struct {
    /// The activation at which this non-local return should become the
    /// regular return value.
    target_activation: Activation.Weak,
    // FIXME: We shouldn't allocate while a non-local return is bubbling,
    //        so this tracking is pointless. Turn it into a regular Value.
    /// The value that should be returned when the non-local return reaches
    /// its destination.
    value: Heap.Tracked,
};

data: CompletionData,

/// Initializes a new normal completion with the given value.
pub fn initNormal(value: Value) Self {
    return .{ .data = .{ .Normal = value } };
}

/// Initializes a new non-local return completion.
pub fn initNonlocalReturn(target_activation: Activation.Weak, value: Heap.Tracked) Self {
    return .{ .data = .{ .NonlocalReturn = .{ .target_activation = target_activation, .value = value } } };
}

/// Creates a new runtime error completion with the given format string and parameters.
pub fn initRuntimeError(allocator: Allocator, comptime fmt: []const u8, args: anytype) interpreter.InterpreterError!Self {
    const error_message = try std.fmt.allocPrint(allocator, fmt, args);
    return Self{ .data = .{ .RuntimeError = error_message } };
}

/// Creates a restart completion.
pub fn initRestart() Self {
    return .{ .data = .{ .Restart = .{} } };
}

/// Deinitializes values in this completion as necessary.
pub fn deinit(self: *Self, allocator: Allocator) void {
    switch (self.data) {
        .Normal, .Restart => {},
        .NonlocalReturn => |nonlocal_return| {
            nonlocal_return.target_activation.deinit();
            // NOTE: We explicitly DON'T untrack the heap value here, as that will be borrowed by
            //       executeMethodMessage when the value has arrived to its intended destination.
        },
        .RuntimeError => |err| allocator.free(err),
    }
}

pub fn isNormal(self: Self) bool {
    return self.data == .Normal;
}
