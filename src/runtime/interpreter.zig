// Copyright (c) 2021-2022, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

const Heap = @import("./Heap.zig");
const Slot = slot_import.Slot;
const debug = @import("../debug.zig");
const Actor = @import("./Actor.zig");
const bless = @import("./object_bless.zig");
const Value = @import("./value.zig").Value;
const Object = @import("./object.zig").Object;
const bytecode = @import("./bytecode.zig");
const BlockMap = block_object.BlockMap;
const SlotsMap = slots_object.SlotsMap;
const ByteArray = @import("./ByteArray.zig");
const MethodMap = method_object.MethodMap;
const traversal = @import("./object_traversal.zig");
const Activation = @import("./Activation.zig");
const Completion = @import("./Completion.zig");
const primitives = @import("./primitives.zig");
const SourceRange = @import("./SourceRange.zig");
const BlockObject = block_object.Block;
const SlotsObject = slots_object.Slots;
const slot_import = @import("./slot.zig");
const block_object = @import("objects/block.zig");
const slots_object = @import("objects/slots.zig");
const MethodObject = method_object.Method;
const method_object = @import("objects/method.zig");
const VirtualMachine = @import("./VirtualMachine.zig");
const ByteArrayObject = @import("objects/byte_array.zig").ByteArray;
const ActivationObject = @import("objects/activation.zig").Activation;

const EXECUTION_DEBUG = debug.EXECUTION_DEBUG;

/// The result of executing a single instruction.
pub const ExecutionResult = union(enum) {
    /// The current actor has been switched.
    ActorSwitch,
    /// An activation has been entered or exited (but not the last activation).
    ActivationChange,
    /// The instruction successfully executed.
    Success,
    /// A completion happened. Either the last activation was exited (in which
    /// case the a Normal completion is returned), or a runtime error was raised.
    Completion: Completion,

    pub fn success() ExecutionResult {
        return .{ .Success = {} };
    }

    pub fn activationChange() ExecutionResult {
        return .{ .ActivationChange = {} };
    }

    pub fn actorSwitch() ExecutionResult {
        return .{ .ActorSwitch = {} };
    }

    pub fn completion(c: Completion) ExecutionResult {
        return .{ .Completion = c };
    }
};

