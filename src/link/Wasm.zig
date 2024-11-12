const Wasm = @This();
const Archive = @import("Wasm/Archive.zig");
const Object = @import("Wasm/Object.zig");
const Flush = @import("Wasm/Flush.zig");
const ZigObject = @import("Wasm/ZigObject.zig");

const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const build_options = @import("build_options");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Cache = std.Build.Cache;
const Path = Cache.Path;
const assert = std.debug.assert;
const fs = std.fs;
const leb = std.leb;
const log = std.log.scoped(.link);
const mem = std.mem;

const Air = @import("../Air.zig");
const CodeGen = @import("../arch/wasm/CodeGen.zig");
const Compilation = @import("../Compilation.zig");
const Dwarf = @import("Dwarf.zig");
const InternPool = @import("../InternPool.zig");
const Liveness = @import("../Liveness.zig");
const LlvmObject = @import("../codegen/llvm.zig").Object;
const Zcu = @import("../Zcu.zig");
const codegen = @import("../codegen.zig");
const dev = @import("../dev.zig");
const link = @import("../link.zig");
const lldMain = @import("../main.zig").lldMain;
const trace = @import("../tracy.zig").trace;
const wasi_libc = @import("../wasi_libc.zig");
const Value = @import("../Value.zig");

base: link.File,
/// Null-terminated strings, indexes have type String and string_table provides
/// lookup.
///
/// There are a couple of sites that add things here without adding
/// corresponding string_table entries. For such cases, when implementing
/// serialization/deserialization, they should be adjusted to prefix that data
/// with a null byte so that deserialization does not attempt to create
/// string_table entries for them. Alternately those sites could be moved to
/// use a different byte array for this purpose.
string_bytes: std.ArrayListUnmanaged(u8),
/// Omitted when serializing linker state.
string_table: String.Table,
/// Symbol name of the entry function to export
entry_name: OptionalString,
/// When true, will allow undefined symbols
import_symbols: bool,
/// Set of *global* symbol names to export to the host environment.
export_symbol_names: []const []const u8,
/// When defined, sets the start of the data section.
global_base: ?u64,
/// When defined, sets the initial memory size of the memory.
initial_memory: ?u64,
/// When defined, sets the maximum memory size of the memory.
max_memory: ?u64,
/// When true, will import the function table from the host environment.
import_table: bool,
/// When true, will export the function table to the host environment.
export_table: bool,
/// Output name of the file
name: []const u8,
/// If this is not null, an object file is created by LLVM and linked with LLD afterwards.
llvm_object: ?LlvmObject.Ptr = null,
/// List of relocatable files to be linked into the final binary.
objects: std.ArrayListUnmanaged(Object) = .{},

func_types: std.AutoArrayHashMapUnmanaged(FunctionType, void) = .empty,
/// Provides a mapping of both imports and provided functions to symbol name.
/// Local functions may be unnamed.
object_function_imports: std.AutoArrayHashMapUnmanaged(String, FunctionImport) = .empty,
/// All functions for all objects.
object_functions: std.ArrayListUnmanaged(Function) = .empty,

/// Provides a mapping of both imports and provided globals to symbol name.
/// Local globals may be unnamed.
object_global_imports: std.AutoArrayHashMapUnmanaged(String, GlobalImport) = .empty,
/// All globals for all objects.
object_globals: std.ArrayListUnmanaged(Global) = .empty,

/// All table imports for all objects.
object_table_imports: std.ArrayListUnmanaged(TableImport) = .empty,
/// All parsed table sections for all objects.
object_tables: std.ArrayListUnmanaged(Table) = .empty,

/// All memory imports for all objects.
object_memory_imports: std.ArrayListUnmanaged(MemoryImport) = .empty,
/// All parsed memory sections for all objects.
object_memories: std.ArrayListUnmanaged(std.wasm.Memory) = .empty,

/// List of initialization functions. These must be called in order of priority
/// by the (synthetic) __wasm_call_ctors function.
object_init_funcs: std.ArrayListUnmanaged(InitFunc) = .empty,
/// All relocations from all objects concatenated. `relocs_start` marks the end
/// point of object relocations and start point of Zcu relocations.
relocations: std.MultiArrayList(Relocation) = .empty,

/// Non-synthetic section that can essentially be mem-cpy'd into place after performing relocations.
object_data_segments: std.ArrayListUnmanaged(DataSegment) = .empty,
/// Non-synthetic section that can essentially be mem-cpy'd into place after performing relocations.
object_custom_segments: std.AutoArrayHashMapUnmanaged(InputSectionIndex, CustomSegment) = .empty,

/// All comdat information for all objects.
object_comdats: std.ArrayListUnmanaged(Comdat) = .empty,
/// A table that maps the relocations to be performed where the key represents
/// the section (across all objects) that the slice of relocations applies to.
object_relocations_table: std.AutoArrayHashMapUnmanaged(InputSectionIndex, Relocation.Slice) = .empty,
/// Incremented across all objects in order to enable calculation of `InputSectionIndex` values.
object_total_sections: u32 = 0,
/// All comdat symbols from all objects concatenated.
object_comdat_symbols: std.MultiArrayList(Comdat.Symbol) = .empty,

/// When importing objects from the host environment, a name must be supplied.
/// LLVM uses "env" by default when none is given. This would be a good default for Zig
/// to support existing code.
/// TODO: Allow setting this through a flag?
host_name: String,

/// Memory section
memories: std.wasm.Memory = .{ .limits = .{
    .min = 0,
    .max = undefined,
    .flags = .{ .has_max = false, .is_shared = false },
} },

/// `--verbose-link` output.
/// Initialized on creation, appended to as inputs are added, printed during `flush`.
/// String data is allocated into Compilation arena.
dump_argv_list: std.ArrayListUnmanaged([]const u8),

preloaded_strings: PreloadedStrings,

navs: std.AutoArrayHashMapUnmanaged(InternPool.Nav.Index, Nav) = .empty,
nav_exports: std.AutoArrayHashMapUnmanaged(NavExport, Zcu.Export.Index) = .empty,
uav_exports: std.AutoArrayHashMapUnmanaged(UavExport, Zcu.Export.Index) = .empty,
imports: std.AutoArrayHashMapUnmanaged(InternPool.Nav.Index, void) = .empty,

/// During the pre-link phase, the `function_imports` field of Wasm contains
/// all the functions that remain undefined after processing all the linker
/// inputs. These could be resolved to functions defined by ZigObject, or if no
/// such function is present, they will be emitted into the import section.
///
/// This integer tracks the end position of that `function_imports` field after
/// the pre-link phase but before any ZigObject functions are generated. This
/// way, that same map can be used to store additional function imports needed
/// by the ZigObject, while retaining the ability to restore state back to end
/// of the pre-link phase.
function_import_start: u32,
/// Same as `function_import_start` but for global imports.
global_import_start: u32,
/// Same as `function_import_start` but for output globals.
global_start: u32,
/// Same as `function_import_start` but for relocations
relocs_start: u32,

dwarf: ?Dwarf = null,
debug_sections: DebugSections,

flush_buffer: Flush = .init,

/// The first N indexes correspond to input objects (`objects`) array.
/// After that, the indexes correspond to the `source_locations` array,
/// representing a location in a Zig source file that can be pinpointed
/// precisely via AST node and token.
pub const SourceLocation = enum(u32) {
    /// From the Zig compilation unit but no precise source location.
    zig_object_nofile = std.math.maxInt(u32) - 1,
    none = std.math.maxInt(u32),
    _,
};

