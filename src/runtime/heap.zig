// Copyright (c) 2021, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const hash = @import("../utility/hash.zig");
const Value = @import("./value.zig").Value;
const Object = @import("./object.zig");
const ByteVector = @import("./byte_vector.zig");
const Activation = @import("./activation.zig");
const debug = @import("../debug.zig");

const GC_DEBUG = debug.GC_DEBUG;
const REMEMBERED_SET_DEBUG = debug.REMEMBERED_SET_DEBUG;

const Self = @This();
const UninitializedHeapScrubByte = 0xAB;

/// This is the space where newly created objects are placed. It is a fixed size
/// space, and objects that survive this space are placed in the from-space.
eden: Space,

/// This is the space where objects that survive the eden and previous scavenges
/// are placed. It is a fixed size space. When a scavenge cannot clean up enough
/// objects to leave memory for the survivors of a scavenge in this space, all
/// the objects in this space are moved to the old space where they reside until
/// a compaction happens.
from_space: Space,
/// This is a space with an identical size to the from space. When a scavenge
/// happens in the new space, the from space and this space are swapped.
to_space: Space,

/// This is the space where permanent objects reside. It can be expanded as
/// memory requirements of the program grows.
old_space: Space,

/// This is where all the handles for tracked objects are stored. This arena
/// lives as long as the heap does, and will constantly grow.
handle_area: ArenaAllocator,
handle_allocator: Allocator,

allocator: Allocator,
activation_stack: ?*std.ArrayList(*Activation),

// FIXME: Make eden + new space configurable at runtime
const EdenSize = 1 * 1024 * 1024;
const NewSpaceSize = 4 * 1024 * 1024;
const InitialOldSpaceSize = 16 * 1024 * 1024;

pub fn create(allocator: Allocator) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    try self.init(allocator);
    return self;
}

pub fn destroy(self: *Self) void {
    self.deinit();
    self.allocator.destroy(self);
}

fn init(self: *Self, allocator: Allocator) !void {
    self.allocator = allocator;
    self.activation_stack = null;

    self.old_space = try Space.init(allocator, "old space", InitialOldSpaceSize);
    errdefer self.old_space.deinit(allocator);

    self.from_space = try Space.init(allocator, "from space", NewSpaceSize);
    errdefer self.from_space.deinit(allocator);

    self.to_space = try Space.init(allocator, "to space", NewSpaceSize);
    errdefer self.to_space.deinit(allocator);

    self.eden = try Space.init(allocator, "eden", EdenSize);

    self.from_space.scavenge_target = &self.to_space;
    self.from_space.tenure_target = &self.old_space;
    self.eden.tenure_target = &self.from_space;

    self.handle_area = std.heap.ArenaAllocator.init(allocator);
    self.handle_allocator = self.handle_area.allocator();

    if (GC_DEBUG) {
        std.debug.print("Heap.init: Eden is {*}-{*}\n", .{ self.eden.memory.ptr, self.eden.memory.ptr + self.eden.memory.len });
        std.debug.print("Heap.init: From space is {*}-{*}\n", .{ self.from_space.memory.ptr, self.from_space.memory.ptr + self.from_space.memory.len });
        std.debug.print("Heap.init: To space is {*}-{*}\n", .{ self.to_space.memory.ptr, self.to_space.memory.ptr + self.to_space.memory.len });
        std.debug.print("Heap.init: Old space is {*}-{*}\n", .{ self.old_space.memory.ptr, self.old_space.memory.ptr + self.old_space.memory.len });
    }
}

fn deinit(self: *Self) void {
    self.eden.deinit(self.allocator);
    self.from_space.deinit(self.allocator);
    self.to_space.deinit(self.allocator);
    self.old_space.deinit(self.allocator);
    self.handle_area.deinit();
}

// Attempts to allocate `size` bytes in the object segment of the eden. If
// necessary, garbage collection is performed in the process.
// The given address must be a multiple of `@sizeOf(u64)`.
pub fn allocateInObjectSegment(self: *Self, size: usize) ![*]u64 {
    const stack = if (self.activation_stack) |activation_stack|
        activation_stack.items
    else
        &[_]*Activation{};

    return try self.eden.allocateInObjectSegment(self.allocator, stack, size);
}

pub fn allocateInByteVectorSegment(self: *Self, size: usize) ![*]u64 {
    const stack = if (self.activation_stack) |activation_stack|
        activation_stack.items
    else
        &[_]*Activation{};

    return try self.eden.allocateInByteVectorSegment(self.allocator, stack, size);
}

pub fn setActivationStack(self: *Self, activation_stack: ?*std.ArrayList(*Activation)) void {
    self.activation_stack = activation_stack;
}

/// Mark the given address within the heap as an object which needs to know when
/// it is finalized. The address must've just been allocated (i.e. still in
/// eden).
pub fn markAddressAsNeedingFinalization(self: *Self, address: [*]u64) !void {
    if (!self.eden.objectSegmentContains(address)) {
        std.debug.panic("!!! markAddressAsNeedingFinalization called on address which isn't in eden object segment", .{});
    }

    try self.eden.addToFinalizationSet(self.allocator, address);
}

