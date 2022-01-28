// Copyright (c) 2021, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Allocator = std.mem.Allocator;

const AST = @import("../language/ast.zig");
const Slot = @import("./slot.zig").Slot;
const Heap = @import("./heap.zig");
const Value = @import("./value.zig").Value;
const Object = @import("./object.zig");
const Script = @import("../language/script.zig");
const Activation = @import("./activation.zig");
const ByteVector = @import("./byte_vector.zig");
const environment = @import("./environment.zig");
const runtime_error = @import("./error.zig");
const ASTCopyVisitor = @import("../language/ast_copy_visitor.zig");

const message_interpreter = @import("./interpreter/message.zig");

pub const InterpreterContext = struct {
    /// The object that is the current context. The identifier "self" will
    /// resolve to this object.
    self_object: Heap.Tracked,
    /// The root of the current Self world.
    lobby: Heap.Tracked,
    /// The method/block activation stack. This is used with blocks in order to
    /// verify that the block is executed within its enclosing method and for
    /// stack traces. When the activation completes, the activation object is
    /// popped; when a new activation occurs, it is pushed. Pushed objects must
    /// be pushed with the assumption that 1 ref is borrowed by this stack.
    activation_stack: *std.ArrayList(*Activation),
    /// The script file that is currently executing, used to resolve the
    /// relative paths of other script files.
    script: Script.Ref,
    /// The current error message value. executeScript catches this and displays
    /// the error with a stack trace. The user must free it.
    current_error: ?[]const u8,
    /// The current non-local return value. Should *NOT* rise to executeScript.
    current_nonlocal_return: ?struct {
        /// The activation at which this non-local return should become the
        /// regular return value.
        target_activation: Activation.Weak,
        /// The value that should be returned when the non-local return reaches
        /// its destination.
        value: Heap.Tracked,
    },
};

// FIXME: These aren't very nice. Collect them into a single place.
pub const NonlocalReturnError = error{NonlocalReturn};
pub const InterpreterError = Allocator.Error || runtime_error.SelfRuntimeError || NonlocalReturnError;

/// Executes a script node. `lobby` is ref'd for the function lifetime. The last
/// expression result is returned, or if no statements were available, null is
/// returned.
///
/// Borrows a ref for `script` from the caller.
pub fn executeScript(allocator: Allocator, heap: *Heap, script: Script.Ref, lobby: Value) InterpreterError!?Value {
    defer script.unref();

    var activation_stack = std.ArrayList(*Activation).init(allocator);
    defer activation_stack.deinit();
    errdefer {
        for (activation_stack.items) |activation| {
            activation.destroy();
        }
    }

    heap.setActivationStack(&activation_stack);
    defer heap.setActivationStack(null);

    var tracked_lobby = try heap.track(lobby);
    defer tracked_lobby.untrackAndDestroy(heap);

    var context = InterpreterContext{
        .self_object = tracked_lobby,
        .lobby = tracked_lobby,
        .activation_stack = &activation_stack,
        .script = script,
        .current_error = null,
        .current_nonlocal_return = null,
    };
    var last_expression_result: ?Heap.Tracked = null;
    for (script.value.ast_root.?.statements) |statement| {
        std.debug.assert(activation_stack.items.len == 0);

        if (last_expression_result) |result| {
            result.untrackAndDestroy(heap);
        }

        const expression_result = executeStatement(allocator, heap, statement, &context) catch |err| {
            switch (err) {
                runtime_error.SelfRuntimeError.RuntimeError => {
                    var error_message = context.current_error.?;
                    defer allocator.free(error_message);

                    std.debug.print("Received error at top level: {s}\n", .{error_message});
                    runtime_error.printTraceFromActivationStack(activation_stack.items);

                    // Since the execution was abruptly stopped the activation
                    // stack wasn't properly unwound, so let's do that now.
                    for (activation_stack.items) |activation| {
                        activation.destroy();
                    }

                    return null;
                },
                NonlocalReturnError.NonlocalReturn => {
                    std.debug.print("A non-local return has bubbled up to the top! This is likely a bug!", .{});
                    runtime_error.printTraceFromActivationStack(activation_stack.items);
                    context.current_nonlocal_return.?.target_activation.deinit();
                    context.current_nonlocal_return.?.value.untrackAndDestroy(heap);

                    // Since the execution was abruptly stopped the activation
                    // stack wasn't properly unwound, so let's do that now.
                    for (activation_stack.items) |activation| {
                        activation.destroy();
                    }

                    return null;
                },
                else => return err,
            }
        };

        last_expression_result = try heap.track(expression_result);
    }

    return if (last_expression_result) |result| result.getValue() else null;
}