/// The lower bits of this ABI-match the flags here:
/// https://github.com/WebAssembly/tool-conventions/blob/df8d737539eb8a8f446ba5eab9dc670c40dfb81e/Linking.md#symbol-table-subsection
/// The upper bits are used for nefarious purposes.
pub const SymbolFlags = packed struct(u32) {
    binding: Binding = .strong,
    /// Indicating that this is a hidden symbol. Hidden symbols are not to be
    /// exported when performing the final link, but may be linked to other
    /// modules.
    visibility_hidden: bool = false,
    padding0: u1 = 0,
    /// For non-data symbols, this must match whether the symbol is an import
    /// or is defined; for data symbols, determines whether a segment is
    /// specified.
    undefined: bool = false,
    /// The symbol is intended to be exported from the wasm module to the host
    /// environment. This differs from the visibility flags in that it affects
    /// static linking.
    exported: bool = false,
    /// The symbol uses an explicit symbol name, rather than reusing the name
    /// from a wasm import. This allows it to remap imports from foreign
    /// WebAssembly modules into local symbols with different names.
    explicit_name: bool = false,
    /// The symbol is intended to be included in the linker output, regardless
    /// of whether it is used by the program. Same meaning as `retain`.
    no_strip: bool = false,
    /// The symbol resides in thread local storage.
    tls: bool = false,
    /// The symbol represents an absolute address. This means its offset is
    /// relative to the start of the wasm memory as opposed to being relative
    /// to a data segment.
    absolute: bool = false,

    // Above here matches the tooling conventions ABI.

    padding1: u7 = 0,
    /// Zig-specific. Dead things are allowed to be garbage collected.
    alive: bool = false,
    /// Zig-specific. Segments only. Signals that the segment contains only
    /// null terminated strings allowing the linker to perform merging.
    strings: bool = false,
    /// Zig-specific. This symbol comes from an object that must be included in
    /// the final link.
    must_link: bool = false,
    /// Zig-specific. Data segments only.
    is_passive: bool = false,
    /// Zig-specific. Data segments only.
    alignment: Alignment = .none,
    /// Zig-specific. Globals only.
    global_type: Global.Type = .zero,

    pub const Binding = enum(u2) {
        strong = 0,
        /// Indicating that this is a weak symbol. When linking multiple modules
        /// defining the same symbol, all weak definitions are discarded if any
        /// strong definitions exist; then if multiple weak definitions exist all
        /// but one (unspecified) are discarded; and finally it is an error if more
        /// than one definition remains.
        weak = 1,
        /// Indicating that this is a local symbol. Local symbols are not to be
        /// exported, or linked to other modules/sections. The names of all
        /// non-local symbols must be unique, but the names of local symbols
        /// are not considered for uniqueness. A local function or global
        /// symbol cannot reference an import.
        local = 2,
    };

    pub fn initZigSpecific(flags: *SymbolFlags, must_link: bool, no_strip: bool) void {
        flags.alive = false;
        flags.strings = false;
        flags.must_link = must_link;
        flags.no_strip = no_strip;
        flags.alignment = .none;
        flags.global_type = .zero;
        flags.is_passive = false;
    }

    pub fn isIncluded(flags: SymbolFlags, is_dynamic: bool) bool {
        return flags.exported or
            (is_dynamic and !flags.visibility_hidden) or
            (flags.no_strip and flags.must_link);
    }

    pub fn isExported(flags: SymbolFlags, is_dynamic: bool) bool {
        if (flags.undefined or flags.binding == .local) return false;
        if (is_dynamic and !flags.visibility_hidden) return true;
        return flags.exported;
    }

    pub fn requiresImport(flags: SymbolFlags, is_data: bool) bool {
        if (is_data) return false;
        if (!flags.undefined) return false;
        if (flags.binding == .weak) return false;
        return true;
    }

    /// Returns the name as how it will be output into the final object
    /// file or binary. When `merge` is true, this will return the
    /// short name. i.e. ".rodata". When false, it returns the entire name instead.
    pub fn outputName(flags: SymbolFlags, name: []const u8, merge: bool) []const u8 {
        if (flags.tls) return ".tdata";
        if (!merge) return name;
        if (mem.startsWith(u8, name, ".rodata.")) return ".rodata";
        if (mem.startsWith(u8, name, ".text.")) return ".text";
        if (mem.startsWith(u8, name, ".data.")) return ".data";
        if (mem.startsWith(u8, name, ".bss.")) return ".bss";
        return name;
    }

    /// Masks off the Zig-specific stuff.
    pub fn toAbiInteger(flags: SymbolFlags) u32 {
        var copy = flags;
        copy.initZigSpecific(false, false);
        return @bitCast(copy);
    }
};

pub const Nav = extern struct {
    code: DataSegment.Payload,
    relocs: Relocation.Slice,

    pub const Code = DataSegment.Payload;

    /// Index into `navs`.
    /// Note that swapRemove is sometimes performed on `navs`.
    pub const Index = enum(u32) {
        _,

        pub fn key(i: @This(), zo: *const ZigObject) *InternPool.Nav.Index {
            return &zo.navs.keys()[@intFromEnum(i)];
        }

        pub fn value(i: @This(), zo: *const ZigObject) *Nav {
            return &zo.navs.values()[@intFromEnum(i)];
        }
    };
};

pub const NavExport = extern struct {
    name: String,
    nav_index: InternPool.Nav.Index,
};

pub const UavExport = extern struct {
    name: String,
    uav_index: InternPool.Index,
};

const DebugSections = struct {
    abbrev: DebugSection,
    info: DebugSection,
    line: DebugSection,
    loc: DebugSection,
    pubnames: DebugSection,
    pubtypes: DebugSection,
    ranges: DebugSection,
    str: DebugSection,
};

const DebugSection = struct {};

pub const FunctionImport = extern struct {
    flags: SymbolFlags,
    module_name: String,
    source_location: SourceLocation,
    resolution: Resolution,
    type: FunctionType.Index,

    /// Represents a synthetic function, a function from an object, or a
    /// function from the Zcu.
    pub const Resolution = enum(u32) {
        unresolved,
        __wasm_apply_global_tls_relocs,
        __wasm_call_ctors,
        __wasm_init_memory,
        __wasm_init_tls,
        // Next, index into `object_functions`.
        // Next, index into `navs`.
        _,
    };

    /// Index into `object_function_imports`.
    pub const Index = enum(u32) {
        _,
    };
};

pub const Function = extern struct {
    flags: SymbolFlags,
    /// `none` if this function has no symbol describing it.
    name: OptionalString,
    type_index: FunctionType.Index,
    code: Code,
    /// The offset within the section where the data starts.
    offset: u32,
    section_index: InputSectionIndex,
    source_location: SourceLocation,

    pub const Code = DataSegment.Payload;
};

pub const GlobalImport = extern struct {
    flags: SymbolFlags,
    module_name: String,
    source_location: SourceLocation,
    resolution: Resolution,

    /// Represents a synthetic global, or a global from an object.
    pub const Resolution = enum(u32) {
        unresolved,
        __heap_base,
        __heap_end,
        __stack_pointer,
        __tls_align,
        __tls_base,
        __tls_size,
        // Next, index into `object_globals`.
        // Next, index into `navs`.
        _,
    };
};

pub const Global = extern struct {
    /// `none` if this function has no symbol describing it.
    name: OptionalString,
    flags: SymbolFlags,
    expr: Expr,

    pub const Type = packed struct(u4) {
        valtype: Valtype,
        mutable: bool,

        pub const zero: Type = @bitCast(@as(u4, 0));
    };

    pub const Valtype = enum(u3) {
        i32,
        i64,
        f32,
        f64,
        v128,

        pub fn from(v: std.wasm.Valtype) Valtype {
            return switch (v) {
                .i32 => .i32,
                .i64 => .i64,
                .f32 => .f32,
                .f64 => .f64,
                .v128 => .v128,
            };
        }

        pub fn to(v: Valtype) std.wasm.Valtype {
            return switch (v) {
                .i32 => .i32,
                .i64 => .i64,
                .f32 => .f32,
                .f64 => .f64,
                .v128 => .v128,
            };
        }
    };
};

pub const TableImport = extern struct {
    flags: SymbolFlags,
    module_name: String,
    source_location: SourceLocation,
    resolution: Resolution,

    /// Represents a synthetic table, or a table from an object.
    pub const Resolution = enum(u32) {
        unresolved,
        __indirect_function_table,
        // Next, index into `object_tables`.
        _,
    };
};

pub const Table = extern struct {
    module_name: String,
    name: String,
    flags: SymbolFlags,
    limits_min: u32,
    limits_max: u32,
    limits_has_max: bool,
    limits_is_shared: bool,
    reftype: std.wasm.RefType,
    padding: [1]u8 = .{0},
};

/// Uniquely identifies a section across all objects. Each Object has a section_start field.
/// By subtracting that value from this one, the Object section index is obtained.
pub const InputSectionIndex = enum(u32) {
    _,
};