fn allocateHandle(self: *Self) !*[*]u64 {
    return self.handle_allocator.create([*]u64);
}

/// Track the given value, returning a Tracked. When a garbage collection
/// occurs, the value will be updated with the new location.
pub fn track(self: *Self, value: Value) !Tracked {
    if (value.isObjectReference()) {
        const handle = try self.allocateHandle();
        handle.* = value.asObjectAddress();

        const tracked = Tracked.createWithObject(handle);
        _ = try self.eden.startTracking(self.allocator, handle);

        return tracked;
    } else {
        return Tracked.createWithLiteral(value);
    }
}

/// Untracks the given value.
pub fn untrack(self: *Self, tracked: Tracked) void {
    if (tracked.value == .Object) {
        _ = self.eden.stopTracking(tracked.value.Object);
    }
}

/// Ensures that the given amount of bytes are immediately available in eden, so
/// garbage collection won't happen. Performs a pre-emptive garbage collection
/// if there isn't enough space.
pub fn ensureSpaceInEden(self: *Self, required_memory: usize) !void {
    const stack = if (self.activation_stack) |activation_stack|
        activation_stack.items
    else
        &[_]*Activation{};

    try self.eden.collectGarbage(self.allocator, required_memory, stack);
}

/// Go through the whole heap, updating references to the given value with the
/// new value.
pub fn updateAllReferencesTo(self: *Self, old_value: Value, new_value: Value) void {
    _ = self;
    _ = old_value;
    _ = new_value;
    std.debug.panic("TODO", .{});
}

/// Figure out which spaces the referrer and target object are in, and add an
/// entry to the target object's space's remembered set. This ensures that the
/// object in the old space gets its references properly updated when the new
/// space gets garbage collected.
pub fn rememberObjectReference(self: *Self, referrer: Value, target: Value) !void {
    // FIXME: If we add an assignable slot to traits integer for instance, this
    //        will cause the assignment code to explode. What can we do there?
    std.debug.assert(referrer.isObjectReference());
    if (!target.isObjectReference()) return;

    if (REMEMBERED_SET_DEBUG) std.debug.print("Heap.rememberObjectReference: Trying to create a reference {*} -> {*}\n", .{ referrer.asObjectAddress(), target.asObjectAddress() });

    const referrer_address = referrer.asObjectAddress();
    const target_address = target.asObjectAddress();

    var referrer_space: ?*Space = null;
    var target_space: ?*Space = null;

    if (self.eden.objectSegmentContains(referrer_address)) referrer_space = &self.eden;
    if (self.from_space.objectSegmentContains(referrer_address)) referrer_space = &self.from_space;
    if (self.old_space.objectSegmentContains(referrer_address)) referrer_space = &self.old_space;
    std.debug.assert(referrer_space != null);

    if (REMEMBERED_SET_DEBUG) std.debug.print("Heap.rememberObjectReference: Referrer is in {s}\n", .{referrer_space.?.name});

    const referrer_space_is_newer = blk: {
        if (self.eden.objectSegmentContains(target_address)) {
            if (REMEMBERED_SET_DEBUG) std.debug.print("Heap.rememberObjectReference: Target is in eden\n", .{});
            if (referrer_space.? == &self.eden) break :blk false;
            target_space = &self.eden;
        } else if (self.from_space.objectSegmentContains(target_address)) {
            if (REMEMBERED_SET_DEBUG) std.debug.print("Heap.rememberObjectReference: Target is in from space\n", .{});
            if (referrer_space.? == &self.eden or referrer_space.? == &self.from_space) break :blk false;
            target_space = &self.from_space;
        } else if (self.old_space.objectSegmentContains(target_address)) {
            if (REMEMBERED_SET_DEBUG) std.debug.print("Heap.rememberObjectReference: Target is in old space\n", .{});
            // Old space to old space references need not be updated, as the old
            // space is supposed to infinitely expand.
            break :blk false;
        }
        std.debug.assert(target_space != null);
        break :blk true;
    };
    if (!referrer_space_is_newer) {
        if (REMEMBERED_SET_DEBUG) std.debug.print("Heap.rememberObjectReference: Referrer in same or older space than target, not creating a reference.\n", .{});
        return;
    }

    if (REMEMBERED_SET_DEBUG) std.debug.print("Heap.rememberObjectReference: Adding to remembered set of {s}\n", .{target_space.?.name});
    try target_space.?.addToRememberedSet(self.allocator, referrer_address, referrer.asObject().getSizeInMemory());
}