/// Execute a script object as a child script of the root script. The root
/// interpreter context is passed in order to preserve the activation stack and
/// various other context objects.
///
/// Borrows a ref for `script` from the caller.
pub fn executeSubScript(allocator: Allocator, heap: *Heap, script: Script.Ref, parent_context: *InterpreterContext) InterpreterError!?Value {
    defer script.unref();

    var child_context = InterpreterContext{
        .self_object = parent_context.lobby,
        .lobby = parent_context.lobby,
        .activation_stack = parent_context.activation_stack,
        .script = script,
        .current_error = null,
        .current_nonlocal_return = null,
    };
    var last_expression_result: ?Heap.Tracked = null;
    for (script.value.ast_root.?.statements) |statement| {
        if (last_expression_result) |result| {
            result.untrackAndDestroy(heap);
        }

        const expression_result = executeStatement(allocator, heap, statement, &child_context) catch |err| {
            switch (err) {
                runtime_error.SelfRuntimeError.RuntimeError => {
                    // Pass the error message up the script chain.
                    parent_context.current_error = child_context.current_error;
                    // Allow the error to keep bubbling up.
                    return err;
                },
                NonlocalReturnError.NonlocalReturn => {
                    return runtime_error.raiseError(allocator, parent_context, "A non-local return has bubbled up to the top of a sub-script! This is likely a bug!", .{});
                },
                else => return err,
            }
        };
        last_expression_result = try heap.track(expression_result);
    }

    return if (last_expression_result) |result| result.getValue() else null;
}

/// Executes a statement. All refs are forwardded.
pub fn executeStatement(allocator: Allocator, heap: *Heap, statement: AST.StatementNode, context: *InterpreterContext) InterpreterError!Value {
    return try executeExpression(allocator, heap, statement.expression, context);
}

/// Executes an expression. All refs are forwarded.
pub fn executeExpression(allocator: Allocator, heap: *Heap, expression: AST.ExpressionNode, context: *InterpreterContext) InterpreterError!Value {
    return switch (expression) {
        .Object => |object| try executeObject(allocator, heap, object.*, context),
        .Block => |block| try executeBlock(allocator, heap, block.*, context),
        .Message => |message| try message_interpreter.executeMessage(allocator, heap, message.*, context),
        .Return => |return_node| return executeReturn(allocator, heap, return_node.*, context),

        .Identifier => |identifier| try executeIdentifier(allocator, heap, identifier, context),
        .String => |string| try executeString(allocator, heap, string, context),
        .Number => |number| try executeNumber(allocator, heap, number, context),
    };
}

/// Creates a new method object. All refs are forwarded. `arguments` and
/// `object_node`'s statements are copied.
fn executeMethod(
    allocator: Allocator,
    heap: *Heap,
    name: []const u8,
    object_node: AST.ObjectNode,
    arguments: [][]const u8,
    context: *InterpreterContext,
) InterpreterError!Value {
    var assignable_slot_values = try std.ArrayList(Heap.Tracked).initCapacity(allocator, arguments.len);
    defer {
        for (assignable_slot_values.items) |value| {
            value.untrackAndDestroy(heap);
        }
        assignable_slot_values.deinit();
    }

    var statements = try std.ArrayList(AST.StatementNode).initCapacity(allocator, object_node.slots.len);
    errdefer {
        for (statements.items) |*statement| {
            statement.deinit(allocator);
        }
        statements.deinit();
    }

    for (object_node.statements) |statement| {
        var statement_copy = try ASTCopyVisitor.visitStatement(statement, allocator);
        errdefer statement_copy.deinit(allocator);

        try statements.append(statement_copy);
    }

    // This will prevent garbage collections until the execution of slots at
    // least.
    var required_memory: usize = ByteVector.requiredSizeForAllocation(name.len);
    required_memory += Object.Map.Method.requiredSizeForAllocation(@intCast(u32, object_node.slots.len + arguments.len));
    for (arguments) |argument| {
        required_memory += ByteVector.requiredSizeForAllocation(argument.len);
    }

    try heap.ensureSpaceInEden(required_memory);

    context.script.ref();
    // NOTE: Once we create the method map successfully, the ref we just created
    // above is owned by the method_map, and we shouldn't try to unref in case
    // of an error.
    var method_map = blk: {
        errdefer context.script.unref();

        const method_name_in_heap = try ByteVector.createFromString(heap, name);
        break :blk try Object.Map.Method.create(
            heap,
            @intCast(u8, arguments.len),
            @intCast(u32, object_node.slots.len),
            statements.toOwnedSlice(),
            method_name_in_heap,
            context.script,
        );
    };

    var slot_init_offset: usize = 0;

    const argument_slots = method_map.getArgumentSlots();
    for (arguments) |argument| {
        const argument_in_heap = try ByteVector.createFromString(heap, argument);
        argument_slots[slot_init_offset].initMutable(Object.Map.Method, method_map, argument_in_heap, .NotParent);
        assignable_slot_values.appendAssumeCapacity(try heap.track(environment.globalNil()));

        slot_init_offset += 1;
    }

    const tracked_method_map = try heap.track(method_map.asValue());
    defer tracked_method_map.untrackAndDestroy(heap);

    for (object_node.slots) |slot_node| {
        var slot_value = try executeSlot(allocator, heap, slot_node, Object.Map.Method, tracked_method_map.getValue().asObject().asMap().asMethodMap(), slot_init_offset, context);
        if (slot_value) |value| {
            try assignable_slot_values.append(try heap.track(value));
        }

        slot_init_offset += 1;
    }

    // Ensure that creating the method object won't cause a garbage collection
    // before the assignable slot values are copied in.
    try heap.ensureSpaceInEden(Object.Method.requiredSizeForAllocation(@intCast(u8, assignable_slot_values.items.len)));

    var current_assignable_slot_values = try allocator.alloc(Value, assignable_slot_values.items.len);
    defer allocator.free(current_assignable_slot_values);
    for (assignable_slot_values.items) |value, i| {
        current_assignable_slot_values[i] = value.getValue();
    }

    return (try Object.Method.create(heap, tracked_method_map.getValue().asObject().asMap().asMethodMap(), current_assignable_slot_values)).asValue();
}

