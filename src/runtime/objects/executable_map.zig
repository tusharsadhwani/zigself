// Copyright (c) 2021-2022, sin-ack <sin-ack@protonmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Allocator = std.mem.Allocator;

const Map = @import("map.zig").Map;
const Value = value_import.Value;
const MapType = @import("map.zig").MapType;
const bytecode = @import("../bytecode.zig");
const SlotsMap = @import("slots.zig").SlotsMap;
const value_import = @import("../value.zig");
const PointerValue = value_import.PointerValue;
const stage2_compat = @import("../../utility/stage2_compat.zig");
const RefCountedValue = value_import.RefCountedValue;

/// An "executable map" is one that contains a reference to executable code.
/// They have a VM-intrinsic way to activate them; for instance, methods are
/// activated by sending the message with the same name to an object that has it
/// in its lookup chain, and blocks are activated by sending them the correct
/// `value:With:...` method.
pub const ExecutableMap = extern struct {
    slots: SlotsMap align(@alignOf(u64)),
    /// The address of the bytecode block. Owned by definition_executable_ref.
    block: PointerValue(bytecode.Block) align(@alignOf(u64)),
    /// The executable which this map was created from.
    definition_executable_ref: RefCountedValue(bytecode.Executable) align(@alignOf(u64)),

    pub const Ptr = stage2_compat.HeapPtr(ExecutableMap, .Mutable);

    pub const ExecutableInformation = packed struct(u16) {
        argument_slot_count: u8,
        padding: u8 = 0,
    };

    /// Refs `script`.
    pub fn init(
        self: ExecutableMap.Ptr,
        comptime map_type: MapType,
        map_map: Map.Ptr,
        argument_slot_count: u8,
        total_slot_count: u32,
        block: *bytecode.Block,
        executable: bytecode.Executable.Ref,
    ) void {
        std.debug.assert(argument_slot_count <= total_slot_count);

        self.slots.init(total_slot_count, map_map);
        self.slots.map.init(map_type, map_map);
        self.setArgumentSlotCount(argument_slot_count);

        self.block = PointerValue(bytecode.Block).init(block);
        self.definition_executable_ref = RefCountedValue(bytecode.Executable).init(executable);
    }

    /// Finalizes this object. All maps that have a SlotsAndBytecodeMap member
    /// must call this function in their finalize.
    pub fn finalize(self: ExecutableMap.Ptr, allocator: Allocator) void {
        _ = allocator;
        self.definition_executable_ref.deinit();
    }

    pub fn getArgumentSlotCount(self: ExecutableMap.Ptr) u8 {
        return @ptrCast(*ExecutableInformation, &self.slots.information.extra).argument_slot_count;
    }

    fn setArgumentSlotCount(self: ExecutableMap.Ptr, count: u8) void {
        @ptrCast(*ExecutableInformation, &self.slots.information.extra).argument_slot_count = count;
    }
};