/// A mapping from an address to its size. This area of memory is checked for
/// any object references in the current space which are then copied during a
/// scavenge.
const RememberedSet = std.AutoArrayHashMapUnmanaged([*]u64, usize);
/// A set of objects which should be notified when they are not referenced
/// anymore. See `Space.finalization_set` for more information.
const FinalizationSet = std.AutoArrayHashMapUnmanaged([*]u64, void);
/// A set of objects which are tracked across garbage collection events.
const TrackedSet = std.AutoArrayHashMapUnmanaged(*[*]u64, void);
const Space = struct {
    /// The raw memory contents of the space. The space capacity can be learned
    /// with `memory.len`.
    memory: []u64,
    /// Points to the first free address in this space's object segment (which
    /// grows upwards in memory).
    object_cursor: [*]u64,
    /// Points to the first used address in this space's bytevector segment
    /// (which grows downwards in memory). May point to the byte after `memory`,
    /// in which case the bytevector segment is empty.
    byte_vector_cursor: [*]u64,
    /// The set of objects which reference an object in this space. When a
    /// constant or assignable slot from a previous space references this space,
    /// it is added to this set; when it starts referencing another space, it is
    /// removed from this space. During scavenging, this space is cleared and
    /// any references that were still pointing to this space at scavenge time
    /// are transferred to the target space.
    ///
    /// TODO: The original Self VM used "cards" (i.e. a bitmap) to mark certain
    ///       regions of memory as pointing to a new space indiscriminate of
    ///       object size. Figure out whether that is faster than this
    ///       approach.
    remembered_set: RememberedSet,
    /// The finalization set of a space represents the set of objects which
    /// should be notified when they haven't been copied after a scavenge
    /// operation. These objects need to perform additional steps once they are
    /// not scavenged (in other words, not referenced by anyone anymore).
    ///
    ///When an item in this set gets copied to the target space, it is removed
    ///from this set and added to the target set.
    finalization_set: FinalizationSet,
    /// The tracked set of this space. At a garbage collection, all the objects
    /// pointed to by values in this set will be marked as referenced and will
    /// be copied to the new space. The tracked values are then transferred to
    /// the new space, updating them with their new locations.
    tracked_set: TrackedSet,
    /// The scavenging target of this space. When the space runs out of memory
    /// and this space is set, the space will attempt to perform a scavenging
    /// operation towards this space. This space must have the same size as the
    /// current space and must be empty when the scavenging starts. After the
    /// scavenge is complete, this object swaps its memory and cursors with the
    /// other object.
    scavenge_target: ?*Space = null,
    /// The tenure target of this space. When the space runs out of memory and a
    /// scavenge did not clear enough memory, a tenuring operation is done in
    /// order to evacuate all the objects to a higher generation.
    tenure_target: ?*Space = null,
    /// The name of this space.
    name: [*:0]const u8,

    /// A link node for a newer generation space to scan in order to update
    /// references from the newer space to the older one.
    const NewerGenerationLink = struct {
        space: *Space,
        previous: ?*const NewerGenerationLink,
    };

    pub fn init(allocator: Allocator, comptime name: [*:0]const u8, size: usize) !Space {
        var memory = try allocator.alloc(u64, size / @sizeOf(u64));
        return Space{
            .memory = memory,
            .object_cursor = memory.ptr,
            .byte_vector_cursor = memory.ptr + memory.len,
            .remembered_set = .{},
            .finalization_set = .{},
            .tracked_set = .{},
            .name = name,
        };
    }

    pub fn deinit(self: *Space, allocator: Allocator) void {
        // Finalize everything that needs to be finalized.
        var finalization_it = self.finalization_set.iterator();
        while (finalization_it.next()) |entry| {
            var object = Value.fromObjectAddress(entry.key_ptr.*).asObject();
            object.finalize(allocator);
        }

        self.finalization_set.deinit(allocator);
        self.tracked_set.deinit(allocator);
        self.remembered_set.deinit(allocator);
        allocator.free(self.memory);
    }

    /// Return the amount of free memory in this space in bytes.
    pub fn freeMemory(self: *Space) usize {
        const memory_word_count = self.memory.len;
        const start_of_memory = self.memory.ptr;
        const end_of_memory = start_of_memory + memory_word_count;

        const object_size = @ptrToInt(self.object_cursor) - @ptrToInt(start_of_memory);
        const byte_vector_size = @ptrToInt(end_of_memory) - @ptrToInt(self.byte_vector_cursor);

        return memory_word_count * @sizeOf(u64) - object_size - byte_vector_size;
    }

    /// Copy the given address as a new object in the target space. Creates a
    /// forwarding reference in this space; if more than one object was pointing
    /// to this object in the old space, then a special marker is placed in the
    /// location of the old object which tells the future calls of this function
    /// for the same object to just return the new location and avoid copying
    /// again.
    fn copyObjectTo(self: *Space, allocator: Allocator, address: [*]u64, target_space: *Space) ![*]u64 {
        const object = Object.fromAddress(address);
        if (object.isForwardingReference()) {
            const forward_address = object.getForwardAddress();
            return forward_address;
        }

        const object_size = object.getSizeInMemory();
        std.debug.assert(object_size % @sizeOf(u64) == 0);

        const object_size_in_words = object_size / @sizeOf(u64);
        // We must have enough space at this point, so the empty activation
        // stack doesn't matter (copyObjectTo is only called from within
        // cheneyCommon).
        const new_address = target_space.allocateInObjectSegment(allocator, &[_]*Activation{}, object_size) catch unreachable;
        std.mem.copy(u64, new_address[0..object_size_in_words], address[0..object_size_in_words]);

        // Add this object to the target space's finalization set if it is in
        // ours.
        if (self.finalizationSetContains(address)) {
            self.removeFromFinalizationSet(address) catch unreachable;
            try target_space.addToFinalizationSet(allocator, new_address);
        }

        // Create a forwarding reference
        object.setForwardAddress(new_address);
        return new_address;
    }

    /// Same as copyObjectTo, but for byte vectors.
    fn copyByteVectorTo(allocator: Allocator, address: [*]u64, target_space: *Space) [*]u64 {
        const byte_vector = ByteVector.fromAddress(address);
        const byte_vector_size = byte_vector.getSizeInMemory();
        std.debug.assert(byte_vector_size % @sizeOf(u64) == 0);

        const byte_vector_size_in_words = byte_vector_size / @sizeOf(u64);
        // We must have enough space at this point.
        const new_address = target_space.allocateInByteVectorSegment(allocator, &[_]*Activation{}, byte_vector_size) catch unreachable;
        std.mem.copy(u64, new_address[0..byte_vector_size_in_words], address[0..byte_vector_size_in_words]);

        return new_address;
    }

    /// Copy the given address to the target space. If require_copy is true,
    /// panics if the given address wasn't in this space.
    fn copyAddress(self: *Space, allocator: Allocator, address: [*]u64, target_space: *Space, comptime require_copy: bool) !?[*]u64 {
        if (self.objectSegmentContains(address)) {
            return self.copyObjectTo(allocator, address, target_space);
        } else if (self.byteVectorSegmentContains(address)) {
            return copyByteVectorTo(allocator, address, target_space);
        } else if (require_copy) {
            std.debug.panic("!!! copyAddress called with an address that's not allocated in this space!", .{});
        }

        return null;
    }

    /// Performs Cheney's algorithm, copying alive objects to the given target.
    pub fn cheneyCommon(
        self: *Space,
        allocator: Allocator,
        activation_stack: []const *Activation,
        target_space: *Space,
        newer_generation_link: ?*const NewerGenerationLink,
    ) Allocator.Error!void {
        // First see if the target space has enough space to potentially take
        // everything in this space.
        const space_size = self.memory.len * @sizeOf(u64);
        const required_size = space_size - self.freeMemory();
        if (required_size > target_space.freeMemory()) {
            if (GC_DEBUG) std.debug.print("Space.cheneyCommon: Target space doesn't have enough memory to hold all of our objects, attempting to perform GC on it\n", .{});

            // Make the other space garbage collect first.
            const my_link = NewerGenerationLink{ .space = self, .previous = newer_generation_link };
            try target_space.collectGarbageInternal(allocator, required_size, activation_stack, &my_link);

            if (space_size - self.freeMemory() > target_space.freeMemory()) {
                std.debug.panic("Even after a garbage collection, the target space doesn't have enough memory for me to perform a scavenge, sorry.", .{});
            }

            if (GC_DEBUG) std.debug.print("Space.cheneyCommon: Target space successfully GC'd, now has {} bytes free\n", .{target_space.freeMemory()});
        }
        // If we got here, then we have enough free memory on the target space
        // to perform our operations.

        // These are saved in order to race against them in the final phase
        // of the scavenge.
        var object_scan_cursor = target_space.object_cursor;

        // Go through the whole activation stack, copying activation objects
        // that are within this space
        for (activation_stack) |activation| {
            const activation_object_reference = activation.activation_object;
            std.debug.assert(activation_object_reference.isObjectReference());
            const activation_object_address = activation_object_reference.asObjectAddress();

            // If the activation object address is not within the object segment
            // of our space, then we do not care about it.
            if (!self.objectSegmentContains(activation_object_address))
                continue;

            const new_address = try self.copyObjectTo(allocator, activation_object_address, target_space);
            activation.activation_object = Value.fromObjectAddress(new_address);
        }

        // Go through the tracked set, copying referenced objects
        for (self.tracked_set.keys()) |handle| {
            const address = handle.*;
            handle.* = (try self.copyAddress(allocator, address, target_space, true)).?;
            try target_space.addToTrackedSet(allocator, handle);
        }

        {
            var remembered_set_iterator = self.remembered_set.iterator();
            // Go through the remembered set, and copy any referenced objects.
            // Transfer the remembered set objects to the new space if it has a
            // remembered set of its own. (TODO old space shouldn't have one)
            while (remembered_set_iterator.next()) |entry| {
                const start_of_object = entry.key_ptr.*;
                const object_size_in_bytes = entry.value_ptr.*;
                const object_slice = start_of_object[0 .. object_size_in_bytes / @sizeOf(u64)];

                var found_references: usize = 0;
                for (object_slice) |*word| {
                    const value = Value{ .data = word.* };
                    if (value.isObjectReference()) {
                        const address = value.asObjectAddress();
                        if (try self.copyAddress(allocator, address, target_space, false)) |new_address| {
                            word.* = Value.fromObjectAddress(new_address).data;
                            found_references += 1;
                        }
                    }
                }

                // Make sure that the object in the remembered set actually has a
                // purpose of being there, i.e. actually contains references to this
                // space.
                std.debug.assert(found_references > 0);

                try target_space.remembered_set.put(allocator, start_of_object, object_size_in_bytes);
            }
        }

        // Go through any memory regions in newer spaces, and copy any
        // referenced objects (and update these newer spaces' remembered sets).
        // This ensures that new->old references are also preserved.
        var newer_generation_link_it = newer_generation_link;
        while (newer_generation_link_it) |link| {
            if (GC_DEBUG) std.debug.print("Space.cheneyCommon: Scanning newer generation {s}\n", .{link.space.name});

            const newer_generation_space = link.space;
            const object_segment_size_in_words = (@ptrToInt(newer_generation_space.object_cursor) - @ptrToInt(newer_generation_space.memory.ptr)) / @sizeOf(u64);
            const object_segment_of_space = newer_generation_space.memory.ptr[0..object_segment_size_in_words];

            // Update all the addresses in the newer space with the new
            // locations in the target space
            for (object_segment_of_space) |*word| {
                const value = Value{ .data = word.* };
                if (value.isObjectReference()) {
                    const address = value.asObjectAddress();
                    if (try self.copyAddress(allocator, address, target_space, false)) |new_address| {
                        word.* = Value.fromObjectAddress(new_address).data;
                    }
                }
            }

            newer_generation_link_it = link.previous;
        }

        if (GC_DEBUG) std.debug.print("Space.cheneyCommon: Trying to catch up from {*} to {*}\n", .{ object_scan_cursor, target_space.object_cursor });

        // Try to catch up to the target space's object and byte vector cursors,
        // copying any other objects/byte vectors that still exist in this space
        while (@ptrToInt(object_scan_cursor) < @ptrToInt(target_space.object_cursor)) : (object_scan_cursor += 1) {
            const word = object_scan_cursor[0];
            const value = Value{ .data = word };

            if (value.isObjectReference()) {
                const address = value.asObjectAddress();

                if (self.objectSegmentContains(address)) {
                    object_scan_cursor[0] = Value.fromObjectAddress(try self.copyObjectTo(allocator, address, target_space)).data;
                } else if (self.byteVectorSegmentContains(address)) {
                    object_scan_cursor[0] = Value.fromObjectAddress(copyByteVectorTo(allocator, address, target_space)).data;
                }
            }
        }

        std.debug.assert(object_scan_cursor == target_space.object_cursor);

        // Notify any object who didn't make it out of this space and wanted to
        // be notified about being finalized.
        for (self.finalization_set.keys()) |address| {
            const object = Object.fromAddress(address);
            object.finalize(allocator);
        }

        // Go through all the newer generations again, and remove or replace all
        // the items in the remembered set which point to this space.
        //
        // NOTE: Must happen AFTER all copying of objects is finished, as we
        //       need to know which objects survived the scavenge and which ones
        //       did not - the ones which didn't survive the scavenge will
        //       simply be removed from the remembered set, while the ones which
        //       did must be replaced with the new object in the target space.
        newer_generation_link_it = newer_generation_link;
        while (newer_generation_link_it) |link| {
            if (GC_DEBUG) std.debug.print("Space.cheneyCommon: Updating remembered set of newer generation {s}\n", .{link.space.name});

            const newer_generation_space = link.space;
            // NOTE: Must create a copy, as we're modifying entries in the
            //       remembered set
            var remembered_set_copy = try newer_generation_space.remembered_set.clone(allocator);
            defer remembered_set_copy.deinit(allocator);

            var remembered_set_iterator = remembered_set_copy.iterator();
            while (remembered_set_iterator.next()) |entry| {
                const object_address = entry.key_ptr.*;
                const object_size = entry.value_ptr.*;

                if (self.objectSegmentContains(object_address)) {
                    const object = Object.fromAddress(object_address);

                    if (object.isForwardingReference()) {
                        // Yes, the object's been copied. Replace the entry in
                        // the remembered set.
                        const new_address = object.getForwardAddress();
                        newer_generation_space.removeFromRememberedSet(object_address) catch unreachable;
                        // Hopefully the object size has not changed somehow
                        // during a GC. :^)
                        try newer_generation_space.addToRememberedSet(allocator, new_address, object_size);
                    } else {
                        // No, the object didn't survive the scavenge.
                        newer_generation_space.removeFromRememberedSet(object_address) catch unreachable;
                    }
                }
            }

            newer_generation_link_it = link.previous;
        }

        // Reset this space's pointers, tracked set, remembered set and
        // finalization set, as it is now effectively empty.
        self.object_cursor = self.memory.ptr;
        self.byte_vector_cursor = self.memory.ptr + self.memory.len;
        self.remembered_set.clearRetainingCapacity();
        self.finalization_set.clearRetainingCapacity();
        self.tracked_set.clearRetainingCapacity();
    }

    /// Performs a garbage collection operation on this space.
    ///
    /// This method performs either a scavenge or a tenure; if a scavenge target
    /// is defined for this space, it first attempts a scavenge. If not enough
    /// memory is cleaned up by a scavenge operation, or there wasn't a defined
    /// scavenge target, a *tenure* is attempted towards the tenure target of
    /// this space. If a tenure target is not specified either, then the heap is
    /// simply expanded to accomodate the new objects.
    pub fn collectGarbage(self: *Space, allocator: Allocator, required_memory: usize, activation_stack: []const *Activation) !void {
        try self.collectGarbageInternal(allocator, required_memory, activation_stack, null);
    }

    /// Performs the actual operation as described in collectGarbage. Takes an
    /// additional memory_link argument, which describes a set of memory areas
    /// to scan after a garbage collection is done for stale references.
    fn collectGarbageInternal(
        self: *Space,
        allocator: Allocator,
        required_memory: usize,
        activation_stack: []const *Activation,
        newer_generation_link: ?*const NewerGenerationLink,
    ) !void {
        // See if we already have the required memory amount.
        if (self.freeMemory() >= required_memory) return;

        if (GC_DEBUG) std.debug.print("Space.collectGarbage: Attempting to garbage collect in {s}\n", .{self.name});

        // See if we can perform a scavenge first.
        if (self.scavenge_target) |scavenge_target| {
            if (GC_DEBUG) std.debug.print("Space.collectGarbage: Attempting to perform a scavenge to my scavenge target, {s}\n", .{scavenge_target.name});
            try self.cheneyCommon(allocator, activation_stack, scavenge_target, newer_generation_link);
            self.swapMemoryWith(scavenge_target);

            if (self.freeMemory() >= required_memory) {
                if (GC_DEBUG) std.debug.print("Space.collectGarbage: Scavenging was sufficient. {} bytes now free in {s}.\n", .{ self.freeMemory(), self.name });
                return;
            }
        }

        // Looks like the scavenge didn't give us enough memory. Let's attempt a
        // tenure.
        if (self.tenure_target) |tenure_target| {
            const tenure_target_previous_free_memory = tenure_target.freeMemory();

            if (GC_DEBUG) std.debug.print("Space.collectGarbage: Attempting to tenure to {s}\n", .{tenure_target.name});
            try self.cheneyCommon(allocator, activation_stack, tenure_target, newer_generation_link);

            // FIXME: Return an error instead of panicing when the allocation
            //        is too large for this space. How should we handle large
            //        allocations anyway?
            if (self.freeMemory() < required_memory) {
                std.debug.panic("!!! Could not free enough space in {s} even after tenuring! ({} bytes free, {} required)\n", .{ self.name, self.freeMemory(), required_memory });
            }

            if (GC_DEBUG) {
                const tenure_target_current_free_memory = tenure_target.freeMemory();
                const free_memory_diff = @intCast(isize, tenure_target_previous_free_memory) - @intCast(isize, tenure_target_current_free_memory);

                std.debug.print("Space.collectGarbage: Successfully tenured, {} bytes now free in {s}.\n", .{ self.freeMemory(), self.name });
                if (free_memory_diff < 0) {
                    std.debug.print("Space.collectGarbage: (Tenure target {s} LOST {} bytes, target did a GC?)\n", .{ tenure_target.name, -free_memory_diff });
                } else {
                    std.debug.print("Space.collectGarbage: (Tenure target {s} gained {} bytes)\n", .{ tenure_target.name, free_memory_diff });
                }
            }
            return;
        }

        std.debug.panic("TODO expanding a space which doesn't have a tenure or scavenge target", .{});
    }

    fn swapMemoryWith(self: *Space, target_space: *Space) void {
        std.mem.swap([]u64, &self.memory, &target_space.memory);
        std.mem.swap([*]u64, &self.object_cursor, &target_space.object_cursor);
        std.mem.swap([*]u64, &self.byte_vector_cursor, &target_space.byte_vector_cursor);
        std.mem.swap(RememberedSet, &self.remembered_set, &target_space.remembered_set);
        std.mem.swap(FinalizationSet, &self.finalization_set, &target_space.finalization_set);
        std.mem.swap(TrackedSet, &self.tracked_set, &target_space.tracked_set);
    }

    fn objectSegmentContains(self: *Space, address: [*]u64) bool {
        return @ptrToInt(address) >= @ptrToInt(self.memory.ptr) and @ptrToInt(address) < @ptrToInt(self.object_cursor);
    }

    fn byteVectorSegmentContains(self: *Space, address: [*]u64) bool {
        return @ptrToInt(address) >= @ptrToInt(self.byte_vector_cursor) and @ptrToInt(address) < @ptrToInt(self.memory.ptr + self.memory.len);
    }

    /// Allocates the requested amount in bytes in the object segment of this
    /// space, garbage collecting if there is not enough space.
    pub fn allocateInObjectSegment(self: *Space, allocator: Allocator, activation_stack: []const *Activation, size: usize) ![*]u64 {
        std.debug.assert(size % 8 == 0);
        if (self.freeMemory() < size) try self.collectGarbage(allocator, size, activation_stack);

        const start_of_object = self.object_cursor;
        self.object_cursor += size / @sizeOf(u64);

        if (builtin.mode == .Debug)
            std.mem.set(u8, @ptrCast([*]align(@alignOf(u64)) u8, start_of_object)[0..size], UninitializedHeapScrubByte);

        return start_of_object;
    }

    /// Allocates the requested amount in bytes in the byte vector segment of
    /// this space, garbage collecting if there is not enough space.
    pub fn allocateInByteVectorSegment(self: *Space, allocator: Allocator, activation_stack: []const *Activation, size: usize) ![*]u64 {
        std.debug.assert(size % 8 == 0);
        if (self.freeMemory() < size) try self.collectGarbage(allocator, size, activation_stack);

        self.byte_vector_cursor -= size / @sizeOf(u64);

        if (builtin.mode == .Debug)
            std.mem.set(u8, @ptrCast([*]align(@alignOf(u64)) u8, self.byte_vector_cursor)[0..size], UninitializedHeapScrubByte);

        return self.byte_vector_cursor;
    }

    /// Adds the given address to the finalization set of this space.
    pub fn addToFinalizationSet(self: *Space, allocator: Allocator, address: [*]u64) !void {
        try self.finalization_set.put(allocator, address, .{});
    }

    /// Returns whether the finalization set contains the given address.
    pub fn finalizationSetContains(self: *Space, address: [*]u64) bool {
        return self.finalization_set.contains(address);
    }

    pub const RemoveFromFinalizationSetError = error{AddressNotInFinalizationSet};
    /// Removes the given address from the finalization set of this space.
    /// Returns AddressNotInFinalizationSet if the address was not in the
    /// finalization set.
    pub fn removeFromFinalizationSet(self: *Space, address: [*]u64) !void {
        if (!self.finalization_set.swapRemove(address)) {
            return RemoveFromFinalizationSetError.AddressNotInFinalizationSet;
        }
    }

    /// Adds the given tracked value into the tracked set of this space.
    pub fn addToTrackedSet(self: *Space, allocator: Allocator, handle: *[*]u64) !void {
        try self.tracked_set.put(allocator, handle, .{});
    }

    /// Returns whether the tracked set contains the given tracked value.
    pub fn trackedSetContains(self: *Space, handle: *[*]u64) !void {
        return self.tracked_set.contains(handle);
    }

    pub const RemoveFromTrackedSetError = error{AddressNotInTrackedSet};
    /// Removes the given object handle from the tracked set of this space.
    /// Returns AddressNotInTrackedSet if the handle was not in the tracked
    /// set.
    pub fn removeFromTrackedSet(self: *Space, handle: *[*]u64) !void {
        if (!self.tracked_set.swapRemove(handle)) {
            return RemoveFromTrackedSetError.AddressNotInTrackedSet;
        }
    }

    /// Adds the given address into the remembered set of this space.
    pub fn addToRememberedSet(self: *Space, allocator: Allocator, address: [*]u64, size: usize) !void {
        try self.remembered_set.put(allocator, address, size);
    }

    pub const RemoveFromRememberedSetError = error{AddressNotInRememberedSet};
    /// Removes the given address from the remembered set of this space. Returns
    /// AddressNotInRememberedSet if the address was not in the remembered set.
    pub fn removeFromRememberedSet(self: *Space, address: [*]u64) !void {
        if (!self.remembered_set.swapRemove(address)) {
            return RemoveFromRememberedSetError.AddressNotInRememberedSet;
        }
    }

    /// Find the space which has this value, and add the tracked value to the
    /// tracked set of that space.
    pub fn startTracking(self: *Space, allocator: Allocator, handle: *[*]u64) Allocator.Error!bool {
        const address = handle.*;

        if (self.objectSegmentContains(address) or self.byteVectorSegmentContains(address)) {
            try self.addToTrackedSet(allocator, handle);
            return true;
        }

        if (self.scavenge_target) |scavenge_target| {
            if (try scavenge_target.startTracking(allocator, handle)) return true;
        }

        if (self.tenure_target) |tenure_target| {
            if (try tenure_target.startTracking(allocator, handle)) return true;
        }

        return false;
    }

    /// Find the space which has this value, and remove the tracked value from
    /// the tracked set of that space.
    pub fn stopTracking(self: *Space, handle: *[*]u64) bool {
        const address = handle.*;

        if (self.objectSegmentContains(address) or self.byteVectorSegmentContains(address)) {
            self.removeFromTrackedSet(handle) catch unreachable;
            return true;
        }

        if (self.scavenge_target) |scavenge_target| {
            if (scavenge_target.stopTracking(handle)) return true;
        }

        if (self.tenure_target) |tenure_target| {
            if (tenure_target.stopTracking(handle)) return true;
        }

        return false;
    }
};

