const std = @import("std");
const _value = @import("./value.zig");
const _obj = @import("./obj.zig");
const _chunk = @import("./chunk.zig");
const disassembler = @import("./disassembler.zig");
const Allocator = std.mem.Allocator;
const Value = _value.Value;
const ValueType = _value.ValueType;
const ObjClosure = _obj.ObjClosure;
const ObjFunction = _obj.ObjFunction;
const ObjUpValue = _obj.ObjUpValue;
const ObjTypeDef = _obj.ObjTypeDef;
const ObjString = _obj.ObjString;
const Obj = _obj.Obj;
const OpCode = _chunk.OpCode;

pub const CallFrame = struct {
    closure: *ObjClosure,
    // Index into closure's chunk
    ip: usize,
    slots: [*]Value,
};

pub const VM = struct {
    const Self = @This();

    pub const init_string: []const u8 = "init";
    pub const this_string: []const u8 = "this";
    pub const empty_string: []const u8 = "";
    pub const script_string: []const u8 = "<script>";

    pub const InterpretResult = enum {
        Ok,
        CompileError,
        RuntimeError,
    };

    allocator: *Allocator,

    frames: std.ArrayList(CallFrame),
    frame_count: u64 = 0,

    // TODO: put ta limit somewhere
    stack: []Value,
    stack_top: [*]Value,
    globals: std.ArrayList(Value),
    // Interned strings
    strings: std.StringHashMap(*ObjString),
    // Interned typedef, find a better way of hashing a key (won't accept float so we use toString)
    type_defs: std.StringHashMap(*ObjTypeDef),
    open_upvalues: ?*ObjUpValue,

    bytes_allocated: usize = 0,
    next_gc: usize = 1024 * 1024,
    // TODO: replace with SinglyLinkedList(*Obj)
    objects: ?*Obj = null,
    gray_stack: std.ArrayList(*Obj),

    pub fn init(allocator: *Allocator) !Self {
        var self: Self = .{
            .allocator = allocator,
            .stack = try allocator.alloc(Value, 1000000),
            .stack_top = undefined,
            .globals = std.ArrayList(Value).init(allocator),
            .frames = std.ArrayList(CallFrame).init(allocator),
            .strings = std.StringHashMap(*ObjString).init(allocator),
            .type_defs = std.StringHashMap(*ObjTypeDef).init(allocator),
            .open_upvalues = null,
            .gray_stack = std.ArrayList(*Obj).init(allocator),
        };

        self.stack_top = @ptrCast([*]Value, self.stack[0..]);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.stack);

        self.frames.deinit();
        self.strings.deinit();

        // TODO: key are strings on the heap so free them, does this work?
        var it = self.type_defs.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
        }

        self.type_defs.deinit();
        
        while (self.open_upvalues) |upvalue| {
            self.open_upvalues = upvalue.next;

            self.allocator.destroy(upvalue);
        }

        self.gray_stack.deinit();
        self.globals.deinit();
    }

    pub fn getTypeDef(self: *Self, type_def: ObjTypeDef) !*ObjTypeDef {
        var type_def_str: []const u8 = try type_def.toString(self.allocator);

        if (self.type_defs.get(type_def_str)) |type_def_ptr| {
            self.allocator.free(type_def_str); // If already in map, we don't need this string anymore
            return type_def_ptr;
        }

        var type_def_ptr: *ObjTypeDef = ObjTypeDef.cast(try _obj.allocateObject(self, .Type)).?;
        type_def_ptr.* = type_def;

        _ = try self.type_defs.put(type_def_str, type_def_ptr);

        return type_def_ptr;
    }

    pub fn push(self: *Self, value: Value) void {
        self.stack_top[0] = value;
        self.stack_top += 1;
    }

    pub fn pop(self: *Self) Value {
        self.stack_top -= 1;
        return self.stack_top[0];
    }

    pub fn peek(self: *Self, distance: u32) Value {
        return (self.stack_top - 1 - distance)[0];
    }

    inline fn swap(self: *Self, from: u8, to: u8) void {
        var temp: Value = (self.stack_top - to - 1)[0];
        (self.stack_top - to - 1)[0] = (self.stack_top - from - 1)[0];
        (self.stack_top - from - 1)[0] = temp;
    }

    pub fn interpret(self: *Self, function: *ObjFunction) !?InterpretResult {
        self.push(.{
            .Obj = function.toObj()
        });

        var closure: *ObjClosure = try self.allocator.create(ObjClosure);
        closure.* = try ObjClosure.init(self.allocator, function);

        _ = self.pop();

        self.push(.{
            .Obj = closure.toObj()
        });

        _ = try self.call(closure, 0);

        return try self.run();
    }

    inline fn readByte(frame: *CallFrame) u8 {
        // TODO: measure if [*]OpCode[0] is faster
        var byte: u8 = frame.closure.function.chunk.code.items[frame.ip];

        frame.ip += 1;

        return byte;
    }

    inline fn readOpCode(frame: *CallFrame) OpCode {
        // TODO: measure if [*]OpCode[0] is faster
        var opcode: OpCode = @intToEnum(OpCode, frame.closure.function.chunk.code.items[frame.ip]);

        frame.ip += 1;

        return opcode;
    }

    inline fn readConstant(frame: *CallFrame) Value {
        return frame.closure.function.chunk.constants.items[readByte(frame)];
    }

    inline fn readString(frame: *CallFrame) *ObjString {
        return ObjString.cast(readConstant(frame).Obj);
    }

    fn run(self: *Self) !InterpretResult {
        var frame: *CallFrame = &self.frames.items[self.frame_count - 1];

        while (true) {
            var instruction: OpCode = readOpCode(frame);
            switch(instruction) {
                .OP_NULL          => self.push(Value { .Null = null }),
                .OP_TRUE          => self.push(Value { .Boolean = true }),
                .OP_FALSE         => self.push(Value { .Boolean = false }),
                .OP_POP           => _ = self.pop(),
                .OP_SWAP          => self.swap(readByte(frame), readByte(frame)),
                .OP_NOT           => self.push(Value { .Boolean = isFalse(self.pop()) }),
                .OP_DEFINE_GLOBAL => {
                    try self.globals.append(self.peek(0));
                    _ = self.pop();
                },
                .OP_GET_GLOBAL    => self.push(self.globals.items[readByte(frame)]),
                .OP_SET_GLOBAL    => self.globals.items[readByte(frame)] = self.peek(0),
                .OP_GET_LOCAL     => self.push(frame.slots[readByte(frame)]),
                .OP_SET_LOCAL     => frame.slots[readByte(frame)] = self.peek(0),
                .OP_GET_UPVALUE   => self.push(frame.closure.upvalues.items[readByte(frame)].location.*),
                .OP_SET_UPVALUE   => frame.closure.upvalues.items[readByte(frame)].location.* = self.peek(0),
                .OP_CONSTANT      => self.push(readConstant(frame)),
                .OP_NEGATE        => {
                    if (@as(ValueType, self.peek(0)) != .Number) {
                        runtimeError("Operand must be a number.");

                        return .RuntimeError;
                    }

                    self.push(Value{ .Number = -self.pop().Number });
                },
                .OP_CLOSURE       => {
                    var function: *ObjFunction = ObjFunction.cast(readConstant(frame).Obj).?;
                    var closure: *ObjClosure = ObjClosure.cast(try _obj.allocateObject(self, .Closure)).?;
                    closure.* = try ObjClosure.init(self.allocator, function);

                    self.push(Value{ .Obj = closure.toObj() });

                    var i: usize = 0;
                    while (i < function.upvalue_count) : (i += 1) {
                        var is_local: bool = readByte(frame) == 1;
                        var index: u8 = readByte(frame);

                        if (is_local) {
                            try closure.upvalues.append(try self.captureUpvalue(&(frame.slots + index)[0]));
                        } else {
                            try closure.upvalues.append(frame.closure.upvalues.items[index]);
                        }
                    }
                },
                .OP_CALL          => {
                    var arg_count: u8 = readByte(frame);
                    if (!(try self.callValue(self.peek(arg_count), arg_count))) {
                        return .RuntimeError;
                    }

                    frame = &self.frames.items[self.frame_count - 1];
                },

                // TODO: for now, used to debug
                .OP_RETURN        => {
                    var result: Value = self.pop();

                    self.closeUpValues(&frame.slots[0]);

                    self.frame_count -= 1;
                    if (self.frame_count == 0) {
                        _ = self.pop();
                        return .Ok;
                    }

                    // TODO: find a more zig idiomatic way of doing this
                    // self.stack_top = @ptrToInt(&self.stack[self.stack_top]) - @ptrToInt(&frame.slots[0]);
                    // std.debug.warn("\nptrToInt(slots): {}\nptrToInt(stack): {}\nstack_top: {}\n", .{ @ptrToInt(&frame.slots[0]), @ptrToInt(&self.stack[0]), self.stack_top });
                    // self.stack_top -= @ptrToInt(&frame.slots[0]) - @ptrToInt(&self.stack[0]);
                    self.stack_top = frame.slots;

                    self.push(result);
                    frame = &self.frames.items[self.frame_count - 1];
                },

                // TODO: remove
                .OP_PRINT         => {
                    var value_str: []const u8 = try _value.valueToString(self.allocator, self.pop());
                    defer self.allocator.free(value_str);

                    std.debug.print("{s}\n", .{ value_str });
                },

                else => {
                    std.debug.warn("{} not yet implemented\n", .{ instruction });

                    std.os.exit(1);
                }
            }
        }

        return InterpretResult.Ok;
    }

    fn call(self: *Self, closure: *ObjClosure, arg_count: u8) !bool {
        // We don't type check or check arity becaus it was done at comptime
        
        // TODO: do we check for stack overflow

        var frame = CallFrame {
            .closure = closure,
            .ip = 0,
            // -1 is because we reserve slot 0 for this
            .slots = self.stack_top - arg_count - 1,
        };

        if (self.frames.items.len <= self.frame_count) {
            try self.frames.append(frame);
        } else {
            self.frames.items[self.frame_count] = frame;
        }

        self.frame_count += 1;

        try disassembler.disassembleChunk(
            &frame.closure.function.chunk,
            frame.closure.function.name.string
        );
        std.debug.print("\n\n", .{});

        return true;
    }

    fn callValue(self: *Self, callee: Value, arg_count: u8) !bool {
        var obj: *Obj = callee.Obj;
        switch (obj.obj_type) {
            .Bound => {
                // TODO
            },
            .Class => {
                // TODO
            },
            .Closure => {
                return try self.call(ObjClosure.cast(obj).?, arg_count);
            },
            // .Native => {}
            else => {}
        }

        return false;
    }

    fn closeUpValues(self: *Self, last: *Value) void {
        while (self.open_upvalues != null and @ptrToInt(self.open_upvalues.?.location) >= @ptrToInt(last)) {
            var upvalue: *ObjUpValue = self.open_upvalues.?;
            upvalue.closed = upvalue.location.*;
            upvalue.location = &upvalue.closed.?;
            self.open_upvalues = upvalue.next;
        }
    }

    fn captureUpvalue(self: *Self, local: *Value) !*ObjUpValue {
        var prev_upvalue: ?*ObjUpValue = null;
        var upvalue: ?*ObjUpValue = self.open_upvalues;
        while (upvalue != null and @ptrToInt(upvalue.?.location) > @ptrToInt(local)) {
            prev_upvalue = upvalue;
            upvalue = upvalue.?.next;
        }

        if (upvalue != null and upvalue.?.location == local) {
            return upvalue.?;
        }

        var created_upvalue: *ObjUpValue = ObjUpValue.cast(try _obj.allocateObject(self, .UpValue)).?;
        created_upvalue.* = ObjUpValue.init(local);
        created_upvalue.next = upvalue;

        if (prev_upvalue) |uprev_upvalue| {
            uprev_upvalue.next = created_upvalue;
        } else {
            self.open_upvalues = created_upvalue;
        }

        return created_upvalue;
    }

    fn isFalse(value: Value) bool {
        if (@as(ValueType, value) != .Boolean) {
            runtimeError("Expected boolean but got ...");
        }

        return value.Boolean == false;
    }

    fn runtimeError(error_message: []const u8) void {
        // TODO
        std.debug.warn("\u{001b}[31m{s}\u{001b}[0m\n", .{ error_message });

        std.os.exit(1);
    }
};