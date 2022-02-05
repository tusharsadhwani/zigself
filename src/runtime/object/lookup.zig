// Copyright (c) 2021, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("../../utility/hash.zig");
const Slot = @import("../slot.zig");
const Value = @import("../value.zig").Value;
const Object = @import("../object.zig");
const Completion = @import("../completion.zig");
const InterpreterContext = @import("../interpreter.zig").InterpreterContext;
const debug = @import("../../debug.zig");

const SLOTS_LOOKUP_DEBUG = debug.SLOTS_LOOKUP_DEBUG;
const LOOKUP_DEBUG = debug.LOOKUP_DEBUG;

pub const LookupIntent = enum { Read, Assign };
pub const LookupError = Allocator.Error;
const VisitedValueLink = struct { previous: ?*const VisitedValueLink = null, value: Value };

pub const AssignLookupResult = union(enum) {
    Result: struct {
        object: Object,
        value_ptr: *Value,
    },
    Completion: Completion,
};

pub fn findTraitsObject(comptime selector: []const u8, allocator: Allocator, context: *InterpreterContext) !Completion {
    if (try context.lobby.getValue().lookup(.Read, "traits", allocator, context)) |traits_completion| {
        if (!traits_completion.isNormal())
            return traits_completion;

        const traits = traits_completion.data.Normal;
        if (try traits.lookup(.Read, selector, allocator, context)) |traits_object_completion| {
            if (!traits_object_completion.isNormal())
                return traits_object_completion;

            const traits_object = traits_object_completion.data.Normal;
            return Completion.initNormal(traits_object);
        } else {
            return Completion.initRuntimeError(allocator, "Could not find " ++ selector ++ " in traits", .{});
        }
    } else {
        return Completion.initRuntimeError(allocator, "Could not find traits in lobby", .{});
    }
}

// NOTE: Only intended to share with value.zig

pub fn lookupReturnType(comptime intent: LookupIntent) type {
    if (intent == .Assign) {
        return LookupError!?AssignLookupResult;
    } else {
        return LookupError!?Completion;
    }
}

pub fn lookupCompletionReturn(comptime intent: LookupIntent, completion: Completion) lookupReturnType(intent) {
    if (intent == .Assign) {
        std.debug.assert(!completion.isNormal());
        return AssignLookupResult{ .Completion = completion };
    } else {
        return completion;
    }
}

const self_hash = hash.stringHash("self");
const parent_hash = hash.stringHash("parent");

pub fn lookupByHash(
    self: Object,
    comptime intent: LookupIntent,
    selector_hash: u32,
    allocator: ?Allocator,
    context: ?*InterpreterContext,
) lookupReturnType(intent) {
    if (LOOKUP_DEBUG) std.debug.print("Object.lookupByHash: Looking up hash {x} on a {} object at {*}\n", .{ selector_hash, self.header.getObjectType(), self.header });

    if (intent == .Read) {
        if (selector_hash == self_hash) {
            return Completion.initNormal(self.asValue());
        }
    }

    return try lookupInternal(self, intent, selector_hash, null, allocator, context);
}