/// A tracked heap value. This value is updated whenever garbage collection
/// occurs and the object moves.
pub const Tracked = struct {
    value: union(enum) {
        Object: *[*]u64,
        Literal: Value,
    },

    pub fn createWithObject(handle: *[*]u64) Tracked {
        return Tracked{ .value = .{ .Object = handle } };
    }

    pub fn createWithLiteral(value: Value) Tracked {
        std.debug.assert(!value.isObjectReference());
        return Tracked{ .value = .{ .Literal = value } };
    }

    pub fn untrack(self: Tracked, heap: *Self) void {
        if (self.value == .Object) {
            heap.untrack(self);
        }
    }

    pub fn getValue(self: Tracked) Value {
        return switch (self.value) {
            .Object => |t| Value.fromObjectAddress(t.*),
            .Literal => |t| t,
        };
    }
};

test "allocate one object's worth of space on the heap" {
    const allocator = std.testing.allocator;

    var heap = try Self.create(allocator);
    defer heap.destroy();

    const eden_free_memory = heap.eden.freeMemory();
    _ = try heap.allocateInObjectSegment(16);
    try std.testing.expectEqual(eden_free_memory - 16, heap.eden.freeMemory());
}

test "fill up the eden with objects and attempt to allocate one more" {
    const allocator = std.testing.allocator;

    var heap = try Self.create(allocator);
    defer heap.destroy();

    const eden_free_memory = heap.eden.freeMemory();
    while (heap.eden.freeMemory() > 0) {
        _ = try heap.allocateInObjectSegment(8);
    }

    _ = try heap.allocateInObjectSegment(16);
    try std.testing.expectEqual(eden_free_memory - 16, heap.eden.freeMemory());
    // Expect the from space to be empty, as there were no object refs this
    // entire time
    try std.testing.expectEqual(heap.from_space.memory.ptr, heap.from_space.object_cursor);
}