/// Index into `object_function_imports`.
pub const ObjectFunctionImportIndex = enum(u32) {
    _,

    pub fn ptr(index: ObjectFunctionImportIndex, wasm: *const Wasm) *FunctionImport {
        return &wasm.object_function_imports.items[@intFromEnum(index)];
    }
};

/// Index into `object_global_imports`.
pub const ObjectGlobalImportIndex = enum(u32) {
    _,
};

/// Index into `object_table_imports`.
pub const ObjectTableImportIndex = enum(u32) {
    _,
};

/// Index into `object_tables`.
pub const ObjectTableIndex = enum(u32) {
    _,

    pub fn ptr(index: ObjectTableIndex, wasm: *const Wasm) *Table {
        return &wasm.object_tables.items[@intFromEnum(index)];
    }
};

/// Index into `global_imports`.
pub const GlobalImportIndex = enum(u32) {
    _,
};

/// Index into `object_globals`.
pub const ObjectGlobalIndex = enum(u32) {
    _,
};

/// Index into `object_functions`.
pub const ObjectFunctionIndex = enum(u32) {
    _,

    pub fn ptr(index: ObjectFunctionIndex, wasm: *const Wasm) *Function {
        return &wasm.object_functions.items[@intFromEnum(index)];
    }

    pub fn toOptional(i: ObjectFunctionIndex) OptionalObjectFunctionIndex {
        const result: OptionalObjectFunctionIndex = @enumFromInt(@intFromEnum(i));
        assert(result != .none);
        return result;
    }
};

/// Index into `object_functions`, or null.
pub const OptionalObjectFunctionIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(i: OptionalObjectFunctionIndex) ?ObjectFunctionIndex {
        if (i == .none) return null;
        return @enumFromInt(@intFromEnum(i));
    }
};

pub const DataSegment = extern struct {
    /// `none` if no symbol describes it.
    name: OptionalString,
    flags: SymbolFlags,
    payload: Payload,
    /// From the data segment start to the first byte of payload.
    segment_offset: u32,
    section_index: InputSectionIndex,

    pub const Payload = extern struct {
        /// Points into string_bytes. No corresponding string_table entry.
        off: u32,
        /// The size in bytes of the data representing the segment within the section.
        len: u32,

        fn slice(p: DataSegment.Payload, wasm: *const Wasm) []const u8 {
            return wasm.string_bytes.items[p.off..][0..p.len];
        }
    };

    /// Index into `object_data_segments`.
    pub const Index = enum(u32) {
        _,
    };
};

pub const CustomSegment = extern struct {
    payload: Payload,
    flags: SymbolFlags,
    section_name: String,

    pub const Payload = DataSegment.Payload;
};

/// An index into string_bytes where a wasm expression is found.
pub const Expr = enum(u32) {
    _,
};

pub const FunctionType = extern struct {
    params: ValtypeList,
    returns: ValtypeList,

    /// Index into func_types
    pub const Index = enum(u32) {
        _,

        pub fn ptr(i: FunctionType.Index, wasm: *const Wasm) *FunctionType {
            return &wasm.func_types.keys()[@intFromEnum(i)];
        }
    };

    pub const format = @compileError("can't format without *Wasm reference");

    pub fn eql(a: FunctionType, b: FunctionType) bool {
        return a.params == b.params and a.returns == b.returns;
    }
};

/// Represents a function entry, holding the index to its type
pub const Func = extern struct {
    type_index: FunctionType.Index,
};

/// Type reflection is used on the field names to autopopulate each field
/// during initialization.
const PreloadedStrings = struct {
    __heap_base: String,
    __heap_end: String,
    __indirect_function_table: String,
    __linear_memory: String,
    __stack_pointer: String,
    __tls_align: String,
    __tls_base: String,
    __tls_size: String,
    __wasm_apply_global_tls_relocs: String,
    __wasm_call_ctors: String,
    __wasm_init_memory: String,
    __wasm_init_memory_flag: String,
    __wasm_init_tls: String,
    __zig_err_name_table: String,
    __zig_err_names: String,
    __zig_errors_len: String,
    _initialize: String,
    _start: String,
    memory: String,
};

/// Index into string_bytes
pub const String = enum(u32) {
    _,

    const Table = std.HashMapUnmanaged(String, void, TableContext, std.hash_map.default_max_load_percentage);

    const TableContext = struct {
        bytes: []const u8,

        pub fn eql(_: @This(), a: String, b: String) bool {
            return a == b;
        }

        pub fn hash(ctx: @This(), key: String) u64 {
            return std.hash_map.hashString(mem.sliceTo(ctx.bytes[@intFromEnum(key)..], 0));
        }
    };

    const TableIndexAdapter = struct {
        bytes: []const u8,

        pub fn eql(ctx: @This(), a: []const u8, b: String) bool {
            return mem.eql(u8, a, mem.sliceTo(ctx.bytes[@intFromEnum(b)..], 0));
        }

        pub fn hash(_: @This(), adapted_key: []const u8) u64 {
            assert(mem.indexOfScalar(u8, adapted_key, 0) == null);
            return std.hash_map.hashString(adapted_key);
        }
    };

    pub fn slice(index: String, wasm: *const Wasm) [:0]const u8 {
        const start_slice = wasm.string_bytes.items[@intFromEnum(index)..];
        return start_slice[0..mem.indexOfScalar(u8, start_slice, 0).? :0];
    }

    pub fn toOptional(i: String) OptionalString {
        const result: OptionalString = @enumFromInt(@intFromEnum(i));
        assert(result != .none);
        return result;
    }
};

pub const OptionalString = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(i: OptionalString) ?String {
        if (i == .none) return null;
        return @enumFromInt(@intFromEnum(i));
    }

    pub fn slice(index: OptionalString, wasm: *const Wasm) ?[:0]const u8 {
        return (index.unwrap() orelse return null).slice(wasm);
    }
};

/// Stored identically to `String`. The bytes are reinterpreted as
/// `std.wasm.Valtype` elements.
pub const ValtypeList = enum(u32) {
    _,

    pub fn fromString(s: String) ValtypeList {
        return @enumFromInt(@intFromEnum(s));
    }

    pub fn slice(index: ValtypeList, wasm: *const Wasm) []const std.wasm.Valtype {
        return @bitCast(String.slice(@enumFromInt(@intFromEnum(index)), wasm));
    }
};

/// 0. Index into `object_function_imports`.
/// 1. Index into `imports`.
pub const FunctionImportId = enum(u32) {
    _,
};

/// 0. Index into `object_global_imports`.
/// 1. Index into `imports`.
pub const GlobalImportId = enum(u32) {
    _,
};

pub const Relocation = struct {
    tag: Tag,
    /// Offset of the value to rewrite relative to the relevant section's contents.
    /// When `offset` is zero, its position is immediately after the id and size of the section.
    offset: u32,
    pointee: Pointee,
    /// Populated only for `MEMORY_ADDR_*`, `FUNCTION_OFFSET_I32` and `SECTION_OFFSET_I32`.
    addend: i32,

    pub const Pointee = union {
        symbol_name: String,
        type_index: FunctionType.Index,
        section: InputSectionIndex,
    };

    pub const Slice = extern struct {
        /// Index into `relocations`.
        off: u32,
        len: u32,

        pub fn slice(s: Slice, wasm: *const Wasm) []Relocation {
            return wasm.relocations.items[s.off..][0..s.len];
        }
    };

    pub const Tag = enum(u8) {
        /// Uses `symbol_name`.
        FUNCTION_INDEX_LEB = 0,
        TABLE_INDEX_SLEB = 1,
        TABLE_INDEX_I32 = 2,
        MEMORY_ADDR_LEB = 3,
        MEMORY_ADDR_SLEB = 4,
        MEMORY_ADDR_I32 = 5,
        /// Uses `type_index`.
        TYPE_INDEX_LEB = 6,
        /// Uses `symbol_name`.
        GLOBAL_INDEX_LEB = 7,
        FUNCTION_OFFSET_I32 = 8,
        SECTION_OFFSET_I32 = 9,
        TAG_INDEX_LEB = 10,
        MEMORY_ADDR_REL_SLEB = 11,
        TABLE_INDEX_REL_SLEB = 12,
        /// Uses `symbol_name`.
        GLOBAL_INDEX_I32 = 13,
        MEMORY_ADDR_LEB64 = 14,
        MEMORY_ADDR_SLEB64 = 15,
        MEMORY_ADDR_I64 = 16,
        MEMORY_ADDR_REL_SLEB64 = 17,
        TABLE_INDEX_SLEB64 = 18,
        TABLE_INDEX_I64 = 19,
        TABLE_NUMBER_LEB = 20,
        MEMORY_ADDR_TLS_SLEB = 21,
        FUNCTION_OFFSET_I64 = 22,
        MEMORY_ADDR_LOCREL_I32 = 23,
        TABLE_INDEX_REL_SLEB64 = 24,
        MEMORY_ADDR_TLS_SLEB64 = 25,
        /// Uses `symbol_name`.
        FUNCTION_INDEX_I32 = 26,
    };
};

