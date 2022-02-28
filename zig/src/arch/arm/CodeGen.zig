const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const Air = @import("../../Air.zig");
const Mir = @import("Mir.zig");
const Emit = @import("Emit.zig");
const Liveness = @import("../../Liveness.zig");
const Type = @import("../../type.zig").Type;
const Value = @import("../../value.zig").Value;
const TypedValue = @import("../../TypedValue.zig");
const link = @import("../../link.zig");
const Module = @import("../../Module.zig");
const Compilation = @import("../../Compilation.zig");
const ErrorMsg = Module.ErrorMsg;
const Target = std.Target;
const Allocator = mem.Allocator;
const trace = @import("../../tracy.zig").trace;
const DW = std.dwarf;
const leb128 = std.leb;
const log = std.log.scoped(.codegen);
const build_options = @import("build_options");
const RegisterManager = @import("../../register_manager.zig").RegisterManager;

const FnResult = @import("../../codegen.zig").FnResult;
const GenerateSymbolError = @import("../../codegen.zig").GenerateSymbolError;
const DebugInfoOutput = @import("../../codegen.zig").DebugInfoOutput;

const InnerError = error{
    OutOfMemory,
    CodegenFail,
    OutOfRegisters,
};

gpa: Allocator,
air: Air,
liveness: Liveness,
bin_file: *link.File,
target: *const std.Target,
mod_fn: *const Module.Fn,
err_msg: ?*ErrorMsg,
args: []MCValue,
ret_mcv: MCValue,
fn_type: Type,
arg_index: u32,
src_loc: Module.SrcLoc,
stack_align: u32,

/// MIR Instructions
mir_instructions: std.MultiArrayList(Mir.Inst) = .{},
/// MIR extra data
mir_extra: std.ArrayListUnmanaged(u32) = .{},

/// Byte offset within the source file of the ending curly.
end_di_line: u32,
end_di_column: u32,

/// The value is an offset into the `Function` `code` from the beginning.
/// To perform the reloc, write 32-bit signed little-endian integer
/// which is a relative jump, based on the address following the reloc.
exitlude_jump_relocs: std.ArrayListUnmanaged(usize) = .{},

/// Whenever there is a runtime branch, we push a Branch onto this stack,
/// and pop it off when the runtime branch joins. This provides an "overlay"
/// of the table of mappings from instructions to `MCValue` from within the branch.
/// This way we can modify the `MCValue` for an instruction in different ways
/// within different branches. Special consideration is needed when a branch
/// joins with its parent, to make sure all instructions have the same MCValue
/// across each runtime branch upon joining.
branch_stack: *std.ArrayList(Branch),

// Key is the block instruction
blocks: std.AutoHashMapUnmanaged(Air.Inst.Index, BlockData) = .{},

register_manager: RegisterManager(Self, Register, &callee_preserved_regs) = .{},
/// Maps offset to what is stored there.
stack: std.AutoHashMapUnmanaged(u32, StackAllocation) = .{},
/// Tracks the current instruction allocated to the compare flags
compare_flags_inst: ?Air.Inst.Index = null,

/// Offset from the stack base, representing the end of the stack frame.
max_end_stack: u32 = 0,
/// Represents the current end stack offset. If there is no existing slot
/// to place a new stack allocation, it goes here, and then bumps `max_end_stack`.
next_stack_offset: u32 = 0,

saved_regs_stack_space: u32 = 0,

/// Debug field, used to find bugs in the compiler.
air_bookkeeping: @TypeOf(air_bookkeeping_init) = air_bookkeeping_init,

const air_bookkeeping_init = if (std.debug.runtime_safety) @as(usize, 0) else {};

const MCValue = union(enum) {
    /// No runtime bits. `void` types, empty structs, u0, enums with 1 tag, etc.
    /// TODO Look into deleting this tag and using `dead` instead, since every use
    /// of MCValue.none should be instead looking at the type and noticing it is 0 bits.
    none,
    /// Control flow will not allow this value to be observed.
    unreach,
    /// No more references to this value remain.
    dead,
    /// The value is undefined.
    undef,
    /// A pointer-sized integer that fits in a register.
    /// If the type is a pointer, this is the pointer address in virtual address space.
    immediate: u32,
    /// The constant was emitted into the code, at this offset.
    /// If the type is a pointer, it means the pointer address is embedded in the code.
    embedded_in_code: usize,
    /// The value is a pointer to a constant which was emitted into the code, at this offset.
    ptr_embedded_in_code: usize,
    /// The value is in a target-specific register.
    register: Register,
    /// The value is in memory at a hard-coded address.
    /// If the type is a pointer, it means the pointer address is at this memory location.
    memory: u64,
    /// The value is one of the stack variables.
    /// If the type is a pointer, it means the pointer address is in the stack at this offset.
    stack_offset: u32,
    /// The value is a pointer to one of the stack variables (payload is stack offset).
    ptr_stack_offset: u32,
    /// The value is in the compare flags assuming an unsigned operation,
    /// with this operator applied on top of it.
    compare_flags_unsigned: math.CompareOperator,
    /// The value is in the compare flags assuming a signed operation,
    /// with this operator applied on top of it.
    compare_flags_signed: math.CompareOperator,
    /// The value is a function argument passed via the stack.
    stack_argument_offset: u32,

    fn isMemory(mcv: MCValue) bool {
        return switch (mcv) {
            .embedded_in_code, .memory, .stack_offset, .stack_argument_offset => true,
            else => false,
        };
    }

    fn isImmediate(mcv: MCValue) bool {
        return switch (mcv) {
            .immediate => true,
            else => false,
        };
    }

    fn isMutable(mcv: MCValue) bool {
        return switch (mcv) {
            .none => unreachable,
            .unreach => unreachable,
            .dead => unreachable,

            .immediate,
            .embedded_in_code,
            .memory,
            .compare_flags_unsigned,
            .compare_flags_signed,
            .ptr_stack_offset,
            .ptr_embedded_in_code,
            .undef,
            .stack_argument_offset,
            => false,

            .register,
            .stack_offset,
            => true,
        };
    }
};

const Branch = struct {
    inst_table: std.AutoArrayHashMapUnmanaged(Air.Inst.Index, MCValue) = .{},

    fn deinit(self: *Branch, gpa: Allocator) void {
        self.inst_table.deinit(gpa);
        self.* = undefined;
    }
};

const StackAllocation = struct {
    inst: Air.Inst.Index,
    /// TODO do we need size? should be determined by inst.ty.abiSize()
    size: u32,
};

const BlockData = struct {
    relocs: std.ArrayListUnmanaged(Mir.Inst.Index),
    /// The first break instruction encounters `null` here and chooses a
    /// machine code value for the block result, populating this field.
    /// Following break instructions encounter that value and use it for
    /// the location to store their block results.
    mcv: MCValue,
};

const BigTomb = struct {
    function: *Self,
    inst: Air.Inst.Index,
    tomb_bits: Liveness.Bpi,
    big_tomb_bits: u32,
    bit_index: usize,

    fn feed(bt: *BigTomb, op_ref: Air.Inst.Ref) void {
        const this_bit_index = bt.bit_index;
        bt.bit_index += 1;

        const op_int = @enumToInt(op_ref);
        if (op_int < Air.Inst.Ref.typed_value_map.len) return;
        const op_index = @intCast(Air.Inst.Index, op_int - Air.Inst.Ref.typed_value_map.len);

        if (this_bit_index < Liveness.bpi - 1) {
            const dies = @truncate(u1, bt.tomb_bits >> @intCast(Liveness.OperandInt, this_bit_index)) != 0;
            if (!dies) return;
        } else {
            const big_bit_index = @intCast(u5, this_bit_index - (Liveness.bpi - 1));
            const dies = @truncate(u1, bt.big_tomb_bits >> big_bit_index) != 0;
            if (!dies) return;
        }
        bt.function.processDeath(op_index);
    }

    fn finishAir(bt: *BigTomb, result: MCValue) void {
        const is_used = !bt.function.liveness.isUnused(bt.inst);
        if (is_used) {
            log.debug("%{d} => {}", .{ bt.inst, result });
            const branch = &bt.function.branch_stack.items[bt.function.branch_stack.items.len - 1];
            branch.inst_table.putAssumeCapacityNoClobber(bt.inst, result);
        }
        bt.function.finishAirBookkeeping();
    }
};

const Self = @This();

pub fn generate(
    bin_file: *link.File,
    src_loc: Module.SrcLoc,
    module_fn: *Module.Fn,
    air: Air,
    liveness: Liveness,
    code: *std.ArrayList(u8),
    debug_output: DebugInfoOutput,
) GenerateSymbolError!FnResult {
    if (build_options.skip_non_native and builtin.cpu.arch != bin_file.options.target.cpu.arch) {
        @panic("Attempted to compile for architecture that was disabled by build configuration");
    }

    assert(module_fn.owner_decl.has_tv);
    const fn_type = module_fn.owner_decl.ty;

    var branch_stack = std.ArrayList(Branch).init(bin_file.allocator);
    defer {
        assert(branch_stack.items.len == 1);
        branch_stack.items[0].deinit(bin_file.allocator);
        branch_stack.deinit();
    }
    try branch_stack.append(.{});

    var function = Self{
        .gpa = bin_file.allocator,
        .air = air,
        .liveness = liveness,
        .target = &bin_file.options.target,
        .bin_file = bin_file,
        .mod_fn = module_fn,
        .err_msg = null,
        .args = undefined, // populated after `resolveCallingConventionValues`
        .ret_mcv = undefined, // populated after `resolveCallingConventionValues`
        .fn_type = fn_type,
        .arg_index = 0,
        .branch_stack = &branch_stack,
        .src_loc = src_loc,
        .stack_align = undefined,
        .end_di_line = module_fn.rbrace_line,
        .end_di_column = module_fn.rbrace_column,
    };
    defer function.stack.deinit(bin_file.allocator);
    defer function.blocks.deinit(bin_file.allocator);
    defer function.exitlude_jump_relocs.deinit(bin_file.allocator);

    var call_info = function.resolveCallingConventionValues(fn_type) catch |err| switch (err) {
        error.CodegenFail => return FnResult{ .fail = function.err_msg.? },
        error.OutOfRegisters => return FnResult{
            .fail = try ErrorMsg.create(bin_file.allocator, src_loc, "CodeGen ran out of registers. This is a bug in the Zig compiler.", .{}),
        },
        else => |e| return e,
    };
    defer call_info.deinit(&function);

    function.args = call_info.args;
    function.ret_mcv = call_info.return_value;
    function.stack_align = call_info.stack_align;
    function.max_end_stack = call_info.stack_byte_count;

    function.gen() catch |err| switch (err) {
        error.CodegenFail => return FnResult{ .fail = function.err_msg.? },
        error.OutOfRegisters => return FnResult{
            .fail = try ErrorMsg.create(bin_file.allocator, src_loc, "CodeGen ran out of registers. This is a bug in the Zig compiler.", .{}),
        },
        else => |e| return e,
    };

    var mir = Mir{
        .instructions = function.mir_instructions.toOwnedSlice(),
        .extra = function.mir_extra.toOwnedSlice(bin_file.allocator),
    };
    defer mir.deinit(bin_file.allocator);

    var emit = Emit{
        .mir = mir,
        .bin_file = bin_file,
        .function = &function,
        .debug_output = debug_output,
        .target = &bin_file.options.target,
        .src_loc = src_loc,
        .code = code,
        .prev_di_pc = 0,
        .prev_di_line = module_fn.lbrace_line,
        .prev_di_column = module_fn.lbrace_column,
        .prologue_stack_space = call_info.stack_byte_count + function.saved_regs_stack_space,
    };
    defer emit.deinit();

    emit.emitMir() catch |err| switch (err) {
        error.EmitFail => return FnResult{ .fail = emit.err_msg.? },
        else => |e| return e,
    };

    if (function.err_msg) |em| {
        return FnResult{ .fail = em };
    } else {
        return FnResult{ .appended = {} };
    }
}

fn addInst(self: *Self, inst: Mir.Inst) error{OutOfMemory}!Mir.Inst.Index {
    const gpa = self.gpa;

    try self.mir_instructions.ensureUnusedCapacity(gpa, 1);

    const result_index = @intCast(Air.Inst.Index, self.mir_instructions.len);
    self.mir_instructions.appendAssumeCapacity(inst);
    return result_index;
}

fn addNop(self: *Self) error{OutOfMemory}!Mir.Inst.Index {
    return try self.addInst(.{
        .tag = .nop,
        .data = .{ .nop = {} },
    });
}

pub fn addExtra(self: *Self, extra: anytype) Allocator.Error!u32 {
    const fields = std.meta.fields(@TypeOf(extra));
    try self.mir_extra.ensureUnusedCapacity(self.gpa, fields.len);
    return self.addExtraAssumeCapacity(extra);
}

pub fn addExtraAssumeCapacity(self: *Self, extra: anytype) u32 {
    const fields = std.meta.fields(@TypeOf(extra));
    const result = @intCast(u32, self.mir_extra.items.len);
    inline for (fields) |field| {
        self.mir_extra.appendAssumeCapacity(switch (field.field_type) {
            u32 => @field(extra, field.name),
            i32 => @bitCast(u32, @field(extra, field.name)),
            else => @compileError("bad field type"),
        });
    }
    return result;
}

fn gen(self: *Self) !void {
    const cc = self.fn_type.fnCallingConvention();
    if (cc != .Naked) {
        // push {fp, lr}
        const push_reloc = try self.addNop();

        // mov fp, sp
        _ = try self.addInst(.{
            .tag = .mov,
            .data = .{ .rr_op = .{
                .rd = .fp,
                .rn = .r0,
                .op = Instruction.Operand.reg(.sp, Instruction.Operand.Shift.none),
            } },
        });

        // sub sp, sp, #reloc
        const sub_reloc = try self.addNop();

        _ = try self.addInst(.{
            .tag = .dbg_prologue_end,
            .cond = undefined,
            .data = .{ .nop = {} },
        });

        try self.genBody(self.air.getMainBody());

        // Backpatch push callee saved regs
        var saved_regs = Instruction.RegisterList{
            .r11 = true, // fp
            .r14 = true, // lr
        };
        self.saved_regs_stack_space = 8;
        inline for (callee_preserved_regs) |reg| {
            if (self.register_manager.isRegAllocated(reg)) {
                @field(saved_regs, @tagName(reg)) = true;
                self.saved_regs_stack_space += 4;
            }
        }

        self.mir_instructions.set(push_reloc, .{
            .tag = .push,
            .data = .{ .register_list = saved_regs },
        });

        // Backpatch stack offset
        const total_stack_size = self.max_end_stack + self.saved_regs_stack_space;
        const aligned_total_stack_end = mem.alignForwardGeneric(u32, total_stack_size, self.stack_align);
        const stack_size = aligned_total_stack_end - self.saved_regs_stack_space;
        if (Instruction.Operand.fromU32(stack_size)) |op| {
            self.mir_instructions.set(sub_reloc, .{
                .tag = .sub,
                .data = .{ .rr_op = .{ .rd = .sp, .rn = .sp, .op = op } },
            });
        } else {
            return self.failSymbol("TODO ARM: allow larger stacks", .{});
        }

        _ = try self.addInst(.{
            .tag = .dbg_epilogue_begin,
            .cond = undefined,
            .data = .{ .nop = {} },
        });

        // exitlude jumps
        const only_one_exitlude_jump = self.exitlude_jump_relocs.items.len == 1 and
            self.exitlude_jump_relocs.items[0] == self.mir_instructions.len - 1;
        if (only_one_exitlude_jump) {
            // There is only one relocation. Hence,
            // this relocation must be at the end of
            // the code. Therefore, we can just delete
            // the space initially reserved for the
            // jump
            self.mir_instructions.orderedRemove(self.exitlude_jump_relocs.items[0]);
        } else for (self.exitlude_jump_relocs.items) |jmp_reloc| {
            self.mir_instructions.set(jmp_reloc, .{
                .tag = .b,
                .data = .{ .inst = @intCast(u32, self.mir_instructions.len) },
            });
        }

        // Epilogue: pop callee saved registers (swap lr with pc in saved_regs)
        saved_regs.r14 = false; // lr
        saved_regs.r15 = true; // pc

        // mov sp, fp
        _ = try self.addInst(.{
            .tag = .mov,
            .data = .{ .rr_op = .{
                .rd = .sp,
                .rn = .r0,
                .op = Instruction.Operand.reg(.fp, Instruction.Operand.Shift.none),
            } },
        });

        // pop {fp, pc}
        _ = try self.addInst(.{
            .tag = .pop,
            .data = .{ .register_list = saved_regs },
        });
    } else {
        _ = try self.addInst(.{
            .tag = .dbg_prologue_end,
            .cond = undefined,
            .data = .{ .nop = {} },
        });

        try self.genBody(self.air.getMainBody());

        _ = try self.addInst(.{
            .tag = .dbg_epilogue_begin,
            .cond = undefined,
            .data = .{ .nop = {} },
        });
    }

    // Drop them off at the rbrace.
    _ = try self.addInst(.{
        .tag = .dbg_line,
        .cond = undefined,
        .data = .{ .dbg_line_column = .{
            .line = self.end_di_line,
            .column = self.end_di_column,
        } },
    });
}

