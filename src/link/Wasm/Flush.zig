//! Temporary, dynamically allocated structures used only during flush.
//! Could be constructed fresh each time, or kept around between updates to reduce heap allocations.

const Flush = @This();
const Wasm = @import("../Wasm.zig");
const Object = @import("Object.zig");
const Zcu = @import("../../Zcu.zig");
const Alignment = Wasm.Alignment;
const String = Wasm.String;
const Relocation = Wasm.Relocation;

const build_options = @import("build_options");

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const leb = std.leb;
const log = std.log.scoped(.link);
const assert = std.debug.assert;

function_imports: std.AutoArrayHashMapUnmanaged(Wasm.FunctionImportId, void) = .empty,
global_imports: std.AutoArrayHashMapUnmanaged(Wasm.GlobalImportId, void) = .empty,
/// Ordered list of non-import functions that will appear in the final
/// binary.
functions: std.AutoArrayHashMapUnmanaged(Wasm.FunctionImport.Resolution, void) = .empty,
/// Ordered list of non-import globals that will appear in the final binary.
globals: std.AutoArrayHashMapUnmanaged(Wasm.GlobalImport.Resolution, void) = .empty,
/// Ordered list of data segments that will appear in the final binary.
/// When sorted, to-be-merged segments will be made adjacent.
/// Values are offset relative to segment start.
data_segments: std.AutoArrayHashMapUnmanaged(Wasm.DataSegment.Index, u32) = .empty,
/// Each time a `data_segment` offset equals zero it indicates a new group, and
/// the next element in this array will contain the total merged segment size.
data_segment_groups: std.ArrayListUnmanaged(u32) = .empty,

indirect_function_table: std.AutoArrayHashMapUnmanaged(OutputFunctionIndex, u32) = .empty,
binary_bytes: std.ArrayListUnmanaged(u8) = .empty,

/// Empty when outputting an object.
function_exports: std.ArrayListUnmanaged(FunctionIndex) = .empty,
global_exports: std.ArrayListUnmanaged(GlobalIndex) = .empty,

/// Tracks whether this is the first flush or subsequent flush.
/// This flag is not reset during `clear`.
subsequent: bool = false,

/// 0. Index into `data_segments`.
const DataSegmentIndex = enum(u32) {
    _,
};

/// 0. Index into `function_imports`
/// 1. Index into `functions`.
const OutputFunctionIndex = enum(u32) {
    _,
};

/// Index into `functions`.
const FunctionIndex = enum(u32) {
    _,
};

/// Index into `globals`.
const GlobalIndex = enum(u32) {
    _,

    fn key(index: GlobalIndex, f: *const Flush) *Wasm.GlobalImport.Resolution {
        return &f.globals.items[@intFromEnum(index)];
    }
};

pub fn clear(f: *Flush) void {
    f.binary_bytes.clearRetainingCapacity();
    f.function_imports.clearRetainingCapacity();
    f.global_imports.clearRetainingCapacity();
    f.functions.clearRetainingCapacity();
    f.globals.clearRetainingCapacity();
    f.data_segments.clearRetainingCapacity();
    f.data_segment_groups.clearRetainingCapacity();
    f.indirect_function_table.clearRetainingCapacity();
    f.function_exports.clearRetainingCapacity();
    f.global_exports.clearRetainingCapacity();
}

pub fn deinit(f: *Flush, gpa: Allocator) void {
    f.binary_bytes.deinit(gpa);
    f.function_imports.deinit(gpa);
    f.global_imports.deinit(gpa);
    f.functions.deinit(gpa);
    f.globals.deinit(gpa);
    f.data_segments.deinit(gpa);
    f.data_segment_groups.deinit(gpa);
    f.indirect_function_table.deinit(gpa);
    f.function_exports.deinit(gpa);
    f.global_exports.deinit(gpa);
    f.* = undefined;
}