const activation_change = ExecutionResult.activationChange();
const success = ExecutionResult.success();
pub fn execute(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
) !ExecutionResult {
    const source_range = SourceRange.initNoRef(executable, actor.range);

    // FIXME: Re-enable this.
    // if (EXECUTION_DEBUG) std.debug.print("[#{} {s}] Executing: {} = {}\n", .{ actor.id, executable.value.definition_script.value.file_path, inst.target, inst });

    const target_location = block.getTargetLocation(instruction_id);
    return switch (block.getOpcode(instruction_id)) {
        .Send => try opcodeSend(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .SelfSend => try opcodeSelfSend(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .PrimSend => try opcodePrimSend(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .SelfPrimSend => try opcodeSelfPrimSend(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .PushConstantSlot => try opcodePushConstantSlot(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .PushAssignableSlot => try opcodePushAssignableSlot(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .PushArgumentSlot => try opcodePushArgumentSlot(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .PushInheritedSlot => try opcodePushInheritedSlot(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .CreateInteger => try opcodeCreateInteger(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .CreateFloatingPoint => try opcodeCreateFloatingPoint(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .CreateByteArray => try opcodeCreateByteArray(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .CreateObject => try opcodeCreateObject(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .CreateMethod => try opcodeCreateMethod(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .CreateBlock => try opcodeCreateBlock(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .Return => try opcodeReturn(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .NonlocalReturn => try opcodeNonlocalReturn(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .PushArg => try opcodePushArg(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .PushRegisters => try opcodePushRegisters(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .SetMethodInline => try opcodeSetMethodInline(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .SourceRange => try opcodeSourceRange(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .PushArgumentSentinel => try opcodePushArgumentSentinel(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .PushSlotSentinel => try opcodePushSlotSentinel(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .VerifyArgumentSentinel => try opcodeVerifyArgumentSentinel(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
        .VerifySlotSentinel => try opcodeVerifySlotSentinel(vm, actor, last_activation_ref, executable, block, instruction_id, target_location, source_range),
    };
}

fn opcodeSend(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = executable;
    _ = last_activation_ref;
    const payload = block.getTypedPayload(instruction_id, .Send);
    const receiver = vm.readRegister(payload.receiver_location);
    return try performSend(vm, actor, receiver, payload.message_name, target_location, source_range);
}

fn opcodeSelfSend(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = executable;
    _ = last_activation_ref;
    const payload = block.getTypedPayload(instruction_id, .SelfSend);
    const receiver = actor.activation_stack.getCurrent().activation_object.value;
    return try performSend(vm, actor, receiver, payload.message_name, target_location, source_range);
}

fn opcodePrimSend(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = executable;
    _ = last_activation_ref;
    const payload = block.getTypedPayload(instruction_id, .PrimSend);
    const receiver = vm.readRegister(payload.receiver_location);
    return try performPrimitiveSend(vm, actor, receiver, payload.message_name, target_location, source_range);
}

fn opcodeSelfPrimSend(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = executable;
    _ = last_activation_ref;
    const payload = block.getTypedPayload(instruction_id, .SelfPrimSend);
    const receiver = actor.activation_stack.getCurrent().activation_object.get().findActivationReceiver();
    return try performPrimitiveSend(vm, actor, receiver, payload.message_name, target_location, source_range);
}

fn opcodePushConstantSlot(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = target_location;
    _ = executable;
    _ = last_activation_ref;
    const payload = block.getTypedPayload(instruction_id, .PushConstantSlot);
    const name_value = vm.readRegister(payload.name_location);
    const name_byte_array_object = name_value.asObject().mustBeType(.ByteArray);
    const value = vm.readRegister(payload.value_location);

    try actor.slot_stack.push(vm.allocator, Slot.initConstant(name_byte_array_object.getByteArray(), if (payload.is_parent) .Parent else .NotParent, value));
    return success;
}

fn opcodePushAssignableSlot(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = target_location;
    _ = executable;
    _ = last_activation_ref;
    const payload = block.getTypedPayload(instruction_id, .PushAssignableSlot);
    const name_value = vm.readRegister(payload.name_location);
    const name_byte_array_object = name_value.asObject().mustBeType(.ByteArray);
    const value = vm.readRegister(payload.value_location);

    try actor.slot_stack.push(vm.allocator, Slot.initAssignable(name_byte_array_object.getByteArray(), if (payload.is_parent) .Parent else .NotParent, value));
    return success;
}

fn opcodePushArgumentSlot(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = target_location;
    _ = executable;
    _ = last_activation_ref;
    const payload = block.getTypedPayload(instruction_id, .PushArgumentSlot);
    const name_value = vm.readRegister(payload.name_location);
    const name_byte_array_object = name_value.asObject().mustBeType(.ByteArray);

    try actor.slot_stack.push(vm.allocator, Slot.initArgument(name_byte_array_object.getByteArray()));
    return success;
}

fn opcodePushInheritedSlot(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = executable;
    _ = last_activation_ref;
    _ = source_range;
    _ = target_location;
    const payload = block.getTypedPayload(instruction_id, .PushInheritedSlot);
    const name_value = vm.readRegister(payload.name_location);
    const name_byte_array_object = name_value.asObject().mustBeType(.ByteArray);
    const value = vm.readRegister(payload.value_location);

    try actor.slot_stack.push(vm.allocator, Slot.initInherited(name_byte_array_object.getByteArray(), value));
    return success;
}

fn opcodeCreateInteger(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = executable;
    _ = last_activation_ref;
    _ = actor;
    vm.writeRegister(target_location, Value.fromInteger(block.getTypedPayload(instruction_id, .CreateInteger)));
    return success;
}

fn opcodeCreateFloatingPoint(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = executable;
    _ = last_activation_ref;
    _ = actor;
    vm.writeRegister(target_location, Value.fromFloatingPoint(block.getTypedPayload(instruction_id, .CreateFloatingPoint)));
    return success;
}

fn opcodeCreateByteArray(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = executable;
    _ = last_activation_ref;
    const payload = block.getTypedPayload(instruction_id, .CreateByteArray);
    var token = try vm.heap.getAllocation(ByteArrayObject.requiredSizeForAllocation(payload.len));
    defer token.deinit();

    const byte_array = ByteArrayObject.createWithValues(vm.getMapMap(), &token, actor.id, payload);
    vm.writeRegister(target_location, byte_array.asValue());
    return success;
}

fn opcodeCreateObject(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = executable;
    _ = last_activation_ref;
    return try createObject(vm, actor, block.getTypedPayload(instruction_id, .CreateObject).slot_count, target_location);
}

fn opcodeCreateMethod(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = last_activation_ref;
    const payload = block.getTypedPayload(instruction_id, .CreateMethod);
    const method_name_byte_array = vm.readRegister(payload.method_name_location).asObject().mustBeType(.ByteArray).getByteArray();
    return try createMethod(
        vm,
        actor,
        executable,
        method_name_byte_array,
        payload.slot_count,
        payload.block_index,
        target_location,
    );
}

fn opcodeCreateBlock(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = last_activation_ref;
    const payload = block.getTypedPayload(instruction_id, .CreateBlock);
    return try createBlock(
        vm,
        actor,
        executable,
        payload.slot_count,
        payload.block_index,
        target_location,
    );
}

fn opcodeReturn(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = executable;
    _ = source_range;
    _ = target_location;
    const value = vm.readRegister(block.getTypedPayload(instruction_id, .Return).value_location);
    vm.writeRegister(.ret, value);

    if (actor.exitCurrentActivation(vm, last_activation_ref) == .LastActivation)
        return ExecutionResult.completion(Completion.initNormal(vm.readRegister(.ret)));
    return activation_change;
}

fn opcodeNonlocalReturn(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = target_location;
    _ = executable;
    const value = vm.readRegister(block.getTypedPayload(instruction_id, .NonlocalReturn).value_location);
    vm.writeRegister(.ret, value);

    const current_activation = actor.activation_stack.getCurrent();
    // FIXME: Better name
    const target_activation_ref = current_activation.nonlocal_return_target_activation.?;
    const target_activation = target_activation_ref.get(actor.activation_stack) orelse
        return ExecutionResult.completion(try Completion.initRuntimeError(vm, source_range, "Attempted to non-local return to non-existent activation", .{}));

    if (actor.exitActivation(vm, last_activation_ref, target_activation) == .LastActivation)
        return ExecutionResult.completion(Completion.initNormal(vm.readRegister(.ret)));
    return activation_change;
}

fn opcodePushArg(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = target_location;
    _ = executable;
    _ = last_activation_ref;
    var argument = vm.readRegister(block.getTypedPayload(instruction_id, .PushArg).argument_location);
    if (argument.isObjectReference()) {
        if (argument.asObject().asType(.Activation)) |activation| {
            argument = activation.findActivationReceiver();
        }
    }
    try actor.argument_stack.push(vm.allocator, argument);

    return success;
}

fn opcodePushRegisters(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = target_location;
    _ = executable;
    _ = last_activation_ref;
    var iterator = block.getTypedPayload(instruction_id, .PushRegisters).iterator(.{});
    while (iterator.next()) |clobbered_register| {
        // FIXME: Remove manual register number adjustment!
        const register = bytecode.RegisterLocation.fromInt(@intCast(u32, clobbered_register + 2));
        try actor.saved_register_stack.push(vm.allocator, .{ .register = register, .value = vm.readRegister(register) });
    }

    return success;
}

fn opcodeSetMethodInline(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = vm;
    _ = source_range;
    _ = target_location;
    _ = instruction_id;
    _ = block;
    _ = executable;
    _ = last_activation_ref;
    actor.next_method_is_inline = true;
    return success;
}

fn opcodeSourceRange(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = vm;
    _ = source_range;
    _ = target_location;
    _ = executable;
    _ = last_activation_ref;
    actor.range = block.getTypedPayload(instruction_id, .SourceRange);
    return success;
}

fn opcodePushArgumentSentinel(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = target_location;
    _ = instruction_id;
    _ = block;
    _ = executable;
    _ = last_activation_ref;
    try actor.argument_stack.pushSentinel(vm.allocator);
    return success;
}

fn opcodePushSlotSentinel(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = target_location;
    _ = instruction_id;
    _ = block;
    _ = executable;
    _ = last_activation_ref;
    try actor.slot_stack.pushSentinel(vm.allocator);
    return success;
}

fn opcodeVerifyArgumentSentinel(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = target_location;
    _ = instruction_id;
    _ = block;
    _ = executable;
    _ = last_activation_ref;
    _ = vm;
    actor.argument_stack.verifySentinel();
    return success;
}

fn opcodeVerifySlotSentinel(
    vm: *VirtualMachine,
    actor: *Actor,
    last_activation_ref: ?Activation.ActivationRef,
    executable: bytecode.Executable.Ref,
    block: *bytecode.Block,
    instruction_id: u32,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    _ = source_range;
    _ = target_location;
    _ = instruction_id;
    _ = block;
    _ = executable;
    _ = last_activation_ref;
    _ = vm;
    actor.slot_stack.verifySentinel();
    return success;
}

fn performSend(
    vm: *VirtualMachine,
    actor: *Actor,
    receiver: Value,
    message_name: []const u8,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    const completion = (try sendMessage(vm, actor, receiver, message_name, target_location, source_range)) orelse
        return activation_change;

    if (completion.isNormal()) {
        var result = completion.data.Normal;
        if (result.isObjectReference()) {
            if (result.asObject().asType(.Activation)) |activation| {
                result = activation.findActivationReceiver();
            }
        }

        vm.writeRegister(target_location, result);
        return success;
    }

    return ExecutionResult.completion(completion);
}

fn performPrimitiveSend(
    vm: *VirtualMachine,
    actor: *Actor,
    receiver_: Value,
    message_name: []const u8,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !ExecutionResult {
    if (primitives.getPrimitive(message_name)) |primitive| {
        var receiver = receiver_;
        if (receiver.isObjectReference()) {
            if (receiver.asObject().asType(.Activation)) |activation| {
                receiver = activation.findActivationReceiver();
            }
        }

        const tracked_receiver = try vm.heap.track(receiver);
        defer tracked_receiver.untrack(vm.heap);

        const argument_slice = actor.argument_stack.lastNItems(primitive.arity);

        const primitive_result = try primitive.call(vm, actor, tracked_receiver, argument_slice, target_location, source_range);
        if (!(primitive_result == .ActorSwitch and actor.yield_reason == .Blocked)) {
            // NOTE: If the actor got blocked, it will retry the same
            //       primitive call when it gets unblocked, so we
            //       shouldn't pop values off its stack.
            actor.argument_stack.popNItems(primitive.arity);
        }

        switch (primitive_result) {
            .ActorSwitch, .ActivationChange, .Success => return primitive_result,
            .Completion => |completion| {
                if (completion.isNormal()) {
                    vm.writeRegister(target_location, completion.data.Normal);
                    return success;
                }

                return ExecutionResult.completion(completion);
            },
        }
    }

    return ExecutionResult.completion(
        try Completion.initRuntimeError(vm, source_range, "Unknown primitive selector '{s}'", .{message_name}),
    );
}

/// Sends a message to the given receiver, returning the result as a normal
/// completion if it can be immediately resolved; if the message send must
/// create a new activation, pushes the activation onto the stack and returns
/// null. If the message send fails, then returns an error completion.
pub fn sendMessage(
    vm: *VirtualMachine,
    actor: *Actor,
    receiver: Value,
    message_name: []const u8,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !?Completion {
    // Check for block activation. Note that this isn't the same as calling a
    // method on traits block, this is actually executing the block itself via
    // the virtual method.
    // FIXME: Only activate this when the message looks like a block execution.
    {
        var block_receiver = receiver;
        if (block_receiver.isObjectReference()) {
            if (block_receiver.asObject().asType(.Activation)) |activation| {
                block_receiver = activation.findActivationReceiver();
            }
        }

        if (block_receiver.isObjectReference()) {
            if (block_receiver.asObject().asType(.Block)) |receiver_as_block| {
                if (receiver_as_block.isCorrectMessageForBlockExecution(message_name)) {
                    const argument_count = receiver_as_block.getArgumentSlotCount();
                    const argument_slice = actor.argument_stack.lastNItems(argument_count);

                    // Advance the instruction for the activation that will be returned to.
                    actor.activation_stack.getCurrent().advanceInstruction();

                    try executeBlock(vm, actor, receiver_as_block, argument_slice, target_location, source_range);

                    actor.argument_stack.popNItems(argument_count);
                    // Bump the argument stack height of the (now current)
                    // activation since we've now popped this activation's items off
                    // it.
                    actor.activation_stack.getCurrent().stack_snapshot.bumpArgumentHeight(actor);
                    return null;
                }
            }
        }
    }

    actor.ensureCanRead(receiver, source_range);

    return switch (receiver.lookup(vm, message_name)) {
        .Regular => |lookup_result| {
            if (lookup_result.isObjectReference()) {
                if (lookup_result.asObject().asType(.Method)) |method| {
                    const argument_count = method.getArgumentSlotCount();
                    const argument_slice = actor.argument_stack.lastNItems(argument_count);

                    // Advance the instruction for the activation that will be returned to.
                    actor.activation_stack.getCurrent().advanceInstruction();

                    try executeMethod(vm, actor, receiver, method, argument_slice, target_location, source_range);

                    actor.argument_stack.popNItems(argument_count);
                    // Bump the argument stack height of the (now current)
                    // activation since we've now popped this activation's items off
                    // it.
                    actor.activation_stack.getCurrent().stack_snapshot.bumpArgumentHeight(actor);
                    return null;
                }
            }

            return Completion.initNormal(lookup_result);
        },
        .Assignment => |assignment_context| {
            const argument_slice = actor.argument_stack.lastNItems(1);
            var argument = argument_slice[0];
            // NOTE: This is required, for instance, when we are assigning `self` to
            //       a slot (happens more often than you might think!). We need to strip
            //       the activation object to get to the actual value inside.
            if (argument.isObjectReference()) {
                if (argument.asObject().asType(.Activation)) |activation| {
                    argument = activation.findActivationReceiver();
                }
            }

            const object_that_has_the_assignable_slot = assignment_context.object;
            const value_ptr = assignment_context.value_ptr;

            if (!actor.canWriteTo(object_that_has_the_assignable_slot.asValue())) {
                return try Completion.initRuntimeError(vm, source_range, "Assignment target is not writable for actor", .{});
            }

            if (object_that_has_the_assignable_slot.object_information.reachability == .Global) {
                // Mark every object that's not globally reachable in the
                // argument's object graph as globally reachable. This will
                // make the whole object graph part of the global object
                // hierarchy.
                _ = traversal.traverseNonGloballyReachableObjectGraph(argument, {}, struct {
                    fn f(context: void, object: Object.Ptr) error{}!Object.Ptr {
                        _ = context;
                        object.object_information.reachability = .Global;
                        return object;
                    }
                }.f) catch unreachable;
            }

            value_ptr.* = argument;

            // David will remember that.
            try vm.heap.rememberObjectReference(object_that_has_the_assignable_slot.asValue(), argument);

            actor.argument_stack.popNItems(1);
            return Completion.initNormal(receiver);
        },
        .ActorMessage => |actor_message| {
            const method = actor_message.method;
            const argument_count = method.getArgumentSlotCount();
            const argument_slice = actor.argument_stack.lastNItems(argument_count);

            var target_actor = actor_message.target_actor.getActor();

            // FIXME: Figure out a way to avoid creating an owned slice here.
            //        This is required for the time being because we don't have
            //        a better first-in-last-out (which is how messages are
            //        processed) structure yet.
            const new_arguments_slice = try vm.allocator.alloc(Value, argument_slice.len);
            errdefer vm.allocator.free(new_arguments_slice);

            // Blessing each argument is required so that actors don't share memory.
            for (argument_slice) |argument, i| {
                new_arguments_slice[i] = try bless.bless(vm.heap, target_actor.id, argument);
            }

            try target_actor.putMessageInMailbox(
                vm.allocator,
                actor.actor_object.get(),
                method,
                new_arguments_slice,
                source_range,
            );

            actor.argument_stack.popNItems(argument_count);
            return Completion.initNormal(vm.nil());
        },
        .Nothing => try Completion.initRuntimeError(vm, source_range, "Unknown selector '{s}'", .{message_name}),
    };
}

fn executeBlock(
    vm: *VirtualMachine,
    actor: *Actor,
    block_receiver: BlockObject.Ptr,
    arguments: []const Value,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !void {
    const message_name = try vm.getOrCreateBlockMessageName(@intCast(u8, arguments.len));
    var block = block_receiver;

    var required_memory = ActivationObject.requiredSizeForAllocation(
        block.getArgumentSlotCount(),
        block.getAssignableSlotCount(),
    );
    if (!message_name.exists) required_memory += message_name.requiredSize();

    var token = token: {
        var tracked_block: ?Heap.Tracked = null;
        defer if (tracked_block) |t| t.untrack(vm.heap);

        if (vm.heap.needsToGarbageCollectToProvide(required_memory)) {
            tracked_block = try vm.heap.track(block.asValue());
        }

        // Ensure that we won't GC by creating an activation.
        var token = try vm.heap.getAllocation(required_memory);

        if (tracked_block) |t| {
            // Refresh the pointer to the block.
            block = t.getValue().asObject().mustBeType(.Block);
        }

        break :token token;
    };
    defer token.deinit();

    const parent_activation_object = block.getMap().parent_activation.get(actor.activation_stack).?.activation_object;
    const activation_slot = try actor.activation_stack.getNewActivationSlot(vm.allocator);
    block.activateBlock(
        vm,
        &token,
        parent_activation_object.value,
        arguments,
        target_location,
        try message_name.get(&token),
        source_range,
        activation_slot,
    );
}

fn executeMethod(
    vm: *VirtualMachine,
    actor: *Actor,
    const_receiver: Value,
    const_method: MethodObject.Ptr,
    arguments: []const Value,
    target_location: bytecode.RegisterLocation,
    source_range: SourceRange,
) !void {
    var receiver_of_method = const_receiver;
    var method = const_method;

    const required_memory = ActivationObject.requiredSizeForAllocation(
        method.getArgumentSlotCount(),
        method.getAssignableSlotCount(),
    );

    var token = token: {
        var tracked_receiver: ?Heap.Tracked = null;
        var tracked_method: ?Heap.Tracked = null;

        defer if (tracked_receiver) |t| {
            t.untrack(vm.heap);
            tracked_method.?.untrack(vm.heap);
        };

        if (vm.heap.needsToGarbageCollectToProvide(required_memory)) {
            tracked_receiver = try vm.heap.track(receiver_of_method);
            tracked_method = try vm.heap.track(method.asValue());
        }

        // Get the allocation token for the method
        var token = try vm.heap.getAllocation(required_memory);

        if (tracked_receiver) |t| {
            // Refresh the pointers to the method and its receiver.
            receiver_of_method = t.getValue();
            method = tracked_method.?.getValue().asObject().mustBeType(.Method);
        }

        break :token token;
    };
    defer token.deinit();

    // NOTE: The receiver of a method activation must never be an activation
    //       object (unless it explicitly wants that), as that would allow
    //       us to access the slots of upper scopes.
    if (!method.expectsActivationObjectAsReceiver() and receiver_of_method.isObjectReference()) {
        if (receiver_of_method.asObject().asType(.Activation)) |activation| {
            receiver_of_method = activation.findActivationReceiver();
        }
    }

    const activation_slot = try actor.activation_stack.getNewActivationSlot(vm.allocator);
    method.activateMethod(vm, &token, actor.id, receiver_of_method, arguments, target_location, source_range, activation_slot);
}

fn createObject(
    vm: *VirtualMachine,
    actor: *Actor,
    slot_count: u32,
    target_location: bytecode.RegisterLocation,
) !ExecutionResult {
    const slots = actor.slot_stack.lastNItems(slot_count);

    var total_slot_count: u32 = 0;
    var total_assignable_slot_count: u8 = 0;
    for (slots) |slot, i| {
        total_slot_count += slot.requiredSlotSpace(slots[0..i]);
        total_assignable_slot_count += @intCast(u8, slot.requiredAssignableSlotValueSpace(slots[0..i]));
    }

    var token = try vm.heap.getAllocation(
        SlotsMap.requiredSizeForAllocation(total_slot_count) +
            SlotsObject.requiredSizeForAllocation(total_assignable_slot_count),
    );
    defer token.deinit();

    var slots_map = SlotsMap.create(vm.getMapMap(), &token, total_slot_count);
    var map_builder = slots_map.getMapBuilder(&token);

    for (slots) |slot| {
        map_builder.addSlot(slot);
    }

    const the_slots_object = map_builder.createObject(actor.id);
    vm.writeRegister(target_location, the_slots_object.asValue());
    actor.slot_stack.popNItems(slot_count);
    return success;
}

fn createMethod(
    vm: *VirtualMachine,
    actor: *Actor,
    executable: bytecode.Executable.Ref,
    method_name: ByteArray,
    slot_count: u32,
    block_index: u32,
    target_location: bytecode.RegisterLocation,
) !ExecutionResult {
    defer actor.next_method_is_inline = false;

    const slots = actor.slot_stack.lastNItems(slot_count);
    var total_slot_count: u32 = 0;
    var total_assignable_slot_count: u8 = 0;
    var argument_slot_count: u8 = 0;
    for (slots) |slot, i| {
        total_slot_count += slot.requiredSlotSpace(slots[0..i]);
        total_assignable_slot_count += @intCast(u8, slot.requiredAssignableSlotValueSpace(slots[0..i]));

        // FIXME: This makes the assumption that argument slots are
        //        never overwritten.
        if (slot.isArgument())
            argument_slot_count += 1;
    }

    var token = try vm.heap.getAllocation(
        MethodMap.requiredSizeForAllocation(total_slot_count) +
            MethodObject.requiredSizeForAllocation(total_assignable_slot_count),
    );
    defer token.deinit();

    const block = executable.value.getBlock(block_index);
    var method_map = try MethodMap.create(
        vm.getMapMap(),
        &token,
        argument_slot_count,
        total_slot_count,
        actor.next_method_is_inline,
        method_name,
        block,
        executable,
    );

    var map_builder = method_map.getMapBuilder(&token);

    for (slots) |slot| {
        map_builder.addSlot(slot);
    }

    const method = map_builder.createObject(actor.id);
    vm.writeRegister(target_location, method.asValue());
    actor.slot_stack.popNItems(slot_count);
    return success;
}

fn createBlock(
    vm: *VirtualMachine,
    actor: *Actor,
    executable: bytecode.Executable.Ref,
    slot_count: u32,
    block_index: u32,
    target_location: bytecode.RegisterLocation,
) !ExecutionResult {
    const slots = actor.slot_stack.lastNItems(slot_count);
    var total_slot_count: u32 = 0;
    var total_assignable_slot_count: u8 = 0;
    var argument_slot_count: u8 = 0;
    for (slots) |slot, i| {
        total_slot_count += slot.requiredSlotSpace(slots[0..i]);
        total_assignable_slot_count += @intCast(u8, slot.requiredAssignableSlotValueSpace(slots[0..i]));

        // FIXME: This makes the assumption that argument slots are
        //        never overwritten.
        if (slot.isArgument())
            argument_slot_count += 1;
    }

    const block = executable.value.getBlock(block_index);
    // The latest activation is where the block was created, so it will always
    // be the parent activation (i.e., where we look for parent blocks' and the
    // method's slots).
    const parent_activation = actor.activation_stack.getCurrent();
    // However, we want the _method_ as the non-local return target; because the
    // non-local return can only be returned by the method in which the block
    // making the non-local return was defined, this needs to be separate from
    // parent_activation. If the parent activation is a block, it will also
    // contain a target activation; if it's a method the target activation _is_
    // the parent.
    const nonlocal_return_target_activation = if (parent_activation.nonlocal_return_target_activation) |target|
        target
    else
        parent_activation.takeRef(actor.activation_stack);
    std.debug.assert(nonlocal_return_target_activation.get(actor.activation_stack).?.nonlocal_return_target_activation == null);

    var token = try vm.heap.getAllocation(
        BlockMap.requiredSizeForAllocation(total_slot_count) +
            BlockObject.requiredSizeForAllocation(total_assignable_slot_count),
    );
    defer token.deinit();

    var block_map = try BlockMap.create(
        vm.getMapMap(),
        &token,
        argument_slot_count,
        total_slot_count,
        parent_activation.takeRef(actor.activation_stack),
        nonlocal_return_target_activation,
        block,
        executable,
    );

    var map_builder = block_map.getMapBuilder(&token);

    for (slots) |slot| {
        map_builder.addSlot(slot);
    }

    const the_block_object = map_builder.createObject(actor.id);
    vm.writeRegister(target_location, the_block_object.asValue());
    actor.slot_stack.popNItems(slot_count);
    return success;
}