/// Creates a new slot. All refs are forwarded.
pub fn executeSlot(
    allocator: Allocator,
    heap: *Heap,
    slot_node: AST.SlotNode,
    comptime MapType: type,
    map: *MapType,
    slot_index: usize,
    context: *InterpreterContext,
) InterpreterError!?Value {
    var value = blk: {
        if (slot_node.value == .Object and slot_node.value.Object.statements.len > 0) {
            break :blk try executeMethod(allocator, heap, slot_node.name, slot_node.value.Object.*, slot_node.arguments, context);
        } else {
            break :blk try executeExpression(allocator, heap, slot_node.value, context);
        }
    };
    const tracked_value = try heap.track(value);
    defer tracked_value.untrackAndDestroy(heap);

    const slot_name = try ByteVector.createFromString(heap, slot_node.name);
    if (slot_node.is_mutable) {
        map.getSlots()[slot_index].initMutable(MapType, map, slot_name, if (slot_node.is_parent) Slot.ParentFlag.Parent else Slot.ParentFlag.NotParent);
        return tracked_value.getValue();
    } else {
        map.getSlots()[slot_index].initConstant(slot_name, if (slot_node.is_parent) Slot.ParentFlag.Parent else Slot.ParentFlag.NotParent, tracked_value.getValue());
        return null;
    }
}

/// Creates a new slots object. All refs are forwarded.
pub fn executeObject(allocator: Allocator, heap: *Heap, object_node: AST.ObjectNode, context: *InterpreterContext) InterpreterError!Value {
    // Verify that we are executing a slots object and not a method; methods
    // are created through executeSlot.
    if (object_node.statements.len > 0) {
        @panic("!!! Attempted to execute a non-slots object! Methods must be created via executeSlot.");
    }

    var assignable_slot_values = std.ArrayList(Heap.Tracked).init(allocator);
    defer {
        for (assignable_slot_values.items) |value| {
            value.untrackAndDestroy(heap);
        }
        assignable_slot_values.deinit();
    }

    var slots_map = try Object.Map.Slots.create(heap, @intCast(u32, object_node.slots.len));
    const tracked_slots_map = try heap.track(slots_map.asValue());

    for (object_node.slots) |slot_node, i| {
        var slot_value = try executeSlot(allocator, heap, slot_node, Object.Map.Slots, tracked_slots_map.getValue().asObject().asMap().asSlotsMap(), i, context);
        if (slot_value) |value| {
            try assignable_slot_values.append(try heap.track(value));
        }
    }

    // Ensure that creating the slots object won't cause a garbage collection
    // before the assignable slot values are copied in.
    try heap.ensureSpaceInEden(Object.Slots.requiredSizeForAllocation(@intCast(u8, assignable_slot_values.items.len)));

    var current_assignable_slot_values = try allocator.alloc(Value, assignable_slot_values.items.len);
    defer allocator.free(current_assignable_slot_values);
    for (assignable_slot_values.items) |value, i| {
        current_assignable_slot_values[i] = value.getValue();
    }

    return (try Object.Slots.create(heap, tracked_slots_map.getValue().asObject().asMap().asSlotsMap(), current_assignable_slot_values)).asValue();
}