pub fn finish(f: *Flush, wasm: *Wasm, arena: Allocator, tid: Zcu.PerThread.Id) anyerror!void {
    const comp = wasm.base.comp;
    const shared_memory = comp.config.shared_memory;
    const diags = &comp.link_diags;
    const gpa = comp.gpa;
    const import_memory = comp.config.import_memory;
    const export_memory = comp.config.export_memory;
    const target = comp.root_mod.resolved_target.result;
    const rdynamic = comp.config.rdynamic;
    const is_obj = comp.config.output_mode == .Obj;
    const allow_undefined = is_obj or wasm.import_symbols;

    if (wasm.zig_object) |zo| {
        try zo.populateErrorNameTable(wasm, tid);
        try zo.setupErrorsLen(wasm);
    }

    for (wasm.export_symbol_names) |exp_name| {
        const exp_name_interned = try wasm.internString(exp_name);
        if (wasm.object_function_imports.getPtr(exp_name_interned)) |*import| {
            if (import.resolution != .unresolved) {
                import.flags.exported = true;
                continue;
            }
        }
        if (wasm.object_global_imports.getPtr(exp_name_interned)) |*import| {
            if (import.resolution != .unresolved) {
                import.flags.exported = true;
                continue;
            }
        }
        diags.addError("manually specified export name '{s}' undefined", .{exp_name});
    }

    if (wasm.entry_name.unwrap()) |entry_name| e: {
        if (wasm.object_function_imports.getPtr(entry_name)) |*import| {
            if (import.resolution != .unresolved) {
                import.flags.exported = true;
                break :e;
            }
        }
        var err = try diags.addErrorWithNotes(1);
        try err.addMsg("entry symbol '{s}' missing", .{entry_name.slice(wasm)});
        try err.addNote("'-fno-entry' suppresses this error", .{});
    }

    if (diags.hasErrors()) return error.LinkFailure;

    if (f.subsequent) {
        // Reset garbage collection state.
        for (wasm.object_function_imports.values()) |*import| import.flags.alive = false;
        for (wasm.object_global_imports.values()) |*import| import.flags.alive = false;
        for (wasm.object_table_imports.values()) |*import| import.flags.alive = false;
    }

    // These loops do both recursive marking of alive symbols well as checking for undefined symbols.
    // At the end, output_functions and output_globals will be populated.
    for (wasm.object_function_imports.keys(), wasm.object_function_imports.values(), 0..) |name, *import, i| {
        if (import.flags.isIncluded(rdynamic)) {
            try markFunction(wasm, name, import, @enumFromInt(i), allow_undefined);
            continue;
        }
    }
    for (wasm.object_global_imports.keys(), wasm.object_global_imports.values(), 0..) |name, *import, i| {
        if (import.flags.isIncluded(rdynamic)) {
            try markGlobal(wasm, name, import, @enumFromInt(i), allow_undefined);
            continue;
        }
    }
    for (wasm.object_table_imports.keys(), wasm.object_table_imports.values(), 0..) |name, *import, i| {
        if (import.flags.isIncluded(rdynamic)) {
            try markTable(wasm, name, import, @enumFromInt(i), allow_undefined);
            continue;
        }
    }
    if (diags.hasErrors()) return error.LinkFailure;

    // TODO only include init functions for objects with must_link=true or
    // which have any alive functions inside them.
    if (wasm.object_init_funcs.items.len > 0) {
        // Zig has no constructors so these are only for object file inputs.
        mem.sortUnstable(Wasm.InitFunc, wasm.object_init_funcs.items, {}, Wasm.InitFunc.lessThan);
        try f.functions.put(gpa, .__wasm_call_ctors, {});
    }

    var any_passive_inits = false;

    // Merge and order the data segments. Depends on garbage collection so that
    // unused segments can be omitted.
    try f.ensureUnusedCapacity(gpa, wasm.object_data_segments.items.len);
    for (wasm.object_data_segments.items, 0..) |*ds, i| {
        if (!ds.flags.alive) continue;
        any_passive_inits = any_passive_inits or ds.flags.is_passive or (import_memory and !isBss(wasm, ds.name));
        f.data_segments.putAssumeCapacityNoClobber(@intCast(i), .{
            .offset = undefined,
        });
    }

    try f.functions.ensureUnusedCapacity(gpa, 3);

    // Passive segments are used to avoid memory being reinitialized on each
    // thread's instantiation. These passive segments are initialized and
    // dropped in __wasm_init_memory, which is registered as the start function
    // We also initialize bss segments (using memory.fill) as part of this
    // function.
    if (any_passive_inits) {
        f.functions.putAssumeCapacity(.__wasm_init_memory, {});
    }

    // When we have TLS GOT entries and shared memory is enabled,
    // we must perform runtime relocations or else we don't create the function.
    if (shared_memory) {
        if (f.need_tls_relocs) f.functions.putAssumeCapacity(.__wasm_apply_global_tls_relocs, {});
        f.functions.putAssumeCapacity(gpa, .__wasm_init_tls, {});
    }

    // Sort order:
    // 0. Whether the segment is TLS
    // 1. Segment name prefix
    // 2. Segment alignment
    // 3. Segment name suffix
    // 4. Segment index (to break ties, keeping it deterministic)
    // TLS segments are intended to be merged with each other, and segments
    // with a common prefix name are intended to be merged with each other.
    // Sorting ensures the segments intended to be merged will be adjacent.
    const Sort = struct {
        wasm: *const Wasm,
        segments: []const Wasm.DataSegment.Index,
        pub fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
            const lhs_segment_index = ctx.segments[lhs];
            const rhs_segment_index = ctx.segments[rhs];
            const lhs_segment = lhs_segment_index.ptr(wasm);
            const rhs_segment = rhs_segment_index.ptr(wasm);
            const lhs_tls = @intFromBool(lhs_segment.flags.tls);
            const rhs_tls = @intFromBool(rhs_segment.flags.tls);
            if (lhs_tls < rhs_tls) return true;
            if (lhs_tls > rhs_tls) return false;
            const lhs_prefix, const lhs_suffix = splitSegmentName(lhs_segment.name.unwrap().slice(ctx.wasm));
            const rhs_prefix, const rhs_suffix = splitSegmentName(rhs_segment.name.unwrap().slice(ctx.wasm));
            switch (mem.order(u8, lhs_prefix, rhs_prefix)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            switch (lhs_segment.flags.alignment.order(rhs_segment.flags.alignment)) {
                .lt => return false,
                .gt => return true,
                .eq => {},
            }
            return switch (mem.order(u8, lhs_suffix, rhs_suffix)) {
                .lt => true,
                .gt => false,
                .eq => @intFromEnum(lhs_segment_index) < @intFromEnum(rhs_segment_index),
            };
        }
    };
    f.data_segments.sortUnstable(@as(Sort, .{
        .wasm = wasm,
        .segments = f.data_segments.keys(),
    }));

    const page_size = std.wasm.page_size; // 64kb
    const stack_alignment: Alignment = .@"16"; // wasm's stack alignment as specified by tool-convention
    const heap_alignment: Alignment = .@"16"; // wasm's heap alignment as specified by tool-convention
    const pointer_alignment: Alignment = .@"4";
    // Always place the stack at the start by default unless the user specified the global-base flag.
    const place_stack_first, var memory_ptr: u32 = if (wasm.global_base) |base| .{ false, base } else .{ true, 0 };

    const VirtualAddrs = struct {
        stack_pointer: u32,
        heap_base: u32,
        heap_end: u32,
        tls_base: ?u32,
        tls_align: ?u32,
        tls_size: ?u32,
        init_memory_flag: ?u32,
    };
    var virtual_addrs: VirtualAddrs = .{
        .stack_pointer = undefined,
        .heap_base = undefined,
        .heap_end = undefined,
        .tls_base = null,
        .tls_align = null,
        .tls_size = null,
        .init_memory_flag = null,
    };

    if (place_stack_first and !is_obj) {
        memory_ptr = stack_alignment.forward(memory_ptr);
        memory_ptr += wasm.base.stack_size;
        virtual_addrs.stack_pointer = memory_ptr;
    }

    const segment_indexes = f.data_segments.keys();
    const segment_offsets = f.data_segments.values();
    assert(f.data_segment_groups.items.len == 0);
    {
        var seen_tls: enum { before, during, after } = .before;
        var offset: u32 = 0;
        for (segment_indexes, segment_offsets, 0..) |segment_index, *segment_offset, i| {
            const segment = segment_index.ptr(f);
            memory_ptr = segment.alignment.forward(memory_ptr);

            const want_new_segment = b: {
                if (is_obj) break :b false;
                switch (seen_tls) {
                    .before => if (segment.flags.tls) {
                        virtual_addrs.tls_base = if (shared_memory) 0 else memory_ptr;
                        virtual_addrs.tls_align = segment.flags.alignment;
                        seen_tls = .during;
                        break :b true;
                    },
                    .during => if (!segment.flags.tls) {
                        virtual_addrs.tls_size = memory_ptr - virtual_addrs.tls_base;
                        virtual_addrs.tls_align = virtual_addrs.tls_align.maxStrict(segment.flags.alignment);
                        seen_tls = .after;
                        break :b true;
                    },
                    .after => {},
                }
                break :b i >= 1 and !wasm.wantSegmentMerge(segment_indexes[i - 1], segment_index);
            };
            if (want_new_segment) {
                if (offset > 0) try f.data_segment_groups.append(gpa, offset);
                offset = 0;
            }

            segment_offset.* = offset;
            offset += segment.size;
            memory_ptr += segment.size;
        }
        if (offset > 0) try f.data_segment_groups.append(gpa, offset);
    }

    if (shared_memory and any_passive_inits) {
        memory_ptr = pointer_alignment.forward(memory_ptr);
        virtual_addrs.init_memory_flag = memory_ptr;
        memory_ptr += 4;
    }

    if (!place_stack_first and !is_obj) {
        memory_ptr = stack_alignment.forward(memory_ptr);
        memory_ptr += wasm.base.stack_size;
        virtual_addrs.stack_pointer = memory_ptr;
    }

    memory_ptr = heap_alignment.forward(memory_ptr);
    virtual_addrs.heap_base = memory_ptr;

    if (wasm.initial_memory) |initial_memory| {
        if (!mem.isAlignedGeneric(u64, initial_memory, page_size)) {
            diags.addError("initial memory value {d} is not {d}-byte aligned", .{ initial_memory, page_size });
        }
        if (memory_ptr > initial_memory) {
            diags.addError("initial memory value {d} insufficient; minimum {d}", .{ initial_memory, memory_ptr });
        }
        if (initial_memory > std.math.maxInt(u32)) {
            diags.addError("initial memory value {d} exceeds 32-bit address space", .{initial_memory});
        }
        if (diags.hasErrors()) return error.LinkFailure;
        memory_ptr = initial_memory;
    } else {
        memory_ptr = mem.alignForward(u64, memory_ptr, std.wasm.page_size);
    }
    virtual_addrs.heap_end = memory_ptr;

    // In case we do not import memory, but define it ourselves, set the
    // minimum amount of pages on the memory section.
    wasm.memories.limits.min = @intCast(memory_ptr / page_size);
    log.debug("total memory pages: {d}", .{wasm.memories.limits.min});

    if (wasm.max_memory) |max_memory| {
        if (!mem.isAlignedGeneric(u64, max_memory, page_size)) {
            diags.addError("maximum memory value {d} is not {d}-byte aligned", .{ max_memory, page_size });
        }
        if (memory_ptr > max_memory) {
            diags.addError("maximum memory value {d} insufficient; minimum {d}", .{ max_memory, memory_ptr });
        }
        if (max_memory > std.math.maxInt(u32)) {
            diags.addError("maximum memory exceeds 32-bit address space", .{max_memory});
        }
        if (diags.hasErrors()) return error.LinkFailure;
        wasm.memories.limits.max = @intCast(max_memory / page_size);
        wasm.memories.limits.flags.has_max = true;
        if (shared_memory) wasm.memories.limits.flags.is_shared = true;
        log.debug("maximum memory pages: {?d}", .{wasm.memories.limits.max});
    }

    // Size of each section header
    const header_size = 5 + 1;
    var section_index: u32 = 0;
    // Index of the code section. Used to tell relocation table where the section lives.
    var code_section_index: ?u32 = null;
    // Index of the data section. Used to tell relocation table where the section lives.
    var data_section_index: ?u32 = null;

    const binary_bytes = &f.binary_bytes;
    assert(binary_bytes.items.len == 0);

    try binary_bytes.appendSlice(gpa, std.wasm.magic ++ std.wasm.version);
    assert(binary_bytes.items.len == 8);

    const binary_writer = binary_bytes.writer(gpa);

    // Type section
    if (wasm.func_types.items.len != 0) {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);
        log.debug("Writing type section. Count: ({d})", .{wasm.func_types.items.len});
        for (wasm.func_types.items) |func_type| {
            try leb.writeUleb128(binary_writer, std.wasm.function_type);
            try leb.writeUleb128(binary_writer, @as(u32, @intCast(func_type.params.len)));
            for (func_type.params) |param_ty| {
                try leb.writeUleb128(binary_writer, std.wasm.valtype(param_ty));
            }
            try leb.writeUleb128(binary_writer, @as(u32, @intCast(func_type.returns.len)));
            for (func_type.returns) |ret_ty| {
                try leb.writeUleb128(binary_writer, std.wasm.valtype(ret_ty));
            }
        }

        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .type,
            @intCast(binary_bytes.items.len - header_offset - header_size),
            @intCast(wasm.func_types.items.len),
        );
        section_index += 1;
    }

    // Import section
    const total_imports_len = wasm.function_imports.items.len + wasm.global_imports.items.len +
        wasm.table_imports.items.len + wasm.memory_imports.items.len + @intFromBool(import_memory);

    if (total_imports_len > 0) {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);

        for (wasm.function_imports.items) |*function_import| {
            const module_name = function_import.module_name.slice(wasm);
            try leb.writeUleb128(binary_writer, @as(u32, @intCast(module_name.len)));
            try binary_writer.writeAll(module_name);

            const name = function_import.name.slice(wasm);
            try leb.writeUleb128(binary_writer, @as(u32, @intCast(name.len)));
            try binary_writer.writeAll(name);

            try binary_writer.writeByte(@intFromEnum(std.wasm.ExternalKind.function));
            try leb.writeUleb128(binary_writer, function_import.index);
        }

        for (wasm.table_imports.items) |*table_import| {
            const module_name = table_import.module_name.slice(wasm);
            try leb.writeUleb128(binary_writer, @as(u32, @intCast(module_name.len)));
            try binary_writer.writeAll(module_name);

            const name = table_import.name.slice(wasm);
            try leb.writeUleb128(binary_writer, @as(u32, @intCast(name.len)));
            try binary_writer.writeAll(name);

            try binary_writer.writeByte(@intFromEnum(std.wasm.ExternalKind.table));
            try leb.writeUleb128(binary_writer, std.wasm.reftype(table_import.reftype));
            try emitLimits(binary_writer, table_import.limits);
        }

        for (wasm.memory_imports.items) |*memory_import| {
            try emitMemoryImport(wasm, binary_writer, memory_import);
        } else if (import_memory) {
            try emitMemoryImport(wasm, binary_writer, &.{
                .module_name = wasm.host_name,
                .name = if (is_obj) wasm.preloaded_strings.__linear_memory else wasm.preloaded_strings.memory,
                .limits_min = wasm.memories.limits.min,
                .limits_max = wasm.memories.limits.max,
                .limits_has_max = wasm.memories.limits.flags.has_max,
                .limits_is_shared = wasm.memories.limits.flags.is_shared,
            });
        }

        for (wasm.global_imports.items) |*global_import| {
            const module_name = global_import.module_name.slice(wasm);
            try leb.writeUleb128(binary_writer, @as(u32, @intCast(module_name.len)));
            try binary_writer.writeAll(module_name);

            const name = global_import.name.slice(wasm);
            try leb.writeUleb128(binary_writer, @as(u32, @intCast(name.len)));
            try binary_writer.writeAll(name);

            try binary_writer.writeByte(@intFromEnum(std.wasm.ExternalKind.global));
            try leb.writeUleb128(binary_writer, @intFromEnum(global_import.valtype));
            try binary_writer.writeByte(@intFromBool(global_import.mutable));
        }

        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .import,
            @intCast(binary_bytes.items.len - header_offset - header_size),
            @intCast(total_imports_len),
        );
        section_index += 1;
    }

    // Function section
    if (wasm.functions.count() != 0) {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);
        for (wasm.functions.values()) |function| {
            try leb.writeUleb128(binary_writer, function.func.type_index);
        }

        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .function,
            @intCast(binary_bytes.items.len - header_offset - header_size),
            @intCast(wasm.functions.count()),
        );
        section_index += 1;
    }

    // Table section
    if (wasm.tables.items.len > 0) {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);

        for (wasm.tables.items) |table| {
            try leb.writeUleb128(binary_writer, std.wasm.reftype(table.reftype));
            try emitLimits(binary_writer, table.limits);
        }

        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .table,
            @intCast(binary_bytes.items.len - header_offset - header_size),
            @intCast(wasm.tables.items.len),
        );
        section_index += 1;
    }

    // Memory section
    if (!import_memory) {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);

        try emitLimits(binary_writer, wasm.memories.limits);
        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .memory,
            @intCast(binary_bytes.items.len - header_offset - header_size),
            1, // wasm currently only supports 1 linear memory segment
        );
        section_index += 1;
    }

    // Global section (used to emit stack pointer)
    if (wasm.output_globals.items.len > 0) {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);

        for (wasm.output_globals.items) |global| {
            try binary_writer.writeByte(std.wasm.valtype(global.global_type.valtype));
            try binary_writer.writeByte(@intFromBool(global.global_type.mutable));
            try emitInit(binary_writer, global.init);
        }

        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .global,
            @intCast(binary_bytes.items.len - header_offset - header_size),
            @intCast(wasm.output_globals.items.len),
        );
        section_index += 1;
    }

    // Export section
    if (wasm.exports.items.len != 0 or export_memory) {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);

        for (wasm.exports.items) |exp| {
            const name = exp.name.slice(wasm);
            try leb.writeUleb128(binary_writer, @as(u32, @intCast(name.len)));
            try binary_writer.writeAll(name);
            try leb.writeUleb128(binary_writer, @intFromEnum(exp.kind));
            try leb.writeUleb128(binary_writer, exp.index);
        }

        if (export_memory) {
            try leb.writeUleb128(binary_writer, @as(u32, @intCast("memory".len)));
            try binary_writer.writeAll("memory");
            try binary_writer.writeByte(std.wasm.externalKind(.memory));
            try leb.writeUleb128(binary_writer, @as(u32, 0));
        }

        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .@"export",
            @intCast(binary_bytes.items.len - header_offset - header_size),
            @intCast(wasm.exports.items.len + @intFromBool(export_memory)),
        );
        section_index += 1;
    }

    if (wasm.entry) |entry_index| {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);
        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .start,
            @intCast(binary_bytes.items.len - header_offset - header_size),
            entry_index,
        );
    }

    // element section (function table)
    if (wasm.function_table.count() > 0) {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);

        const table_loc = wasm.globals.get(wasm.preloaded_strings.__indirect_function_table).?;
        const table_sym = wasm.finalSymbolByLoc(table_loc);

        const flags: u32 = if (table_sym.index == 0) 0x0 else 0x02; // passive with implicit 0-index table or set table index manually
        try leb.writeUleb128(binary_writer, flags);
        if (flags == 0x02) {
            try leb.writeUleb128(binary_writer, table_sym.index);
        }
        try emitInit(binary_writer, .{ .i32_const = 1 }); // We start at index 1, so unresolved function pointers are invalid
        if (flags == 0x02) {
            try leb.writeUleb128(binary_writer, @as(u8, 0)); // represents funcref
        }
        try leb.writeUleb128(binary_writer, @as(u32, @intCast(wasm.function_table.count())));
        var symbol_it = wasm.function_table.keyIterator();
        while (symbol_it.next()) |symbol_loc_ptr| {
            const sym = wasm.finalSymbolByLoc(symbol_loc_ptr.*);
            assert(sym.flags.alive);
            assert(sym.index < wasm.functions.count() + wasm.imported_functions_count);
            try leb.writeUleb128(binary_writer, sym.index);
        }

        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .element,
            @intCast(binary_bytes.items.len - header_offset - header_size),
            1,
        );
        section_index += 1;
    }

    // When the shared-memory option is enabled, we *must* emit the 'data count' section.
    if (f.data_segment_groups.items.len > 0 and shared_memory) {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);
        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .data_count,
            @intCast(binary_bytes.items.len - header_offset - header_size),
            @intCast(f.data_segment_groups.items.len),
        );
    }

    // Code section.
    if (f.functions.count() != 0) {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);
        const start_offset = binary_bytes.items.len - 5; // minus 5 so start offset is 5 to include entry count

        for (f.functions.keys()) |resolution| switch (resolution.unpack()) {
            .unresolved => unreachable,
            .__wasm_apply_global_tls_relocs => @panic("TODO lower __wasm_apply_global_tls_relocs"),
            .__wasm_call_ctors => @panic("TODO lower __wasm_call_ctors"),
            .__wasm_init_memory => @panic("TODO lower __wasm_init_memory "),
            .__wasm_init_tls => @panic("TODO lower __wasm_init_tls "),
            .object_function => |i| {
                _ = i;
                _ = start_offset;
                @panic("TODO lower object function code and apply relocations");
                //try leb.writeUleb128(binary_writer, atom.code.len);
                //try binary_bytes.appendSlice(gpa, atom.code.slice(wasm));
            },
            .nav => |i| {
                _ = i;
                _ = start_offset;
                @panic("TODO lower nav code and apply relocations");
                //try leb.writeUleb128(binary_writer, atom.code.len);
                //try binary_bytes.appendSlice(gpa, atom.code.slice(wasm));
            },
        };

        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .code,
            @intCast(binary_bytes.items.len - header_offset - header_size),
            @intCast(wasm.functions.count()),
        );
        code_section_index = section_index;
        section_index += 1;
    }

    // Data section.
    if (f.data_segment_groups.items.len != 0) {
        const header_offset = try reserveVecSectionHeader(gpa, binary_bytes);

        var group_index: u32 = 0;
        var offset: u32 = undefined;
        for (segment_indexes, segment_offsets) |segment_index, segment_offset| {
            const segment = segment_index.ptr(wasm);
            if (segment.size == 0) continue;
            if (!import_memory and isBss(wasm, segment.name)) {
                // It counted for virtual memory but it does not go into the binary.
                continue;
            }
            if (segment_offset == 0) {
                const group_size = f.data_segment_groups.items[group_index];
                group_index += 1;
                offset = 0;

                const flags: Object.DataSegmentFlags = if (segment.flags.is_passive) .passive else .active;
                try leb.writeUleb128(binary_writer, @intFromEnum(flags));
                // when a segment is passive, it's initialized during runtime.
                if (flags != .passive) {
                    try emitInit(binary_writer, .{ .i32_const = @as(i32, @bitCast(segment_offset)) });
                }
                try leb.writeUleb128(binary_writer, group_size);
            }

            try binary_bytes.appendNTimes(gpa, 0, segment_offset - offset);
            offset = segment_offset;
            try binary_bytes.appendSlice(gpa, segment.payload.slice(wasm));
            offset += segment.payload.len;
            if (true) @panic("TODO apply data segment relocations");
        }
        assert(group_index == f.data_segment_groups.items.len);

        try writeVecSectionHeader(
            binary_bytes.items,
            header_offset,
            .data,
            @intCast(binary_bytes.items.len - header_offset - header_size),
            group_index,
        );
        data_section_index = section_index;
        section_index += 1;
    }

    if (is_obj) {
        @panic("TODO emit link section for object file and apply relocations");
        //var symbol_table = std.AutoArrayHashMap(SymbolLoc, u32).init(arena);
        //try wasm.emitLinkSection(binary_bytes, &symbol_table);
        //if (code_section_index) |code_index| {
        //    try wasm.emitCodeRelocations(binary_bytes, code_index, symbol_table);
        //}
        //if (data_section_index) |data_index| {
        //    if (wasm.data_segments.count() > 0)
        //        try wasm.emitDataRelocations(binary_bytes, data_index, symbol_table);
        //}
    } else if (comp.config.debug_format != .strip) {
        try wasm.emitNameSection(binary_bytes, arena);
    }

    if (comp.config.debug_format != .strip) {
        // The build id must be computed on the main sections only,
        // so we have to do it now, before the debug sections.
        switch (wasm.base.build_id) {
            .none => {},
            .fast => {
                var id: [16]u8 = undefined;
                std.crypto.hash.sha3.TurboShake128(null).hash(binary_bytes.items, &id, .{});
                var uuid: [36]u8 = undefined;
                _ = try std.fmt.bufPrint(&uuid, "{s}-{s}-{s}-{s}-{s}", .{
                    std.fmt.fmtSliceHexLower(id[0..4]),
                    std.fmt.fmtSliceHexLower(id[4..6]),
                    std.fmt.fmtSliceHexLower(id[6..8]),
                    std.fmt.fmtSliceHexLower(id[8..10]),
                    std.fmt.fmtSliceHexLower(id[10..]),
                });
                try emitBuildIdSection(binary_bytes, &uuid);
            },
            .hexstring => |hs| {
                var buffer: [32 * 2]u8 = undefined;
                const str = std.fmt.bufPrint(&buffer, "{s}", .{
                    std.fmt.fmtSliceHexLower(hs.toSlice()),
                }) catch unreachable;
                try emitBuildIdSection(binary_bytes, str);
            },
            else => |mode| {
                var err = try diags.addErrorWithNotes(0);
                try err.addMsg("build-id '{s}' is not supported for WebAssembly", .{@tagName(mode)});
            },
        }

        var debug_bytes = std.ArrayList(u8).init(gpa);
        defer debug_bytes.deinit();

        try emitProducerSection(binary_bytes);
        if (!target.cpu.features.isEmpty())
            try emitFeaturesSection(binary_bytes, target.cpu.features);
    }

    // Finally, write the entire binary into the file.
    const file = wasm.base.file.?;
    try file.pwriteAll(binary_bytes.items, 0);
    try file.setEndPos(binary_bytes.items.len);
}