pub const MemoryImport = extern struct {
    module_name: String,
    name: String,
    limits_min: u32,
    limits_max: u32,
    limits_has_max: bool,
    limits_is_shared: bool,
    padding: [2]u8 = .{ 0, 0 },
};

pub const Alignment = @import("../InternPool.zig").Alignment;

pub const InitFunc = extern struct {
    priority: u32,
    function_index: ObjectFunctionIndex,

    fn lessThan(ctx: void, lhs: InitFunc, rhs: InitFunc) bool {
        _ = ctx;
        if (lhs.priority == rhs.priority) {
            return @intFromEnum(lhs.function_index) < @intFromEnum(rhs.function_index);
        } else {
            return lhs.priority < rhs.priority;
        }
    }
};

pub const Comdat = struct {
    name: String,
    /// Must be zero, no flags are currently defined by the tool-convention.
    flags: u32,
    symbols: Comdat.Symbol.Slice,

    pub const Symbol = struct {
        kind: Comdat.Symbol.Type,
        /// Index of the data segment/function/global/event/table within a WASM module.
        /// The object must not be an import.
        index: u32,

        pub const Slice = struct {
            /// Index into Wasm object_comdat_symbols
            off: u32,
            len: u32,
        };

        pub const Type = enum(u8) {
            data = 0,
            function = 1,
            global = 2,
            event = 3,
            table = 4,
            section = 5,
        };
    };
};

/// Stored as a u8 so it can reuse the string table mechanism.
pub const Feature = packed struct(u8) {
    prefix: Prefix,
    /// Type of the feature, must be unique in the sequence of features.
    tag: Tag,

    /// Stored identically to `String`. The bytes are reinterpreted as `Feature`
    /// elements. Elements must be sorted before string-interning.
    pub const Set = enum(u32) {
        _,

        pub fn fromString(s: String) Set {
            return @enumFromInt(@intFromEnum(s));
        }
    };

    /// Unlike `std.Target.wasm.Feature` this also contains linker-features such as shared-mem.
    /// Additionally the name uses convention matching the wasm binary format.
    pub const Tag = enum(u6) {
        atomics,
        @"bulk-memory",
        @"exception-handling",
        @"extended-const",
        @"half-precision",
        multimemory,
        multivalue,
        @"mutable-globals",
        @"nontrapping-fptoint",
        @"reference-types",
        @"relaxed-simd",
        @"sign-ext",
        simd128,
        @"tail-call",
        @"shared-mem",

        pub fn fromCpuFeature(feature: std.Target.wasm.Feature) Tag {
            return @enumFromInt(@intFromEnum(feature));
        }

        pub const format = @compileError("use @tagName instead");
    };

    /// Provides information about the usage of the feature.
    pub const Prefix = enum(u2) {
        /// Reserved so that a 0-byte Feature is invalid and therefore can be a sentinel.
        invalid,
        /// '0x2b': Object uses this feature, and the link fails if feature is
        /// not in the allowed set.
        @"+",
        /// '0x2d': Object does not use this feature, and the link fails if
        /// this feature is in the allowed set.
        @"-",
        /// '0x3d': Object uses this feature, and the link fails if this
        /// feature is not in the allowed set, or if any object does not use
        /// this feature.
        @"=",
    };

    pub fn format(feature: Feature, comptime fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = opt;
        _ = fmt;
        try writer.print("{s} {s}", .{ @tagName(feature.prefix), @tagName(feature.tag) });
    }

    pub fn lessThan(_: void, a: Feature, b: Feature) bool {
        assert(a != b);
        const a_int: u8 = @bitCast(a);
        const b_int: u8 = @bitCast(b);
        return a_int < b_int;
    }
};