pub fn executeBlock(allocator: Allocator, heap: *Heap, block: AST.BlockNode, context: *InterpreterContext) InterpreterError!Value {
    var argument_slot_count: u8 = 0;
    for (block.slots) |slot_node| {
        if (slot_node.is_argument) argument_slot_count += 1;
    }

    // FIXME: Track slot values and untrack them on error/return
    var assignable_slot_values = try std.ArrayList(Heap.Tracked).initCapacity(allocator, argument_slot_count);
    defer {
        for (assignable_slot_values.items) |value| {
            value.untrackAndDestroy(heap);
        }
        assignable_slot_values.deinit();
    }

    var statements = try std.ArrayList(AST.StatementNode).initCapacity(allocator, block.statements.len);
    errdefer {
        for (statements.items) |*statement| {
            statement.deinit(allocator);
        }
        statements.deinit();
    }

    for (block.statements) |statement| {
        var statement_copy = try ASTCopyVisitor.visitStatement(statement, allocator);
        errdefer statement_copy.deinit(allocator);

        try statements.append(statement_copy);
    }

    // The latest activation is where the block was created, so it will always
    // be the parent activation (i.e., where we look for parent blocks' and the
    // method's slots).
    const parent_activation = context.activation_stack.items[context.activation_stack.items.len - 1];
    // However, we want the _method_ as the non-local return target; because the
    // non-local return can only be returned by the method in which the block
    // making the non-local return was defined, this needs to be separate from
    // parent_activation. If the parent activation is a block, it will also
    // contain a target activation; if it's a method the target activation _is_
    // the parent.
    const nonlocal_return_target_activation = if (parent_activation.nonlocal_return_target_activation) |target| target else parent_activation;
    std.debug.assert(nonlocal_return_target_activation.nonlocal_return_target_activation == null);

    var required_memory: usize = Object.Map.Block.requiredSizeForAllocation(@intCast(u32, block.slots.len));
    for (block.slots) |slot_node| {
        if (slot_node.is_argument) {
            required_memory += ByteVector.requiredSizeForAllocation(slot_node.name.len);
        }
    }

    try heap.ensureSpaceInEden(required_memory);

    context.script.ref();
    // NOTE: Once we create the block map successfully, the ref we just created
    // above is owned by the block_map, and we shouldn't try to unref in case
    // of an error.
    var block_map = blk: {
        errdefer context.script.unref();

        break :blk try Object.Map.Block.create(
            heap,
            argument_slot_count,
            @intCast(u32, block.slots.len) - argument_slot_count,
            statements.toOwnedSlice(),
            parent_activation,
            nonlocal_return_target_activation,
            context.script,
        );
    };

    var slot_init_offset: usize = 0;

    // Add all the argument slots
    var argument_slots = block_map.getArgumentSlots();
    for (block.slots) |slot_node| {
        if (slot_node.is_argument) {
            const slot_name = try ByteVector.createFromString(heap, slot_node.name);

            argument_slots[slot_init_offset].initMutable(
                Object.Map.Block,
                block_map,
                slot_name,
                if (slot_node.is_parent) Slot.ParentFlag.Parent else Slot.ParentFlag.NotParent,
            );
            assignable_slot_values.appendAssumeCapacity(try heap.track(environment.globalNil()));

            slot_init_offset += 1;
        }
    }

    const tracked_block_map = try heap.track(block_map.asValue());
    defer tracked_block_map.untrackAndDestroy(heap);

    // Add all the non-argument slots
    for (block.slots) |slot_node| {
        if (!slot_node.is_argument) {
            var slot_value = try executeSlot(allocator, heap, slot_node, Object.Map.Block, tracked_block_map.getValue().asObject().asMap().asBlockMap(), slot_init_offset, context);
            if (slot_value) |value| {
                try assignable_slot_values.append(try heap.track(value));
            }

            slot_init_offset += 1;
        }
    }

    // Ensure that creating the block object won't cause a garbage collection
    // before the assignable slot values are copied in.
    try heap.ensureSpaceInEden(Object.Block.requiredSizeForAllocation(@intCast(u8, assignable_slot_values.items.len)));

    var current_assignable_slot_values = try allocator.alloc(Value, assignable_slot_values.items.len);
    defer allocator.free(current_assignable_slot_values);
    for (assignable_slot_values.items) |value, i| {
        current_assignable_slot_values[i] = value.getValue();
    }

    return (try Object.Block.create(heap, block_map, current_assignable_slot_values)).asValue();
}