fn genBody(self: *Self, body: []const Air.Inst.Index) InnerError!void {
    const air_tags = self.air.instructions.items(.tag);

    for (body) |inst| {
        const old_air_bookkeeping = self.air_bookkeeping;
        try self.ensureProcessDeathCapacity(Liveness.bpi);

        switch (air_tags[inst]) {
            // zig fmt: off
            .add, .ptr_add   => try self.airBinOp(inst),
            .addwrap         => try self.airAddWrap(inst),
            .add_sat         => try self.airAddSat(inst),
            .sub, .ptr_sub   => try self.airBinOp(inst),
            .subwrap         => try self.airSubWrap(inst),
            .sub_sat         => try self.airSubSat(inst),
            .mul             => try self.airBinOp(inst),
            .mulwrap         => try self.airMulWrap(inst),
            .mul_sat         => try self.airMulSat(inst),
            .rem             => try self.airRem(inst),
            .mod             => try self.airMod(inst),
            .shl, .shl_exact => try self.airBinOp(inst),
            .shl_sat         => try self.airShlSat(inst),
            .min             => try self.airMin(inst),
            .max             => try self.airMax(inst),
            .slice           => try self.airSlice(inst),

            .sqrt,
            .sin,
            .cos,
            .exp,
            .exp2,
            .log,
            .log2,
            .log10,
            .fabs,
            .floor,
            .ceil,
            .round,
            .trunc_float,
            => try self.airUnaryMath(inst),

            .add_with_overflow => try self.airAddWithOverflow(inst),
            .sub_with_overflow => try self.airSubWithOverflow(inst),
            .mul_with_overflow => try self.airMulWithOverflow(inst),
            .shl_with_overflow => try self.airShlWithOverflow(inst),

            .div_float, .div_trunc, .div_floor, .div_exact => try self.airDiv(inst),

            .cmp_lt  => try self.airCmp(inst, .lt),
            .cmp_lte => try self.airCmp(inst, .lte),
            .cmp_eq  => try self.airCmp(inst, .eq),
            .cmp_gte => try self.airCmp(inst, .gte),
            .cmp_gt  => try self.airCmp(inst, .gt),
            .cmp_neq => try self.airCmp(inst, .neq),

            .bool_and        => try self.airBinOp(inst),
            .bool_or         => try self.airBinOp(inst),
            .bit_and         => try self.airBinOp(inst),
            .bit_or          => try self.airBinOp(inst),
            .xor             => try self.airBinOp(inst),
            .shr, .shr_exact => try self.airBinOp(inst),

            .alloc           => try self.airAlloc(inst),
            .ret_ptr         => try self.airRetPtr(inst),
            .arg             => try self.airArg(inst),
            .assembly        => try self.airAsm(inst),
            .bitcast         => try self.airBitCast(inst),
            .block           => try self.airBlock(inst),
            .br              => try self.airBr(inst),
            .breakpoint      => try self.airBreakpoint(),
            .ret_addr        => try self.airRetAddr(),
            .fence           => try self.airFence(),
            .call            => try self.airCall(inst),
            .cond_br         => try self.airCondBr(inst),
            .dbg_stmt        => try self.airDbgStmt(inst),
            .fptrunc         => try self.airFptrunc(inst),
            .fpext           => try self.airFpext(inst),
            .intcast         => try self.airIntCast(inst),
            .trunc           => try self.airTrunc(inst),
            .bool_to_int     => try self.airBoolToInt(inst),
            .is_non_null     => try self.airIsNonNull(inst),
            .is_non_null_ptr => try self.airIsNonNullPtr(inst),
            .is_null         => try self.airIsNull(inst),
            .is_null_ptr     => try self.airIsNullPtr(inst),
            .is_non_err      => try self.airIsNonErr(inst),
            .is_non_err_ptr  => try self.airIsNonErrPtr(inst),
            .is_err          => try self.airIsErr(inst),
            .is_err_ptr      => try self.airIsErrPtr(inst),
            .load            => try self.airLoad(inst),
            .loop            => try self.airLoop(inst),
            .not             => try self.airNot(inst),
            .ptrtoint        => try self.airPtrToInt(inst),
            .ret             => try self.airRet(inst),
            .ret_load        => try self.airRetLoad(inst),
            .store           => try self.airStore(inst),
            .struct_field_ptr=> try self.airStructFieldPtr(inst),
            .struct_field_val=> try self.airStructFieldVal(inst),
            .array_to_slice  => try self.airArrayToSlice(inst),
            .int_to_float    => try self.airIntToFloat(inst),
            .float_to_int    => try self.airFloatToInt(inst),
            .cmpxchg_strong  => try self.airCmpxchg(inst),
            .cmpxchg_weak    => try self.airCmpxchg(inst),
            .atomic_rmw      => try self.airAtomicRmw(inst),
            .atomic_load     => try self.airAtomicLoad(inst),
            .memcpy          => try self.airMemcpy(inst),
            .memset          => try self.airMemset(inst),
            .set_union_tag   => try self.airSetUnionTag(inst),
            .get_union_tag   => try self.airGetUnionTag(inst),
            .clz             => try self.airClz(inst),
            .ctz             => try self.airCtz(inst),
            .popcount        => try self.airPopcount(inst),
            .byte_swap       => try self.airByteSwap(inst),
            .bit_reverse     => try self.airBitReverse(inst),
            .tag_name        => try self.airTagName(inst),
            .error_name      => try self.airErrorName(inst),
            .splat           => try self.airSplat(inst),
            .aggregate_init  => try self.airAggregateInit(inst),
            .union_init      => try self.airUnionInit(inst),
            .prefetch        => try self.airPrefetch(inst),

            .atomic_store_unordered => try self.airAtomicStore(inst, .Unordered),
            .atomic_store_monotonic => try self.airAtomicStore(inst, .Monotonic),
            .atomic_store_release   => try self.airAtomicStore(inst, .Release),
            .atomic_store_seq_cst   => try self.airAtomicStore(inst, .SeqCst),

            .struct_field_ptr_index_0 => try self.airStructFieldPtrIndex(inst, 0),
            .struct_field_ptr_index_1 => try self.airStructFieldPtrIndex(inst, 1),
            .struct_field_ptr_index_2 => try self.airStructFieldPtrIndex(inst, 2),
            .struct_field_ptr_index_3 => try self.airStructFieldPtrIndex(inst, 3),

            .field_parent_ptr => try self.airFieldParentPtr(inst),

            .switch_br       => try self.airSwitch(inst),
            .slice_ptr       => try self.airSlicePtr(inst),
            .slice_len       => try self.airSliceLen(inst),

            .ptr_slice_len_ptr => try self.airPtrSliceLenPtr(inst),
            .ptr_slice_ptr_ptr => try self.airPtrSlicePtrPtr(inst),

            .array_elem_val      => try self.airArrayElemVal(inst),
            .slice_elem_val      => try self.airSliceElemVal(inst),
            .slice_elem_ptr      => try self.airSliceElemPtr(inst),
            .ptr_elem_val        => try self.airPtrElemVal(inst),
            .ptr_elem_ptr        => try self.airPtrElemPtr(inst),

            .constant => unreachable, // excluded from function bodies
            .const_ty => unreachable, // excluded from function bodies
            .unreach  => self.finishAirBookkeeping(),

            .optional_payload           => try self.airOptionalPayload(inst),
            .optional_payload_ptr       => try self.airOptionalPayloadPtr(inst),
            .optional_payload_ptr_set   => try self.airOptionalPayloadPtrSet(inst),
            .unwrap_errunion_err        => try self.airUnwrapErrErr(inst),
            .unwrap_errunion_payload    => try self.airUnwrapErrPayload(inst),
            .unwrap_errunion_err_ptr    => try self.airUnwrapErrErrPtr(inst),
            .unwrap_errunion_payload_ptr=> try self.airUnwrapErrPayloadPtr(inst),
            .errunion_payload_ptr_set   => try self.airErrUnionPayloadPtrSet(inst),

            .wrap_optional         => try self.airWrapOptional(inst),
            .wrap_errunion_payload => try self.airWrapErrUnionPayload(inst),
            .wrap_errunion_err     => try self.airWrapErrUnionErr(inst),
            // zig fmt: on
        }

        assert(!self.register_manager.frozenRegsExist());

        if (std.debug.runtime_safety) {
            if (self.air_bookkeeping < old_air_bookkeeping + 1) {
                std.debug.panic("in codegen.zig, handling of AIR instruction %{d} ('{}') did not do proper bookkeeping. Look for a missing call to finishAir.", .{ inst, air_tags[inst] });
            }
        }
    }
}

/// Asserts there is already capacity to insert into top branch inst_table.
fn processDeath(self: *Self, inst: Air.Inst.Index) void {
    const air_tags = self.air.instructions.items(.tag);
    if (air_tags[inst] == .constant) return; // Constants are immortal.
    // When editing this function, note that the logic must synchronize with `reuseOperand`.
    const prev_value = self.getResolvedInstValue(inst);
    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
    branch.inst_table.putAssumeCapacity(inst, .dead);
    switch (prev_value) {
        .register => |reg| {
            self.register_manager.freeReg(reg);
        },
        .compare_flags_signed, .compare_flags_unsigned => {
            self.compare_flags_inst = null;
        },
        else => {}, // TODO process stack allocation death
    }
}

/// Called when there are no operands, and the instruction is always unreferenced.
fn finishAirBookkeeping(self: *Self) void {
    if (std.debug.runtime_safety) {
        self.air_bookkeeping += 1;
    }
}

fn finishAir(self: *Self, inst: Air.Inst.Index, result: MCValue, operands: [Liveness.bpi - 1]Air.Inst.Ref) void {
    var tomb_bits = self.liveness.getTombBits(inst);
    for (operands) |op| {
        const dies = @truncate(u1, tomb_bits) != 0;
        tomb_bits >>= 1;
        if (!dies) continue;
        const op_int = @enumToInt(op);
        if (op_int < Air.Inst.Ref.typed_value_map.len) continue;
        const op_index = @intCast(Air.Inst.Index, op_int - Air.Inst.Ref.typed_value_map.len);
        self.processDeath(op_index);
    }
    const is_used = @truncate(u1, tomb_bits) == 0;
    if (is_used) {
        log.debug("%{d} => {}", .{ inst, result });
        const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
        branch.inst_table.putAssumeCapacityNoClobber(inst, result);

        switch (result) {
            .register => |reg| {
                // In some cases (such as bitcast), an operand
                // may be the same MCValue as the result. If
                // that operand died and was a register, it
                // was freed by processDeath. We have to
                // "re-allocate" the register.
                if (self.register_manager.isRegFree(reg)) {
                    self.register_manager.getRegAssumeFree(reg, inst);
                }
            },
            else => {},
        }
    }
    self.finishAirBookkeeping();
}

fn ensureProcessDeathCapacity(self: *Self, additional_count: usize) !void {
    const table = &self.branch_stack.items[self.branch_stack.items.len - 1].inst_table;
    try table.ensureUnusedCapacity(self.gpa, additional_count);
}

fn allocMem(self: *Self, inst: Air.Inst.Index, abi_size: u32, abi_align: u32) !u32 {
    if (abi_align > self.stack_align)
        self.stack_align = abi_align;
    // TODO find a free slot instead of always appending
    const offset = mem.alignForwardGeneric(u32, self.next_stack_offset, abi_align);
    self.next_stack_offset = offset + abi_size;
    if (self.next_stack_offset > self.max_end_stack)
        self.max_end_stack = self.next_stack_offset;
    try self.stack.putNoClobber(self.gpa, offset, .{
        .inst = inst,
        .size = abi_size,
    });
    return offset;
}

/// Use a pointer instruction as the basis for allocating stack memory.
fn allocMemPtr(self: *Self, inst: Air.Inst.Index) !u32 {
    const elem_ty = self.air.typeOfIndex(inst).elemType();

    if (!elem_ty.hasRuntimeBits()) {
        // As this stack item will never be dereferenced at runtime,
        // return the current stack offset
        try self.stack.putNoClobber(self.gpa, self.next_stack_offset, .{
            .inst = inst,
            .size = 0,
        });
        return self.next_stack_offset;
    }

    const abi_size = math.cast(u32, elem_ty.abiSize(self.target.*)) catch {
        return self.fail("type '{}' too big to fit into stack frame", .{elem_ty});
    };
    // TODO swap this for inst.ty.ptrAlign
    const abi_align = elem_ty.abiAlignment(self.target.*);
    return self.allocMem(inst, abi_size, abi_align);
}

fn allocRegOrMem(self: *Self, inst: Air.Inst.Index, reg_ok: bool) !MCValue {
    const elem_ty = self.air.typeOfIndex(inst);
    const abi_size = math.cast(u32, elem_ty.abiSize(self.target.*)) catch {
        return self.fail("type '{}' too big to fit into stack frame", .{elem_ty});
    };
    const abi_align = elem_ty.abiAlignment(self.target.*);
    if (abi_align > self.stack_align)
        self.stack_align = abi_align;

    if (reg_ok) {
        // Make sure the type can fit in a register before we try to allocate one.
        const ptr_bits = self.target.cpu.arch.ptrBitWidth();
        const ptr_bytes: u64 = @divExact(ptr_bits, 8);
        if (abi_size <= ptr_bytes) {
            if (self.register_manager.tryAllocReg(inst)) |reg| {
                return MCValue{ .register = reg };
            }
        }
    }
    const stack_offset = try self.allocMem(inst, abi_size, abi_align);
    return MCValue{ .stack_offset = stack_offset };
}

pub fn spillInstruction(self: *Self, reg: Register, inst: Air.Inst.Index) !void {
    const stack_mcv = try self.allocRegOrMem(inst, false);
    log.debug("spilling {} (%{d}) to stack mcv {any}", .{ reg, inst, stack_mcv });
    const reg_mcv = self.getResolvedInstValue(inst);
    assert(reg == reg_mcv.register);
    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
    try branch.inst_table.put(self.gpa, inst, stack_mcv);
    try self.genSetStack(self.air.typeOfIndex(inst), stack_mcv.stack_offset, reg_mcv);
}

/// Save the current instruction stored in the compare flags if
/// occupied
fn spillCompareFlagsIfOccupied(self: *Self) !void {
    if (self.compare_flags_inst) |inst_to_save| {
        const mcv = self.getResolvedInstValue(inst_to_save);
        assert(mcv == .compare_flags_signed or mcv == .compare_flags_unsigned);

        const new_mcv = try self.allocRegOrMem(inst_to_save, true);
        try self.setRegOrMem(self.air.typeOfIndex(inst_to_save), new_mcv, mcv);
        log.debug("spilling {d} to mcv {any}", .{ inst_to_save, new_mcv });

        const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
        try branch.inst_table.put(self.gpa, inst_to_save, new_mcv);

        self.compare_flags_inst = null;
    }
}

/// Copies a value to a register without tracking the register. The register is not considered
/// allocated. A second call to `copyToTmpRegister` may return the same register.
/// This can have a side effect of spilling instructions to the stack to free up a register.
fn copyToTmpRegister(self: *Self, ty: Type, mcv: MCValue) !Register {
    const reg = try self.register_manager.allocReg(null);
    try self.genSetReg(ty, reg, mcv);
    return reg;
}

/// Allocates a new register and copies `mcv` into it.
/// `reg_owner` is the instruction that gets associated with the register in the register table.
/// This can have a side effect of spilling instructions to the stack to free up a register.
fn copyToNewRegister(self: *Self, reg_owner: Air.Inst.Index, mcv: MCValue) !MCValue {
    const reg = try self.register_manager.allocReg(reg_owner);
    try self.genSetReg(self.air.typeOfIndex(reg_owner), reg, mcv);
    return MCValue{ .register = reg };
}

fn airAlloc(self: *Self, inst: Air.Inst.Index) !void {
    const stack_offset = try self.allocMemPtr(inst);
    return self.finishAir(inst, .{ .ptr_stack_offset = stack_offset }, .{ .none, .none, .none });
}

fn airRetPtr(self: *Self, inst: Air.Inst.Index) !void {
    const stack_offset = try self.allocMemPtr(inst);
    return self.finishAir(inst, .{ .ptr_stack_offset = stack_offset }, .{ .none, .none, .none });
}