pub fn open(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*Wasm {
    // TODO: restore saved linker state, don't truncate the file, and
    // participate in incremental compilation.
    return createEmpty(arena, comp, emit, options);
}

pub fn createEmpty(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*Wasm {
    const gpa = comp.gpa;
    const target = comp.root_mod.resolved_target.result;
    assert(target.ofmt == .wasm);

    const use_lld = build_options.have_llvm and comp.config.use_lld;
    const use_llvm = comp.config.use_llvm;
    const output_mode = comp.config.output_mode;
    const wasi_exec_model = comp.config.wasi_exec_model;

    // If using LLD to link, this code should produce an object file so that it
    // can be passed to LLD.
    // If using LLVM to generate the object file for the zig compilation unit,
    // we need a place to put the object file so that it can be subsequently
    // handled.
    const zcu_object_sub_path = if (!use_lld and !use_llvm)
        null
    else
        try std.fmt.allocPrint(arena, "{s}.o", .{emit.sub_path});

    const wasm = try arena.create(Wasm);
    wasm.* = .{
        .base = .{
            .tag = .wasm,
            .comp = comp,
            .emit = emit,
            .zcu_object_sub_path = zcu_object_sub_path,
            // Garbage collection is so crucial to WebAssembly that we design
            // the linker around the assumption that it will be on in the vast
            // majority of cases, and therefore express "no garbage collection"
            // in terms of setting the no_strip and must_link flags on all
            // symbols.
            .gc_sections = options.gc_sections orelse (output_mode != .Obj),
            .print_gc_sections = options.print_gc_sections,
            .stack_size = options.stack_size orelse switch (target.os.tag) {
                .freestanding => 1 * 1024 * 1024, // 1 MiB
                else => 16 * 1024 * 1024, // 16 MiB
            },
            .allow_shlib_undefined = options.allow_shlib_undefined orelse false,
            .file = null,
            .disable_lld_caching = options.disable_lld_caching,
            .build_id = options.build_id,
        },
        .name = undefined,
        .string_table = .empty,
        .string_bytes = .empty,
        .import_table = options.import_table,
        .export_table = options.export_table,
        .import_symbols = options.import_symbols,
        .export_symbol_names = options.export_symbol_names,
        .global_base = options.global_base,
        .initial_memory = options.initial_memory,
        .max_memory = options.max_memory,

        .entry_name = undefined,
        .zig_object = null,
        .dump_argv_list = .empty,
        .host_name = undefined,
        .preloaded_strings = undefined,
    };
    if (use_llvm and comp.config.have_zcu) {
        wasm.llvm_object = try LlvmObject.create(arena, comp);
    }
    errdefer wasm.base.destroy();

    wasm.host_name = try wasm.internString("env");

    inline for (@typeInfo(PreloadedStrings).@"struct".fields) |field| {
        @field(wasm.preloaded_strings, field.name) = try wasm.internString(field.name);
    }

    wasm.entry_name = switch (options.entry) {
        .disabled => .none,
        .default => if (output_mode != .Exe) .none else defaultEntrySymbolName(&wasm.preloaded_strings, wasi_exec_model).toOptional(),
        .enabled => defaultEntrySymbolName(&wasm.preloaded_strings, wasi_exec_model).toOptional(),
        .named => |name| (try wasm.internString(name)).toOptional(),
    };

    if (use_lld and (use_llvm or !comp.config.have_zcu)) {
        // LLVM emits the object file (if any); LLD links it into the final product.
        return wasm;
    }

    // What path should this Wasm linker code output to?
    // If using LLD to link, this code should produce an object file so that it
    // can be passed to LLD.
    const sub_path = if (use_lld) zcu_object_sub_path.? else emit.sub_path;

    wasm.base.file = try emit.root_dir.handle.createFile(sub_path, .{
        .truncate = true,
        .read = true,
        .mode = if (fs.has_executable_bit)
            if (target.os.tag == .wasi and output_mode == .Exe)
                fs.File.default_mode | 0b001_000_000
            else
                fs.File.default_mode
        else
            0,
    });
    wasm.name = sub_path;

    if (comp.zcu) |zcu| {
        if (!use_llvm) {
            const zig_object = try arena.create(ZigObject);
            wasm.zig_object = zig_object;
            zig_object.* = .{
                .path = .{
                    .root_dir = std.Build.Cache.Directory.cwd(),
                    .sub_path = try std.fmt.allocPrint(gpa, "{s}.o", .{fs.path.stem(zcu.main_mod.root_src_path)}),
                },
                .stack_pointer_sym = undefined,
            };
        }
    }

    return wasm;
}

fn openParseObjectReportingFailure(wasm: *Wasm, path: Path) void {
    const diags = &wasm.base.comp.link_diags;
    const obj = link.openObject(path, false, false) catch |err| {
        switch (diags.failParse(path, "failed to open object: {s}", .{@errorName(err)})) {
            error.LinkFailure => return,
        }
    };
    wasm.parseObject(obj) catch |err| {
        switch (diags.failParse(path, "failed to parse object: {s}", .{@errorName(err)})) {
            error.LinkFailure => return,
        }
    };
}

fn parseObject(wasm: *Wasm, obj: link.Input.Object) !void {
    const gpa = wasm.base.comp.gpa;
    const gc_sections = wasm.base.gc_sections;

    defer obj.file.close();

    try wasm.objects.ensureUnusedCapacity(gpa, 1);
    const stat = try obj.file.stat();
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;

    const file_contents = try gpa.alloc(u8, size);
    defer gpa.free(file_contents);

    const n = try obj.file.preadAll(file_contents, 0);
    if (n != file_contents.len) return error.UnexpectedEndOfFile;

    var ss: Object.ScratchSpace = .{};
    defer ss.deinit(gpa);

    const object = try Object.parse(wasm, file_contents, obj.path, null, wasm.host_name, &ss, obj.must_link, gc_sections);
    wasm.objects.appendAssumeCapacity(object);
}

fn parseArchive(wasm: *Wasm, obj: link.Input.Object) !void {
    const gpa = wasm.base.comp.gpa;
    const gc_sections = wasm.base.gc_sections;

    defer obj.file.close();

    const stat = try obj.file.stat();
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;

    const file_contents = try gpa.alloc(u8, size);
    defer gpa.free(file_contents);

    const n = try obj.file.preadAll(file_contents, 0);
    if (n != file_contents.len) return error.UnexpectedEndOfFile;

    var archive = try Archive.parse(gpa, file_contents);
    defer archive.deinit(gpa);

    // In this case we must force link all embedded object files within the archive
    // We loop over all symbols, and then group them by offset as the offset
    // notates where the object file starts.
    var offsets = std.AutoArrayHashMap(u32, void).init(gpa);
    defer offsets.deinit();
    for (archive.toc.values()) |symbol_offsets| {
        for (symbol_offsets.items) |sym_offset| {
            try offsets.put(sym_offset, {});
        }
    }

    var ss: Object.ScratchSpace = .{};
    defer ss.deinit(gpa);

    try wasm.objects.ensureUnusedCapacity(gpa, offsets.count());
    for (offsets.keys()) |file_offset| {
        const contents = file_contents[file_offset..];
        const object = try archive.parseObject(wasm, contents, obj.path, wasm.host_name, &ss, obj.must_link, gc_sections);
        wasm.objects.appendAssumeCapacity(object);
    }
}

pub fn deinit(wasm: *Wasm) void {
    const gpa = wasm.base.comp.gpa;
    if (wasm.llvm_object) |llvm_object| llvm_object.deinit();

    wasm.navs.deinit(gpa);
    wasm.nav_exports.deinit(gpa);
    wasm.uav_exports.deinit(gpa);
    wasm.imports.deinit(gpa);

    wasm.flush_buffer.deinit(gpa);

    if (wasm.dwarf) |*dwarf| dwarf.deinit();

    wasm.objects.deinit(gpa);
    wasm.object_data_segments.deinit(gpa);
    wasm.object_relocatable_codes.deinit(gpa);
    wasm.object_custom_segments.deinit(gpa);
    wasm.object_function_imports.deinit(gpa);
    wasm.object_table_imports.deinit(gpa);
    wasm.object_memory_imports.deinit(gpa);
    wasm.object_global_imports.deinit(gpa);
    wasm.object_functions.deinit(gpa);
    wasm.object_tables.deinit(gpa);
    wasm.object_memories.deinit(gpa);
    wasm.object_globals.deinit(gpa);
    wasm.object_symbols.deinit(gpa);
    wasm.object_named_segments.deinit(gpa);
    wasm.object_init_funcs.deinit(gpa);
    wasm.object_comdats.deinit(gpa);
    wasm.object_relocations.deinit(gpa);
    wasm.object_relocations_table.deinit(gpa);
    wasm.object_comdat_symbols.deinit(gpa);

    wasm.atoms.deinit(gpa);

    wasm.synthetic_symbols.deinit(gpa);
    wasm.globals.deinit(gpa);
    wasm.undefs.deinit(gpa);
    wasm.discarded.deinit(gpa);
    wasm.segments.deinit(gpa);
    wasm.segment_info.deinit(gpa);

    wasm.function_imports.deinit(gpa);
    wasm.global_imports.deinit(gpa);
    wasm.func_types.deinit(gpa);
    wasm.functions.deinit(gpa);
    wasm.output_globals.deinit(gpa);
    wasm.exports.deinit(gpa);

    wasm.string_bytes.deinit(gpa);
    wasm.string_table.deinit(gpa);
    wasm.dump_argv_list.deinit(gpa);
}

pub fn updateFunc(wasm: *Wasm, pt: Zcu.PerThread, func_index: InternPool.Index, air: Air, liveness: Liveness) !void {
    if (build_options.skip_non_native and builtin.object_format != .wasm) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }
    if (wasm.llvm_object) |llvm_object| return llvm_object.updateFunc(pt, func_index, air, liveness);

    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const func = pt.zcu.funcInfo(func_index);
    const nav_index = func.owner_nav;

    const code_start: u32 = @intCast(wasm.string_bytes.items.len);
    const relocs_start: u32 = @intCast(wasm.relocations.items.len);
    wasm.string_bytes_lock.lock();

    const wasm_codegen = @import("../../arch/wasm/CodeGen.zig");
    dev.check(.wasm_backend);
    const result = try wasm_codegen.generate(
        &wasm.base,
        pt,
        zcu.navSrcLoc(nav_index),
        func_index,
        air,
        liveness,
        &wasm.string_bytes,
        .none,
    );

    const code_len: u32 = @intCast(wasm.string_bytes.items.len - code_start);
    const relocs_len: u32 = @intCast(wasm.relocations.items.len - relocs_start);
    wasm.string_bytes_lock.unlock();

    const code: Nav.Code = switch (result) {
        .ok => .{
            .off = code_start,
            .len = code_len,
        },
        .fail => |em| {
            try pt.zcu.failed_codegen.put(gpa, nav_index, em);
            return;
        },
    };

    const gop = try wasm.navs.getOrPut(gpa, nav_index);
    if (gop.found_existing) {
        @panic("TODO reuse these resources");
    } else {
        _ = wasm.imports.swapRemove(nav_index);
    }
    gop.value_ptr.* = .{
        .code = code,
        .relocs = .{
            .off = relocs_start,
            .len = relocs_len,
        },
    };
}

// Generate code for the "Nav", storing it in memory to be later written to
// the file on flush().
pub fn updateNav(wasm: *Wasm, pt: Zcu.PerThread, nav_index: InternPool.Nav.Index) !void {
    if (build_options.skip_non_native and builtin.object_format != .wasm) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }
    if (wasm.llvm_object) |llvm_object| return llvm_object.updateNav(pt, nav_index);
    const zcu = pt.zcu;
    const ip = &zcu.intern_pool;
    const nav = ip.getNav(nav_index);
    const gpa = wasm.base.comp.gpa;

    const nav_val = zcu.navValue(nav_index);
    const is_extern, const nav_init = switch (ip.indexToKey(nav_val.toIntern())) {
        .variable => |variable| .{ false, Value.fromInterned(variable.init) },
        .func => unreachable,
        .@"extern" => b: {
            assert(!ip.isFunctionType(nav.typeOf(ip)));
            break :b .{ true, nav_val };
        },
        else => .{ false, nav_val },
    };

    if (!nav_init.typeOf(zcu).hasRuntimeBits(zcu)) {
        _ = wasm.imports.swapRemove(nav_index);
        _ = wasm.navs.swapRemove(nav_index); // TODO reclaim resources
        return;
    }

    if (is_extern) {
        try wasm.imports.put(nav_index, {});
        _ = wasm.navs.swapRemove(nav_index); // TODO reclaim resources
        return;
    }

    const code_start: u32 = @intCast(wasm.string_bytes.items.len);
    const relocs_start: u32 = @intCast(wasm.relocations.items.len);
    wasm.string_bytes_lock.lock();

    const res = try codegen.generateSymbol(
        &wasm.base,
        pt,
        zcu.navSrcLoc(nav_index),
        nav_init,
        &wasm.string_bytes,
        .none,
    );

    const code_len: u32 = @intCast(wasm.string_bytes.items.len - code_start);
    const relocs_len: u32 = @intCast(wasm.relocations.items.len - relocs_start);
    wasm.string_bytes_lock.unlock();

    const code: Nav.Code = switch (res) {
        .ok => .{
            .off = code_start,
            .len = code_len,
        },
        .fail => |em| {
            try zcu.failed_codegen.put(gpa, nav_index, em);
            return;
        },
    };

    const gop = try wasm.navs.getOrPut(gpa, nav_index);
    if (gop.found_existing) {
        @panic("TODO reuse these resources");
    } else {
        _ = wasm.imports.swapRemove(nav_index);
    }
    gop.value_ptr.* = .{
        .code = code,
        .relocs = .{
            .off = relocs_start,
            .len = relocs_len,
        },
    };
}