fn emitNameSection(wasm: *Wasm, binary_bytes: *std.ArrayListUnmanaged(u8), arena: Allocator) !void {
    const comp = wasm.base.comp;
    const gpa = comp.gpa;
    const import_memory = comp.config.import_memory;

    // Deduplicate symbols that point to the same function.
    var funcs: std.AutoArrayHashMapUnmanaged(u32, String) = .empty;
    try funcs.ensureUnusedCapacityPrecise(arena, wasm.functions.count() + wasm.function_imports.items.len);

    const NamedIndex = struct {
        index: u32,
        name: String,
    };

    var globals: std.MultiArrayList(NamedIndex) = .empty;
    try globals.ensureTotalCapacityPrecise(arena, wasm.output_globals.items.len + wasm.global_imports.items.len);

    var segments: std.MultiArrayList(NamedIndex) = .empty;
    try segments.ensureTotalCapacityPrecise(arena, wasm.data_segments.count());

    for (wasm.resolved_symbols.keys()) |sym_loc| {
        const symbol = wasm.finalSymbolByLoc(sym_loc).*;
        if (!symbol.flags.alive) continue;
        const name = wasm.finalSymbolByLoc(sym_loc).name;
        switch (symbol.tag) {
            .function => {
                const index = if (symbol.flags.undefined)
                    @intFromEnum(symbol.pointee.function_import)
                else
                    wasm.function_imports.items.len + @intFromEnum(symbol.pointee.function);
                const gop = funcs.getOrPutAssumeCapacity(index);
                if (gop.found_existing) {
                    assert(gop.value_ptr.* == name);
                } else {
                    gop.value_ptr.* = name;
                }
            },
            .global => {
                globals.appendAssumeCapacity(.{
                    .index = if (symbol.flags.undefined)
                        @intFromEnum(symbol.pointee.global_import)
                    else
                        @intFromEnum(symbol.pointee.global),
                    .name = name,
                });
            },
            else => {},
        }
    }

    for (wasm.data_segments.keys(), 0..) |key, index| {
        // bss section is not emitted when this condition holds true, so we also
        // do not output a name for it.
        if (!import_memory and mem.eql(u8, key, ".bss")) continue;
        segments.appendAssumeCapacity(.{ .index = @intCast(index), .name = key });
    }

    const Sort = struct {
        indexes: []const u32,
        pub fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
            return ctx.indexes[lhs] < ctx.indexes[rhs];
        }
    };
    funcs.entries.sortUnstable(@as(Sort, .{ .indexes = funcs.keys() }));
    globals.sortUnstable(@as(Sort, .{ .indexes = globals.items(.index) }));
    // Data segments are already ordered.

    const header_offset = try reserveCustomSectionHeader(gpa, binary_bytes);
    const writer = binary_bytes.writer();
    try leb.writeUleb128(writer, @as(u32, @intCast("name".len)));
    try writer.writeAll("name");

    try emitNameSubsection(wasm, binary_bytes, .function, funcs.keys(), funcs.values());
    try emitNameSubsection(wasm, binary_bytes, .global, globals.items(.index), globals.items(.name));
    try emitNameSubsection(wasm, binary_bytes, .data_segment, segments.items(.index), segments.items(.name));

    try writeCustomSectionHeader(
        binary_bytes.items,
        header_offset,
        @as(u32, @intCast(binary_bytes.items.len - header_offset - 6)),
    );
}