test "link an object to another and perform scavenge" {
    const allocator = std.testing.allocator;

    var heap = try Self.create(allocator);
    defer heap.destroy();

    // The object being referenced
    var referenced_object_map = try Object.Map.Slots.create(heap, 1);
    var actual_name = try ByteVector.createFromString(heap, "actual");
    referenced_object_map.getSlots()[0].initConstant(actual_name, .NotParent, Value.fromUnsignedInteger(0xDEADBEEF));
    var referenced_object = try Object.Slots.create(heap, referenced_object_map, &[_]Value{});

    // The "activation object", which is how we get a reference to the object in
    // the from space after the tenure is done
    var activation_object_map = try Object.Map.Slots.create(heap, 1);
    var reference_name = try ByteVector.createFromString(heap, "reference");
    activation_object_map.getSlots()[0].initMutable(Object.Map.Slots, activation_object_map, reference_name, .NotParent);
    var activation_object = try Object.Slots.create(heap, activation_object_map, &[_]Value{referenced_object.asValue()});

    // Create the activation
    var activation = Activation{ .activation_object = activation_object.asValue() };

    // Activate the garbage collection, tenuring from the eden to from space
    try heap.eden.collectGarbage(allocator, EdenSize, &[_]*Activation{&activation});

    // Find the new activation object
    var new_activation_object = activation.activation_object.asObject().asSlotsObject();
    try std.testing.expect(activation_object != new_activation_object);
    var new_activation_object_map = new_activation_object.getMap();
    try std.testing.expect(activation_object_map != new_activation_object_map);
    try std.testing.expect(activation_object_map.getSlots()[0].name.asObjectAddress() != new_activation_object_map.getSlots()[0].name.asObjectAddress());
    try std.testing.expectEqualStrings("reference", new_activation_object_map.getSlots()[0].name.asByteVector().getValues());

    // Find the new referenced object
    var new_referenced_object = new_activation_object.getAssignableSlotValueByName("reference").?.asObject().asSlotsObject();
    try std.testing.expect(referenced_object != new_referenced_object);
    var new_referenced_object_map = new_referenced_object.getMap();
    try std.testing.expect(referenced_object_map != new_referenced_object_map);
    try std.testing.expect(referenced_object_map.getSlots()[0].name.asObjectAddress() != new_referenced_object_map.getSlots()[0].name.asObjectAddress());
    try std.testing.expectEqualStrings("actual", new_referenced_object_map.getSlots()[0].name.asByteVector().getValues());

    // Verify that the map map is shared (aka forwarding addresses work)
    try std.testing.expectEqual(
        new_activation_object_map.map.header.getMap(),
        new_referenced_object_map.map.header.getMap(),
    );

    // Get the value we stored and compare it
    var referenced_object_value = new_referenced_object.getMap().getSlotByName("actual").?.value;
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), referenced_object_value.asUnsignedInteger());
}