pub fn updateNavLineNumber(wasm: *Wasm, pt: Zcu.PerThread, nav_index: InternPool.Nav.Index) !void {
    if (wasm.llvm_object != null) return;
    const ip = &pt.zcu.intern_pool;
    const nav = ip.getNav(nav_index);

    log.debug("updateNavLineNumber {}({d})", .{ nav.fqn.fmt(ip), nav_index });

    if (wasm.dwarf) |*dwarf| {
        try dwarf.updateNavLineNumber(pt.zcu, nav_index);
    }
}

pub fn deleteExport(
    wasm: *Wasm,
    exported: Zcu.Exported,
    name: InternPool.NullTerminatedString,
) void {
    if (wasm.llvm_object != null) return;

    const zcu = wasm.base.comp.zcu.?;
    const ip = &zcu.intern_pool;
    const export_name = try wasm.internString(name.toSlice(ip));
    switch (exported) {
        .nav => |nav_index| assert(wasm.nav_exports.swapRemove(.{ .nav_index = nav_index, .name = export_name })),
        .uav => |uav_index| assert(wasm.uav_exports.swapRemove(.{ .uav_index = uav_index, .name = export_name })),
    }
}

pub fn updateExports(
    wasm: *Wasm,
    pt: Zcu.PerThread,
    exported: Zcu.Exported,
    export_indices: []const u32,
) !void {
    if (build_options.skip_non_native and builtin.object_format != .wasm) {
        @panic("Attempted to compile for object format that was disabled by build configuration");
    }
    if (wasm.llvm_object) |llvm_object| return llvm_object.updateExports(pt, exported, export_indices);

    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    for (export_indices) |export_idx| {
        const exp = export_idx.ptr(zcu);
        const name = try wasm.internString(exp.opts.name.toSlice(ip));
        switch (exported) {
            .nav => |nav_index| wasm.nav_exports.put(gpa, .{ .nav_index = nav_index, .name = name }, export_idx),
            .uav => |uav_index| wasm.uav_exports.put(gpa, .{ .uav_index = uav_index, .name = name }, export_idx),
        }
    }
}

pub fn loadInput(wasm: *Wasm, input: link.Input) !void {
    const comp = wasm.base.comp;
    const gpa = comp.gpa;

    if (comp.verbose_link) {
        comp.mutex.lock(); // protect comp.arena
        defer comp.mutex.unlock();

        const argv = &wasm.dump_argv_list;
        switch (input) {
            .res => unreachable,
            .dso_exact => unreachable,
            .dso => unreachable,
            .object, .archive => |obj| try argv.append(gpa, try obj.path.toString(comp.arena)),
        }
    }

    switch (input) {
        .res => unreachable,
        .dso_exact => unreachable,
        .dso => unreachable,
        .object => |obj| try parseObject(wasm, obj),
        .archive => |obj| try parseArchive(wasm, obj),
    }
}

pub fn flush(wasm: *Wasm, arena: Allocator, tid: Zcu.PerThread.Id, prog_node: std.Progress.Node) link.File.FlushError!void {
    const comp = wasm.base.comp;
    const use_lld = build_options.have_llvm and comp.config.use_lld;

    if (use_lld) {
        return wasm.linkWithLLD(arena, tid, prog_node);
    }
    return wasm.flushModule(arena, tid, prog_node);
}

pub fn prelink(wasm: *Wasm, prog_node: std.Progress.Node) anyerror!void {
    const tracy = trace(@src());
    defer tracy.end();

    const sub_prog_node = prog_node.start("Wasm Prelink", 0);
    defer sub_prog_node.end();

    if (wasm.object_init_funcs.items.len > 0) {
        // Zig has no constructors so these are only for object file inputs.
        mem.sortUnstable(InitFunc, wasm.object_init_funcs.items, {}, InitFunc.lessThan);
        try wasm.initializeCallCtorsFunction();
    }

    if (wasm.zig_object) |zo| {
        zo.function_import_start = @intCast(wasm.function_imports.count());
        zo.global_import_start = @intCast(wasm.global_imports.count());
        zo.global_start = @intCast(wasm.output_globals.items.len);
        assert(wasm.output_globals.items.len == wasm.global_names.count());
    }
}

pub fn flushModule(wasm: *Wasm, arena: Allocator, tid: Zcu.PerThread.Id, prog_node: std.Progress.Node) anyerror!void {
    const comp = wasm.base.comp;
    const use_lld = build_options.have_llvm and comp.config.use_lld;

    if (wasm.llvm_object) |llvm_object| {
        try wasm.base.emitLlvmObject(arena, llvm_object, prog_node);
        if (use_lld) return;
    }

    if (comp.verbose_link) Compilation.dump_argv(wasm.dump_argv_list.items);

    if (wasm.base.zcu_object_sub_path) |path| {
        const module_obj_path = .{
            .root_dir = wasm.base.emit.root_dir,
            .sub_path = if (fs.path.dirname(wasm.base.emit.sub_path)) |dirname|
                try fs.path.join(arena, &.{ dirname, path })
            else
                path,
        };
        openParseObjectReportingFailure(wasm, module_obj_path);
        try prelink(wasm, prog_node);
    }

    const tracy = trace(@src());
    defer tracy.end();

    const sub_prog_node = prog_node.start("Wasm Flush", 0);
    defer sub_prog_node.end();

    wasm.flush_buffer.clear();
    return wasm.flush_buffer.finish(wasm, arena, tid);
}