fn writeCustomSectionHeader(buffer: []u8, offset: u32, size: u32) !void {
    var buf: [1 + 5]u8 = undefined;
    buf[0] = 0; // 0 = 'custom' section
    leb.writeUnsignedFixed(5, buf[1..6], size);
    buffer[offset..][0..buf.len].* = buf;
}

fn reserveCustomSectionHeader(gpa: Allocator, bytes: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!u32 {
    // unlike regular section, we don't emit the count
    const header_size = 1 + 5;
    try bytes.appendNTimes(gpa, 0, header_size);
    return @intCast(bytes.items.len - header_size);
}

fn emitNameSubsection(
    wasm: *const Wasm,
    binary_bytes: *std.ArrayListUnmanaged(u8),
    section_id: std.wasm.NameSubsection,
    indexes: []const u32,
    names: []const String,
) !void {
    assert(indexes.len == names.len);
    const gpa = wasm.base.comp.gpa;
    // We must emit subsection size, so first write to a temporary list
    var section_list: std.ArrayListUnmanaged(u8) = .empty;
    defer section_list.deinit(gpa);
    const sub_writer = section_list.writer(gpa);

    try leb.writeUleb128(sub_writer, @as(u32, @intCast(names.len)));
    for (indexes, names) |index, name_index| {
        const name = name_index.slice(wasm);
        log.debug("emit symbol '{s}' type({s})", .{ name, @tagName(section_id) });
        try leb.writeUleb128(sub_writer, index);
        try leb.writeUleb128(sub_writer, @as(u32, @intCast(name.len)));
        try sub_writer.writeAll(name);
    }

    // From now, write to the actual writer
    const writer = binary_bytes.writer(gpa);
    try leb.writeUleb128(writer, @intFromEnum(section_id));
    try leb.writeUleb128(writer, @as(u32, @intCast(section_list.items.len)));
    try binary_bytes.appendSlice(gpa, section_list.items);
}

fn emitFeaturesSection(
    gpa: Allocator,
    binary_bytes: *std.ArrayListUnmanaged(u8),
    features: []const Wasm.Feature,
) !void {
    const header_offset = try reserveCustomSectionHeader(gpa, binary_bytes);

    const writer = binary_bytes.writer();
    const target_features = "target_features";
    try leb.writeUleb128(writer, @as(u32, @intCast(target_features.len)));
    try writer.writeAll(target_features);

    try leb.writeUleb128(writer, @as(u32, @intCast(features.len)));
    for (features) |feature| {
        assert(feature.prefix != .invalid);
        try leb.writeUleb128(writer, @tagName(feature.prefix)[0]);
        const name = @tagName(feature.tag);
        try leb.writeUleb128(writer, @as(u32, name.len));
        try writer.writeAll(name);
    }

    try writeCustomSectionHeader(
        binary_bytes.items,
        header_offset,
        @as(u32, @intCast(binary_bytes.items.len - header_offset - 6)),
    );
}

fn emitBuildIdSection(gpa: Allocator, binary_bytes: *std.ArrayListUnmanaged(u8), build_id: []const u8) !void {
    const header_offset = try reserveCustomSectionHeader(gpa, binary_bytes);

    const writer = binary_bytes.writer();
    const hdr_build_id = "build_id";
    try leb.writeUleb128(writer, @as(u32, @intCast(hdr_build_id.len)));
    try writer.writeAll(hdr_build_id);

    try leb.writeUleb128(writer, @as(u32, 1));
    try leb.writeUleb128(writer, @as(u32, @intCast(build_id.len)));
    try writer.writeAll(build_id);

    try writeCustomSectionHeader(
        binary_bytes.items,
        header_offset,
        @as(u32, @intCast(binary_bytes.items.len - header_offset - 6)),
    );
}

fn emitProducerSection(gpa: Allocator, binary_bytes: *std.ArrayListUnmanaged(u8)) !void {
    const header_offset = try reserveCustomSectionHeader(gpa, binary_bytes);

    const writer = binary_bytes.writer();
    const producers = "producers";
    try leb.writeUleb128(writer, @as(u32, @intCast(producers.len)));
    try writer.writeAll(producers);

    try leb.writeUleb128(writer, @as(u32, 2)); // 2 fields: Language + processed-by

    // language field
    {
        const language = "language";
        try leb.writeUleb128(writer, @as(u32, @intCast(language.len)));
        try writer.writeAll(language);

        // field_value_count (TODO: Parse object files for producer sections to detect their language)
        try leb.writeUleb128(writer, @as(u32, 1));

        // versioned name
        {
            try leb.writeUleb128(writer, @as(u32, 3)); // len of "Zig"
            try writer.writeAll("Zig");

            try leb.writeUleb128(writer, @as(u32, @intCast(build_options.version.len)));
            try writer.writeAll(build_options.version);
        }
    }

    // processed-by field
    {
        const processed_by = "processed-by";
        try leb.writeUleb128(writer, @as(u32, @intCast(processed_by.len)));
        try writer.writeAll(processed_by);

        // field_value_count (TODO: Parse object files for producer sections to detect other used tools)
        try leb.writeUleb128(writer, @as(u32, 1));

        // versioned name
        {
            try leb.writeUleb128(writer, @as(u32, 3)); // len of "Zig"
            try writer.writeAll("Zig");

            try leb.writeUleb128(writer, @as(u32, @intCast(build_options.version.len)));
            try writer.writeAll(build_options.version);
        }
    }

    try writeCustomSectionHeader(
        binary_bytes.items,
        header_offset,
        @as(u32, @intCast(binary_bytes.items.len - header_offset - 6)),
    );
}

///// For each relocatable section, emits a custom "relocation.<section_name>" section
//fn emitCodeRelocations(
//    wasm: *Wasm,
//    binary_bytes: *std.ArrayListUnmanaged(u8),
//    section_index: u32,
//    symbol_table: std.AutoArrayHashMapUnmanaged(SymbolLoc, u32),
//) !void {
//    const comp = wasm.base.comp;
//    const gpa = comp.gpa;
//    const code_index = wasm.code_section_index.unwrap() orelse return;
//    const writer = binary_bytes.writer();
//    const header_offset = try reserveCustomSectionHeader(gpa, binary_bytes);
//
//    // write custom section information
//    const name = "reloc.CODE";
//    try leb.writeUleb128(writer, @as(u32, @intCast(name.len)));
//    try writer.writeAll(name);
//    try leb.writeUleb128(writer, section_index);
//    const reloc_start = binary_bytes.items.len;
//
//    var count: u32 = 0;
//    var atom: *Atom = wasm.atoms.get(code_index).?.ptr(wasm);
//    // for each atom, we calculate the uleb size and append that
//    var size_offset: u32 = 5; // account for code section size leb128
//    while (true) {
//        size_offset += getUleb128Size(atom.code.len);
//        for (atom.relocSlice(wasm)) |relocation| {
//            count += 1;
//            const sym_loc: SymbolLoc = .{ .file = atom.file, .index = @enumFromInt(relocation.index) };
//            const symbol_index = symbol_table.get(sym_loc).?;
//            try leb.writeUleb128(writer, @intFromEnum(relocation.tag));
//            const offset = atom.offset + relocation.offset + size_offset;
//            try leb.writeUleb128(writer, offset);
//            try leb.writeUleb128(writer, symbol_index);
//            if (relocation.tag.addendIsPresent()) {
//                try leb.writeIleb128(writer, relocation.addend);
//            }
//            log.debug("Emit relocation: {}", .{relocation});
//        }
//        if (atom.prev == .none) break;
//        atom = atom.prev.ptr(wasm);
//    }
//    if (count == 0) return;
//    var buf: [5]u8 = undefined;
//    leb.writeUnsignedFixed(5, &buf, count);
//    try binary_bytes.insertSlice(reloc_start, &buf);
//    const size: u32 = @intCast(binary_bytes.items.len - header_offset - 6);
//    try writeCustomSectionHeader(binary_bytes.items, header_offset, size);
//}

//fn emitDataRelocations(
//    wasm: *Wasm,
//    binary_bytes: *std.ArrayList(u8),
//    section_index: u32,
//    symbol_table: std.AutoArrayHashMap(SymbolLoc, u32),
//) !void {
//    const comp = wasm.base.comp;
//    const gpa = comp.gpa;
//    const writer = binary_bytes.writer();
//    const header_offset = try reserveCustomSectionHeader(gpa, binary_bytes);
//
//    // write custom section information
//    const name = "reloc.DATA";
//    try leb.writeUleb128(writer, @as(u32, @intCast(name.len)));
//    try writer.writeAll(name);
//    try leb.writeUleb128(writer, section_index);
//    const reloc_start = binary_bytes.items.len;
//
//    var count: u32 = 0;
//    // for each atom, we calculate the uleb size and append that
//    var size_offset: u32 = 5; // account for code section size leb128
//    for (wasm.data_segments.values()) |segment_index| {
//        var atom: *Atom = wasm.atoms.get(segment_index).?.ptr(wasm);
//        while (true) {
//            size_offset += getUleb128Size(atom.code.len);
//            for (atom.relocSlice(wasm)) |relocation| {
//                count += 1;
//                const sym_loc: SymbolLoc = .{ .file = atom.file, .index = @enumFromInt(relocation.index) };
//                const symbol_index = symbol_table.get(sym_loc).?;
//                try leb.writeUleb128(writer, @intFromEnum(relocation.tag));
//                const offset = atom.offset + relocation.offset + size_offset;
//                try leb.writeUleb128(writer, offset);
//                try leb.writeUleb128(writer, symbol_index);
//                if (relocation.tag.addendIsPresent()) {
//                    try leb.writeIleb128(writer, relocation.addend);
//                }
//                log.debug("Emit relocation: {}", .{relocation});
//            }
//            if (atom.prev == .none) break;
//            atom = atom.prev.ptr(wasm);
//        }
//    }
//    if (count == 0) return;
//
//    var buf: [5]u8 = undefined;
//    leb.writeUnsignedFixed(5, &buf, count);
//    try binary_bytes.insertSlice(reloc_start, &buf);
//    const size = @as(u32, @intCast(binary_bytes.items.len - header_offset - 6));
//    try writeCustomSectionHeader(binary_bytes.items, header_offset, size);
//}

/// Recursively mark alive everything referenced by the function.
fn markFunction(
    wasm: *Wasm,
    f: *Flush,
    name: String,
    import: *Wasm.FunctionImport,
    func_index: Wasm.ObjectFunctionImportIndex,
    allow_undefined: bool,
) error{OutOfMemory}!void {
    if (import.flags.alive) return;
    import.flags.alive = true;

    const comp = wasm.base.comp;
    const gpa = comp.gpa;
    const diags = &comp.link_diags;
    const rdynamic = comp.config.rdynamic;
    const is_obj = comp.config.output_mode == .Obj;

    try f.functions.ensureUnusedCapacity(gpa, 1);

    if (import.resolution == .unresolved) {
        if (name == wasm.preloaded_strings.__wasm_init_memory) {
            import.resolution = .__wasm_init_memory;
            f.functions.putAssumeCapacity(.__wasm_init_memory, {});
        } else if (name == wasm.preloaded_strings.__wasm_apply_global_tls_relocs) {
            import.resolution = .__wasm_apply_global_tls_relocs;
            f.functions.putAssumeCapacity(.__wasm_apply_global_tls_relocs, {});
        } else if (name == wasm.preloaded_strings.__wasm_call_ctors) {
            import.resolution = .__wasm_call_ctors;
            f.functions.putAssumeCapacity(.__wasm_call_ctors, {});
        } else if (name == wasm.preloaded_strings.__wasm_init_tls) {
            import.resolution = .__wasm_init_tls;
            f.functions.putAssumeCapacity(.__wasm_init_tls, {});
        } else if (!allow_undefined) {
            diags.addSrcError(import.source_location, "undefined function: {s}", .{name.slice(wasm)});
        } else {
            try f.function_imports.put(gpa, .fromObject(func_index), {});
        }
    } else {
        const gop = f.functions.getOrPutAssumeCapacity(import.resolution);

        if (!is_obj and import.flags.isExported(rdynamic))
            try f.function_exports.append(gpa, @intCast(gop.index));

        for (wasm.functionResolutionRelocSlice(import.resolution)) |reloc|
            try wasm.markReloc(reloc);
    }
}

/// Recursively mark alive everything referenced by the global.
fn markGlobal(
    wasm: *Wasm,
    f: *Flush,
    name: String,
    import: *Wasm.GlobalImport,
    global_index: Wasm.ObjectGlobalImportIndex,
    allow_undefined: bool,
) !void {
    if (import.flags.alive) return;
    import.flags.alive = true;

    const comp = wasm.base.comp;
    const gpa = comp.gpa;
    const diags = &comp.link_diags;
    const rdynamic = comp.config.rdynamic;
    const is_obj = comp.config.output_mode == .Obj;

    try f.globals.ensureUnusedCapacity(gpa, 1);

    if (import.resolution == .unresolved) {
        if (name == wasm.preloaded_strings.__heap_base) {
            import.resolution = .__heap_base;
            f.globals.putAssumeCapacity(.__heap_base, {});
        } else if (name == wasm.preloaded_strings.__heap_end) {
            import.resolution = .__heap_end;
            f.globals.putAssumeCapacity(.__heap_end, {});
        } else if (name == wasm.preloaded_strings.__stack_pointer) {
            import.resolution = .__stack_pointer;
            f.globals.putAssumeCapacity(.__stack_pointer, {});
        } else if (name == wasm.preloaded_strings.__tls_align) {
            import.resolution = .__tls_align;
            f.globals.putAssumeCapacity(.__tls_align, {});
        } else if (name == wasm.preloaded_strings.__tls_base) {
            import.resolution = .__tls_base;
            f.globals.putAssumeCapacity(.__tls_base, {});
        } else if (name == wasm.preloaded_strings.__tls_size) {
            import.resolution = .__tls_size;
            f.globals.putAssumeCapacity(.__tls_size, {});
        } else if (!allow_undefined) {
            diags.addSrcError(import.source_location, "undefined global: {s}", .{name.slice(wasm)});
        } else {
            try f.global_imports.put(gpa, .fromObject(global_index), {});
        }
    } else {
        const gop = f.globals.getOrPutAssumeCapacity(import.resolution);

        if (!is_obj and import.flags.isExported(rdynamic))
            try f.global_exports.append(gpa, @intCast(gop.index));

        for (wasm.globalResolutionRelocSlice(import.resolution)) |reloc|
            try wasm.markReloc(reloc);
    }
}

fn markTable(wasm: *Wasm, f: *Flush, name: String, import: *Wasm.TableImport, table_index: Wasm.ObjectTableImportIndex, allow_undefined: bool) !void {
    if (import.flags.alive) return;
    import.flags.alive = true;

    const comp = wasm.base.comp;
    const gpa = comp.gpa;
    const diags = &comp.link_diags;

    try f.tables.ensureUnusedCapacity(gpa, 1);

    if (import.resolution == .unresolved) {
        if (name == wasm.preloaded_strings.__indirect_function_table) {
            import.resolution = .__indirect_function_table;
            f.tables.putAssumeCapacity(.__indirect_function_table, {});
        } else if (!allow_undefined) {
            diags.addSrcError(import.source_location, "undefined table: {s}", .{name.slice(wasm)});
        } else {
            try f.table_imports.put(gpa, .fromObject(table_index), {});
        }
    } else {
        f.tables.putAssumeCapacity(import.resolution, {});
        // Tables have no relocations.
    }
}

fn globalResolutionRelocSlice(wasm: *Wasm, resolution: Wasm.GlobalImport.Resolution) ![]const Relocation {
    assert(resolution != .none);
    _ = wasm;
    @panic("TODO");
}

fn functionResolutionRelocSlice(wasm: *Wasm, resolution: Wasm.FunctionImport.Resolution) ![]const Relocation {
    assert(resolution != .none);
    _ = wasm;
    @panic("TODO");
}

fn isBss(wasm: *Wasm, name: String) bool {
    const s = name.slice(wasm);
    return mem.eql(u8, s, ".bss") or mem.startsWith(u8, s, ".bss.");
}

fn splitSegmentName(name: []const u8) struct { []const u8, []const u8 } {
    const start = @intFromBool(name.len >= 1 and name[0] == '.');
    const pivot = mem.indexOfScalarPos(u8, name, start, '.') orelse 0;
    return .{ name[0..pivot], name[pivot..] };
}

fn wantSegmentMerge(wasm: *const Wasm, a_index: Wasm.DataSegment.Index, b_index: Wasm.DataSegment.Index) bool {
    const a = a_index.ptr(wasm);
    const b = b_index.ptr(wasm);
    if (a.flags.tls and b.flags.tls) return true;
    if (a.flags.tls != b.flags.tls) return false;
    if (a.flags.is_passive != b.flags.is_passive) return false;
    if (a.name == b.name) return true;
    const a_prefix, _ = splitSegmentName(a.name.slice(wasm));
    const b_prefix, _ = splitSegmentName(b.name.slice(wasm));
    return a_prefix.len > 0 and mem.eql(u8, a_prefix, b_prefix);
}

fn reserveVecSectionHeader(gpa: Allocator, bytes: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!u32 {
    // section id + fixed leb contents size + fixed leb vector length
    const header_size = 1 + 5 + 5;
    try bytes.appendNTimes(gpa, 0, header_size);
    return @intCast(bytes.items.len - header_size);
}

fn writeVecSectionHeader(buffer: []u8, offset: u32, section: std.wasm.Section, size: u32, items: u32) !void {
    var buf: [1 + 5 + 5]u8 = undefined;
    buf[0] = @intFromEnum(section);
    leb.writeUnsignedFixed(5, buf[1..6], size);
    leb.writeUnsignedFixed(5, buf[6..], items);
    buffer[offset..][0..buf.len].* = buf;
}

fn emitLimits(writer: anytype, limits: std.wasm.Limits) !void {
    try writer.writeByte(limits.flags);
    try leb.writeUleb128(writer, limits.min);
    if (limits.flags.has_max) try leb.writeUleb128(writer, limits.max);
}

fn emitMemoryImport(wasm: *Wasm, writer: anytype, memory_import: *const Wasm.MemoryImport) error{OutOfMemory}!void {
    const module_name = memory_import.module_name.slice(wasm);
    try leb.writeUleb128(writer, @as(u32, @intCast(module_name.len)));
    try writer.writeAll(module_name);

    const name = memory_import.name.slice(wasm);
    try leb.writeUleb128(writer, @as(u32, @intCast(name.len)));
    try writer.writeAll(name);

    try writer.writeByte(@intFromEnum(std.wasm.ExternalKind.memory));
    try emitLimits(writer, memory_import.limits());
}

pub fn emitInit(writer: anytype, init_expr: std.wasm.InitExpression) !void {
    switch (init_expr) {
        .i32_const => |val| {
            try writer.writeByte(@intFromEnum(std.wasm.Opcode.i32_const));
            try leb.writeIleb128(writer, val);
        },
        .i64_const => |val| {
            try writer.writeByte(@intFromEnum(std.wasm.Opcode.i64_const));
            try leb.writeIleb128(writer, val);
        },
        .f32_const => |val| {
            try writer.writeByte(@intFromEnum(std.wasm.Opcode.f32_const));
            try writer.writeInt(u32, @bitCast(val), .little);
        },
        .f64_const => |val| {
            try writer.writeByte(@intFromEnum(std.wasm.Opcode.f64_const));
            try writer.writeInt(u64, @bitCast(val), .little);
        },
        .global_get => |val| {
            try writer.writeByte(@intFromEnum(std.wasm.Opcode.global_get));
            try leb.writeUleb128(writer, val);
        },
    }
    try writer.writeByte(@intFromEnum(std.wasm.Opcode.end));
}

//fn emitLinkSection(
//    wasm: *Wasm,
//    binary_bytes: *std.ArrayListUnmanaged(u8),
//    symbol_table: *std.AutoArrayHashMapUnmanaged(SymbolLoc, u32),
//) !void {
//    const gpa = wasm.base.comp.gpa;
//    const offset = try reserveCustomSectionHeader(gpa, binary_bytes);
//    const writer = binary_bytes.writer();
//    // emit "linking" custom section name
//    const section_name = "linking";
//    try leb.writeUleb128(writer, section_name.len);
//    try writer.writeAll(section_name);
//
//    // meta data version, which is currently '2'
//    try leb.writeUleb128(writer, @as(u32, 2));
//
//    // For each subsection type (found in Subsection) we can emit a section.
//    // Currently, we only support emitting segment info and the symbol table.
//    try wasm.emitSymbolTable(binary_bytes, symbol_table);
//    try wasm.emitSegmentInfo(binary_bytes);
//
//    const size: u32 = @intCast(binary_bytes.items.len - offset - 6);
//    try writeCustomSectionHeader(binary_bytes.items, offset, size);
//}

fn emitSegmentInfo(wasm: *Wasm, binary_bytes: *std.ArrayList(u8)) !void {
    const writer = binary_bytes.writer();
    try leb.writeUleb128(writer, @intFromEnum(Wasm.SubsectionType.segment_info));
    const segment_offset = binary_bytes.items.len;

    try leb.writeUleb128(writer, @as(u32, @intCast(wasm.segment_info.count())));
    for (wasm.segment_info.values()) |segment_info| {
        log.debug("Emit segment: {s} align({d}) flags({b})", .{
            segment_info.name,
            segment_info.alignment,
            segment_info.flags,
        });
        try leb.writeUleb128(writer, @as(u32, @intCast(segment_info.name.len)));
        try writer.writeAll(segment_info.name);
        try leb.writeUleb128(writer, segment_info.alignment.toLog2Units());
        try leb.writeUleb128(writer, segment_info.flags);
    }

    var buf: [5]u8 = undefined;
    leb.writeUnsignedFixed(5, &buf, @as(u32, @intCast(binary_bytes.items.len - segment_offset)));
    try binary_bytes.insertSlice(segment_offset, &buf);
}

//fn emitSymbolTable(
//    wasm: *Wasm,
//    binary_bytes: *std.ArrayListUnmanaged(u8),
//    symbol_table: *std.AutoArrayHashMapUnmanaged(SymbolLoc, u32),
//) !void {
//    const gpa = wasm.base.comp.gpa;
//    const writer = binary_bytes.writer(gpa);
//
//    try leb.writeUleb128(writer, @intFromEnum(SubsectionType.symbol_table));
//    const table_offset = binary_bytes.items.len;
//
//    var symbol_count: u32 = 0;
//    for (wasm.resolved_symbols.keys()) |sym_loc| {
//        const symbol = wasm.finalSymbolByLoc(sym_loc).*;
//        if (symbol.tag == .dead) continue;
//        try symbol_table.putNoClobber(gpa, sym_loc, symbol_count);
//        symbol_count += 1;
//        log.debug("emit symbol: {}", .{symbol});
//        try leb.writeUleb128(writer, @intFromEnum(symbol.tag));
//        try leb.writeUleb128(writer, symbol.flags);
//
//        const sym_name = wasm.symbolLocName(sym_loc);
//        switch (symbol.tag) {
//            .data => {
//                try leb.writeUleb128(writer, @as(u32, @intCast(sym_name.len)));
//                try writer.writeAll(sym_name);
//
//                if (!symbol.flags.undefined) {
//                    try leb.writeUleb128(writer, @intFromEnum(symbol.pointee.data_out));
//                    const atom_index = wasm.symbol_atom.get(sym_loc).?;
//                    const atom = wasm.getAtom(atom_index);
//                    try leb.writeUleb128(writer, @as(u32, atom.offset));
//                    try leb.writeUleb128(writer, @as(u32, atom.code.len));
//                }
//            },
//            .section => {
//                try leb.writeUleb128(writer, @intFromEnum(symbol.pointee.section));
//            },
//            .function => {
//                if (symbol.flags.undefined) {
//                    try leb.writeUleb128(writer, @intFromEnum(symbol.pointee.function_import));
//                } else {
//                    try leb.writeUleb128(writer, @intFromEnum(symbol.pointee.function));
//                    try leb.writeUleb128(writer, @as(u32, @intCast(sym_name.len)));
//                    try writer.writeAll(sym_name);
//                }
//            },
//            .global => {
//                if (symbol.flags.undefined) {
//                    try leb.writeUleb128(writer, @intFromEnum(symbol.pointee.global_import));
//                } else {
//                    try leb.writeUleb128(writer, @intFromEnum(symbol.pointee.global));
//                    try leb.writeUleb128(writer, @as(u32, @intCast(sym_name.len)));
//                    try writer.writeAll(sym_name);
//                }
//            },
//            .table => {
//                if (symbol.flags.undefined) {
//                    try leb.writeUleb128(writer, @intFromEnum(symbol.pointee.table_import));
//                } else {
//                    try leb.writeUleb128(writer, @intFromEnum(symbol.pointee.table));
//                    try leb.writeUleb128(writer, @as(u32, @intCast(sym_name.len)));
//                    try writer.writeAll(sym_name);
//                }
//            },
//            .event => unreachable,
//            .dead => unreachable,
//            .uninitialized => unreachable,
//        }
//    }
//
//    var buf: [10]u8 = undefined;
//    leb.writeUnsignedFixed(5, buf[0..5], @intCast(binary_bytes.items.len - table_offset + 5));
//    leb.writeUnsignedFixed(5, buf[5..], symbol_count);
//    try binary_bytes.insertSlice(table_offset, &buf);
//}

///// Resolves the relocations within the atom, writing the new value
///// at the calculated offset.
//fn resolveAtomRelocs(wasm: *const Wasm, atom: *Atom) void {
//    const symbol_name = wasm.symbolLocName(atom.symbolLoc());
//    log.debug("resolving {d} relocs in atom '{s}'", .{ atom.relocs.len, symbol_name });
//
//    for (atom.relocSlice(wasm)) |reloc| {
//        const value = atomRelocationValue(wasm, atom, reloc);
//        log.debug("relocating '{s}' referenced in '{s}' offset=0x{x:0>8} value={d}", .{
//            wasm.symbolLocName(.{
//                .file = atom.file,
//                .index = @enumFromInt(reloc.index),
//            }),
//            symbol_name,
//            reloc.offset,
//            value,
//        });
//
//        switch (reloc.tag) {
//            .TABLE_INDEX_I32,
//            .FUNCTION_OFFSET_I32,
//            .GLOBAL_INDEX_I32,
//            .MEMORY_ADDR_I32,
//            .SECTION_OFFSET_I32,
//            => mem.writeInt(u32, atom.code.slice(wasm)[reloc.offset - atom.original_offset ..][0..4], @as(u32, @truncate(value)), .little),
//
//            .TABLE_INDEX_I64,
//            .MEMORY_ADDR_I64,
//            => mem.writeInt(u64, atom.code.slice(wasm)[reloc.offset - atom.original_offset ..][0..8], value, .little),
//
//            .GLOBAL_INDEX_LEB,
//            .EVENT_INDEX_LEB,
//            .FUNCTION_INDEX_LEB,
//            .MEMORY_ADDR_LEB,
//            .MEMORY_ADDR_SLEB,
//            .TABLE_INDEX_SLEB,
//            .TABLE_NUMBER_LEB,
//            .TYPE_INDEX_LEB,
//            .MEMORY_ADDR_TLS_SLEB,
//            => leb.writeUnsignedFixed(5, atom.code.slice(wasm)[reloc.offset - atom.original_offset ..][0..5], @as(u32, @truncate(value))),
//
//            .MEMORY_ADDR_LEB64,
//            .MEMORY_ADDR_SLEB64,
//            .TABLE_INDEX_SLEB64,
//            .MEMORY_ADDR_TLS_SLEB64,
//            => leb.writeUnsignedFixed(10, atom.code.slice(wasm)[reloc.offset - atom.original_offset ..][0..10], value),
//        }
//    }
//}

///// From a given `relocation` will return the new value to be written.
///// All values will be represented as a `u64` as all values can fit within it.
///// The final value must be casted to the correct size.
//fn atomRelocationValue(wasm: *const Wasm, atom: *const Atom, relocation: *const Relocation) u64 {
//    if (relocation.tag == .TYPE_INDEX_LEB) {
//        // Eagerly resolved when parsing the object file.
//        if (true) @panic("TODO the eager resolve when parsing");
//        return relocation.index;
//    }
//    const target_loc = wasm.symbolLocFinalLoc(.{
//        .file = atom.file,
//        .index = @enumFromInt(relocation.index),
//    });
//    const symbol = wasm.finalSymbolByLoc(target_loc);
//    if (symbol.tag != .section and !symbol.flags.alive) {
//        const val = atom.tombstone(wasm) orelse relocation.addend;
//        return @bitCast(val);
//    }
//    return switch (relocation.tag) {
//        .FUNCTION_INDEX_LEB => if (symbol.flags.undefined)
//            @intFromEnum(symbol.pointee.function_import)
//        else
//            @intFromEnum(symbol.pointee.function) + wasm.function_imports.items.len,
//        .TABLE_NUMBER_LEB => if (symbol.flags.undefined)
//            @intFromEnum(symbol.pointee.table_import)
//        else
//            @intFromEnum(symbol.pointee.table) + wasm.table_imports.items.len,
//        .TABLE_INDEX_I32,
//        .TABLE_INDEX_I64,
//        .TABLE_INDEX_SLEB,
//        .TABLE_INDEX_SLEB64,
//        => wasm.function_table.get(.{ .file = atom.file, .index = @enumFromInt(relocation.index) }) orelse 0,
//
//        .TYPE_INDEX_LEB => unreachable, // handled above
//        .GLOBAL_INDEX_I32, .GLOBAL_INDEX_LEB => if (symbol.flags.undefined)
//            @intFromEnum(symbol.pointee.global_import)
//        else
//            @intFromEnum(symbol.pointee.global) + wasm.global_imports.items.len,
//
//        .MEMORY_ADDR_I32,
//        .MEMORY_ADDR_I64,
//        .MEMORY_ADDR_LEB,
//        .MEMORY_ADDR_LEB64,
//        .MEMORY_ADDR_SLEB,
//        .MEMORY_ADDR_SLEB64,
//        => {
//            assert(symbol.tag == .data);
//            if (symbol.flags.undefined) return 0;
//            const va: i33 = symbol.virtual_address;
//            return @intCast(va + relocation.addend);
//        },
//        .EVENT_INDEX_LEB => @panic("TODO: expose this as an error, events are unsupported"),
//        .SECTION_OFFSET_I32 => {
//            const target_atom_index = wasm.symbol_atom.get(target_loc).?;
//            const target_atom = wasm.getAtom(target_atom_index);
//            const rel_value: i33 = target_atom.offset;
//            return @intCast(rel_value + relocation.addend);
//        },
//        .FUNCTION_OFFSET_I32 => {
//            if (symbol.flags.undefined) {
//                const val = atom.tombstone(wasm) orelse relocation.addend;
//                return @bitCast(val);
//            }
//            const target_atom_index = wasm.symbol_atom.get(target_loc).?;
//            const target_atom = wasm.getAtom(target_atom_index);
//            const rel_value: i33 = target_atom.offset;
//            return @intCast(rel_value + relocation.addend);
//        },
//        .MEMORY_ADDR_TLS_SLEB,
//        .MEMORY_ADDR_TLS_SLEB64,
//        => {
//            const va: i33 = symbol.virtual_address;
//            return @intCast(va + relocation.addend);
//        },
//    };
//}

///// For a given `Atom` returns whether it has a tombstone value or not.
///// This defines whether we want a specific value when a section is dead.
//fn tombstone(atom: Atom, wasm: *const Wasm) ?i64 {
//    const atom_name = wasm.finalSymbolByLoc(atom.symbolLoc()).name;
//    if (atom_name == wasm.custom_sections.@".debug_ranges".name or
//        atom_name == wasm.custom_sections.@".debug_loc".name)
//    {
//        return -2;
//    } else if (mem.startsWith(u8, atom_name.slice(wasm), ".debug_")) {
//        return -1;
//    } else {
//        return null;
//    }
//}

fn getUleb128Size(uint_value: anytype) u32 {
    const T = @TypeOf(uint_value);
    const U = if (@typeInfo(T).int.bits < 8) u8 else T;
    var value = @as(U, @intCast(uint_value));

    var size: u32 = 0;
    while (value != 0) : (size += 1) {
        value >>= 7;
    }
    return size;
}