pub fn executeReturn(allocator: Allocator, heap: *Heap, return_node: AST.ReturnNode, context: *InterpreterContext) InterpreterError {
    _ = heap;
    const latest_activation = context.activation_stack.items[context.activation_stack.items.len - 1];
    const target_activation = latest_activation.nonlocal_return_target_activation.?;
    std.debug.assert(target_activation.nonlocal_return_target_activation == null);

    const value = try executeExpression(allocator, heap, return_node.expression, context);
    const target_activation_weak = target_activation.makeWeakRef();
    context.current_nonlocal_return = .{ .target_activation = target_activation_weak, .value = try heap.track(value) };

    return NonlocalReturnError.NonlocalReturn;
}

/// Executes an identifier expression. If the looked up value exists, the value
/// gains a ref. `self_object` gains a ref during a method execution.
pub fn executeIdentifier(allocator: Allocator, heap: *Heap, identifier: AST.IdentifierNode, context: *InterpreterContext) InterpreterError!Value {
    _ = heap;
    if (identifier.value[0] == '_') {
        var receiver = context.self_object.getValue();

        if (receiver.isObjectReference() and receiver.asObject().isActivationObject()) {
            receiver = receiver.asObject().asActivationObject().findActivationReceiver();
        }

        var tracked_receiver = try heap.track(receiver);
        defer tracked_receiver.untrackAndDestroy(heap);

        return try message_interpreter.executePrimitiveMessage(allocator, heap, identifier.range, tracked_receiver, identifier.value, &[_]Heap.Tracked{}, context);
    }

    // Check for block activation. Note that this isn't the same as calling a
    // method on traits block, this is actually executing the block itself via
    // the virtual method.
    {
        var receiver = context.self_object.getValue();
        if (receiver.isObjectReference() and receiver.asObject().isActivationObject()) {
            receiver = receiver.asObject().asActivationObject().findActivationReceiver();
        }

        if (receiver.isObjectReference() and
            receiver.asObject().isBlockObject() and
            receiver.asObject().asBlockObject().isCorrectMessageForBlockExecution(identifier.value))
        {
            var tracked_receiver = try heap.track(receiver);
            defer tracked_receiver.untrackAndDestroy(heap);

            return try message_interpreter.executeBlockMessage(allocator, heap, identifier.range, tracked_receiver, &[_]Heap.Tracked{}, context);
        }
    }

    if (try context.self_object.getValue().lookup(.Read, identifier.value, allocator, context)) |lookup_result| {
        if (lookup_result.isObjectReference() and lookup_result.asObject().isMethodObject()) {
            var tracked_lookup_result = try heap.track(lookup_result);
            defer tracked_lookup_result.untrackAndDestroy(heap);

            return try message_interpreter.executeMethodMessage(
                allocator,
                heap,
                identifier.range,
                context.self_object,
                tracked_lookup_result,
                &[_]Heap.Tracked{},
                context,
            );
        } else {
            return lookup_result;
        }
    } else {
        return runtime_error.raiseError(allocator, context, "Failed looking up \"{s}\"", .{identifier.value});
    }
}

/// Executes a string literal expression. `lobby` gains a ref during the
/// lifetime of the function.
pub fn executeString(allocator: Allocator, heap: *Heap, string: AST.StringNode, context: *InterpreterContext) InterpreterError!Value {
    _ = allocator;
    _ = heap;
    _ = context;

    try heap.ensureSpaceInEden(
        ByteVector.requiredSizeForAllocation(string.value.len) +
            Object.Map.ByteVector.requiredSizeForAllocation() +
            Object.ByteVector.requiredSizeForAllocation(),
    );

    const byte_vector = try ByteVector.createFromString(heap, string.value);
    const byte_vector_map = try Object.Map.ByteVector.create(heap, byte_vector);
    return (try Object.ByteVector.create(heap, byte_vector_map)).asValue();
}

/// Executes a number literal expression. `lobby` gains a ref during the
/// lifetime of the function.
pub fn executeNumber(allocator: Allocator, heap: *Heap, number: AST.NumberNode, context: *InterpreterContext) InterpreterError!Value {
    _ = allocator;
    _ = heap;
    _ = context;

    return switch (number.value) {
        .Integer => Value.fromInteger(number.value.Integer),
        .FloatingPoint => Value.fromFloatingPoint(number.value.FloatingPoint),
    };
}