fn linkWithLLD(wasm: *Wasm, arena: Allocator, tid: Zcu.PerThread.Id, prog_node: std.Progress.Node) !void {
    dev.check(.lld_linker);

    const tracy = trace(@src());
    defer tracy.end();

    const comp = wasm.base.comp;
    const shared_memory = comp.config.shared_memory;
    const export_memory = comp.config.export_memory;
    const import_memory = comp.config.import_memory;
    const target = comp.root_mod.resolved_target.result;

    const gpa = comp.gpa;

    const directory = wasm.base.emit.root_dir; // Just an alias to make it shorter to type.
    const full_out_path = try directory.join(arena, &[_][]const u8{wasm.base.emit.sub_path});

    // If there is no Zig code to compile, then we should skip flushing the output file because it
    // will not be part of the linker line anyway.
    const module_obj_path: ?[]const u8 = if (comp.zcu != null) blk: {
        try wasm.flushModule(arena, tid, prog_node);

        if (fs.path.dirname(full_out_path)) |dirname| {
            break :blk try fs.path.join(arena, &.{ dirname, wasm.base.zcu_object_sub_path.? });
        } else {
            break :blk wasm.base.zcu_object_sub_path.?;
        }
    } else null;

    const sub_prog_node = prog_node.start("LLD Link", 0);
    defer sub_prog_node.end();

    const is_obj = comp.config.output_mode == .Obj;
    const compiler_rt_path: ?Path = blk: {
        if (comp.compiler_rt_lib) |lib| break :blk lib.full_object_path;
        if (comp.compiler_rt_obj) |obj| break :blk obj.full_object_path;
        break :blk null;
    };

    const id_symlink_basename = "lld.id";

    var man: Cache.Manifest = undefined;
    defer if (!wasm.base.disable_lld_caching) man.deinit();

    var digest: [Cache.hex_digest_len]u8 = undefined;

    if (!wasm.base.disable_lld_caching) {
        man = comp.cache_parent.obtain();

        // We are about to obtain this lock, so here we give other processes a chance first.
        wasm.base.releaseLock();

        comptime assert(Compilation.link_hash_implementation_version == 14);

        try link.hashInputs(&man, comp.link_inputs);
        for (comp.c_object_table.keys()) |key| {
            _ = try man.addFilePath(key.status.success.object_path, null);
        }
        try man.addOptionalFile(module_obj_path);
        try man.addOptionalFilePath(compiler_rt_path);
        man.hash.addOptionalBytes(wasm.optionalStringSlice(wasm.entry_name));
        man.hash.add(wasm.base.stack_size);
        man.hash.add(wasm.base.build_id);
        man.hash.add(import_memory);
        man.hash.add(export_memory);
        man.hash.add(wasm.import_table);
        man.hash.add(wasm.export_table);
        man.hash.addOptional(wasm.initial_memory);
        man.hash.addOptional(wasm.max_memory);
        man.hash.add(shared_memory);
        man.hash.addOptional(wasm.global_base);
        man.hash.addListOfBytes(wasm.export_symbol_names);
        // strip does not need to go into the linker hash because it is part of the hash namespace

        // We don't actually care whether it's a cache hit or miss; we just need the digest and the lock.
        _ = try man.hit();
        digest = man.final();

        var prev_digest_buf: [digest.len]u8 = undefined;
        const prev_digest: []u8 = Cache.readSmallFile(
            directory.handle,
            id_symlink_basename,
            &prev_digest_buf,
        ) catch |err| blk: {
            log.debug("WASM LLD new_digest={s} error: {s}", .{ std.fmt.fmtSliceHexLower(&digest), @errorName(err) });
            // Handle this as a cache miss.
            break :blk prev_digest_buf[0..0];
        };
        if (mem.eql(u8, prev_digest, &digest)) {
            log.debug("WASM LLD digest={s} match - skipping invocation", .{std.fmt.fmtSliceHexLower(&digest)});
            // Hot diggity dog! The output binary is already there.
            wasm.base.lock = man.toOwnedLock();
            return;
        }
        log.debug("WASM LLD prev_digest={s} new_digest={s}", .{ std.fmt.fmtSliceHexLower(prev_digest), std.fmt.fmtSliceHexLower(&digest) });

        // We are about to change the output file to be different, so we invalidate the build hash now.
        directory.handle.deleteFile(id_symlink_basename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    if (is_obj) {
        // LLD's WASM driver does not support the equivalent of `-r` so we do a simple file copy
        // here. TODO: think carefully about how we can avoid this redundant operation when doing
        // build-obj. See also the corresponding TODO in linkAsArchive.
        const the_object_path = blk: {
            if (link.firstObjectInput(comp.link_inputs)) |obj| break :blk obj.path;

            if (comp.c_object_table.count() != 0)
                break :blk comp.c_object_table.keys()[0].status.success.object_path;

            if (module_obj_path) |p|
                break :blk Path.initCwd(p);

            // TODO I think this is unreachable. Audit this situation when solving the above TODO
            // regarding eliding redundant object -> object transformations.
            return error.NoObjectsToLink;
        };
        try fs.Dir.copyFile(
            the_object_path.root_dir.handle,
            the_object_path.sub_path,
            directory.handle,
            wasm.base.emit.sub_path,
            .{},
        );
    } else {
        // Create an LLD command line and invoke it.
        var argv = std.ArrayList([]const u8).init(gpa);
        defer argv.deinit();
        // We will invoke ourselves as a child process to gain access to LLD.
        // This is necessary because LLD does not behave properly as a library -
        // it calls exit() and does not reset all global data between invocations.
        const linker_command = "wasm-ld";
        try argv.appendSlice(&[_][]const u8{ comp.self_exe_path.?, linker_command });
        try argv.append("--error-limit=0");

        if (comp.config.lto) {
            switch (comp.root_mod.optimize_mode) {
                .Debug => {},
                .ReleaseSmall => try argv.append("-O2"),
                .ReleaseFast, .ReleaseSafe => try argv.append("-O3"),
            }
        }

        if (import_memory) {
            try argv.append("--import-memory");
        }

        if (export_memory) {
            try argv.append("--export-memory");
        }

        if (wasm.import_table) {
            assert(!wasm.export_table);
            try argv.append("--import-table");
        }

        if (wasm.export_table) {
            assert(!wasm.import_table);
            try argv.append("--export-table");
        }

        // For wasm-ld we only need to specify '--no-gc-sections' when the user explicitly
        // specified it as garbage collection is enabled by default.
        if (!wasm.base.gc_sections) {
            try argv.append("--no-gc-sections");
        }

        if (comp.config.debug_format == .strip) {
            try argv.append("-s");
        }

        if (wasm.initial_memory) |initial_memory| {
            const arg = try std.fmt.allocPrint(arena, "--initial-memory={d}", .{initial_memory});
            try argv.append(arg);
        }

        if (wasm.max_memory) |max_memory| {
            const arg = try std.fmt.allocPrint(arena, "--max-memory={d}", .{max_memory});
            try argv.append(arg);
        }

        if (shared_memory) {
            try argv.append("--shared-memory");
        }

        if (wasm.global_base) |global_base| {
            const arg = try std.fmt.allocPrint(arena, "--global-base={d}", .{global_base});
            try argv.append(arg);
        } else {
            // We prepend it by default, so when a stack overflow happens the runtime will trap correctly,
            // rather than silently overwrite all global declarations. See https://github.com/ziglang/zig/issues/4496
            //
            // The user can overwrite this behavior by setting the global-base
            try argv.append("--stack-first");
        }

        // Users are allowed to specify which symbols they want to export to the wasm host.
        for (wasm.export_symbol_names) |symbol_name| {
            const arg = try std.fmt.allocPrint(arena, "--export={s}", .{symbol_name});
            try argv.append(arg);
        }

        if (comp.config.rdynamic) {
            try argv.append("--export-dynamic");
        }

        if (wasm.optionalStringSlice(wasm.entry_name)) |entry_name| {
            try argv.appendSlice(&.{ "--entry", entry_name });
        } else {
            try argv.append("--no-entry");
        }

        try argv.appendSlice(&.{
            "-z",
            try std.fmt.allocPrint(arena, "stack-size={d}", .{wasm.base.stack_size}),
        });

        if (wasm.import_symbols) {
            try argv.append("--allow-undefined");
        }

        if (comp.config.output_mode == .Lib and comp.config.link_mode == .dynamic) {
            try argv.append("--shared");
        }
        if (comp.config.pie) {
            try argv.append("--pie");
        }

        // XXX - TODO: add when wasm-ld supports --build-id.
        // if (wasm.base.build_id) {
        //     try argv.append("--build-id=tree");
        // }

        try argv.appendSlice(&.{ "-o", full_out_path });

        if (target.cpu.arch == .wasm64) {
            try argv.append("-mwasm64");
        }

        if (target.os.tag == .wasi) {
            const is_exe_or_dyn_lib = comp.config.output_mode == .Exe or
                (comp.config.output_mode == .Lib and comp.config.link_mode == .dynamic);
            if (is_exe_or_dyn_lib) {
                for (comp.wasi_emulated_libs) |crt_file| {
                    try argv.append(try comp.crtFileAsString(
                        arena,
                        wasi_libc.emulatedLibCRFileLibName(crt_file),
                    ));
                }

                if (comp.config.link_libc) {
                    try argv.append(try comp.crtFileAsString(
                        arena,
                        wasi_libc.execModelCrtFileFullName(comp.config.wasi_exec_model),
                    ));
                    try argv.append(try comp.crtFileAsString(arena, "libc.a"));
                }

                if (comp.config.link_libcpp) {
                    try argv.append(try comp.libcxx_static_lib.?.full_object_path.toString(arena));
                    try argv.append(try comp.libcxxabi_static_lib.?.full_object_path.toString(arena));
                }
            }
        }

        // Positional arguments to the linker such as object files.
        var whole_archive = false;
        for (comp.link_inputs) |link_input| switch (link_input) {
            .object, .archive => |obj| {
                if (obj.must_link and !whole_archive) {
                    try argv.append("-whole-archive");
                    whole_archive = true;
                } else if (!obj.must_link and whole_archive) {
                    try argv.append("-no-whole-archive");
                    whole_archive = false;
                }
                try argv.append(try obj.path.toString(arena));
            },
            .dso => |dso| {
                try argv.append(try dso.path.toString(arena));
            },
            .dso_exact => unreachable,
            .res => unreachable,
        };
        if (whole_archive) {
            try argv.append("-no-whole-archive");
            whole_archive = false;
        }

        for (comp.c_object_table.keys()) |key| {
            try argv.append(try key.status.success.object_path.toString(arena));
        }
        if (module_obj_path) |p| {
            try argv.append(p);
        }

        if (comp.libc_static_lib) |crt_file| {
            try argv.append(try crt_file.full_object_path.toString(arena));
        }

        if (compiler_rt_path) |p| {
            try argv.append(try p.toString(arena));
        }

        if (comp.verbose_link) {
            // Skip over our own name so that the LLD linker name is the first argv item.
            Compilation.dump_argv(argv.items[1..]);
        }

        if (std.process.can_spawn) {
            // If possible, we run LLD as a child process because it does not always
            // behave properly as a library, unfortunately.
            // https://github.com/ziglang/zig/issues/3825
            var child = std.process.Child.init(argv.items, arena);
            if (comp.clang_passthrough_mode) {
                child.stdin_behavior = .Inherit;
                child.stdout_behavior = .Inherit;
                child.stderr_behavior = .Inherit;

                const term = child.spawnAndWait() catch |err| {
                    log.err("unable to spawn {s}: {s}", .{ argv.items[0], @errorName(err) });
                    return error.UnableToSpawnWasm;
                };
                switch (term) {
                    .Exited => |code| {
                        if (code != 0) {
                            std.process.exit(code);
                        }
                    },
                    else => std.process.abort(),
                }
            } else {
                child.stdin_behavior = .Ignore;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Pipe;

                try child.spawn();

                const stderr = try child.stderr.?.reader().readAllAlloc(arena, std.math.maxInt(usize));

                const term = child.wait() catch |err| {
                    log.err("unable to spawn {s}: {s}", .{ argv.items[0], @errorName(err) });
                    return error.UnableToSpawnWasm;
                };

                switch (term) {
                    .Exited => |code| {
                        if (code != 0) {
                            const diags = &comp.link_diags;
                            diags.lockAndParseLldStderr(linker_command, stderr);
                            return error.LLDReportedFailure;
                        }
                    },
                    else => {
                        log.err("{s} terminated with stderr:\n{s}", .{ argv.items[0], stderr });
                        return error.LLDCrashed;
                    },
                }

                if (stderr.len != 0) {
                    log.warn("unexpected LLD stderr:\n{s}", .{stderr});
                }
            }
        } else {
            const exit_code = try lldMain(arena, argv.items, false);
            if (exit_code != 0) {
                if (comp.clang_passthrough_mode) {
                    std.process.exit(exit_code);
                } else {
                    return error.LLDReportedFailure;
                }
            }
        }

        // Give +x to the .wasm file if it is an executable and the OS is WASI.
        // Some systems may be configured to execute such binaries directly. Even if that
        // is not the case, it means we will get "exec format error" when trying to run
        // it, and then can react to that in the same way as trying to run an ELF file
        // from a foreign CPU architecture.
        if (fs.has_executable_bit and target.os.tag == .wasi and
            comp.config.output_mode == .Exe)
        {
            // TODO: what's our strategy for reporting linker errors from this function?
            // report a nice error here with the file path if it fails instead of
            // just returning the error code.
            // chmod does not interact with umask, so we use a conservative -rwxr--r-- here.
            std.posix.fchmodat(fs.cwd().fd, full_out_path, 0o744, 0) catch |err| switch (err) {
                error.OperationNotSupported => unreachable, // Not a symlink.
                else => |e| return e,
            };
        }
    }

    if (!wasm.base.disable_lld_caching) {
        // Update the file with the digest. If it fails we can continue; it only
        // means that the next invocation will have an unnecessary cache miss.
        Cache.writeSmallFile(directory.handle, id_symlink_basename, &digest) catch |err| {
            log.warn("failed to save linking hash digest symlink: {s}", .{@errorName(err)});
        };
        // Again failure here only means an unnecessary cache miss.
        man.writeManifest() catch |err| {
            log.warn("failed to write cache manifest when linking: {s}", .{@errorName(err)});
        };
        // We hang on to this lock so that the output file path can be used without
        // other processes clobbering it.
        wasm.base.lock = man.toOwnedLock();
    }
}

/// Returns the symbol index of the error name table.
///
/// When the symbol does not yet exist, it will create a new one instead.
pub fn getErrorTableSymbol(wasm: *Wasm, pt: Zcu.PerThread) !u32 {
    const sym_index = try wasm.zig_object.?.getErrorTableSymbol(wasm, pt);
    return @intFromEnum(sym_index);
}

fn defaultEntrySymbolName(
    preloaded_strings: *const PreloadedStrings,
    wasi_exec_model: std.builtin.WasiExecModel,
) String {
    return switch (wasi_exec_model) {
        .reactor => preloaded_strings._initialize,
        .command => preloaded_strings._start,
    };
}

pub fn internString(wasm: *Wasm, bytes: []const u8) error{OutOfMemory}!String {
    assert(mem.indexOfScalar(u8, bytes, 0) == null);
    const gpa = wasm.base.comp.gpa;
    const gop = try wasm.string_table.getOrPutContextAdapted(
        gpa,
        @as([]const u8, bytes),
        @as(String.TableIndexAdapter, .{ .bytes = wasm.string_bytes.items }),
        @as(String.TableContext, .{ .bytes = wasm.string_bytes.items }),
    );
    if (gop.found_existing) return gop.key_ptr.*;

    try wasm.string_bytes.ensureUnusedCapacity(gpa, bytes.len + 1);
    const new_off: String = @enumFromInt(wasm.string_bytes.items.len);

    wasm.string_bytes.appendSliceAssumeCapacity(bytes);
    wasm.string_bytes.appendAssumeCapacity(0);

    gop.key_ptr.* = new_off;

    return new_off;
}

pub fn internValtypeList(wasm: *Wasm, valtype_list: []const std.wasm.Valtype) error{OutOfMemory}!ValtypeList {
    return .fromString(try internString(wasm, @ptrCast(valtype_list)));
}

pub fn addFuncType(wasm: *Wasm, ft: FunctionType) error{OutOfMemory}!FunctionType.Index {
    const gpa = wasm.base.comp.gpa;
    const gop = try wasm.func_types.getOrPut(gpa, ft);
    return @enumFromInt(gop.index);
}

pub fn addExpr(wasm: *Wasm, bytes: []const u8) error{OutOfMemory}!Expr {
    const gpa = wasm.base.comp.gpa;
    // We can't use string table deduplication here since these expressions can
    // have null bytes in them however it may be interesting to explore since
    // it is likely for globals to share initialization values. Then again
    // there may not be very many globals in total.
    try wasm.string_bytes.appendSlice(gpa, bytes);
    return @enumFromInt(wasm.string_bytes.items.len - bytes.len);
}

pub fn addRelocatableDataPayload(wasm: *Wasm, bytes: []const u8) error{OutOfMemory}!DataSegment.Payload {
    const gpa = wasm.base.comp.gpa;
    try wasm.string_bytes.appendSlice(gpa, bytes);
    return @enumFromInt(wasm.string_bytes.items.len - bytes.len);
}