fn airFptrunc(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement airFptrunc for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airFpext(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement airFpext for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airIntCast(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    if (self.liveness.isUnused(inst))
        return self.finishAir(inst, .dead, .{ ty_op.operand, .none, .none });

    const operand_ty = self.air.typeOf(ty_op.operand);
    const operand = try self.resolveInst(ty_op.operand);
    const info_a = operand_ty.intInfo(self.target.*);
    const info_b = self.air.typeOfIndex(inst).intInfo(self.target.*);
    if (info_a.signedness != info_b.signedness)
        return self.fail("TODO gen intcast sign safety in semantic analysis", .{});

    if (info_a.bits == info_b.bits)
        return self.finishAir(inst, operand, .{ ty_op.operand, .none, .none });

    return self.fail("TODO implement intCast for {}", .{self.target.cpu.arch});
    // return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airTrunc(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    if (self.liveness.isUnused(inst))
        return self.finishAir(inst, .dead, .{ ty_op.operand, .none, .none });

    const operand_ty = self.air.typeOf(ty_op.operand);
    const operand = try self.resolveInst(ty_op.operand);
    const info_a = operand_ty.intInfo(self.target.*);
    const info_b = self.air.typeOfIndex(inst).intInfo(self.target.*);

    const result: MCValue = blk: {
        if (info_b.bits <= 32) {
            const operand_reg = switch (operand) {
                .register => |r| r,
                else => operand_reg: {
                    if (info_a.bits <= 32) {
                        break :operand_reg try self.copyToTmpRegister(operand_ty, operand);
                    } else {
                        return self.fail("TODO load least significant word into register", .{});
                    }
                },
            };
            self.register_manager.freezeRegs(&.{operand_reg});
            defer self.register_manager.unfreezeRegs(&.{operand_reg});

            const dest_reg = dest_reg: {
                if (operand == .register and self.reuseOperand(inst, ty_op.operand, 0, operand)) {
                    break :dest_reg operand_reg;
                }

                break :dest_reg try self.register_manager.allocReg(null);
            };

            switch (info_b.bits) {
                32 => {
                    try self.genSetReg(operand_ty, dest_reg, .{ .register = operand_reg });
                    break :blk MCValue{ .register = dest_reg };
                },
                else => {
                    _ = try self.addInst(.{
                        .tag = switch (info_b.signedness) {
                            .signed => .sbfx,
                            .unsigned => .ubfx,
                        },
                        .data = .{ .rr_lsb_width = .{
                            .rd = dest_reg,
                            .rn = operand_reg,
                            .lsb = 0,
                            .width = @intCast(u6, info_b.bits),
                        } },
                    });
                    break :blk MCValue{ .register = dest_reg };
                },
            }
        } else {
            return self.fail("TODO: truncate to ints > 32 bits", .{});
        }
    };

    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airBoolToInt(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const operand = try self.resolveInst(un_op);
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else operand;
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airNot(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const operand = try self.resolveInst(ty_op.operand);
        const operand_ty = self.air.typeOf(ty_op.operand);
        switch (operand) {
            .dead => unreachable,
            .unreach => unreachable,
            .compare_flags_unsigned => |op| {
                const r = MCValue{
                    .compare_flags_unsigned = switch (op) {
                        .gte => .lt,
                        .gt => .lte,
                        .neq => .eq,
                        .lt => .gte,
                        .lte => .gt,
                        .eq => .neq,
                    },
                };
                break :result r;
            },
            .compare_flags_signed => |op| {
                const r = MCValue{
                    .compare_flags_signed = switch (op) {
                        .gte => .lt,
                        .gt => .lte,
                        .neq => .eq,
                        .lt => .gte,
                        .lte => .gt,
                        .eq => .neq,
                    },
                };
                break :result r;
            },
            else => {
                switch (operand_ty.zigTypeTag()) {
                    .Bool => {
                        const op_reg = switch (operand) {
                            .register => |r| r,
                            else => try self.copyToTmpRegister(operand_ty, operand),
                        };
                        self.register_manager.freezeRegs(&.{op_reg});
                        defer self.register_manager.unfreezeRegs(&.{op_reg});

                        const dest_reg = blk: {
                            if (operand == .register and self.reuseOperand(inst, ty_op.operand, 0, operand)) {
                                break :blk op_reg;
                            }

                            break :blk try self.register_manager.allocReg(null);
                        };

                        _ = try self.addInst(.{
                            .tag = .eor,
                            .data = .{ .rr_op = .{
                                .rd = dest_reg,
                                .rn = op_reg,
                                .op = Instruction.Operand.fromU32(1).?,
                            } },
                        });

                        break :result MCValue{ .register = dest_reg };
                    },
                    .Int => {
                        const int_info = operand_ty.intInfo(self.target.*);
                        if (int_info.bits <= 32) {
                            const op_reg = switch (operand) {
                                .register => |r| r,
                                else => try self.copyToTmpRegister(operand_ty, operand),
                            };
                            self.register_manager.freezeRegs(&.{op_reg});
                            defer self.register_manager.unfreezeRegs(&.{op_reg});

                            const dest_reg = blk: {
                                if (operand == .register and self.reuseOperand(inst, ty_op.operand, 0, operand)) {
                                    break :blk op_reg;
                                }

                                break :blk try self.register_manager.allocReg(null);
                            };

                            _ = try self.addInst(.{
                                .tag = .mvn,
                                .data = .{ .rr_op = .{
                                    .rd = dest_reg,
                                    .rn = undefined,
                                    .op = Instruction.Operand.reg(op_reg, Instruction.Operand.Shift.none),
                                } },
                            });

                            break :result MCValue{ .register = dest_reg };
                        } else {
                            return self.fail("TODO ARM not on integers > u32/i32", .{});
                        }
                    },
                    else => unreachable,
                }
            },
        }
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airMin(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement min for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airMax(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement max for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airSlice(self: *Self, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const ptr = try self.resolveInst(bin_op.lhs);
        const ptr_ty = self.air.typeOf(bin_op.lhs);
        const len = try self.resolveInst(bin_op.rhs);
        const len_ty = self.air.typeOf(bin_op.rhs);

        const stack_offset = try self.allocMem(inst, 8, 8);
        try self.genSetStack(ptr_ty, stack_offset + 4, ptr);
        try self.genSetStack(len_ty, stack_offset, len);
        break :result MCValue{ .stack_offset = stack_offset };
    };
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airBinOp(self: *Self, inst: Air.Inst.Index) !void {
    const tag = self.air.instructions.items(.tag)[inst];
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);
    const lhs_ty = self.air.typeOf(bin_op.lhs);
    const rhs_ty = self.air.typeOf(bin_op.rhs);

    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else try self.binOp(tag, inst, lhs, rhs, lhs_ty, rhs_ty);
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airAddWrap(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement addwrap for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airAddSat(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement add_sat for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airSubWrap(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement subwrap for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airSubSat(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement sub_sat for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airMulWrap(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement mulwrap for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airMulSat(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement mul_sat for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airAddWithOverflow(self: *Self, inst: Air.Inst.Index) !void {
    _ = inst;
    return self.fail("TODO implement airAddWithOverflow for {}", .{self.target.cpu.arch});
}

fn airSubWithOverflow(self: *Self, inst: Air.Inst.Index) !void {
    _ = inst;
    return self.fail("TODO implement airSubWithOverflow for {}", .{self.target.cpu.arch});
}

fn airMulWithOverflow(self: *Self, inst: Air.Inst.Index) !void {
    _ = inst;
    return self.fail("TODO implement airMulWithOverflow for {}", .{self.target.cpu.arch});
}

fn airShlWithOverflow(self: *Self, inst: Air.Inst.Index) !void {
    _ = inst;
    return self.fail("TODO implement airShlWithOverflow for {}", .{self.target.cpu.arch});
}

fn airDiv(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement div for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airRem(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement rem for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airMod(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement mod for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airShlSat(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement shl_sat for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airOptionalPayload(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement .optional_payload for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airOptionalPayloadPtr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement .optional_payload_ptr for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airOptionalPayloadPtrSet(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement .optional_payload_ptr_set for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airUnwrapErrErr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const error_union_ty = self.air.typeOf(ty_op.operand);
        const payload_ty = error_union_ty.errorUnionPayload();
        const mcv = try self.resolveInst(ty_op.operand);
        if (!payload_ty.hasRuntimeBits()) break :result mcv;

        return self.fail("TODO implement unwrap error union error for non-empty payloads", .{});
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airUnwrapErrPayload(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const error_union_ty = self.air.typeOf(ty_op.operand);
        const payload_ty = error_union_ty.errorUnionPayload();
        if (!payload_ty.hasRuntimeBits()) break :result MCValue.none;

        return self.fail("TODO implement unwrap error union payload for non-empty payloads", .{});
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

// *(E!T) -> E
fn airUnwrapErrErrPtr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement unwrap error union error ptr for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

// *(E!T) -> *T
fn airUnwrapErrPayloadPtr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement unwrap error union payload ptr for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airErrUnionPayloadPtrSet(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement .errunion_payload_ptr_set for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airWrapOptional(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const optional_ty = self.air.typeOfIndex(inst);

        // Optional with a zero-bit payload type is just a boolean true
        if (optional_ty.abiSize(self.target.*) == 1)
            break :result MCValue{ .immediate = 1 };

        return self.fail("TODO implement wrap optional for {}", .{self.target.cpu.arch});
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

/// T to E!T
fn airWrapErrUnionPayload(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement wrap errunion payload for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

/// E to E!T
fn airWrapErrUnionErr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const error_union_ty = self.air.getRefType(ty_op.ty);
        const payload_ty = error_union_ty.errorUnionPayload();
        const mcv = try self.resolveInst(ty_op.operand);
        if (!payload_ty.hasRuntimeBits()) break :result mcv;

        return self.fail("TODO implement wrap errunion error for non-empty payloads", .{});
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airSlicePtr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const mcv = try self.resolveInst(ty_op.operand);
        switch (mcv) {
            .dead, .unreach => unreachable,
            .register => unreachable, // a slice doesn't fit in one register
            .stack_argument_offset => |off| {
                break :result MCValue{ .stack_argument_offset = off + 4 };
            },
            .stack_offset => |off| {
                break :result MCValue{ .stack_offset = off + 4 };
            },
            .memory => |addr| {
                break :result MCValue{ .memory = addr };
            },
            else => return self.fail("TODO implement slice_ptr for {}", .{mcv}),
        }
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airSliceLen(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const mcv = try self.resolveInst(ty_op.operand);
        switch (mcv) {
            .dead, .unreach => unreachable,
            .register => unreachable, // a slice doesn't fit in one register
            .stack_argument_offset => |off| {
                break :result MCValue{ .stack_argument_offset = off };
            },
            .stack_offset => |off| {
                break :result MCValue{ .stack_offset = off };
            },
            .memory => |addr| {
                break :result MCValue{ .memory = addr + 4 };
            },
            else => return self.fail("TODO implement slice_len for {}", .{mcv}),
        }
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airPtrSliceLenPtr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const mcv = try self.resolveInst(ty_op.operand);
        switch (mcv) {
            .dead, .unreach => unreachable,
            .ptr_stack_offset => |off| {
                break :result MCValue{ .ptr_stack_offset = off + 4 };
            },
            else => return self.fail("TODO implement ptr_slice_len_ptr for {}", .{mcv}),
        }
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airPtrSlicePtrPtr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const mcv = try self.resolveInst(ty_op.operand);
        switch (mcv) {
            .dead, .unreach => unreachable,
            .ptr_stack_offset => |off| {
                break :result MCValue{ .ptr_stack_offset = off };
            },
            else => return self.fail("TODO implement ptr_slice_ptr_ptr for {}", .{mcv}),
        }
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airSliceElemVal(self: *Self, inst: Air.Inst.Index) !void {
    const is_volatile = false; // TODO
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;

    if (!is_volatile and self.liveness.isUnused(inst)) return self.finishAir(inst, .dead, .{ bin_op.lhs, bin_op.rhs, .none });
    const result: MCValue = result: {
        const slice_mcv = try self.resolveInst(bin_op.lhs);

        // TODO optimize for the case where the index is a constant,
        // i.e. index_mcv == .immediate
        const index_mcv = try self.resolveInst(bin_op.rhs);
        const index_is_register = index_mcv == .register;

        const slice_ty = self.air.typeOf(bin_op.lhs);
        const elem_ty = slice_ty.childType();
        const elem_size = @intCast(u32, elem_ty.abiSize(self.target.*));

        var buf: Type.SlicePtrFieldTypeBuffer = undefined;
        const slice_ptr_field_type = slice_ty.slicePtrFieldType(&buf);

        if (index_is_register) self.register_manager.freezeRegs(&.{index_mcv.register});
        defer if (index_is_register) self.register_manager.unfreezeRegs(&.{index_mcv.register});

        const base_mcv: MCValue = switch (slice_mcv) {
            .stack_offset => |off| .{ .register = try self.copyToTmpRegister(slice_ptr_field_type, .{ .stack_offset = off + 4 }) },
            .stack_argument_offset => |off| .{ .register = try self.copyToTmpRegister(slice_ptr_field_type, .{ .stack_argument_offset = off + 4 }) },
            else => return self.fail("TODO slice_elem_val when slice is {}", .{slice_mcv}),
        };
        self.register_manager.freezeRegs(&.{base_mcv.register});

        switch (elem_size) {
            1, 4 => {
                const dst_reg = try self.register_manager.allocReg(inst);
                const dst_mcv = MCValue{ .register = dst_reg };
                self.register_manager.freezeRegs(&.{dst_reg});
                defer self.register_manager.unfreezeRegs(&.{dst_reg});

                const index_reg: Register = switch (index_mcv) {
                    .register => |reg| reg,
                    else => try self.copyToTmpRegister(Type.usize, index_mcv),
                };
                self.register_manager.freezeRegs(&.{index_reg});
                defer self.register_manager.unfreezeRegs(&.{index_reg});

                const tag: Mir.Inst.Tag = switch (elem_size) {
                    1 => .ldrb,
                    4 => .ldr,
                    else => unreachable,
                };
                const shift: u5 = switch (elem_size) {
                    1 => 0,
                    4 => 2,
                    else => unreachable,
                };

                _ = try self.addInst(.{
                    .tag = tag,
                    .data = .{ .rr_offset = .{
                        .rt = dst_reg,
                        .rn = base_mcv.register,
                        .offset = .{ .offset = Instruction.Offset.reg(index_reg, .{ .lsl = shift }) },
                    } },
                });

                self.register_manager.unfreezeRegs(&.{base_mcv.register});

                break :result dst_mcv;
            },
            else => {
                const dst_mcv = try self.allocRegOrMem(inst, true);

                const offset_mcv = try self.binOp(
                    .mul,
                    null,
                    index_mcv,
                    .{ .immediate = elem_size },
                    Type.usize,
                    Type.usize,
                );
                assert(offset_mcv == .register); // result of multiplication should always be register
                self.register_manager.freezeRegs(&.{offset_mcv.register});

                const addr_mcv = try self.binOp(.add, null, base_mcv, offset_mcv, Type.usize, Type.usize);

                // At this point in time, neither the base register
                // nor the offset register contains any valuable data
                // anymore.
                self.register_manager.unfreezeRegs(&.{ base_mcv.register, offset_mcv.register });

                try self.load(dst_mcv, addr_mcv, slice_ptr_field_type);

                break :result dst_mcv;
            },
        }
    };
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airSliceElemPtr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const extra = self.air.extraData(Air.Bin, ty_pl.payload).data;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement slice_elem_ptr for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ extra.lhs, extra.rhs, .none });
}

fn airArrayElemVal(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement array_elem_val for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airPtrElemVal(self: *Self, inst: Air.Inst.Index) !void {
    const is_volatile = false; // TODO
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (!is_volatile and self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement ptr_elem_val for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airPtrElemPtr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const extra = self.air.extraData(Air.Bin, ty_pl.payload).data;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement ptr_elem_ptr for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ extra.lhs, extra.rhs, .none });
}

fn airSetUnionTag(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    _ = bin_op;
    return self.fail("TODO implement airSetUnionTag for {}", .{self.target.cpu.arch});
    // return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airGetUnionTag(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    _ = ty_op;
    return self.fail("TODO implement airGetUnionTag for {}", .{self.target.cpu.arch});
    // return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airClz(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    _ = ty_op;
    return self.fail("TODO implement airClz for {}", .{self.target.cpu.arch});
    // return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airCtz(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    _ = ty_op;
    return self.fail("TODO implement airCtz for {}", .{self.target.cpu.arch});
    // return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airPopcount(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    _ = ty_op;
    return self.fail("TODO implement airPopcount for {}", .{self.target.cpu.arch});
    // return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airByteSwap(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    _ = ty_op;
    return self.fail("TODO implement airByteSwap for {}", .{self.target.cpu.arch});
    // return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airBitReverse(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    _ = ty_op;
    return self.fail("TODO implement airBitReverse for {}", .{self.target.cpu.arch});
    // return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airUnaryMath(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const result: MCValue = if (self.liveness.isUnused(inst))
        .dead
    else
        return self.fail("TODO implement airUnaryMath for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn reuseOperand(self: *Self, inst: Air.Inst.Index, operand: Air.Inst.Ref, op_index: Liveness.OperandInt, mcv: MCValue) bool {
    if (!self.liveness.operandDies(inst, op_index))
        return false;

    switch (mcv) {
        .register => |reg| {
            // If it's in the registers table, need to associate the register with the
            // new instruction.
            if (reg.allocIndex()) |index| {
                if (!self.register_manager.isRegFree(reg)) {
                    self.register_manager.registers[index] = inst;
                }
            }
            log.debug("%{d} => {} (reused)", .{ inst, reg });
        },
        .stack_offset => |off| {
            log.debug("%{d} => stack offset {d} (reused)", .{ inst, off });
        },
        else => return false,
    }

    // Prevent the operand deaths processing code from deallocating it.
    self.liveness.clearOperandDeath(inst, op_index);

    // That makes us responsible for doing the rest of the stuff that processDeath would have done.
    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
    branch.inst_table.putAssumeCapacity(Air.refToIndex(operand).?, .dead);

    return true;
}

fn load(self: *Self, dst_mcv: MCValue, ptr: MCValue, ptr_ty: Type) InnerError!void {
    const elem_ty = ptr_ty.elemType();
    const elem_size = @intCast(u32, elem_ty.abiSize(self.target.*));

    switch (ptr) {
        .none => unreachable,
        .undef => unreachable,
        .unreach => unreachable,
        .dead => unreachable,
        .compare_flags_unsigned => unreachable,
        .compare_flags_signed => unreachable,
        .immediate => |imm| try self.setRegOrMem(elem_ty, dst_mcv, .{ .memory = imm }),
        .ptr_stack_offset => |off| try self.setRegOrMem(elem_ty, dst_mcv, .{ .stack_offset = off }),
        .ptr_embedded_in_code => |off| {
            try self.setRegOrMem(elem_ty, dst_mcv, .{ .embedded_in_code = off });
        },
        .embedded_in_code => {
            return self.fail("TODO implement loading from MCValue.embedded_in_code", .{});
        },
        .register => |reg| {
            self.register_manager.freezeRegs(&.{reg});
            defer self.register_manager.unfreezeRegs(&.{reg});

            switch (dst_mcv) {
                .dead => unreachable,
                .undef => unreachable,
                .compare_flags_signed, .compare_flags_unsigned => unreachable,
                .embedded_in_code => unreachable,
                .register => |dst_reg| {
                    try self.genLdrRegister(dst_reg, reg, elem_ty);
                },
                .stack_offset => |off| {
                    if (elem_size <= 4) {
                        const tmp_reg = try self.register_manager.allocReg(null);
                        self.register_manager.freezeRegs(&.{tmp_reg});
                        defer self.register_manager.unfreezeRegs(&.{tmp_reg});

                        try self.load(.{ .register = tmp_reg }, ptr, ptr_ty);
                        try self.genSetStack(elem_ty, off, MCValue{ .register = tmp_reg });
                    } else {
                        // TODO optimize the register allocation
                        const regs = try self.register_manager.allocRegs(4, .{ null, null, null, null });
                        self.register_manager.freezeRegs(&regs);
                        defer self.register_manager.unfreezeRegs(&regs);

                        const src_reg = reg;
                        const dst_reg = regs[0];
                        const len_reg = regs[1];
                        const count_reg = regs[2];
                        const tmp_reg = regs[3];

                        // sub dst_reg, fp, #off
                        try self.genSetReg(ptr_ty, dst_reg, .{ .ptr_stack_offset = off });

                        // mov len, #elem_size
                        try self.genSetReg(Type.usize, len_reg, .{ .immediate = elem_size });

                        // memcpy(src, dst, len)
                        try self.genInlineMemcpy(src_reg, dst_reg, len_reg, count_reg, tmp_reg);
                    }
                },
                else => return self.fail("TODO load from register into {}", .{dst_mcv}),
            }
        },
        .memory,
        .stack_offset,
        .stack_argument_offset,
        => {
            const reg = try self.register_manager.allocReg(null);
            self.register_manager.freezeRegs(&.{reg});
            defer self.register_manager.unfreezeRegs(&.{reg});

            try self.genSetReg(ptr_ty, reg, ptr);
            try self.load(dst_mcv, .{ .register = reg }, ptr_ty);
        },
    }
}

fn airLoad(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const elem_ty = self.air.typeOfIndex(inst);
    const result: MCValue = result: {
        if (!elem_ty.hasRuntimeBits())
            break :result MCValue.none;

        const ptr = try self.resolveInst(ty_op.operand);
        const is_volatile = self.air.typeOf(ty_op.operand).isVolatilePtr();
        if (self.liveness.isUnused(inst) and !is_volatile)
            break :result MCValue.dead;

        const dst_mcv: MCValue = blk: {
            if (self.reuseOperand(inst, ty_op.operand, 0, ptr)) {
                // The MCValue that holds the pointer can be re-used as the value.
                break :blk ptr;
            } else {
                break :blk try self.allocRegOrMem(inst, true);
            }
        };
        try self.load(dst_mcv, ptr, self.air.typeOf(ty_op.operand));
        break :result dst_mcv;
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn store(self: *Self, ptr: MCValue, value: MCValue, ptr_ty: Type, value_ty: Type) InnerError!void {
    switch (ptr) {
        .none => unreachable,
        .undef => unreachable,
        .unreach => unreachable,
        .dead => unreachable,
        .compare_flags_unsigned => unreachable,
        .compare_flags_signed => unreachable,
        .immediate => |imm| {
            try self.setRegOrMem(value_ty, .{ .memory = imm }, value);
        },
        .ptr_stack_offset => |off| {
            try self.genSetStack(value_ty, off, value);
        },
        .ptr_embedded_in_code => |off| {
            try self.setRegOrMem(value_ty, .{ .embedded_in_code = off }, value);
        },
        .embedded_in_code => {
            return self.fail("TODO implement storing to MCValue.embedded_in_code", .{});
        },
        .register => |addr_reg| {
            self.register_manager.freezeRegs(&.{addr_reg});
            defer self.register_manager.unfreezeRegs(&.{addr_reg});

            switch (value) {
                .register => |value_reg| {
                    try self.genStrRegister(value_reg, addr_reg, value_ty);
                },
                else => {
                    if (value_ty.abiSize(self.target.*) <= 4) {
                        const tmp_reg = try self.register_manager.allocReg(null);
                        self.register_manager.freezeRegs(&.{tmp_reg});
                        defer self.register_manager.unfreezeRegs(&.{tmp_reg});

                        try self.genSetReg(value_ty, tmp_reg, value);
                        try self.store(ptr, .{ .register = tmp_reg }, ptr_ty, value_ty);
                    } else {
                        return self.fail("TODO implement memcpy", .{});
                    }
                },
            }
        },
        .memory,
        .stack_offset,
        .stack_argument_offset,
        => {
            const addr_reg = try self.copyToTmpRegister(ptr_ty, ptr);
            try self.store(.{ .register = addr_reg }, value, ptr_ty, value_ty);
        },
    }
}

fn airStore(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const ptr = try self.resolveInst(bin_op.lhs);
    const value = try self.resolveInst(bin_op.rhs);
    const ptr_ty = self.air.typeOf(bin_op.lhs);
    const value_ty = self.air.typeOf(bin_op.rhs);

    try self.store(ptr, value, ptr_ty, value_ty);

    return self.finishAir(inst, .dead, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airStructFieldPtr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const extra = self.air.extraData(Air.StructField, ty_pl.payload).data;
    const result = try self.structFieldPtr(inst, extra.struct_operand, extra.field_index);
    return self.finishAir(inst, result, .{ extra.struct_operand, .none, .none });
}

fn airStructFieldPtrIndex(self: *Self, inst: Air.Inst.Index, index: u8) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result = try self.structFieldPtr(inst, ty_op.operand, index);
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn structFieldPtr(self: *Self, inst: Air.Inst.Index, operand: Air.Inst.Ref, index: u32) !MCValue {
    return if (self.liveness.isUnused(inst)) .dead else result: {
        const mcv = try self.resolveInst(operand);
        const ptr_ty = self.air.typeOf(operand);
        const struct_ty = ptr_ty.childType();
        const struct_size = @intCast(u32, struct_ty.abiSize(self.target.*));
        const struct_field_offset = @intCast(u32, struct_ty.structFieldOffset(index, self.target.*));
        const struct_field_ty = struct_ty.structFieldType(index);
        const struct_field_size = @intCast(u32, struct_field_ty.abiSize(self.target.*));
        switch (mcv) {
            .ptr_stack_offset => |off| {
                break :result MCValue{ .ptr_stack_offset = off + struct_size - struct_field_offset - struct_field_size };
            },
            else => {
                const offset_reg = try self.copyToTmpRegister(ptr_ty, .{
                    .immediate = struct_field_offset,
                });
                self.register_manager.freezeRegs(&.{offset_reg});
                defer self.register_manager.unfreezeRegs(&.{offset_reg});

                const addr_reg = try self.copyToTmpRegister(ptr_ty, mcv);
                self.register_manager.freezeRegs(&.{addr_reg});
                defer self.register_manager.unfreezeRegs(&.{addr_reg});

                const dest = try self.binOp(
                    .add,
                    null,
                    .{ .register = addr_reg },
                    .{ .register = offset_reg },
                    Type.usize,
                    Type.usize,
                );

                break :result dest;
            },
        }
    };
}

fn airStructFieldVal(self: *Self, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const extra = self.air.extraData(Air.StructField, ty_pl.payload).data;
    const operand = extra.struct_operand;
    const index = extra.field_index;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const mcv = try self.resolveInst(operand);
        const struct_ty = self.air.typeOf(operand);
        const struct_size = @intCast(u32, struct_ty.abiSize(self.target.*));
        const struct_field_offset = @intCast(u32, struct_ty.structFieldOffset(index, self.target.*));
        const struct_field_ty = struct_ty.structFieldType(index);
        const struct_field_size = @intCast(u32, struct_field_ty.abiSize(self.target.*));
        const adjusted_field_offset = struct_size - struct_field_offset - struct_field_size;

        switch (mcv) {
            .dead, .unreach => unreachable,
            .stack_argument_offset => |off| {
                break :result MCValue{ .stack_argument_offset = off + adjusted_field_offset };
            },
            .stack_offset => |off| {
                break :result MCValue{ .stack_offset = off + adjusted_field_offset };
            },
            .memory => |addr| {
                break :result MCValue{ .memory = addr + adjusted_field_offset };
            },
            else => return self.fail("TODO implement codegen struct_field_val for {}", .{mcv}),
        }
    };

    return self.finishAir(inst, result, .{ extra.struct_operand, .none, .none });
}

fn airFieldParentPtr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement airFieldParentPtr", .{});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

/// Don't call this function directly. Use binOp instead.
///
/// Calling this function signals an intention to generate a Mir
/// instruction of the form
///
///     op dest, lhs, rhs
///
/// Asserts that generating an instruction of that form is possible.
fn binOpRegister(
    self: *Self,
    tag: Air.Inst.Tag,
    maybe_inst: ?Air.Inst.Index,
    lhs: MCValue,
    rhs: MCValue,
    lhs_ty: Type,
    rhs_ty: Type,
) !MCValue {
    const lhs_is_register = lhs == .register;
    const rhs_is_register = rhs == .register;

    if (lhs_is_register) self.register_manager.freezeRegs(&.{lhs.register});
    if (rhs_is_register) self.register_manager.freezeRegs(&.{rhs.register});

    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];

    const lhs_reg = if (lhs_is_register) lhs.register else blk: {
        const track_inst: ?Air.Inst.Index = if (maybe_inst) |inst| inst: {
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            break :inst Air.refToIndex(bin_op.lhs).?;
        } else null;

        const reg = try self.register_manager.allocReg(track_inst);
        self.register_manager.freezeRegs(&.{reg});

        if (track_inst) |inst| branch.inst_table.putAssumeCapacity(inst, .{ .register = reg });

        break :blk reg;
    };
    defer self.register_manager.unfreezeRegs(&.{lhs_reg});

    const rhs_reg = if (rhs_is_register) rhs.register else blk: {
        const track_inst: ?Air.Inst.Index = if (maybe_inst) |inst| inst: {
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            break :inst Air.refToIndex(bin_op.rhs).?;
        } else null;

        const reg = try self.register_manager.allocReg(track_inst);
        self.register_manager.freezeRegs(&.{reg});

        if (track_inst) |inst| branch.inst_table.putAssumeCapacity(inst, .{ .register = reg });

        break :blk reg;
    };
    defer self.register_manager.unfreezeRegs(&.{rhs_reg});

    const dest_reg = switch (tag) {
        .cmp_eq => .r0, // cmp has no destination regardless
        else => if (maybe_inst) |inst| blk: {
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;

            if (lhs_is_register and self.reuseOperand(inst, bin_op.lhs, 0, lhs)) {
                break :blk lhs_reg;
            } else if (rhs_is_register and self.reuseOperand(inst, bin_op.rhs, 1, rhs)) {
                break :blk rhs_reg;
            } else {
                break :blk try self.register_manager.allocReg(inst);
            }
        } else try self.register_manager.allocReg(null),
    };

    if (!lhs_is_register) try self.genSetReg(lhs_ty, lhs_reg, lhs);
    if (!rhs_is_register) try self.genSetReg(rhs_ty, rhs_reg, rhs);

    const mir_tag: Mir.Inst.Tag = switch (tag) {
        .add, .ptr_add => .add,
        .sub, .ptr_sub => .sub,
        .cmp_eq => .cmp,
        .mul => .mul,
        .bit_and,
        .bool_and,
        => .@"and",
        .bit_or,
        .bool_or,
        => .orr,
        .shl,
        .shl_exact,
        => .lsl,
        .shr,
        .shr_exact,
        => switch (lhs_ty.intInfo(self.target.*).signedness) {
            .signed => Mir.Inst.Tag.asr,
            .unsigned => Mir.Inst.Tag.lsr,
        },
        .xor => .eor,
        else => unreachable,
    };
    const mir_data: Mir.Inst.Data = switch (tag) {
        .add,
        .sub,
        .cmp_eq,
        .bit_and,
        .bool_and,
        .bit_or,
        .bool_or,
        .xor,
        .ptr_add,
        .ptr_sub,
        => .{ .rr_op = .{
            .rd = dest_reg,
            .rn = lhs_reg,
            .op = Instruction.Operand.reg(rhs_reg, Instruction.Operand.Shift.none),
        } },
        .shl,
        .shl_exact,
        .shr,
        .shr_exact,
        => .{ .rr_shift = .{
            .rd = dest_reg,
            .rm = lhs_reg,
            .shift_amount = Instruction.ShiftAmount.reg(rhs_reg),
        } },
        .mul => .{ .rrr = .{
            .rd = dest_reg,
            .rn = lhs_reg,
            .rm = rhs_reg,
        } },
        else => unreachable,
    };

    _ = try self.addInst(.{
        .tag = mir_tag,
        .data = mir_data,
    });

    return MCValue{ .register = dest_reg };
}

/// Don't call this function directly. Use binOp instead.
///
/// Calling this function signals an intention to generate a Mir
/// instruction of the form
///
///     op dest, lhs, #rhs_imm
///
/// Set lhs_and_rhs_swapped to true iff inst.bin_op.lhs corresponds to
/// rhs and vice versa. This parameter is only used when maybe_inst !=
/// null.
///
/// Asserts that generating an instruction of that form is possible.
fn binOpImmediate(
    self: *Self,
    tag: Air.Inst.Tag,
    maybe_inst: ?Air.Inst.Index,
    lhs: MCValue,
    rhs: MCValue,
    lhs_ty: Type,
    lhs_and_rhs_swapped: bool,
) !MCValue {
    const lhs_is_register = lhs == .register;

    if (lhs_is_register) self.register_manager.freezeRegs(&.{lhs.register});

    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];

    const lhs_reg = if (lhs_is_register) lhs.register else blk: {
        const track_inst: ?Air.Inst.Index = if (maybe_inst) |inst| inst: {
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;
            break :inst Air.refToIndex(
                if (lhs_and_rhs_swapped) bin_op.rhs else bin_op.lhs,
            ).?;
        } else null;

        const reg = try self.register_manager.allocReg(track_inst);
        self.register_manager.freezeRegs(&.{reg});

        if (track_inst) |inst| branch.inst_table.putAssumeCapacity(inst, .{ .register = reg });

        break :blk reg;
    };
    defer self.register_manager.unfreezeRegs(&.{lhs_reg});

    const dest_reg = switch (tag) {
        .cmp_eq => .r0, // cmp has no destination reg
        else => if (maybe_inst) |inst| blk: {
            const bin_op = self.air.instructions.items(.data)[inst].bin_op;

            if (lhs_is_register and self.reuseOperand(
                inst,
                if (lhs_and_rhs_swapped) bin_op.rhs else bin_op.lhs,
                if (lhs_and_rhs_swapped) 1 else 0,
                lhs,
            )) {
                break :blk lhs_reg;
            } else {
                break :blk try self.register_manager.allocReg(inst);
            }
        } else try self.register_manager.allocReg(null),
    };

    if (!lhs_is_register) try self.genSetReg(lhs_ty, lhs_reg, lhs);

    const mir_tag: Mir.Inst.Tag = switch (tag) {
        .add => .add,
        .sub => .sub,
        .cmp_eq => .cmp,
        .bit_and,
        .bool_and,
        => .@"and",
        .bit_or,
        .bool_or,
        => .orr,
        .shl,
        .shl_exact,
        => .lsl,
        .shr,
        .shr_exact,
        => switch (lhs_ty.intInfo(self.target.*).signedness) {
            .signed => Mir.Inst.Tag.asr,
            .unsigned => Mir.Inst.Tag.lsr,
        },
        .xor => .eor,
        else => unreachable,
    };
    const mir_data: Mir.Inst.Data = switch (tag) {
        .add,
        .sub,
        .cmp_eq,
        .bit_and,
        .bool_and,
        .bit_or,
        .bool_or,
        .xor,
        => .{ .rr_op = .{
            .rd = dest_reg,
            .rn = lhs_reg,
            .op = Instruction.Operand.fromU32(rhs.immediate).?,
        } },
        .shl,
        .shl_exact,
        .shr,
        .shr_exact,
        => .{ .rr_shift = .{
            .rd = dest_reg,
            .rm = lhs_reg,
            .shift_amount = Instruction.ShiftAmount.imm(@intCast(u5, rhs.immediate)),
        } },
        else => unreachable,
    };

    _ = try self.addInst(.{
        .tag = mir_tag,
        .data = mir_data,
    });

    return MCValue{ .register = dest_reg };
}

/// For all your binary operation needs, this function will generate
/// the corresponding Mir instruction(s). Returns the location of the
/// result.
///
/// If the binary operation itself happens to be an Air instruction,
/// pass the corresponding index in the inst parameter. That helps
/// this function do stuff like reusing operands.
///
/// This function does not do any lowering to Mir itself, but instead
/// looks at the lhs and rhs and determines which kind of lowering
/// would be best suitable and then delegates the lowering to other
/// functions.
fn binOp(
    self: *Self,
    tag: Air.Inst.Tag,
    maybe_inst: ?Air.Inst.Index,
    lhs: MCValue,
    rhs: MCValue,
    lhs_ty: Type,
    rhs_ty: Type,
) !MCValue {
    switch (tag) {
        .add,
        .sub,
        .cmp_eq,
        => {
            switch (lhs_ty.zigTypeTag()) {
                .Float => return self.fail("TODO ARM binary operations on floats", .{}),
                .Vector => return self.fail("TODO ARM binary operations on vectors", .{}),
                .Int => {
                    assert(lhs_ty.eql(rhs_ty));
                    const int_info = lhs_ty.intInfo(self.target.*);
                    if (int_info.bits <= 32) {
                        // Only say yes if the operation is
                        // commutative, i.e. we can swap both of the
                        // operands
                        const lhs_immediate_ok = switch (tag) {
                            .add => lhs == .immediate and Instruction.Operand.fromU32(lhs.immediate) != null,
                            .sub,
                            .cmp_eq,
                            => false,
                            else => unreachable,
                        };
                        const rhs_immediate_ok = switch (tag) {
                            .add,
                            .sub,
                            .cmp_eq,
                            => rhs == .immediate and Instruction.Operand.fromU32(rhs.immediate) != null,
                            else => unreachable,
                        };

                        if (rhs_immediate_ok) {
                            return try self.binOpImmediate(tag, maybe_inst, lhs, rhs, lhs_ty, false);
                        } else if (lhs_immediate_ok) {
                            // swap lhs and rhs
                            return try self.binOpImmediate(tag, maybe_inst, rhs, lhs, rhs_ty, true);
                        } else {
                            return try self.binOpRegister(tag, maybe_inst, lhs, rhs, lhs_ty, rhs_ty);
                        }
                    } else {
                        return self.fail("TODO ARM binary operations on integers > u32/i32", .{});
                    }
                },
                else => unreachable,
            }
        },
        .mul => {
            switch (lhs_ty.zigTypeTag()) {
                .Float => return self.fail("TODO ARM binary operations on floats", .{}),
                .Vector => return self.fail("TODO ARM binary operations on vectors", .{}),
                .Int => {
                    assert(lhs_ty.eql(rhs_ty));
                    const int_info = lhs_ty.intInfo(self.target.*);
                    if (int_info.bits <= 32) {
                        // TODO add optimisations for multiplication
                        // with immediates, for example a * 2 can be
                        // lowered to a << 1
                        return try self.binOpRegister(tag, maybe_inst, lhs, rhs, lhs_ty, rhs_ty);
                    } else {
                        return self.fail("TODO ARM binary operations on integers > u32/i32", .{});
                    }
                },
                else => unreachable,
            }
        },
        .bit_and,
        .bit_or,
        .xor,
        => {
            switch (lhs_ty.zigTypeTag()) {
                .Vector => return self.fail("TODO ARM binary operations on vectors", .{}),
                .Int => {
                    assert(lhs_ty.eql(rhs_ty));
                    const int_info = lhs_ty.intInfo(self.target.*);
                    if (int_info.bits <= 32) {
                        const lhs_immediate_ok = lhs == .immediate and Instruction.Operand.fromU32(lhs.immediate) != null;
                        const rhs_immediate_ok = rhs == .immediate and Instruction.Operand.fromU32(rhs.immediate) != null;

                        if (rhs_immediate_ok) {
                            return try self.binOpImmediate(tag, maybe_inst, lhs, rhs, lhs_ty, false);
                        } else if (lhs_immediate_ok) {
                            // swap lhs and rhs
                            return try self.binOpImmediate(tag, maybe_inst, rhs, lhs, rhs_ty, true);
                        } else {
                            return try self.binOpRegister(tag, maybe_inst, lhs, rhs, lhs_ty, rhs_ty);
                        }
                    } else {
                        return self.fail("TODO ARM binary operations on integers > u32/i32", .{});
                    }
                },
                else => unreachable,
            }
        },
        .shl,
        .shr,
        => {
            switch (lhs_ty.zigTypeTag()) {
                .Vector => return self.fail("TODO ARM binary operations on vectors", .{}),
                .Int => {
                    const int_info = lhs_ty.intInfo(self.target.*);
                    if (int_info.bits <= 32) {
                        const rhs_immediate_ok = rhs == .immediate;

                        if (rhs_immediate_ok) {
                            return try self.binOpImmediate(tag, maybe_inst, lhs, rhs, lhs_ty, false);
                        } else {
                            return try self.binOpRegister(tag, maybe_inst, lhs, rhs, lhs_ty, rhs_ty);
                        }
                    } else {
                        return self.fail("TODO ARM binary operations on integers > u32/i32", .{});
                    }
                },
                else => unreachable,
            }
        },
        .bool_and,
        .bool_or,
        => {
            switch (lhs_ty.zigTypeTag()) {
                .Bool => {
                    const lhs_immediate_ok = lhs == .immediate;
                    const rhs_immediate_ok = rhs == .immediate;

                    if (rhs_immediate_ok) {
                        return try self.binOpImmediate(tag, maybe_inst, lhs, rhs, lhs_ty, false);
                    } else if (lhs_immediate_ok) {
                        // swap lhs and rhs
                        return try self.binOpImmediate(tag, maybe_inst, rhs, lhs, rhs_ty, true);
                    } else {
                        return try self.binOpRegister(tag, maybe_inst, lhs, rhs, lhs_ty, rhs_ty);
                    }
                },
                else => unreachable,
            }
        },
        .ptr_add,
        .ptr_sub,
        => {
            switch (lhs_ty.zigTypeTag()) {
                .Pointer => {
                    const ptr_ty = lhs_ty;
                    const pointee_ty = switch (ptr_ty.ptrSize()) {
                        .One => ptr_ty.childType().childType(), // ptr to array, so get array element type
                        else => ptr_ty.childType(),
                    };

                    if (pointee_ty.abiSize(self.target.*) > 1) {
                        return self.fail("TODO ptr_add, ptr_sub with more element sizes", .{});
                    }

                    return try self.binOpRegister(tag, maybe_inst, lhs, rhs, lhs_ty, rhs_ty);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

fn genLdrRegister(self: *Self, dest_reg: Register, addr_reg: Register, ty: Type) !void {
    const abi_size = ty.abiSize(self.target.*);

    const tag: Mir.Inst.Tag = switch (abi_size) {
        1 => if (ty.isSignedInt()) Mir.Inst.Tag.ldrsb else .ldrb,
        2 => if (ty.isSignedInt()) Mir.Inst.Tag.ldrsh else .ldrh,
        3, 4 => .ldr,
        else => unreachable,
    };

    const rr_offset: Mir.Inst.Data = .{ .rr_offset = .{
        .rt = dest_reg,
        .rn = addr_reg,
        .offset = .{ .offset = Instruction.Offset.none },
    } };
    const rr_extra_offset: Mir.Inst.Data = .{ .rr_extra_offset = .{
        .rt = dest_reg,
        .rn = addr_reg,
        .offset = .{ .offset = Instruction.ExtraLoadStoreOffset.none },
    } };

    const data: Mir.Inst.Data = switch (abi_size) {
        1 => if (ty.isSignedInt()) rr_extra_offset else rr_offset,
        2 => rr_extra_offset,
        3, 4 => rr_offset,
        else => unreachable,
    };

    _ = try self.addInst(.{
        .tag = tag,
        .data = data,
    });
}

fn genStrRegister(self: *Self, source_reg: Register, addr_reg: Register, ty: Type) !void {
    const abi_size = ty.abiSize(self.target.*);

    const tag: Mir.Inst.Tag = switch (abi_size) {
        1 => .strb,
        2 => .strh,
        3, 4 => .str,
        else => unreachable,
    };

    const rr_offset: Mir.Inst.Data = .{ .rr_offset = .{
        .rt = source_reg,
        .rn = addr_reg,
        .offset = .{ .offset = Instruction.Offset.none },
    } };
    const rr_extra_offset: Mir.Inst.Data = .{ .rr_extra_offset = .{
        .rt = source_reg,
        .rn = addr_reg,
        .offset = .{ .offset = Instruction.ExtraLoadStoreOffset.none },
    } };

    const data: Mir.Inst.Data = switch (abi_size) {
        1, 3, 4 => rr_offset,
        2 => rr_extra_offset,
        else => unreachable,
    };

    _ = try self.addInst(.{
        .tag = tag,
        .data = data,
    });
}

fn genInlineMemcpy(
    self: *Self,
    src: Register,
    dst: Register,
    len: Register,
    count: Register,
    tmp: Register,
) !void {
    // mov count, #0
    _ = try self.addInst(.{
        .tag = .mov,
        .data = .{ .rr_op = .{
            .rd = count,
            .rn = .r0,
            .op = Instruction.Operand.imm(0, 0),
        } },
    });

    // loop:
    // cmp count, len
    _ = try self.addInst(.{
        .tag = .cmp,
        .data = .{ .rr_op = .{
            .rd = .r0,
            .rn = count,
            .op = Instruction.Operand.reg(len, Instruction.Operand.Shift.none),
        } },
    });

    // bge end
    _ = try self.addInst(.{
        .tag = .b,
        .cond = .ge,
        .data = .{ .inst = @intCast(u32, self.mir_instructions.len + 5) },
    });

    // ldrb tmp, [src, count]
    _ = try self.addInst(.{
        .tag = .ldrb,
        .data = .{ .rr_offset = .{
            .rt = tmp,
            .rn = src,
            .offset = .{ .offset = Instruction.Offset.reg(count, .none) },
        } },
    });

    // strb tmp, [src, count]
    _ = try self.addInst(.{
        .tag = .strb,
        .data = .{ .rr_offset = .{
            .rt = tmp,
            .rn = dst,
            .offset = .{ .offset = Instruction.Offset.reg(count, .none) },
        } },
    });

    // add count, count, #1
    _ = try self.addInst(.{
        .tag = .add,
        .data = .{ .rr_op = .{
            .rd = count,
            .rn = count,
            .op = Instruction.Operand.imm(1, 0),
        } },
    });

    // b loop
    _ = try self.addInst(.{
        .tag = .b,
        .data = .{ .inst = @intCast(u32, self.mir_instructions.len - 5) },
    });

    // end:
}

fn airArg(self: *Self, inst: Air.Inst.Index) !void {
    const arg_index = self.arg_index;
    self.arg_index += 1;

    const ty = self.air.typeOfIndex(inst);

    const result = self.args[arg_index];
    const mcv = switch (result) {
        // Copy registers to the stack
        .register => |reg| blk: {
            const abi_size = math.cast(u32, ty.abiSize(self.target.*)) catch {
                return self.fail("type '{}' too big to fit into stack frame", .{ty});
            };
            const abi_align = ty.abiAlignment(self.target.*);
            const stack_offset = try self.allocMem(inst, abi_size, abi_align);
            try self.genSetStack(ty, stack_offset, MCValue{ .register = reg });

            break :blk MCValue{ .stack_offset = stack_offset };
        },
        else => result,
    };

    _ = try self.addInst(.{
        .tag = .dbg_arg,
        .cond = undefined,
        .data = .{ .dbg_arg_info = .{
            .air_inst = inst,
            .arg_index = arg_index,
        } },
    });

    if (self.liveness.isUnused(inst))
        return self.finishAirBookkeeping();

    switch (mcv) {
        .register => |reg| {
            self.register_manager.getRegAssumeFree(reg, inst);
        },
        else => {},
    }

    return self.finishAir(inst, mcv, .{ .none, .none, .none });
}

fn airBreakpoint(self: *Self) !void {
    _ = try self.addInst(.{
        .tag = .bkpt,
        .data = .{ .imm16 = 0 },
    });
    return self.finishAirBookkeeping();
}

fn airRetAddr(self: *Self) !void {
    return self.fail("TODO implement airRetAddr for {}", .{self.target.cpu.arch});
}

fn airFence(self: *Self) !void {
    return self.fail("TODO implement fence() for {}", .{self.target.cpu.arch});
    //return self.finishAirBookkeeping();
}

fn airCall(self: *Self, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[inst].pl_op;
    const callee = pl_op.operand;
    const extra = self.air.extraData(Air.Call, pl_op.payload);
    const args = @bitCast([]const Air.Inst.Ref, self.air.extra[extra.end..][0..extra.data.args_len]);
    const ty = self.air.typeOf(callee);

    const fn_ty = switch (ty.zigTypeTag()) {
        .Fn => ty,
        .Pointer => ty.childType(),
        else => unreachable,
    };

    var info = try self.resolveCallingConventionValues(fn_ty);
    defer info.deinit(self);

    // According to the Procedure Call Standard for the ARM
    // Architecture, compare flags are not preserved across
    // calls. Therefore, if some value is currently stored there, we
    // need to save it.
    //
    // TODO once caller-saved registers are implemented, save them
    // here too, but crucially *after* we save the compare flags as
    // saving compare flags may require a new caller-saved register
    try self.spillCompareFlagsIfOccupied();

    // Make space for the arguments passed via the stack
    self.max_end_stack += info.stack_byte_count;

    // Due to incremental compilation, how function calls are generated depends
    // on linking.
    if (self.bin_file.tag == link.File.Elf.base_tag or self.bin_file.tag == link.File.Coff.base_tag) {
        for (info.args) |mc_arg, arg_i| {
            const arg = args[arg_i];
            const arg_ty = self.air.typeOf(arg);
            const arg_mcv = try self.resolveInst(args[arg_i]);

            switch (mc_arg) {
                .none => continue,
                .undef => unreachable,
                .immediate => unreachable,
                .unreach => unreachable,
                .dead => unreachable,
                .embedded_in_code => unreachable,
                .memory => unreachable,
                .compare_flags_signed => unreachable,
                .compare_flags_unsigned => unreachable,
                .ptr_stack_offset => unreachable,
                .ptr_embedded_in_code => unreachable,
                .register => |reg| {
                    try self.register_manager.getReg(reg, null);
                    try self.genSetReg(arg_ty, reg, arg_mcv);
                },
                .stack_offset => unreachable,
                .stack_argument_offset => |offset| try self.genSetStackArgument(
                    arg_ty,
                    info.stack_byte_count - offset,
                    arg_mcv,
                ),
            }
        }

        if (self.air.value(callee)) |func_value| {
            if (func_value.castTag(.function)) |func_payload| {
                const func = func_payload.data;
                const ptr_bits = self.target.cpu.arch.ptrBitWidth();
                const ptr_bytes: u64 = @divExact(ptr_bits, 8);
                const got_addr = if (self.bin_file.cast(link.File.Elf)) |elf_file| blk: {
                    const got = &elf_file.program_headers.items[elf_file.phdr_got_index.?];
                    break :blk @intCast(u32, got.p_vaddr + func.owner_decl.link.elf.offset_table_index * ptr_bytes);
                } else if (self.bin_file.cast(link.File.Coff)) |coff_file|
                    coff_file.offset_table_virtual_address + func.owner_decl.link.coff.offset_table_index * ptr_bytes
                else
                    unreachable;

                try self.genSetReg(Type.initTag(.usize), .lr, .{ .memory = got_addr });
            } else if (func_value.castTag(.extern_fn)) |_| {
                return self.fail("TODO implement calling extern functions", .{});
            } else {
                return self.fail("TODO implement calling bitcasted functions", .{});
            }
        } else {
            assert(ty.zigTypeTag() == .Pointer);
            const mcv = try self.resolveInst(callee);

            try self.genSetReg(Type.initTag(.usize), .lr, mcv);
        }

        // TODO: add Instruction.supportedOn
        // function for ARM
        if (Target.arm.featureSetHas(self.target.cpu.features, .has_v5t)) {
            _ = try self.addInst(.{
                .tag = .blx,
                .data = .{ .reg = .lr },
            });
        } else {
            return self.fail("TODO fix blx emulation for ARM <v5", .{});
            // _ = try self.addInst(.{
            //     .tag = .mov,
            //     .data = .{ .rr_op = .{
            //         .rd = .lr,
            //         .rn = .r0,
            //         .op = Instruction.Operand.reg(.pc, Instruction.Operand.Shift.none),
            //     } },
            // });
            // _ = try self.addInst(.{
            //     .tag = .bx,
            //     .data = .{ .reg = .lr },
            // });
        }
    } else if (self.bin_file.cast(link.File.MachO)) |_| {
        unreachable; // unsupported architecture for MachO
    } else if (self.bin_file.cast(link.File.Plan9)) |_| {
        return self.fail("TODO implement call on plan9 for {}", .{self.target.cpu.arch});
    } else unreachable;

    const result: MCValue = result: {
        switch (info.return_value) {
            .register => |reg| {
                if (Register.allocIndex(reg) == null) {
                    // Save function return value in a callee saved register
                    break :result try self.copyToNewRegister(inst, info.return_value);
                }
            },
            else => {},
        }
        break :result info.return_value;
    };

    if (args.len <= Liveness.bpi - 2) {
        var buf = [1]Air.Inst.Ref{.none} ** (Liveness.bpi - 1);
        buf[0] = callee;
        std.mem.copy(Air.Inst.Ref, buf[1..], args);
        return self.finishAir(inst, result, buf);
    }
    var bt = try self.iterateBigTomb(inst, 1 + args.len);
    bt.feed(callee);
    for (args) |arg| {
        bt.feed(arg);
    }
    return bt.finishAir(result);
}

fn ret(self: *Self, mcv: MCValue) !void {
    const ret_ty = self.fn_type.fnReturnType();
    try self.setRegOrMem(ret_ty, self.ret_mcv, mcv);

    // Just add space for an instruction, patch this later
    try self.exitlude_jump_relocs.append(self.gpa, try self.addNop());
}

fn airRet(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const operand = try self.resolveInst(un_op);
    try self.ret(operand);
    return self.finishAir(inst, .dead, .{ un_op, .none, .none });
}

fn airRetLoad(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const ptr = try self.resolveInst(un_op);
    _ = ptr;
    return self.fail("TODO implement airRetLoad for {}", .{self.target.cpu.arch});
    //return self.finishAir(inst, .dead, .{ un_op, .none, .none });
}

fn airCmp(self: *Self, inst: Air.Inst.Index, op: math.CompareOperator) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const lhs_ty = self.air.typeOf(bin_op.lhs);

        switch (lhs_ty.zigTypeTag()) {
            .Vector => return self.fail("TODO ARM cmp vectors", .{}),
            .Optional => return self.fail("TODO ARM cmp optionals", .{}),
            .Float => return self.fail("TODO ARM cmp floats", .{}),
            .Int, .Bool, .Pointer, .ErrorSet, .Enum => {
                var int_buffer: Type.Payload.Bits = undefined;
                const int_ty = switch (lhs_ty.zigTypeTag()) {
                    .Enum => lhs_ty.intTagType(&int_buffer),
                    .Int => lhs_ty,
                    .Bool => Type.initTag(.u1),
                    .Pointer => Type.usize,
                    .ErrorSet => Type.initTag(.u16),
                    else => unreachable,
                };

                const int_info = int_ty.intInfo(self.target.*);
                if (int_info.bits <= 32) {
                    try self.spillCompareFlagsIfOccupied();
                    self.compare_flags_inst = inst;

                    _ = try self.binOp(.cmp_eq, inst, lhs, rhs, int_ty, int_ty);

                    break :result switch (int_info.signedness) {
                        .signed => MCValue{ .compare_flags_signed = op },
                        .unsigned => MCValue{ .compare_flags_unsigned = op },
                    };
                } else {
                    return self.fail("TODO ARM cmp for ints > 32 bits", .{});
                }
            },
            else => unreachable,
        }
    };
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airDbgStmt(self: *Self, inst: Air.Inst.Index) !void {
    const dbg_stmt = self.air.instructions.items(.data)[inst].dbg_stmt;

    _ = try self.addInst(.{
        .tag = .dbg_line,
        .cond = undefined,
        .data = .{ .dbg_line_column = .{
            .line = dbg_stmt.line,
            .column = dbg_stmt.column,
        } },
    });

    return self.finishAirBookkeeping();
}

fn airCondBr(self: *Self, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[inst].pl_op;
    const cond = try self.resolveInst(pl_op.operand);
    const extra = self.air.extraData(Air.CondBr, pl_op.payload);
    const then_body = self.air.extra[extra.end..][0..extra.data.then_body_len];
    const else_body = self.air.extra[extra.end + then_body.len ..][0..extra.data.else_body_len];
    const liveness_condbr = self.liveness.getCondBr(inst);

    const reloc: Mir.Inst.Index = reloc: {
        const condition: Condition = switch (cond) {
            .compare_flags_signed => |cmp_op| blk: {
                // Here we map to the opposite condition because the jump is to the false branch.
                const condition = Condition.fromCompareOperatorSigned(cmp_op);
                break :blk condition.negate();
            },
            .compare_flags_unsigned => |cmp_op| blk: {
                // Here we map to the opposite condition because the jump is to the false branch.
                const condition = Condition.fromCompareOperatorUnsigned(cmp_op);
                break :blk condition.negate();
            },
            .register => |reg| blk: {
                try self.spillCompareFlagsIfOccupied();

                // cmp reg, 1
                // bne ...
                _ = try self.addInst(.{
                    .tag = .cmp,
                    .cond = .al,
                    .data = .{ .rr_op = .{
                        .rd = .r0,
                        .rn = reg,
                        .op = Instruction.Operand.imm(1, 0),
                    } },
                });

                break :blk .ne;
            },
            .stack_offset,
            .memory,
            .stack_argument_offset,
            => blk: {
                try self.spillCompareFlagsIfOccupied();

                const reg = try self.copyToTmpRegister(Type.initTag(.bool), cond);

                // cmp reg, 1
                // bne ...
                _ = try self.addInst(.{
                    .tag = .cmp,
                    .data = .{ .rr_op = .{
                        .rd = .r0,
                        .rn = reg,
                        .op = Instruction.Operand.imm(1, 0),
                    } },
                });

                break :blk .ne;
            },
            else => return self.fail("TODO implement condbr {} when condition is {s}", .{ self.target.cpu.arch, @tagName(cond) }),
        };

        break :reloc try self.addInst(.{
            .tag = .b,
            .cond = condition,
            .data = .{ .inst = undefined }, // populated later through performReloc
        });
    };

    // If the condition dies here in this condbr instruction, process
    // that death now instead of later as this has an effect on
    // whether it needs to be spilled in the branches
    if (self.liveness.operandDies(inst, 0)) {
        const op_int = @enumToInt(pl_op.operand);
        if (op_int >= Air.Inst.Ref.typed_value_map.len) {
            const op_index = @intCast(Air.Inst.Index, op_int - Air.Inst.Ref.typed_value_map.len);
            self.processDeath(op_index);
        }
    }

    // Capture the state of register and stack allocation state so that we can revert to it.
    const parent_next_stack_offset = self.next_stack_offset;
    const parent_free_registers = self.register_manager.free_registers;
    var parent_stack = try self.stack.clone(self.gpa);
    defer parent_stack.deinit(self.gpa);
    const parent_registers = self.register_manager.registers;
    const parent_compare_flags_inst = self.compare_flags_inst;

    try self.branch_stack.append(.{});

    try self.ensureProcessDeathCapacity(liveness_condbr.then_deaths.len);
    for (liveness_condbr.then_deaths) |operand| {
        self.processDeath(operand);
    }
    try self.genBody(then_body);

    // Revert to the previous register and stack allocation state.

    var saved_then_branch = self.branch_stack.pop();
    defer saved_then_branch.deinit(self.gpa);

    self.register_manager.registers = parent_registers;
    self.compare_flags_inst = parent_compare_flags_inst;

    self.stack.deinit(self.gpa);
    self.stack = parent_stack;
    parent_stack = .{};

    self.next_stack_offset = parent_next_stack_offset;
    self.register_manager.free_registers = parent_free_registers;

    try self.performReloc(reloc);
    const else_branch = self.branch_stack.addOneAssumeCapacity();
    else_branch.* = .{};

    try self.ensureProcessDeathCapacity(liveness_condbr.else_deaths.len);
    for (liveness_condbr.else_deaths) |operand| {
        self.processDeath(operand);
    }
    try self.genBody(else_body);

    // At this point, each branch will possibly have conflicting values for where
    // each instruction is stored. They agree, however, on which instructions are alive/dead.
    // We use the first ("then") branch as canonical, and here emit
    // instructions into the second ("else") branch to make it conform.
    // We continue respect the data structure semantic guarantees of the else_branch so
    // that we can use all the code emitting abstractions. This is why at the bottom we
    // assert that parent_branch.free_registers equals the saved_then_branch.free_registers
    // rather than assigning it.
    const parent_branch = &self.branch_stack.items[self.branch_stack.items.len - 2];
    try parent_branch.inst_table.ensureUnusedCapacity(self.gpa, else_branch.inst_table.count());

    const else_slice = else_branch.inst_table.entries.slice();
    const else_keys = else_slice.items(.key);
    const else_values = else_slice.items(.value);
    for (else_keys) |else_key, else_idx| {
        const else_value = else_values[else_idx];
        const canon_mcv = if (saved_then_branch.inst_table.fetchSwapRemove(else_key)) |then_entry| blk: {
            // The instruction's MCValue is overridden in both branches.
            parent_branch.inst_table.putAssumeCapacity(else_key, then_entry.value);
            if (else_value == .dead) {
                assert(then_entry.value == .dead);
                continue;
            }
            break :blk then_entry.value;
        } else blk: {
            if (else_value == .dead)
                continue;
            // The instruction is only overridden in the else branch.
            var i: usize = self.branch_stack.items.len - 2;
            while (true) {
                i -= 1; // If this overflows, the question is: why wasn't the instruction marked dead?
                if (self.branch_stack.items[i].inst_table.get(else_key)) |mcv| {
                    assert(mcv != .dead);
                    break :blk mcv;
                }
            }
        };
        log.debug("consolidating else_entry {d} {}=>{}", .{ else_key, else_value, canon_mcv });
        // TODO make sure the destination stack offset / register does not already have something
        // going on there.
        try self.setRegOrMem(self.air.typeOfIndex(else_key), canon_mcv, else_value);
        // TODO track the new register / stack allocation
    }
    try parent_branch.inst_table.ensureUnusedCapacity(self.gpa, saved_then_branch.inst_table.count());
    const then_slice = saved_then_branch.inst_table.entries.slice();
    const then_keys = then_slice.items(.key);
    const then_values = then_slice.items(.value);
    for (then_keys) |then_key, then_idx| {
        const then_value = then_values[then_idx];
        // We already deleted the items from this table that matched the else_branch.
        // So these are all instructions that are only overridden in the then branch.
        parent_branch.inst_table.putAssumeCapacity(then_key, then_value);
        if (then_value == .dead)
            continue;
        const parent_mcv = blk: {
            var i: usize = self.branch_stack.items.len - 2;
            while (true) {
                i -= 1;
                if (self.branch_stack.items[i].inst_table.get(then_key)) |mcv| {
                    assert(mcv != .dead);
                    break :blk mcv;
                }
            }
        };
        log.debug("consolidating then_entry {d} {}=>{}", .{ then_key, parent_mcv, then_value });
        // TODO make sure the destination stack offset / register does not already have something
        // going on there.
        try self.setRegOrMem(self.air.typeOfIndex(then_key), parent_mcv, then_value);
        // TODO track the new register / stack allocation
    }

    self.branch_stack.pop().deinit(self.gpa);

    // We already took care of pl_op.operand earlier, so we're going
    // to pass .none here
    return self.finishAir(inst, .unreach, .{ .none, .none, .none });
}

fn isNull(self: *Self, ty: Type, operand: MCValue) !MCValue {
    if (ty.isPtrLikeOptional()) {
        assert(ty.abiSize(self.target.*) == 4);

        const reg_mcv: MCValue = switch (operand) {
            .register => operand,
            else => .{ .register = try self.copyToTmpRegister(ty, operand) },
        };

        _ = try self.addInst(.{
            .tag = .cmp,
            .data = .{ .rr_op = .{
                .rd = undefined,
                .rn = reg_mcv.register,
                .op = Instruction.Operand.fromU32(0).?,
            } },
        });

        return MCValue{ .compare_flags_unsigned = .eq };
    } else {
        return self.fail("TODO implement non-pointer optionals", .{});
    }
}

fn isNonNull(self: *Self, ty: Type, operand: MCValue) !MCValue {
    const is_null_result = try self.isNull(ty, operand);
    assert(is_null_result.compare_flags_unsigned == .eq);

    return MCValue{ .compare_flags_unsigned = .neq };
}

fn isErr(self: *Self, ty: Type, operand: MCValue) !MCValue {
    const error_type = ty.errorUnionSet();
    const payload_type = ty.errorUnionPayload();

    if (!error_type.hasRuntimeBits()) {
        return MCValue{ .immediate = 0 }; // always false
    } else if (!payload_type.hasRuntimeBits()) {
        if (error_type.abiSize(self.target.*) <= 4) {
            const reg_mcv: MCValue = switch (operand) {
                .register => operand,
                else => .{ .register = try self.copyToTmpRegister(error_type, operand) },
            };

            _ = try self.addInst(.{
                .tag = .cmp,
                .data = .{ .rr_op = .{
                    .rd = undefined,
                    .rn = reg_mcv.register,
                    .op = Instruction.Operand.fromU32(0).?,
                } },
            });

            return MCValue{ .compare_flags_unsigned = .gt };
        } else {
            return self.fail("TODO isErr for errors with size > 4", .{});
        }
    } else {
        return self.fail("TODO isErr for non-empty payloads", .{});
    }
}

fn isNonErr(self: *Self, ty: Type, operand: MCValue) !MCValue {
    const is_err_result = try self.isErr(ty, operand);
    switch (is_err_result) {
        .compare_flags_unsigned => |op| {
            assert(op == .gt);
            return MCValue{ .compare_flags_unsigned = .lte };
        },
        .immediate => |imm| {
            assert(imm == 0);
            return MCValue{ .immediate = 1 };
        },
        else => unreachable,
    }
}

fn airIsNull(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;

    try self.spillCompareFlagsIfOccupied();
    self.compare_flags_inst = inst;

    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const operand = try self.resolveInst(un_op);
        const ty = self.air.typeOf(un_op);
        break :result try self.isNull(ty, operand);
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airIsNullPtr(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const operand_ptr = try self.resolveInst(un_op);
        const ptr_ty = self.air.typeOf(un_op);
        const operand: MCValue = blk: {
            if (self.reuseOperand(inst, un_op, 0, operand_ptr)) {
                // The MCValue that holds the pointer can be re-used as the value.
                break :blk operand_ptr;
            } else {
                break :blk try self.allocRegOrMem(inst, true);
            }
        };
        try self.load(operand, operand_ptr, ptr_ty);
        break :result try self.isNull(ptr_ty.elemType(), operand);
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airIsNonNull(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const operand = try self.resolveInst(un_op);
        const ty = self.air.typeOf(un_op);
        break :result try self.isNonNull(ty, operand);
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airIsNonNullPtr(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const operand_ptr = try self.resolveInst(un_op);
        const ptr_ty = self.air.typeOf(un_op);
        const operand: MCValue = blk: {
            if (self.reuseOperand(inst, un_op, 0, operand_ptr)) {
                // The MCValue that holds the pointer can be re-used as the value.
                break :blk operand_ptr;
            } else {
                break :blk try self.allocRegOrMem(inst, true);
            }
        };
        try self.load(operand, operand_ptr, ptr_ty);
        break :result try self.isNonNull(ptr_ty.elemType(), operand);
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airIsErr(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const operand = try self.resolveInst(un_op);
        const ty = self.air.typeOf(un_op);
        break :result try self.isErr(ty, operand);
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airIsErrPtr(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const operand_ptr = try self.resolveInst(un_op);
        const ptr_ty = self.air.typeOf(un_op);
        const operand: MCValue = blk: {
            if (self.reuseOperand(inst, un_op, 0, operand_ptr)) {
                // The MCValue that holds the pointer can be re-used as the value.
                break :blk operand_ptr;
            } else {
                break :blk try self.allocRegOrMem(inst, true);
            }
        };
        try self.load(operand, operand_ptr, ptr_ty);
        break :result try self.isErr(ptr_ty.elemType(), operand);
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airIsNonErr(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const operand = try self.resolveInst(un_op);
        const ty = self.air.typeOf(un_op);
        break :result try self.isNonErr(ty, operand);
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airIsNonErrPtr(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const operand_ptr = try self.resolveInst(un_op);
        const ptr_ty = self.air.typeOf(un_op);
        const operand: MCValue = blk: {
            if (self.reuseOperand(inst, un_op, 0, operand_ptr)) {
                // The MCValue that holds the pointer can be re-used as the value.
                break :blk operand_ptr;
            } else {
                break :blk try self.allocRegOrMem(inst, true);
            }
        };
        try self.load(operand, operand_ptr, ptr_ty);
        break :result try self.isNonErr(ptr_ty.elemType(), operand);
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airLoop(self: *Self, inst: Air.Inst.Index) !void {
    // A loop is a setup to be able to jump back to the beginning.
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const loop = self.air.extraData(Air.Block, ty_pl.payload);
    const body = self.air.extra[loop.end..][0..loop.data.body_len];
    const start_index = @intCast(Mir.Inst.Index, self.mir_instructions.len);
    try self.genBody(body);
    try self.jump(start_index);
    return self.finishAirBookkeeping();
}

/// Send control flow to `inst`.
fn jump(self: *Self, inst: Mir.Inst.Index) !void {
    _ = try self.addInst(.{
        .tag = .b,
        .data = .{ .inst = inst },
    });
}

fn airBlock(self: *Self, inst: Air.Inst.Index) !void {
    try self.blocks.putNoClobber(self.gpa, inst, .{
        // A block is a setup to be able to jump to the end.
        .relocs = .{},
        // It also acts as a receptacle for break operands.
        // Here we use `MCValue.none` to represent a null value so that the first
        // break instruction will choose a MCValue for the block result and overwrite
        // this field. Following break instructions will use that MCValue to put their
        // block results.
        .mcv = MCValue{ .none = {} },
    });
    defer self.blocks.getPtr(inst).?.relocs.deinit(self.gpa);

    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const extra = self.air.extraData(Air.Block, ty_pl.payload);
    const body = self.air.extra[extra.end..][0..extra.data.body_len];
    try self.genBody(body);

    for (self.blocks.getPtr(inst).?.relocs.items) |reloc| try self.performReloc(reloc);

    const result = self.blocks.getPtr(inst).?.mcv;
    return self.finishAir(inst, result, .{ .none, .none, .none });
}

fn airSwitch(self: *Self, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[inst].pl_op;
    const condition = pl_op.operand;
    _ = condition;
    return self.fail("TODO airSwitch for {}", .{self.target.cpu.arch});
    // return self.finishAir(inst, .dead, .{ condition, .none, .none });
}

fn performReloc(self: *Self, inst: Mir.Inst.Index) !void {
    const tag = self.mir_instructions.items(.tag)[inst];
    switch (tag) {
        .b => self.mir_instructions.items(.data)[inst].inst = @intCast(Air.Inst.Index, self.mir_instructions.len),
        else => unreachable,
    }
}

fn airBr(self: *Self, inst: Air.Inst.Index) !void {
    const branch = self.air.instructions.items(.data)[inst].br;
    try self.br(branch.block_inst, branch.operand);
    return self.finishAir(inst, .dead, .{ branch.operand, .none, .none });
}

fn br(self: *Self, block: Air.Inst.Index, operand: Air.Inst.Ref) !void {
    const block_data = self.blocks.getPtr(block).?;

    if (self.air.typeOf(operand).hasRuntimeBits()) {
        const operand_mcv = try self.resolveInst(operand);
        const block_mcv = block_data.mcv;
        if (block_mcv == .none) {
            block_data.mcv = switch (operand_mcv) {
                .none, .dead, .unreach => unreachable,
                .register, .stack_offset, .memory => operand_mcv,
                .immediate, .stack_argument_offset => blk: {
                    const new_mcv = try self.allocRegOrMem(block, true);
                    try self.setRegOrMem(self.air.typeOfIndex(block), new_mcv, operand_mcv);
                    break :blk new_mcv;
                },
                else => return self.fail("TODO implement block_data.mcv = operand_mcv for {}", .{operand_mcv}),
            };
        } else {
            try self.setRegOrMem(self.air.typeOfIndex(block), block_mcv, operand_mcv);
        }
    }
    return self.brVoid(block);
}

fn brVoid(self: *Self, block: Air.Inst.Index) !void {
    const block_data = self.blocks.getPtr(block).?;

    // Emit a jump with a relocation. It will be patched up after the block ends.
    try block_data.relocs.append(self.gpa, try self.addInst(.{
        .tag = .b,
        .data = .{ .inst = undefined }, // populated later through performReloc
    }));
}

fn airAsm(self: *Self, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const extra = self.air.extraData(Air.Asm, ty_pl.payload);
    const is_volatile = @truncate(u1, extra.data.flags >> 31) != 0;
    const clobbers_len = @truncate(u31, extra.data.flags);
    var extra_i: usize = extra.end;
    const outputs = @bitCast([]const Air.Inst.Ref, self.air.extra[extra_i..][0..extra.data.outputs_len]);
    extra_i += outputs.len;
    const inputs = @bitCast([]const Air.Inst.Ref, self.air.extra[extra_i..][0..extra.data.inputs_len]);
    extra_i += inputs.len;

    const dead = !is_volatile and self.liveness.isUnused(inst);
    const result: MCValue = if (dead) .dead else result: {
        if (outputs.len > 1) {
            return self.fail("TODO implement codegen for asm with more than 1 output", .{});
        }

        const output_constraint: ?[]const u8 = for (outputs) |output| {
            if (output != .none) {
                return self.fail("TODO implement codegen for non-expr asm", .{});
            }
            const constraint = std.mem.sliceTo(std.mem.sliceAsBytes(self.air.extra[extra_i..]), 0);
            // This equation accounts for the fact that even if we have exactly 4 bytes
            // for the string, we still use the next u32 for the null terminator.
            extra_i += constraint.len / 4 + 1;

            break constraint;
        } else null;

        for (inputs) |input| {
            const constraint = std.mem.sliceTo(std.mem.sliceAsBytes(self.air.extra[extra_i..]), 0);
            // This equation accounts for the fact that even if we have exactly 4 bytes
            // for the string, we still use the next u32 for the null terminator.
            extra_i += constraint.len / 4 + 1;

            if (constraint.len < 3 or constraint[0] != '{' or constraint[constraint.len - 1] != '}') {
                return self.fail("unrecognized asm input constraint: '{s}'", .{constraint});
            }
            const reg_name = constraint[1 .. constraint.len - 1];
            const reg = parseRegName(reg_name) orelse
                return self.fail("unrecognized register: '{s}'", .{reg_name});

            const arg_mcv = try self.resolveInst(input);
            try self.register_manager.getReg(reg, null);
            try self.genSetReg(self.air.typeOf(input), reg, arg_mcv);
        }

        {
            var clobber_i: u32 = 0;
            while (clobber_i < clobbers_len) : (clobber_i += 1) {
                const clobber = std.mem.sliceTo(std.mem.sliceAsBytes(self.air.extra[extra_i..]), 0);
                // This equation accounts for the fact that even if we have exactly 4 bytes
                // for the string, we still use the next u32 for the null terminator.
                extra_i += clobber.len / 4 + 1;

                // TODO honor these
            }
        }

        const asm_source = std.mem.sliceAsBytes(self.air.extra[extra_i..])[0..extra.data.source_len];

        if (mem.eql(u8, asm_source, "svc #0")) {
            _ = try self.addInst(.{
                .tag = .svc,
                .data = .{ .imm24 = 0 },
            });
        } else {
            return self.fail("TODO implement support for more arm assembly instructions", .{});
        }

        if (output_constraint) |output| {
            if (output.len < 4 or output[0] != '=' or output[1] != '{' or output[output.len - 1] != '}') {
                return self.fail("unrecognized asm output constraint: '{s}'", .{output});
            }
            const reg_name = output[2 .. output.len - 1];
            const reg = parseRegName(reg_name) orelse
                return self.fail("unrecognized register: '{s}'", .{reg_name});

            break :result MCValue{ .register = reg };
        } else {
            break :result MCValue{ .none = {} };
        }
    };

    simple: {
        var buf = [1]Air.Inst.Ref{.none} ** (Liveness.bpi - 1);
        var buf_index: usize = 0;
        for (outputs) |output| {
            if (output == .none) continue;

            if (buf_index >= buf.len) break :simple;
            buf[buf_index] = output;
            buf_index += 1;
        }
        if (buf_index + inputs.len > buf.len) break :simple;
        std.mem.copy(Air.Inst.Ref, buf[buf_index..], inputs);
        return self.finishAir(inst, result, buf);
    }
    var bt = try self.iterateBigTomb(inst, outputs.len + inputs.len);
    for (outputs) |output| {
        if (output == .none) continue;

        bt.feed(output);
    }
    for (inputs) |input| {
        bt.feed(input);
    }
    return bt.finishAir(result);
}

fn iterateBigTomb(self: *Self, inst: Air.Inst.Index, operand_count: usize) !BigTomb {
    try self.ensureProcessDeathCapacity(operand_count + 1);
    return BigTomb{
        .function = self,
        .inst = inst,
        .tomb_bits = self.liveness.getTombBits(inst),
        .big_tomb_bits = self.liveness.special.get(inst) orelse 0,
        .bit_index = 0,
    };
}

/// Sets the value without any modifications to register allocation metadata or stack allocation metadata.
fn setRegOrMem(self: *Self, ty: Type, loc: MCValue, val: MCValue) !void {
    switch (loc) {
        .none => return,
        .register => |reg| return self.genSetReg(ty, reg, val),
        .stack_offset => |off| return self.genSetStack(ty, off, val),
        .memory => {
            return self.fail("TODO implement setRegOrMem for memory", .{});
        },
        else => unreachable,
    }
}

fn genSetStack(self: *Self, ty: Type, stack_offset: u32, mcv: MCValue) InnerError!void {
    const abi_size = @intCast(u32, ty.abiSize(self.target.*));
    switch (mcv) {
        .dead => unreachable,
        .unreach, .none => return, // Nothing to do.
        .undef => {
            if (!self.wantSafety())
                return; // The already existing value will do just fine.
            // TODO Upgrade this to a memset call when we have that available.
            switch (ty.abiSize(self.target.*)) {
                1 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaa }),
                2 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaa }),
                4 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaaaaaa }),
                else => return self.fail("TODO implement memset", .{}),
            }
        },
        .compare_flags_unsigned,
        .compare_flags_signed,
        .immediate,
        .ptr_stack_offset,
        .ptr_embedded_in_code,
        => {
            const reg = try self.copyToTmpRegister(ty, mcv);
            return self.genSetStack(ty, stack_offset, MCValue{ .register = reg });
        },
        .register => |reg| {
            const adj_off = stack_offset + abi_size;

            switch (abi_size) {
                1, 4 => {
                    const offset = if (math.cast(u12, adj_off)) |imm| blk: {
                        break :blk Instruction.Offset.imm(imm);
                    } else |_| Instruction.Offset.reg(try self.copyToTmpRegister(Type.initTag(.u32), MCValue{ .immediate = adj_off }), .none);

                    const tag: Mir.Inst.Tag = switch (abi_size) {
                        1 => .strb,
                        4 => .str,
                        else => unreachable,
                    };

                    _ = try self.addInst(.{
                        .tag = tag,
                        .data = .{ .rr_offset = .{
                            .rt = reg,
                            .rn = .fp,
                            .offset = .{
                                .offset = offset,
                                .positive = false,
                            },
                        } },
                    });
                },
                2 => {
                    const offset = if (adj_off <= math.maxInt(u8)) blk: {
                        break :blk Instruction.ExtraLoadStoreOffset.imm(@intCast(u8, adj_off));
                    } else Instruction.ExtraLoadStoreOffset.reg(try self.copyToTmpRegister(Type.initTag(.u32), MCValue{ .immediate = adj_off }));

                    _ = try self.addInst(.{
                        .tag = .strh,
                        .data = .{ .rr_extra_offset = .{
                            .rt = reg,
                            .rn = .fp,
                            .offset = .{
                                .offset = offset,
                                .positive = false,
                            },
                        } },
                    });
                },
                else => return self.fail("TODO implement storing other types abi_size={}", .{abi_size}),
            }
        },
        .memory,
        .embedded_in_code,
        .stack_argument_offset,
        .stack_offset,
        => {
            switch (mcv) {
                .stack_offset => |off| {
                    if (stack_offset == off)
                        return; // Copy stack variable to itself; nothing to do.
                },
                else => {},
            }

            if (abi_size <= 4) {
                const reg = try self.copyToTmpRegister(ty, mcv);
                return self.genSetStack(ty, stack_offset, MCValue{ .register = reg });
            } else {
                // TODO call extern memcpy
                const regs = try self.register_manager.allocRegs(5, .{ null, null, null, null, null });
                const src_reg = regs[0];
                const dst_reg = regs[1];
                const len_reg = regs[2];
                const count_reg = regs[3];
                const tmp_reg = regs[4];

                switch (mcv) {
                    .stack_offset => |off| {
                        // sub src_reg, fp, #off
                        const adj_src_offset = off + @intCast(u32, abi_size);
                        const src_offset_op: Instruction.Operand = if (Instruction.Operand.fromU32(adj_src_offset)) |x| x else {
                            return self.fail("TODO load: set reg to stack offset with all possible offsets", .{});
                        };
                        _ = try self.addInst(.{
                            .tag = .sub,
                            .data = .{ .rr_op = .{
                                .rd = src_reg,
                                .rn = .fp,
                                .op = src_offset_op,
                            } },
                        });
                    },
                    .memory => |addr| try self.genSetReg(Type.usize, src_reg, .{ .immediate = @intCast(u32, addr) }),
                    .embedded_in_code,
                    .stack_argument_offset,
                    => return self.fail("TODO genSetStack with src={}", .{mcv}),
                    else => unreachable,
                }

                // sub dst_reg, fp, #stack_offset
                const adj_dst_offset = stack_offset + abi_size;
                const dst_offset_op: Instruction.Operand = if (Instruction.Operand.fromU32(adj_dst_offset)) |x| x else {
                    return self.fail("TODO load: set reg to stack offset with all possible offsets", .{});
                };
                _ = try self.addInst(.{
                    .tag = .sub,
                    .data = .{ .rr_op = .{
                        .rd = dst_reg,
                        .rn = .fp,
                        .op = dst_offset_op,
                    } },
                });

                // mov len, #abi_size
                try self.genSetReg(Type.usize, len_reg, .{ .immediate = abi_size });

                // memcpy(src, dst, len)
                try self.genInlineMemcpy(src_reg, dst_reg, len_reg, count_reg, tmp_reg);
            }
        },
    }
}

fn genSetReg(self: *Self, ty: Type, reg: Register, mcv: MCValue) InnerError!void {
    switch (mcv) {
        .dead => unreachable,
        .ptr_embedded_in_code => unreachable,
        .unreach, .none => return, // Nothing to do.
        .undef => {
            if (!self.wantSafety())
                return; // The already existing value will do just fine.
            // Write the debug undefined value.
            return self.genSetReg(ty, reg, .{ .immediate = 0xaaaaaaaa });
        },
        .ptr_stack_offset => |unadjusted_off| {
            // TODO: maybe addressing from sp instead of fp
            const elem_ty = ty.childType();
            const abi_size = @intCast(u32, elem_ty.abiSize(self.target.*));
            const adj_off = unadjusted_off + abi_size;

            const op = Instruction.Operand.fromU32(adj_off) orelse
                return self.fail("TODO larger stack offsets", .{});

            _ = try self.addInst(.{
                .tag = .sub,
                .data = .{ .rr_op = .{
                    .rd = reg,
                    .rn = .fp,
                    .op = op,
                } },
            });
        },
        .compare_flags_unsigned,
        .compare_flags_signed,
        => |op| {
            const condition = switch (mcv) {
                .compare_flags_unsigned => Condition.fromCompareOperatorUnsigned(op),
                .compare_flags_signed => Condition.fromCompareOperatorSigned(op),
                else => unreachable,
            };

            const zero = Instruction.Operand.imm(0, 0);
            const one = Instruction.Operand.imm(1, 0);

            // mov reg, 0
            _ = try self.addInst(.{
                .tag = .mov,
                .data = .{ .rr_op = .{
                    .rd = reg,
                    .rn = .r0,
                    .op = zero,
                } },
            });

            // moveq reg, 1
            _ = try self.addInst(.{
                .tag = .mov,
                .cond = condition,
                .data = .{ .rr_op = .{
                    .rd = reg,
                    .rn = .r0,
                    .op = one,
                } },
            });
        },
        .immediate => |x| {
            if (x > math.maxInt(u32)) return self.fail("ARM registers are 32-bit wide", .{});

            if (Instruction.Operand.fromU32(@intCast(u32, x))) |op| {
                _ = try self.addInst(.{
                    .tag = .mov,
                    .data = .{ .rr_op = .{
                        .rd = reg,
                        .rn = .r0,
                        .op = op,
                    } },
                });
            } else if (Instruction.Operand.fromU32(~@intCast(u32, x))) |op| {
                _ = try self.addInst(.{
                    .tag = .mvn,
                    .data = .{ .rr_op = .{
                        .rd = reg,
                        .rn = .r0,
                        .op = op,
                    } },
                });
            } else if (x <= math.maxInt(u16)) {
                if (Target.arm.featureSetHas(self.target.cpu.features, .has_v7)) {
                    _ = try self.addInst(.{
                        .tag = .movw,
                        .data = .{ .r_imm16 = .{
                            .rd = reg,
                            .imm16 = @intCast(u16, x),
                        } },
                    });
                } else {
                    _ = try self.addInst(.{
                        .tag = .mov,
                        .data = .{ .rr_op = .{
                            .rd = reg,
                            .rn = .r0,
                            .op = Instruction.Operand.imm(@truncate(u8, x), 0),
                        } },
                    });
                    _ = try self.addInst(.{
                        .tag = .orr,
                        .data = .{ .rr_op = .{
                            .rd = reg,
                            .rn = reg,
                            .op = Instruction.Operand.imm(@truncate(u8, x >> 8), 12),
                        } },
                    });
                }
            } else {
                // TODO write constant to code and load
                // relative to pc
                if (Target.arm.featureSetHas(self.target.cpu.features, .has_v7)) {
                    // immediate: 0xaaaabbbb
                    // movw reg, #0xbbbb
                    // movt reg, #0xaaaa
                    _ = try self.addInst(.{
                        .tag = .movw,
                        .data = .{ .r_imm16 = .{
                            .rd = reg,
                            .imm16 = @truncate(u16, x),
                        } },
                    });
                    _ = try self.addInst(.{
                        .tag = .movt,
                        .data = .{ .r_imm16 = .{
                            .rd = reg,
                            .imm16 = @truncate(u16, x >> 16),
                        } },
                    });
                } else {
                    // immediate: 0xaabbccdd
                    // mov reg, #0xaa
                    // orr reg, reg, #0xbb, 24
                    // orr reg, reg, #0xcc, 16
                    // orr reg, reg, #0xdd, 8
                    _ = try self.addInst(.{
                        .tag = .mov,
                        .data = .{ .rr_op = .{
                            .rd = reg,
                            .rn = .r0,
                            .op = Instruction.Operand.imm(@truncate(u8, x), 0),
                        } },
                    });
                    _ = try self.addInst(.{
                        .tag = .orr,
                        .data = .{ .rr_op = .{
                            .rd = reg,
                            .rn = reg,
                            .op = Instruction.Operand.imm(@truncate(u8, x >> 8), 12),
                        } },
                    });
                    _ = try self.addInst(.{
                        .tag = .orr,
                        .data = .{ .rr_op = .{
                            .rd = reg,
                            .rn = reg,
                            .op = Instruction.Operand.imm(@truncate(u8, x >> 16), 8),
                        } },
                    });
                    _ = try self.addInst(.{
                        .tag = .orr,
                        .data = .{ .rr_op = .{
                            .rd = reg,
                            .rn = reg,
                            .op = Instruction.Operand.imm(@truncate(u8, x >> 24), 4),
                        } },
                    });
                }
            }
        },
        .register => |src_reg| {
            // If the registers are the same, nothing to do.
            if (src_reg.id() == reg.id())
                return;

            // mov reg, src_reg
            _ = try self.addInst(.{
                .tag = .mov,
                .data = .{ .rr_op = .{
                    .rd = reg,
                    .rn = .r0,
                    .op = Instruction.Operand.reg(src_reg, Instruction.Operand.Shift.none),
                } },
            });
        },
        .memory => |addr| {
            // The value is in memory at a hard-coded address.
            // If the type is a pointer, it means the pointer address is at this memory location.
            try self.genSetReg(ty, reg, .{ .immediate = @intCast(u32, addr) });
            try self.genLdrRegister(reg, reg, ty);
        },
        .stack_offset => |unadjusted_off| {
            // TODO: maybe addressing from sp instead of fp
            const abi_size = @intCast(u32, ty.abiSize(self.target.*));
            const adj_off = unadjusted_off + abi_size;

            const tag: Mir.Inst.Tag = switch (abi_size) {
                1 => if (ty.isSignedInt()) Mir.Inst.Tag.ldrsb else .ldrb,
                2 => if (ty.isSignedInt()) Mir.Inst.Tag.ldrsh else .ldrh,
                3, 4 => .ldr,
                else => unreachable,
            };

            const extra_offset = switch (abi_size) {
                1 => ty.isSignedInt(),
                2 => true,
                3, 4 => false,
                else => unreachable,
            };

            if (extra_offset) {
                const offset = if (adj_off <= math.maxInt(u8)) blk: {
                    break :blk Instruction.ExtraLoadStoreOffset.imm(@intCast(u8, adj_off));
                } else Instruction.ExtraLoadStoreOffset.reg(try self.copyToTmpRegister(Type.initTag(.u32), MCValue{ .immediate = adj_off }));

                _ = try self.addInst(.{
                    .tag = tag,
                    .data = .{ .rr_extra_offset = .{
                        .rt = reg,
                        .rn = .fp,
                        .offset = .{
                            .offset = offset,
                            .positive = false,
                        },
                    } },
                });
            } else {
                const offset = if (adj_off <= math.maxInt(u12)) blk: {
                    break :blk Instruction.Offset.imm(@intCast(u12, adj_off));
                } else Instruction.Offset.reg(try self.copyToTmpRegister(Type.initTag(.u32), MCValue{ .immediate = adj_off }), .none);

                _ = try self.addInst(.{
                    .tag = tag,
                    .data = .{ .rr_offset = .{
                        .rt = reg,
                        .rn = .fp,
                        .offset = .{
                            .offset = offset,
                            .positive = false,
                        },
                    } },
                });
            }
        },
        .stack_argument_offset => |unadjusted_off| {
            const abi_size = ty.abiSize(self.target.*);
            const adj_off = unadjusted_off + abi_size;

            const tag: Mir.Inst.Tag = switch (abi_size) {
                1 => if (ty.isSignedInt()) Mir.Inst.Tag.ldrsb_stack_argument else .ldrb_stack_argument,
                2 => if (ty.isSignedInt()) Mir.Inst.Tag.ldrsh_stack_argument else .ldrh_stack_argument,
                3, 4 => .ldr_stack_argument,
                else => unreachable,
            };

            _ = try self.addInst(.{
                .tag = tag,
                .data = .{ .r_stack_offset = .{
                    .rt = reg,
                    .stack_offset = @intCast(u32, adj_off),
                } },
            });
        },
        else => return self.fail("TODO implement getSetReg for arm {}", .{mcv}),
    }
}

fn genSetStackArgument(self: *Self, ty: Type, stack_offset: u32, mcv: MCValue) InnerError!void {
    const abi_size = @intCast(u32, ty.abiSize(self.target.*));
    switch (mcv) {
        .dead => unreachable,
        .none, .unreach => return,
        .undef => {
            if (!self.wantSafety())
                return; // The already existing value will do just fine.
            // TODO Upgrade this to a memset call when we have that available.
            switch (ty.abiSize(self.target.*)) {
                1 => return self.genSetStackArgument(ty, stack_offset, .{ .immediate = 0xaa }),
                2 => return self.genSetStackArgument(ty, stack_offset, .{ .immediate = 0xaaaa }),
                4 => return self.genSetStackArgument(ty, stack_offset, .{ .immediate = 0xaaaaaaaa }),
                else => return self.fail("TODO implement memset", .{}),
            }
        },
        .register => |reg| {
            const adj_off = stack_offset - abi_size;

            switch (abi_size) {
                1, 4 => {
                    const offset = if (math.cast(u12, adj_off)) |imm| blk: {
                        break :blk Instruction.Offset.imm(imm);
                    } else |_| Instruction.Offset.reg(try self.copyToTmpRegister(Type.initTag(.u32), MCValue{ .immediate = adj_off }), .none);

                    const tag: Mir.Inst.Tag = switch (abi_size) {
                        1 => .strb,
                        4 => .str,
                        else => unreachable,
                    };

                    _ = try self.addInst(.{
                        .tag = tag,
                        .data = .{ .rr_offset = .{
                            .rt = reg,
                            .rn = .sp,
                            .offset = .{ .offset = offset },
                        } },
                    });
                },
                2 => {
                    const offset = if (adj_off <= math.maxInt(u8)) blk: {
                        break :blk Instruction.ExtraLoadStoreOffset.imm(@intCast(u8, adj_off));
                    } else Instruction.ExtraLoadStoreOffset.reg(try self.copyToTmpRegister(Type.initTag(.u32), MCValue{ .immediate = adj_off }));

                    _ = try self.addInst(.{
                        .tag = .strh,
                        .data = .{ .rr_extra_offset = .{
                            .rt = reg,
                            .rn = .sp,
                            .offset = .{ .offset = offset },
                        } },
                    });
                },
                else => return self.fail("TODO implement storing other types abi_size={}", .{abi_size}),
            }
        },
        .stack_offset,
        .memory,
        .stack_argument_offset,
        .embedded_in_code,
        => {
            if (abi_size <= 4) {
                const reg = try self.copyToTmpRegister(ty, mcv);
                return self.genSetStackArgument(ty, stack_offset, MCValue{ .register = reg });
            } else {
                // TODO call extern memcpy
                const regs = try self.register_manager.allocRegs(5, .{ null, null, null, null, null });
                const src_reg = regs[0];
                const dst_reg = regs[1];
                const len_reg = regs[2];
                const count_reg = regs[3];
                const tmp_reg = regs[4];

                switch (mcv) {
                    .stack_offset => |off| {
                        // sub src_reg, fp, #off
                        const adj_src_offset = off + abi_size;
                        const src_offset_op: Instruction.Operand = if (Instruction.Operand.fromU32(adj_src_offset)) |x| x else {
                            return self.fail("TODO load: set reg to stack offset with all possible offsets", .{});
                        };
                        _ = try self.addInst(.{
                            .tag = .sub,
                            .data = .{ .rr_op = .{
                                .rd = src_reg,
                                .rn = .fp,
                                .op = src_offset_op,
                            } },
                        });
                    },
                    .memory => |addr| try self.genSetReg(Type.usize, src_reg, .{ .immediate = @intCast(u32, addr) }),
                    .stack_argument_offset,
                    .embedded_in_code,
                    => return self.fail("TODO genSetStackArgument src={}", .{mcv}),
                    else => unreachable,
                }

                // add dst_reg, sp, #stack_offset
                const adj_dst_offset = stack_offset - abi_size;
                const dst_offset_op: Instruction.Operand = if (Instruction.Operand.fromU32(adj_dst_offset)) |x| x else {
                    return self.fail("TODO load: set reg to stack offset with all possible offsets", .{});
                };
                _ = try self.addInst(.{
                    .tag = .add,
                    .data = .{ .rr_op = .{
                        .rd = dst_reg,
                        .rn = .sp,
                        .op = dst_offset_op,
                    } },
                });

                // mov len, #abi_size
                try self.genSetReg(Type.usize, len_reg, .{ .immediate = abi_size });

                // memcpy(src, dst, len)
                try self.genInlineMemcpy(src_reg, dst_reg, len_reg, count_reg, tmp_reg);
            }
        },
        .compare_flags_unsigned,
        .compare_flags_signed,
        .immediate,
        .ptr_stack_offset,
        .ptr_embedded_in_code,
        => {
            const reg = try self.copyToTmpRegister(ty, mcv);
            return self.genSetStackArgument(ty, stack_offset, MCValue{ .register = reg });
        },
    }
}

fn airPtrToInt(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const result = try self.resolveInst(un_op);
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airBitCast(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result = try self.resolveInst(ty_op.operand);
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airArrayToSlice(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const ptr_ty = self.air.typeOf(ty_op.operand);
        const ptr = try self.resolveInst(ty_op.operand);
        const array_ty = ptr_ty.childType();
        const array_len = @intCast(u32, array_ty.arrayLenIncludingSentinel());

        const stack_offset = try self.allocMem(inst, 8, 8);
        try self.genSetStack(ptr_ty, stack_offset + 4, ptr);
        try self.genSetStack(Type.initTag(.usize), stack_offset, .{ .immediate = array_len });
        break :result MCValue{ .stack_offset = stack_offset };
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airIntToFloat(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement airIntToFloat for {}", .{
        self.target.cpu.arch,
    });
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airFloatToInt(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement airFloatToInt for {}", .{
        self.target.cpu.arch,
    });
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airCmpxchg(self: *Self, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const extra = self.air.extraData(Air.Block, ty_pl.payload);
    _ = extra;

    return self.fail("TODO implement airCmpxchg for {}", .{
        self.target.cpu.arch,
    });
}

fn airAtomicRmw(self: *Self, inst: Air.Inst.Index) !void {
    _ = inst;
    return self.fail("TODO implement airCmpxchg for {}", .{self.target.cpu.arch});
}

fn airAtomicLoad(self: *Self, inst: Air.Inst.Index) !void {
    _ = inst;
    return self.fail("TODO implement airAtomicLoad for {}", .{self.target.cpu.arch});
}

fn airAtomicStore(self: *Self, inst: Air.Inst.Index, order: std.builtin.AtomicOrder) !void {
    _ = inst;
    _ = order;
    return self.fail("TODO implement airAtomicStore for {}", .{self.target.cpu.arch});
}

fn airMemset(self: *Self, inst: Air.Inst.Index) !void {
    _ = inst;
    return self.fail("TODO implement airMemset for {}", .{self.target.cpu.arch});
}

fn airMemcpy(self: *Self, inst: Air.Inst.Index) !void {
    _ = inst;
    return self.fail("TODO implement airMemcpy for {}", .{self.target.cpu.arch});
}

fn airTagName(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const operand = try self.resolveInst(un_op);
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else {
        _ = operand;
        return self.fail("TODO implement airTagName for arm", .{});
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airErrorName(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const operand = try self.resolveInst(un_op);
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else {
        _ = operand;
        return self.fail("TODO implement airErrorName for arm", .{});
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airSplat(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement airSplat for arm", .{});
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airAggregateInit(self: *Self, inst: Air.Inst.Index) !void {
    const vector_ty = self.air.typeOfIndex(inst);
    const len = vector_ty.vectorLen();
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const elements = @bitCast([]const Air.Inst.Ref, self.air.extra[ty_pl.payload..][0..len]);
    const result: MCValue = res: {
        if (self.liveness.isUnused(inst)) break :res MCValue.dead;
        return self.fail("TODO implement airAggregateInit for arm", .{});
    };

    if (elements.len <= Liveness.bpi - 1) {
        var buf = [1]Air.Inst.Ref{.none} ** (Liveness.bpi - 1);
        std.mem.copy(Air.Inst.Ref, &buf, elements);
        return self.finishAir(inst, result, buf);
    }
    var bt = try self.iterateBigTomb(inst, elements.len);
    for (elements) |elem| {
        bt.feed(elem);
    }
    return bt.finishAir(result);
}

fn airUnionInit(self: *Self, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const extra = self.air.extraData(Air.UnionInit, ty_pl.payload).data;
    _ = extra;

    return self.fail("TODO implement airUnionInit for arm", .{});
}

fn airPrefetch(self: *Self, inst: Air.Inst.Index) !void {
    const prefetch = self.air.instructions.items(.data)[inst].prefetch;
    return self.finishAir(inst, MCValue.dead, .{ prefetch.ptr, .none, .none });
}

fn resolveInst(self: *Self, inst: Air.Inst.Ref) InnerError!MCValue {
    // First section of indexes correspond to a set number of constant values.
    const ref_int = @enumToInt(inst);
    if (ref_int < Air.Inst.Ref.typed_value_map.len) {
        const tv = Air.Inst.Ref.typed_value_map[ref_int];
        if (!tv.ty.hasRuntimeBits()) {
            return MCValue{ .none = {} };
        }
        return self.genTypedValue(tv);
    }

    // If the type has no codegen bits, no need to store it.
    const inst_ty = self.air.typeOf(inst);
    if (!inst_ty.hasRuntimeBits())
        return MCValue{ .none = {} };

    const inst_index = @intCast(Air.Inst.Index, ref_int - Air.Inst.Ref.typed_value_map.len);
    switch (self.air.instructions.items(.tag)[inst_index]) {
        .constant => {
            // Constants have static lifetimes, so they are always memoized in the outer most table.
            const branch = &self.branch_stack.items[0];
            const gop = try branch.inst_table.getOrPut(self.gpa, inst_index);
            if (!gop.found_existing) {
                const ty_pl = self.air.instructions.items(.data)[inst_index].ty_pl;
                gop.value_ptr.* = try self.genTypedValue(.{
                    .ty = inst_ty,
                    .val = self.air.values[ty_pl.payload],
                });
            }
            return gop.value_ptr.*;
        },
        .const_ty => unreachable,
        else => return self.getResolvedInstValue(inst_index),
    }
}

fn getResolvedInstValue(self: *Self, inst: Air.Inst.Index) MCValue {
    // Treat each stack item as a "layer" on top of the previous one.
    var i: usize = self.branch_stack.items.len;
    while (true) {
        i -= 1;
        if (self.branch_stack.items[i].inst_table.get(inst)) |mcv| {
            assert(mcv != .dead);
            return mcv;
        }
    }
}

fn lowerDeclRef(self: *Self, tv: TypedValue, decl: *Module.Decl) InnerError!MCValue {
    const ptr_bits = self.target.cpu.arch.ptrBitWidth();
    const ptr_bytes: u64 = @divExact(ptr_bits, 8);

    decl.alive = true;
    if (self.bin_file.cast(link.File.Elf)) |elf_file| {
        const got = &elf_file.program_headers.items[elf_file.phdr_got_index.?];
        const got_addr = got.p_vaddr + decl.link.elf.offset_table_index * ptr_bytes;
        return MCValue{ .memory = got_addr };
    } else if (self.bin_file.cast(link.File.MachO)) |_| {
        unreachable; // unsupported architecture for MachO
    } else if (self.bin_file.cast(link.File.Coff)) |coff_file| {
        const got_addr = coff_file.offset_table_virtual_address + decl.link.coff.offset_table_index * ptr_bytes;
        return MCValue{ .memory = got_addr };
    } else if (self.bin_file.cast(link.File.Plan9)) |p9| {
        try p9.seeDecl(decl);
        const got_addr = p9.bases.data + decl.link.plan9.got_index.? * ptr_bytes;
        return MCValue{ .memory = got_addr };
    } else {
        return self.fail("TODO codegen non-ELF const Decl pointer", .{});
    }

    _ = tv;
}

fn lowerUnnamedConst(self: *Self, tv: TypedValue) InnerError!MCValue {
    const local_sym_index = self.bin_file.lowerUnnamedConst(tv, self.mod_fn.owner_decl) catch |err| {
        return self.fail("lowering unnamed constant failed: {s}", .{@errorName(err)});
    };
    if (self.bin_file.cast(link.File.Elf)) |elf_file| {
        const vaddr = elf_file.local_symbols.items[local_sym_index].st_value;
        return MCValue{ .memory = vaddr };
    } else if (self.bin_file.cast(link.File.MachO)) |_| {
        unreachable;
    } else if (self.bin_file.cast(link.File.Coff)) |_| {
        return self.fail("TODO lower unnamed const in COFF", .{});
    } else if (self.bin_file.cast(link.File.Plan9)) |_| {
        return self.fail("TODO lower unnamed const in Plan9", .{});
    } else {
        return self.fail("TODO lower unnamed const", .{});
    }
}

fn genTypedValue(self: *Self, typed_value: TypedValue) InnerError!MCValue {
    if (typed_value.val.isUndef())
        return MCValue{ .undef = {} };
    const ptr_bits = self.target.cpu.arch.ptrBitWidth();

    if (typed_value.val.castTag(.decl_ref)) |payload| {
        return self.lowerDeclRef(typed_value, payload.data);
    }
    if (typed_value.val.castTag(.decl_ref_mut)) |payload| {
        return self.lowerDeclRef(typed_value, payload.data.decl);
    }

    switch (typed_value.ty.zigTypeTag()) {
        .Array => {
            return self.lowerUnnamedConst(typed_value);
        },
        .Pointer => switch (typed_value.ty.ptrSize()) {
            .Slice => {
                return self.lowerUnnamedConst(typed_value);
            },
            else => {
                switch (typed_value.val.tag()) {
                    .int_u64 => {
                        return MCValue{ .immediate = @intCast(u32, typed_value.val.toUnsignedInt()) };
                    },
                    .slice => {
                        return self.lowerUnnamedConst(typed_value);
                    },
                    else => {
                        return self.fail("TODO codegen more kinds of const pointers", .{});
                    },
                }
            },
        },
        .Int => {
            const info = typed_value.ty.intInfo(self.target.*);
            if (info.bits <= ptr_bits) {
                const unsigned = switch (info.signedness) {
                    .signed => blk: {
                        const signed = @intCast(i32, typed_value.val.toSignedInt());
                        break :blk @bitCast(u32, signed);
                    },
                    .unsigned => @intCast(u32, typed_value.val.toUnsignedInt()),
                };

                return MCValue{ .immediate = unsigned };
            } else {
                return self.lowerUnnamedConst(typed_value);
            }
        },
        .Bool => {
            return MCValue{ .immediate = @boolToInt(typed_value.val.toBool()) };
        },
        .ComptimeInt => unreachable, // semantic analysis prevents this
        .ComptimeFloat => unreachable, // semantic analysis prevents this
        .Optional => {
            if (typed_value.ty.isPtrLikeOptional()) {
                if (typed_value.val.isNull())
                    return MCValue{ .immediate = 0 };

                var buf: Type.Payload.ElemType = undefined;
                return self.genTypedValue(.{
                    .ty = typed_value.ty.optionalChild(&buf),
                    .val = typed_value.val,
                });
            } else if (typed_value.ty.abiSize(self.target.*) == 1) {
                return MCValue{ .immediate = @boolToInt(typed_value.val.isNull()) };
            }
            return self.fail("TODO non pointer optionals", .{});
        },
        .Enum => {
            if (typed_value.val.castTag(.enum_field_index)) |field_index| {
                switch (typed_value.ty.tag()) {
                    .enum_simple => {
                        return MCValue{ .immediate = field_index.data };
                    },
                    .enum_full, .enum_nonexhaustive => {
                        const enum_full = typed_value.ty.cast(Type.Payload.EnumFull).?.data;
                        if (enum_full.values.count() != 0) {
                            const tag_val = enum_full.values.keys()[field_index.data];
                            return self.genTypedValue(.{ .ty = enum_full.tag_ty, .val = tag_val });
                        } else {
                            return MCValue{ .immediate = field_index.data };
                        }
                    },
                    else => unreachable,
                }
            } else {
                var int_tag_buffer: Type.Payload.Bits = undefined;
                const int_tag_ty = typed_value.ty.intTagType(&int_tag_buffer);
                return self.genTypedValue(.{ .ty = int_tag_ty, .val = typed_value.val });
            }
        },
        .ErrorSet => {
            const err_name = typed_value.val.castTag(.@"error").?.data.name;
            const module = self.bin_file.options.module.?;
            const global_error_set = module.global_error_set;
            const error_index = global_error_set.get(err_name).?;
            return MCValue{ .immediate = error_index };
        },
        .ErrorUnion => {
            const error_type = typed_value.ty.errorUnionSet();
            const payload_type = typed_value.ty.errorUnionPayload();

            if (typed_value.val.castTag(.eu_payload)) |pl| {
                if (!payload_type.hasRuntimeBits()) {
                    // We use the error type directly as the type.
                    return MCValue{ .immediate = 0 };
                }

                _ = pl;
                return self.fail("TODO implement error union const of type '{}' (non-error)", .{typed_value.ty});
            } else {
                if (!payload_type.hasRuntimeBits()) {
                    // We use the error type directly as the type.
                    return self.genTypedValue(.{ .ty = error_type, .val = typed_value.val });
                }

                return self.fail("TODO implement error union const of type '{}' (error)", .{typed_value.ty});
            }
        },
        .Struct => {
            return self.lowerUnnamedConst(typed_value);
        },
        else => return self.fail("TODO implement const of type '{}'", .{typed_value.ty}),
    }
}

const CallMCValues = struct {
    args: []MCValue,
    return_value: MCValue,
    stack_byte_count: u32,
    stack_align: u32,

    fn deinit(self: *CallMCValues, func: *Self) void {
        func.gpa.free(self.args);
        self.* = undefined;
    }
};

/// Caller must call `CallMCValues.deinit`.
fn resolveCallingConventionValues(self: *Self, fn_ty: Type) !CallMCValues {
    const cc = fn_ty.fnCallingConvention();
    const param_types = try self.gpa.alloc(Type, fn_ty.fnParamLen());
    defer self.gpa.free(param_types);
    fn_ty.fnParamTypes(param_types);
    var result: CallMCValues = .{
        .args = try self.gpa.alloc(MCValue, param_types.len),
        // These undefined values must be populated before returning from this function.
        .return_value = undefined,
        .stack_byte_count = undefined,
        .stack_align = undefined,
    };
    errdefer self.gpa.free(result.args);

    const ret_ty = fn_ty.fnReturnType();

    switch (cc) {
        .Naked => {
            assert(result.args.len == 0);
            result.return_value = .{ .unreach = {} };
            result.stack_byte_count = 0;
            result.stack_align = 1;
            return result;
        },
        .C => {
            // ARM Procedure Call Standard, Chapter 6.5
            var ncrn: usize = 0; // Next Core Register Number
            var nsaa: u32 = 0; // Next stacked argument address

            for (param_types) |ty, i| {
                if (ty.abiAlignment(self.target.*) == 8)
                    ncrn = std.mem.alignForwardGeneric(usize, ncrn, 2);

                const param_size = @intCast(u32, ty.abiSize(self.target.*));
                if (std.math.divCeil(u32, param_size, 4) catch unreachable <= 4 - ncrn) {
                    if (param_size <= 4) {
                        result.args[i] = .{ .register = c_abi_int_param_regs[ncrn] };
                        ncrn += 1;
                    } else {
                        return self.fail("TODO MCValues with multiple registers", .{});
                    }
                } else if (ncrn < 4 and nsaa == 0) {
                    return self.fail("TODO MCValues split between registers and stack", .{});
                } else {
                    ncrn = 4;
                    if (ty.abiAlignment(self.target.*) == 8)
                        nsaa = std.mem.alignForwardGeneric(u32, nsaa, 8);

                    result.args[i] = .{ .stack_argument_offset = nsaa };
                    nsaa += param_size;
                }
            }

            result.stack_byte_count = nsaa;
            result.stack_align = 8;
        },
        .Unspecified => {
            var stack_offset: u32 = 0;

            for (param_types) |ty, i| {
                if (ty.abiSize(self.target.*) > 0) {
                    stack_offset = std.mem.alignForwardGeneric(u32, stack_offset, ty.abiAlignment(self.target.*));
                    result.args[i] = .{ .stack_argument_offset = stack_offset };
                    stack_offset += @intCast(u32, ty.abiSize(self.target.*));
                } else {
                    result.args[i] = .{ .none = {} };
                }
            }

            result.stack_byte_count = stack_offset;
            result.stack_align = 8;
        },
        else => return self.fail("TODO implement function parameters for {} on arm", .{cc}),
    }

    if (ret_ty.zigTypeTag() == .NoReturn) {
        result.return_value = .{ .unreach = {} };
    } else if (!ret_ty.hasRuntimeBits()) {
        result.return_value = .{ .none = {} };
    } else switch (cc) {
        .Naked => unreachable,
        .Unspecified, .C => {
            const ret_ty_size = @intCast(u32, ret_ty.abiSize(self.target.*));
            if (ret_ty_size <= 4) {
                result.return_value = .{ .register = c_abi_int_return_regs[0] };
            } else {
                return self.fail("TODO support more return types for ARM backend", .{});
            }
        },
        else => return self.fail("TODO implement function return values for {}", .{cc}),
    }
    return result;
}

/// TODO support scope overrides. Also note this logic is duplicated with `Module.wantSafety`.
fn wantSafety(self: *Self) bool {
    return switch (self.bin_file.options.optimize_mode) {
        .Debug => true,
        .ReleaseSafe => true,
        .ReleaseFast => false,
        .ReleaseSmall => false,
    };
}

fn fail(self: *Self, comptime format: []const u8, args: anytype) InnerError {
    @setCold(true);
    assert(self.err_msg == null);
    self.err_msg = try ErrorMsg.create(self.bin_file.allocator, self.src_loc, format, args);
    return error.CodegenFail;
}

fn failSymbol(self: *Self, comptime format: []const u8, args: anytype) InnerError {
    @setCold(true);
    assert(self.err_msg == null);
    self.err_msg = try ErrorMsg.create(self.bin_file.allocator, self.src_loc, format, args);
    return error.CodegenFail;
}

const Register = @import("bits.zig").Register;
const Instruction = @import("bits.zig").Instruction;
const Condition = @import("bits.zig").Condition;
const callee_preserved_regs = @import("bits.zig").callee_preserved_regs;
const c_abi_int_param_regs = @import("bits.zig").c_abi_int_param_regs;
const c_abi_int_return_regs = @import("bits.zig").c_abi_int_return_regs;

fn parseRegName(name: []const u8) ?Register {
    if (@hasDecl(Register, "parseRegName")) {
        return Register.parseRegName(name);
    }
    return std.meta.stringToEnum(Register, name);
}