fn lookupInternal(
    self: Object,
    comptime intent: LookupIntent,
    selector_hash: u32,
    previously_visited: ?*const VisitedValueLink,
    allocator: ?Allocator,
    context: ?*InterpreterContext,
) lookupReturnType(intent) {
    switch (self.header.getObjectType()) {
        .ForwardingReference, .Map, .Method => unreachable,
        .Slots => {
            if (try slotsLookup(intent, Object.Slots, self.asSlotsObject(), selector_hash, previously_visited, allocator, context)) |result| {
                return result;
            }

            return null;
        },
        .Activation => {
            if (try slotsLookup(intent, Object.Activation, self.asActivationObject(), selector_hash, previously_visited, allocator, context)) |result| {
                return result;
            }

            // Receiver lookup
            if (try self.asActivationObject().receiver.lookupByHash(intent, selector_hash, allocator, context)) |result| {
                return result;
            }

            return null;
        },
        .Block => {
            if (LOOKUP_DEBUG) std.debug.print("Object.lookupInternal: Looking at traits block\n", .{});
            // NOTE: executeMessage will handle the execution of the block itself.
            if (context) |ctx| {
                const traits_block_completion = try findTraitsObject("block", allocator.?, ctx);
                if (traits_block_completion.isNormal()) {
                    const traits_block = traits_block_completion.data.Normal;
                    if (intent == .Read) {
                        if (selector_hash == parent_hash)
                            return Completion.initNormal(traits_block);
                    }

                    return try traits_block.lookupByHash(intent, selector_hash, allocator, context);
                }

                return lookupCompletionReturn(intent, traits_block_completion);
            } else {
                @panic("Context MUST be passed for Block objects!");
            }
        },
        .Vector => {
            if (LOOKUP_DEBUG) std.debug.print("Object.lookupInternal: Looking at traits vector\n", .{});
            if (context) |ctx| {
                const traits_vector_completion = try findTraitsObject("vector", allocator.?, ctx);
                if (traits_vector_completion.isNormal()) {
                    const traits_vector = traits_vector_completion.data.Normal;
                    if (intent == .Read) {
                        if (selector_hash == parent_hash)
                            return @as(?Completion, Completion.initNormal(traits_vector));
                    }

                    return try traits_vector.lookupByHash(intent, selector_hash, allocator, context);
                }

                return lookupCompletionReturn(intent, traits_vector_completion);
            } else {
                @panic("Context MUST be passed for Vector objects!");
            }
        },
        .ByteVector => {
            if (LOOKUP_DEBUG) std.debug.print("Object.lookupInternal: Looking at traits string\n", .{});
            if (context) |ctx| {
                const traits_string_completion = try findTraitsObject("string", allocator.?, ctx);
                if (traits_string_completion.isNormal()) {
                    const traits_string = traits_string_completion.data.Normal;
                    if (intent == .Read) {
                        if (selector_hash == parent_hash)
                            return @as(?Completion, Completion.initNormal(traits_string));
                    }

                    return try traits_string.lookupByHash(intent, selector_hash, allocator, context);
                }

                return lookupCompletionReturn(intent, traits_string_completion);
            } else {
                @panic("Context MUST be passed for ByteVector objects!");
            }
        },
    }
}

/// Self Handbook, §3.3.8 The lookup algorithm
fn slotsLookup(
    comptime intent: LookupIntent,
    comptime ObjectType: type,
    object: *ObjectType,
    selector_hash: u32,
    previously_visited: ?*const VisitedValueLink,
    allocator: ?Allocator,
    context: ?*InterpreterContext,
) lookupReturnType(intent) {
    if (previously_visited) |visited| {
        var link: ?*const VisitedValueLink = visited;
        while (link) |l| {
            if (l.value.data == object.asValue().data) {
                // Cyclic reference
                return null;
            }

            link = l.previous;
        }
    }

    const currently_visited = VisitedValueLink{ .previous = previously_visited, .value = object.asValue() };

    // Note that we only return the value for the assign intent if it's assignable;
    // if it's not assignable, then we return null. This is important because
    // it prevents assigning to constant slots. Perhaps a primitive can help you
    // assign to a constant slot? It will cause a map copy though.
    var assignable_slots = object.getAssignableSlots();
    var assignable_slots_cursor: usize = 0;
    // Direct lookup
    for (object.getSlots()) |slot| {
        if (SLOTS_LOOKUP_DEBUG) std.debug.print("Object.slotsLookup: Comparing slot \"{s}\" (hash {x}) vs. our hash {x}\n", .{ slot.name.asByteVector().getValues(), slot.hash, selector_hash });
        if (slot.hash == selector_hash) {
            if (intent == .Assign) {
                if (slot.isMutable()) {
                    return AssignLookupResult{
                        .Result = .{
                            .object = Object.fromAddress(object.asObjectAddress()),
                            .value_ptr = &assignable_slots[assignable_slots_cursor],
                        },
                    };
                } else {
                    // Prevent constant slots from being assigned
                    return null;
                }
            } else {
                if (slot.isMutable()) {
                    return Completion.initNormal(assignable_slots[assignable_slots_cursor]);
                } else {
                    return Completion.initNormal(slot.value);
                }
            }
        }

        // FIXME: Don't keep a cursor; use the value field to hold the
        //        assignable slot index instead. It's currently sitting there
        //        doing nothing.
        if (slot.isMutable()) {
            assignable_slots_cursor += 1;
        }
    }

    if (SLOTS_LOOKUP_DEBUG) std.debug.print("Object.slotsLookup: Could not find the slot on this object, looking at parents\n", .{});

    // Parent lookup
    for (object.getSlots()) |slot| {
        if (slot.isParent()) {
            if (slot.value.isObjectReference()) {
                if (try lookupInternal(slot.value.asObject(), intent, selector_hash, &currently_visited, allocator, context)) |result| {
                    return result;
                }
            } else {
                @panic("FIXME: Allow integers and floating point numbers to be parent slot values (let me know of your usecase!)");
            }
        }
    }

    // Nope, not here
    return null;
}
