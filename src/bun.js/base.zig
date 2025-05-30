pub const js = bun.JSC.C;
const std = @import("std");
const bun = @import("root").bun;
const string = bun.string;
const Output = bun.Output;
const Global = bun.Global;
const Environment = bun.Environment;
const strings = bun.strings;
const MutableString = bun.MutableString;
const stringZ = bun.stringZ;
const default_allocator = bun.default_allocator;
const JSC = bun.JSC;
const Test = @import("./test/jest.zig");
const Router = @import("./api/filesystem_router.zig");
const IdentityContext = @import("../identity_context.zig").IdentityContext;
const uws = bun.uws;
const TaggedPointerTypes = @import("../ptr.zig");
const TaggedPointerUnion = TaggedPointerTypes.TaggedPointerUnion;
const JSError = bun.JSError;

pub const ExceptionValueRef = [*c]js.JSValueRef;
pub const JSValueRef = js.JSValueRef;

pub const Lifetime = enum {
    allocated,
    temporary,
};

/// Marshall a zig value into a JSValue using comptime reflection.
///
/// - Primitives are converted to their JS equivalent.
/// - Types with `toJS` or `toJSNewlyCreated` methods have them called
/// - Slices are converted to JS arrays
/// - Enums are converted to 32-bit numbers.
pub fn toJS(globalObject: *JSC.JSGlobalObject, comptime ValueType: type, value: ValueType, comptime lifetime: Lifetime) JSC.JSValue {
    const Type = comptime brk: {
        var CurrentType = ValueType;
        if (@typeInfo(ValueType) == .optional) {
            CurrentType = @typeInfo(ValueType).optional.child;
        }
        break :brk if (@typeInfo(CurrentType) == .pointer and @typeInfo(CurrentType).pointer.size == .one)
            @typeInfo(CurrentType).pointer.child
        else
            CurrentType;
    };

    if (comptime bun.trait.isNumber(Type)) {
        return JSC.JSValue.jsNumberWithType(Type, if (comptime Type != ValueType) value.* else value);
    }

    switch (comptime Type) {
        void => return .undefined,
        bool => return JSC.JSValue.jsBoolean(if (comptime Type != ValueType) value.* else value),
        *JSC.JSGlobalObject => return value.toJSValue(),
        []const u8, [:0]const u8, [*:0]const u8, []u8, [:0]u8, [*:0]u8 => {
            return bun.String.createUTF8ForJS(globalObject, value);
        },
        []const bun.String => {
            defer {
                for (value) |out| {
                    out.deref();
                }
                bun.default_allocator.free(value);
            }
            return bun.String.toJSArray(globalObject, value);
        },
        JSC.JSValue => return if (Type != ValueType) value.* else value,

        inline []const u16, []const u32, []const i16, []const i8, []const i32, []const f32 => {
            var array = JSC.JSValue.createEmptyArray(globalObject, value.len);
            for (value, 0..) |item, i| {
                array.putIndex(
                    globalObject,
                    @truncate(i),
                    JSC.jsNumber(item),
                );
            }
            return array;
        },

        else => {

            // Recursion can stack overflow here
            if (bun.trait.isSlice(Type)) {
                const Child = comptime std.meta.Child(Type);

                var array = JSC.JSValue.createEmptyArray(globalObject, value.len);
                for (value, 0..) |*item, i| {
                    const res = toJS(globalObject, *Child, item, lifetime);
                    if (res == .zero) return .zero;
                    array.putIndex(
                        globalObject,
                        @truncate(i),
                        res,
                    );
                }
                return array;
            }

            if (comptime @hasDecl(Type, "toJSNewlyCreated") and @typeInfo(@TypeOf(@field(Type, "toJSNewlyCreated"))).@"fn".params.len == 2) {
                return value.toJSNewlyCreated(globalObject);
            }

            if (comptime @hasDecl(Type, "toJS") and @typeInfo(@TypeOf(@field(Type, "toJS"))).@"fn".params.len == 2) {
                return value.toJS(globalObject);
            }

            // must come after toJS check in case this enum implements its own serializer.
            if (@typeInfo(Type) == .@"enum") {
                // FIXME: creates non-normalized integers (e.g. u2), which
                // aren't handled by `jsNumberWithType` rn
                return JSC.JSValue.jsNumberWithType(u32, @as(u32, @intFromEnum(value)));
            }

            @compileError("dont know how to convert " ++ @typeName(ValueType) ++ " to JS");
        },
    }
}

pub const Properties = struct {
    pub const UTF8 = struct {
        pub var filepath: string = "filepath";

        pub const module: string = "module";
        pub const globalThis: string = "globalThis";
        pub const exports: string = "exports";
        pub const log: string = "log";
        pub const debug: string = "debug";
        pub const name: string = "name";
        pub const info: string = "info";
        pub const error_: string = "error";
        pub const warn: string = "warn";
        pub const console: string = "console";
        pub const require: string = "require";
        pub const description: string = "description";
        pub const initialize_bundled_module: string = "$$m";
        pub const load_module_function: string = "$lOaDuRcOdE$";
        pub const window: string = "window";
        pub const default: string = "default";
        pub const include: string = "include";

        pub const env: string = "env";

        pub const GET = "GET";
        pub const PUT = "PUT";
        pub const POST = "POST";
        pub const PATCH = "PATCH";
        pub const HEAD = "HEAD";
        pub const OPTIONS = "OPTIONS";

        pub const navigate = "navigate";
        pub const follow = "follow";
    };

    pub const Refs = struct {
        pub var empty_string_ptr = [_]u8{0};
        pub var empty_string: js.JSStringRef = undefined;
    };

    pub fn init() void {
        Refs.empty_string = js.JSStringCreateWithUTF8CString(&Refs.empty_string_ptr);
    }
};

pub const PathString = bun.PathString;

pub fn createError(
    globalThis: *JSC.JSGlobalObject,
    comptime fmt: string,
    args: anytype,
) JSC.JSValue {
    if (comptime std.meta.fields(@TypeOf(args)).len == 0) {
        var zig_str = JSC.ZigString.init(fmt);
        if (comptime !strings.isAllASCII(fmt)) {
            zig_str.markUTF16();
        }

        return zig_str.toErrorInstance(globalThis);
    } else {
        var fallback = std.heap.stackFallback(256, default_allocator);
        var allocator = fallback.get();

        const buf = std.fmt.allocPrint(allocator, fmt, args) catch unreachable;
        var zig_str = JSC.ZigString.init(buf);
        zig_str.detectEncoding();
        // it alwayas clones
        const res = zig_str.toErrorInstance(globalThis);
        allocator.free(buf);
        return res;
    }
}

fn toTypeErrorWithCode(
    code: []const u8,
    comptime fmt: string,
    args: anytype,
    ctx: js.JSContextRef,
) JSC.JSValue {
    @branchHint(.cold);
    var zig_str: JSC.ZigString = undefined;
    if (comptime std.meta.fields(@TypeOf(args)).len == 0) {
        zig_str = JSC.ZigString.init(fmt);
        zig_str.detectEncoding();
    } else {
        const buf = std.fmt.allocPrint(default_allocator, fmt, args) catch unreachable;
        zig_str = JSC.ZigString.init(buf);
        zig_str.detectEncoding();
        zig_str.mark();
    }
    const code_str = JSC.ZigString.init(code);
    return JSC.JSValue.createTypeError(&zig_str, &code_str, ctx);
}

pub fn toTypeError(
    code: JSC.Error,
    comptime fmt: [:0]const u8,
    args: anytype,
    ctx: js.JSContextRef,
) JSC.JSValue {
    return code.fmt(ctx, fmt, args);
}

pub fn throwInvalidArguments(
    comptime fmt: [:0]const u8,
    args: anytype,
    ctx: js.JSContextRef,
    exception: ExceptionValueRef,
) void {
    @branchHint(.cold);
    exception.* = JSC.Error.ERR_INVALID_ARG_TYPE.fmt(ctx, fmt, args).asObjectRef();
}

pub fn toInvalidArguments(
    comptime fmt: [:0]const u8,
    args: anytype,
    ctx: js.JSContextRef,
) JSC.JSValue {
    @branchHint(.cold);
    return JSC.Error.ERR_INVALID_ARG_TYPE.fmt(ctx, fmt, args);
}

pub fn getAllocator(_: js.JSContextRef) std.mem.Allocator {
    return default_allocator;
}

/// Print a JSValue to stdout; this is only meant for debugging purposes
pub fn dump(value: JSC.WebCore.JSValue, globalObject: *JSC.JSGlobalObject) !void {
    var formatter = JSC.ConsoleObject.Formatter{ .globalThis = globalObject };
    defer formatter.deinit();
    try Output.errorWriter().print("{}\n", .{value.toFmt(globalObject, &formatter)});
    Output.flush();
}

pub const JSStringList = std.ArrayList(js.JSStringRef);

pub const ArrayBuffer = extern struct {
    ptr: [*]u8 = undefined,
    offset: usize = 0,
    len: usize = 0,
    byte_len: usize = 0,
    typed_array_type: JSC.JSValue.JSType = .Cell,
    value: JSC.JSValue = JSC.JSValue.zero,
    shared: bool = false,

    // require('buffer').kMaxLength.
    // keep in sync with Bun::Buffer::kMaxLength
    pub const max_size = std.math.maxInt(c_uint);

    extern fn JSBuffer__fromMmap(*JSC.JSGlobalObject, addr: *anyopaque, len: usize) JSC.JSValue;

    // 4 MB or so is pretty good for mmap()
    const mmap_threshold = 1024 * 1024 * 4;

    pub fn bytesPerElement(this: *const ArrayBuffer) ?u8 {
        return switch (this.typed_array_type) {
            .ArrayBuffer, .DataView => null,
            .Uint8Array, .Uint8ClampedArray, .Int8Array => 1,
            .Uint16Array, .Int16Array, .Float16Array => 2,
            .Uint32Array, .Int32Array, .Float32Array => 4,
            .BigUint64Array, .BigInt64Array, .Float64Array => 8,
            else => null,
        };
    }

    /// Only use this when reading from the file descriptor is _very_ cheap. Like, for example, an in-memory file descriptor.
    /// Do not use this for pipes, however tempting it may seem.
    pub fn toJSBufferFromFd(fd: bun.FileDescriptor, size: usize, globalObject: *JSC.JSGlobalObject) JSC.JSValue {
        const buffer_value = Bun__createUint8ArrayForCopy(globalObject, null, size, true);
        if (buffer_value == .zero) {
            return .zero;
        }

        var array_buffer = buffer_value.asArrayBuffer(globalObject) orelse @panic("Unexpected");
        var bytes = array_buffer.byteSlice();

        buffer_value.ensureStillAlive();

        var read: isize = 0;
        while (bytes.len > 0) {
            switch (bun.sys.pread(fd, bytes, read)) {
                .result => |amount| {
                    bytes = bytes[amount..];
                    read += @intCast(amount);

                    if (amount == 0) {
                        if (bytes.len > 0) {
                            @memset(bytes, 0);
                        }
                        break;
                    }
                },
                .err => |err| {
                    return globalObject.throwValue(err.toJSC(globalObject)) catch .zero;
                },
            }
        }

        buffer_value.ensureStillAlive();

        return buffer_value;
    }

    extern fn ArrayBuffer__fromSharedMemfd(fd: i64, globalObject: *JSC.JSGlobalObject, byte_offset: usize, byte_length: usize, total_size: usize, JSC.JSValue.JSType) JSC.JSValue;
    pub const toArrayBufferFromSharedMemfd = ArrayBuffer__fromSharedMemfd;

    pub fn toJSBufferFromMemfd(fd: bun.FileDescriptor, globalObject: *JSC.JSGlobalObject) bun.JSError!JSC.JSValue {
        const stat = switch (bun.sys.fstat(fd)) {
            .err => |err| {
                _ = bun.sys.close(fd);
                return globalObject.throwValue(err.toJSC(globalObject));
            },
            .result => |fstat| fstat,
        };

        const size = stat.size;

        if (size == 0) {
            _ = bun.sys.close(fd);
            return createBuffer(globalObject, "");
        }

        // mmap() is kind of expensive to do
        // It creates a new memory mapping.
        // If there is a lot of repetitive memory allocations in a tight loop, it performs poorly.
        // So we clone it when it's small.
        if (size < mmap_threshold) {
            const result = toJSBufferFromFd(fd, @intCast(size), globalObject);
            _ = bun.sys.close(fd);
            return result;
        }

        const result = bun.sys.mmap(
            null,
            @intCast(@max(size, 0)),
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        _ = bun.sys.close(fd);

        switch (result) {
            .result => |buf| {
                return JSBuffer__fromMmap(globalObject, buf.ptr, buf.len);
            },
            .err => |err| {
                return globalObject.throwValue(err.toJSC(globalObject));
            },
        }
    }

    pub const Strong = struct {
        array_buffer: ArrayBuffer,
        held: JSC.Strong = .empty,

        pub fn clear(this: *ArrayBuffer.Strong) void {
            var ref: *JSC.napi.Ref = this.ref orelse return;
            ref.set(JSC.JSValue.zero);
        }

        pub fn slice(this: *const ArrayBuffer.Strong) []u8 {
            return this.array_buffer.slice();
        }

        pub fn deinit(this: *ArrayBuffer.Strong) void {
            this.held.deinit();
        }
    };

    pub const empty = ArrayBuffer{ .offset = 0, .len = 0, .byte_len = 0, .typed_array_type = .Uint8Array, .ptr = undefined };

    pub const name = "Bun__ArrayBuffer";
    pub const Stream = std.io.FixedBufferStream([]u8);

    pub inline fn stream(this: ArrayBuffer) Stream {
        return Stream{ .pos = 0, .buf = this.slice() };
    }

    // TODO: this can throw an error! should use JSError!JSValue
    pub fn create(globalThis: *JSC.JSGlobalObject, bytes: []const u8, comptime kind: JSC.JSValue.JSType) JSC.JSValue {
        JSC.markBinding(@src());
        return switch (comptime kind) {
            .Uint8Array => Bun__createUint8ArrayForCopy(globalThis, bytes.ptr, bytes.len, false),
            .ArrayBuffer => Bun__createArrayBufferForCopy(globalThis, bytes.ptr, bytes.len),
            else => @compileError("Not implemented yet"),
        };
    }

    pub fn createEmpty(globalThis: *JSC.JSGlobalObject, comptime kind: JSC.JSValue.JSType) JSC.JSValue {
        JSC.markBinding(@src());

        return switch (comptime kind) {
            .Uint8Array => Bun__createUint8ArrayForCopy(globalThis, null, 0, false),
            .ArrayBuffer => Bun__createArrayBufferForCopy(globalThis, null, 0),
            else => @compileError("Not implemented yet"),
        };
    }

    pub fn createBuffer(globalThis: *JSC.JSGlobalObject, bytes: []const u8) JSC.JSValue {
        JSC.markBinding(@src());
        return Bun__createUint8ArrayForCopy(globalThis, bytes.ptr, bytes.len, true);
    }

    pub fn createUint8Array(globalThis: *JSC.JSGlobalObject, bytes: []const u8) JSC.JSValue {
        JSC.markBinding(@src());
        return Bun__createUint8ArrayForCopy(globalThis, bytes.ptr, bytes.len, false);
    }

    extern "c" fn Bun__allocUint8ArrayForCopy(*JSC.JSGlobalObject, usize, **anyopaque) JSC.JSValue;
    extern "c" fn Bun__allocArrayBufferForCopy(*JSC.JSGlobalObject, usize, **anyopaque) JSC.JSValue;

    pub fn alloc(global: *JSC.JSGlobalObject, comptime kind: JSC.JSValue.JSType, len: u32) JSError!struct { JSC.JSValue, []u8 } {
        var ptr: [*]u8 = undefined;
        const buf = switch (comptime kind) {
            .Uint8Array => Bun__allocUint8ArrayForCopy(global, len, @ptrCast(&ptr)),
            .ArrayBuffer => Bun__allocArrayBufferForCopy(global, len, @ptrCast(&ptr)),
            else => @compileError("Not implemented yet"),
        };
        if (buf == .zero) {
            return error.JSError;
        }
        return .{ buf, ptr[0..len] };
    }

    extern "c" fn Bun__createUint8ArrayForCopy(*JSC.JSGlobalObject, ptr: ?*const anyopaque, len: usize, buffer: bool) JSC.JSValue;
    extern "c" fn Bun__createArrayBufferForCopy(*JSC.JSGlobalObject, ptr: ?*const anyopaque, len: usize) JSC.JSValue;

    pub fn fromTypedArray(ctx: JSC.C.JSContextRef, value: JSC.JSValue) ArrayBuffer {
        var out = std.mem.zeroes(ArrayBuffer);
        const was = value.asArrayBuffer_(ctx, &out);
        bun.assert(was);
        out.value = value;
        return out;
    }

    extern "c" fn JSArrayBuffer__fromDefaultAllocator(*JSC.JSGlobalObject, ptr: [*]u8, len: usize) JSC.JSValue;
    pub fn toJSFromDefaultAllocator(globalThis: *JSC.JSGlobalObject, bytes: []u8) JSC.JSValue {
        return JSArrayBuffer__fromDefaultAllocator(globalThis, bytes.ptr, bytes.len);
    }

    pub fn fromDefaultAllocator(globalThis: *JSC.JSGlobalObject, bytes: []u8, comptime typed_array_type: JSC.JSValue.JSType) JSC.JSValue {
        return switch (typed_array_type) {
            .ArrayBuffer => JSArrayBuffer__fromDefaultAllocator(globalThis, bytes.ptr, bytes.len),
            .Uint8Array => JSC.JSUint8Array.fromBytes(globalThis, bytes),
            else => @compileError("Not implemented yet"),
        };
    }

    pub fn fromBytes(bytes: []u8, typed_array_type: JSC.JSValue.JSType) ArrayBuffer {
        return ArrayBuffer{ .offset = 0, .len = @as(u32, @intCast(bytes.len)), .byte_len = @as(u32, @intCast(bytes.len)), .typed_array_type = typed_array_type, .ptr = bytes.ptr };
    }

    pub fn toJSUnchecked(this: ArrayBuffer, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) JSC.JSValue {

        // The reason for this is
        // JSC C API returns a detached arraybuffer
        // if you pass it a zero-length TypedArray
        // we don't ever want to send the user a detached arraybuffer
        // that's just silly.
        if (this.byte_len == 0) {
            if (this.typed_array_type == .ArrayBuffer) {
                return create(ctx, "", .ArrayBuffer);
            }

            if (this.typed_array_type == .Uint8Array) {
                return create(ctx, "", .Uint8Array);
            }

            // TODO: others
        }

        if (this.typed_array_type == .ArrayBuffer) {
            return JSC.JSValue.fromRef(JSC.C.JSObjectMakeArrayBufferWithBytesNoCopy(
                ctx,
                this.ptr,
                this.byte_len,
                MarkedArrayBuffer_deallocator,
                @as(*anyopaque, @ptrFromInt(@intFromPtr(&bun.default_allocator))),
                exception,
            ));
        }

        return JSC.JSValue.fromRef(JSC.C.JSObjectMakeTypedArrayWithBytesNoCopy(
            ctx,
            this.typed_array_type.toC(),
            this.ptr,
            this.byte_len,
            MarkedArrayBuffer_deallocator,
            @as(*anyopaque, @ptrFromInt(@intFromPtr(&bun.default_allocator))),
            exception,
        ));
    }

    const log = Output.scoped(.ArrayBuffer, false);

    pub fn toJS(this: ArrayBuffer, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) JSC.JSValue {
        if (this.value != .zero) {
            return this.value;
        }

        // If it's not a mimalloc heap buffer, we're not going to call a deallocator
        if (this.len > 0 and !bun.Mimalloc.mi_is_in_heap_region(this.ptr)) {
            log("toJS but will never free: {d} bytes", .{this.len});

            if (this.typed_array_type == .ArrayBuffer) {
                return JSC.JSValue.fromRef(JSC.C.JSObjectMakeArrayBufferWithBytesNoCopy(
                    ctx,
                    this.ptr,
                    this.byte_len,
                    null,
                    null,
                    exception,
                ));
            }

            return JSC.JSValue.fromRef(JSC.C.JSObjectMakeTypedArrayWithBytesNoCopy(
                ctx,
                this.typed_array_type.toC(),
                this.ptr,
                this.byte_len,
                null,
                null,
                exception,
            ));
        }

        return this.toJSUnchecked(ctx, exception);
    }

    pub fn toJSWithContext(
        this: ArrayBuffer,
        ctx: JSC.C.JSContextRef,
        deallocator: ?*anyopaque,
        callback: JSC.C.JSTypedArrayBytesDeallocator,
        exception: JSC.C.ExceptionRef,
    ) JSC.JSValue {
        if (this.value != .zero) {
            return this.value;
        }

        if (this.typed_array_type == .ArrayBuffer) {
            return JSC.JSValue.fromRef(JSC.C.JSObjectMakeArrayBufferWithBytesNoCopy(
                ctx,
                this.ptr,
                this.byte_len,
                callback,
                deallocator,
                exception,
            ));
        }

        return JSC.JSValue.fromRef(JSC.C.JSObjectMakeTypedArrayWithBytesNoCopy(
            ctx,
            this.typed_array_type.toC(),
            this.ptr,
            this.byte_len,
            callback,
            deallocator,
            exception,
        ));
    }

    pub const fromArrayBuffer = fromTypedArray;

    /// The equivalent of
    ///
    /// ```js
    ///    new ArrayBuffer(view.buffer, view.byteOffset, view.byteLength)
    /// ```
    pub inline fn byteSlice(this: *const @This()) []u8 {
        return this.ptr[this.offset..][0..this.byte_len];
    }

    /// The equivalent of
    ///
    /// ```js
    ///    new ArrayBuffer(view.buffer, view.byteOffset, view.byteLength)
    /// ```
    pub const slice = byteSlice;

    pub inline fn asU16(this: *const @This()) []u16 {
        return std.mem.bytesAsSlice(u16, @as([*]u16, @ptrCast(@alignCast(this.ptr)))[this.offset..this.byte_len]);
    }

    pub inline fn asU16Unaligned(this: *const @This()) []align(1) u16 {
        return std.mem.bytesAsSlice(u16, @as([*]align(1) u16, @ptrCast(@alignCast(this.ptr)))[this.offset..this.byte_len]);
    }

    pub inline fn asU32(this: *const @This()) []u32 {
        return std.mem.bytesAsSlice(u32, @as([*]u32, @ptrCast(@alignCast(this.ptr)))[this.offset..this.byte_len]);
    }
};

pub const MarkedArrayBuffer = struct {
    buffer: ArrayBuffer = .{},
    allocator: ?std.mem.Allocator = null,

    pub const Stream = ArrayBuffer.Stream;

    pub inline fn stream(this: *MarkedArrayBuffer) Stream {
        return this.buffer.stream();
    }

    pub fn fromTypedArray(ctx: JSC.C.JSContextRef, value: JSC.JSValue) MarkedArrayBuffer {
        return MarkedArrayBuffer{
            .allocator = null,
            .buffer = ArrayBuffer.fromTypedArray(ctx, value),
        };
    }

    pub fn fromArrayBuffer(ctx: JSC.C.JSContextRef, value: JSC.JSValue) MarkedArrayBuffer {
        return MarkedArrayBuffer{
            .allocator = null,
            .buffer = ArrayBuffer.fromArrayBuffer(ctx, value),
        };
    }

    pub fn fromString(str: []const u8, allocator: std.mem.Allocator) !MarkedArrayBuffer {
        const buf = try allocator.dupe(u8, str);
        return MarkedArrayBuffer.fromBytes(buf, allocator, JSC.JSValue.JSType.Uint8Array);
    }

    pub fn fromJS(global: *JSC.JSGlobalObject, value: JSC.JSValue) ?MarkedArrayBuffer {
        const array_buffer = value.asArrayBuffer(global) orelse return null;
        return MarkedArrayBuffer{ .buffer = array_buffer, .allocator = null };
    }

    pub fn fromBytes(bytes: []u8, allocator: std.mem.Allocator, typed_array_type: JSC.JSValue.JSType) MarkedArrayBuffer {
        return MarkedArrayBuffer{
            .buffer = ArrayBuffer.fromBytes(bytes, typed_array_type),
            .allocator = allocator,
        };
    }

    pub const empty = MarkedArrayBuffer{
        .allocator = null,
        .buffer = ArrayBuffer.empty,
    };

    pub inline fn slice(this: *const @This()) []u8 {
        return this.buffer.byteSlice();
    }

    pub fn destroy(this: *MarkedArrayBuffer) void {
        const content = this.*;
        if (this.allocator) |allocator| {
            this.allocator = null;
            allocator.free(content.buffer.slice());
            allocator.destroy(this);
        }
    }

    pub fn init(allocator: std.mem.Allocator, size: u32, typed_array_type: JSC.JSValue.JSType) !*MarkedArrayBuffer {
        const bytes = try allocator.alloc(u8, size);
        const container = try allocator.create(MarkedArrayBuffer);
        container.* = MarkedArrayBuffer.fromBytes(bytes, allocator, typed_array_type);
        return container;
    }

    pub fn toNodeBuffer(this: *const MarkedArrayBuffer, ctx: js.JSContextRef) JSC.JSValue {
        return JSC.JSValue.createBufferWithCtx(ctx, this.buffer.byteSlice(), this.buffer.ptr, MarkedArrayBuffer_deallocator);
    }

    pub fn toJSObjectRef(this: *const MarkedArrayBuffer, ctx: js.JSContextRef, exception: js.ExceptionRef) js.JSObjectRef {
        if (!this.buffer.value.isEmptyOrUndefinedOrNull()) {
            return this.buffer.value.asObjectRef();
        }
        if (this.buffer.byte_len == 0) {
            return js.JSObjectMakeTypedArray(
                ctx,
                this.buffer.typed_array_type.toC(),
                0,
                exception,
            );
        }

        return js.JSObjectMakeTypedArrayWithBytesNoCopy(
            ctx,
            this.buffer.typed_array_type.toC(),
            this.buffer.ptr,

            this.buffer.byte_len,
            MarkedArrayBuffer_deallocator,
            this.buffer.ptr,
            exception,
        );
    }

    // TODO: refactor this
    pub fn toJS(this: *const MarkedArrayBuffer, globalObject: *JSC.JSGlobalObject) JSC.JSValue {
        var exception = [_]JSC.C.JSValueRef{null};
        const obj = this.toJSObjectRef(globalObject, &exception);

        if (exception[0] != null) {
            return globalObject.throwValue(JSC.JSValue.c(exception[0])) catch return .zero;
        }

        return JSC.JSValue.c(obj);
    }
};

// expensive heap reference-counted string type
// only use this for big strings
// like source code
// not little ones
pub const RefString = struct {
    ptr: [*]const u8 = undefined,
    len: usize = 0,
    hash: Hash = 0,
    impl: bun.WTF.StringImpl,

    allocator: std.mem.Allocator,

    ctx: ?*anyopaque = null,
    onBeforeDeinit: ?*const Callback = null,

    pub const Hash = u32;
    pub const Map = std.HashMap(Hash, *JSC.RefString, IdentityContext(Hash), 80);

    pub fn toJS(this: *RefString, global: *JSC.JSGlobalObject) JSC.JSValue {
        return bun.String.init(this.impl).toJS(global);
    }

    pub const Callback = fn (ctx: *anyopaque, str: *RefString) void;

    pub fn computeHash(input: []const u8) u32 {
        return std.hash.XxHash32.hash(0, input);
    }

    pub fn slice(this: *RefString) []const u8 {
        this.ref();

        return this.leak();
    }

    pub fn ref(this: *RefString) void {
        this.impl.ref();
    }

    pub fn leak(this: RefString) []const u8 {
        @setRuntimeSafety(false);
        return this.ptr[0..this.len];
    }

    pub fn deref(this: *RefString) void {
        this.impl.deref();
    }

    pub fn deinit(this: *RefString) void {
        if (this.onBeforeDeinit) |onBeforeDeinit| {
            onBeforeDeinit(this.ctx.?, this);
        }

        this.allocator.free(this.leak());
        this.allocator.destroy(this);
    }
};

pub export fn MarkedArrayBuffer_deallocator(bytes_: *anyopaque, _: *anyopaque) void {
    const mimalloc = @import("../allocators/mimalloc.zig");
    // zig's memory allocator interface won't work here
    // mimalloc knows the size of things
    // but we don't
    // if (comptime Environment.allow_assert) {
    //     bun.assert(mimalloc.mi_check_owned(bytes_) or
    //         mimalloc.mi_heap_check_owned(JSC.VirtualMachine.get().arena.heap.?, bytes_));
    // }

    mimalloc.mi_free(bytes_);
}

pub export fn BlobArrayBuffer_deallocator(_: *anyopaque, blob: *anyopaque) void {
    // zig's memory allocator interface won't work here
    // mimalloc knows the size of things
    // but we don't
    var store = bun.cast(*JSC.WebCore.Blob.Store, blob);
    store.deref();
}

const Expect = Test.Expect;
const DescribeScope = Test.DescribeScope;
const TestScope = Test.TestScope;
const NodeFS = JSC.Node.NodeFS;
const TextEncoder = JSC.WebCore.TextEncoder;
const TextDecoder = JSC.WebCore.TextDecoder;
const TextEncoderStreamEncoder = JSC.WebCore.TextEncoderStreamEncoder;
const HTMLRewriter = JSC.Cloudflare.HTMLRewriter;
const Element = JSC.Cloudflare.Element;
const Comment = JSC.Cloudflare.Comment;
const TextChunk = JSC.Cloudflare.TextChunk;
const DocType = JSC.Cloudflare.DocType;
const EndTag = JSC.Cloudflare.EndTag;
const DocEnd = JSC.Cloudflare.DocEnd;
const AttributeIterator = JSC.Cloudflare.AttributeIterator;
const Blob = JSC.WebCore.Blob;
const Server = JSC.API.Server;
const SSLServer = JSC.API.SSLServer;
const DebugServer = JSC.API.DebugServer;
const DebugSSLServer = JSC.API.DebugSSLServer;
const SHA1 = JSC.API.Bun.Crypto.SHA1;
const MD5 = JSC.API.Bun.Crypto.MD5;
const MD4 = JSC.API.Bun.Crypto.MD4;
const SHA224 = JSC.API.Bun.Crypto.SHA224;
const SHA512 = JSC.API.Bun.Crypto.SHA512;
const SHA384 = JSC.API.Bun.Crypto.SHA384;
const SHA256 = JSC.API.Bun.Crypto.SHA256;
const SHA512_256 = JSC.API.Bun.Crypto.SHA512_256;
const MD5_SHA1 = JSC.API.Bun.Crypto.MD5_SHA1;
const FFI = JSC.FFI;

pub const JSPropertyNameIterator = struct {
    array: js.JSPropertyNameArrayRef,
    count: u32,
    i: u32 = 0,

    pub fn next(this: *JSPropertyNameIterator) ?js.JSStringRef {
        if (this.i >= this.count) return null;
        const i = this.i;
        this.i += 1;

        return js.JSPropertyNameArrayGetNameAtIndex(this.array, i);
    }
};

pub const DOMEffect = struct {
    reads: [4]ID = std.mem.zeroes([4]ID),
    writes: [4]ID = std.mem.zeroes([4]ID),

    pub const top = DOMEffect{
        .reads = .{ ID.Heap, ID.Heap, ID.Heap, ID.Heap },
        .writes = .{ ID.Heap, ID.Heap, ID.Heap, ID.Heap },
    };

    pub fn forRead(read: ID) DOMEffect {
        return DOMEffect{
            .reads = .{ read, ID.Heap, ID.Heap, ID.Heap },
            .writes = .{ ID.Heap, ID.Heap, ID.Heap, ID.Heap },
        };
    }

    pub fn forWrite(read: ID) DOMEffect {
        return DOMEffect{
            .writes = .{ read, ID.Heap, ID.Heap, ID.Heap },
            .reads = .{ ID.Heap, ID.Heap, ID.Heap, ID.Heap },
        };
    }

    pub const pure = DOMEffect{};

    pub fn isPure(this: DOMEffect) bool {
        return this.reads[0] == ID.InvalidAbstractHeap and this.writes[0] == ID.InvalidAbstractHeap;
    }

    pub const ID = enum(u8) {
        InvalidAbstractHeap = 0,
        World,
        Stack,
        Heap,
        Butterfly_publicLength,
        Butterfly_vectorLength,
        GetterSetter_getter,
        GetterSetter_setter,
        JSCell_cellState,
        JSCell_indexingType,
        JSCell_structureID,
        JSCell_typeInfoFlags,
        JSObject_butterfly,
        JSPropertyNameEnumerator_cachedPropertyNames,
        RegExpObject_lastIndex,
        NamedProperties,
        IndexedInt32Properties,
        IndexedDoubleProperties,
        IndexedContiguousProperties,
        IndexedArrayStorageProperties,
        DirectArgumentsProperties,
        ScopeProperties,
        TypedArrayProperties,
        /// Used to reflect the fact that some allocations reveal object identity */
        HeapObjectCount,
        RegExpState,
        MathDotRandomState,
        JSDateFields,
        JSMapFields,
        JSSetFields,
        JSWeakMapFields,
        WeakSetFields,
        JSInternalFields,
        InternalState,
        CatchLocals,
        Absolute,
        /// DOMJIT tells the heap range with the pair of integers. */
        DOMState,
        /// Use this for writes only, to indicate that this may fire watchpoints. Usually this is never directly written but instead we test to see if a node clobbers this; it just so happens that you have to write world to clobber it. */
        Watchpoint_fire,
        /// Use these for reads only, just to indicate that if the world got clobbered, then this operation will not work. */
        MiscFields,
        /// Use this for writes only, just to indicate that hoisting the node is invalid. This works because we don't hoist anything that has any side effects at all. */
        SideState,
    };
};

fn DOMCallArgumentType(comptime Type: type) []const u8 {
    const ChildType = if (@typeInfo(Type) == .pointer) std.meta.Child(Type) else Type;
    return switch (ChildType) {
        i8, u8, i16, u16, i32 => "JSC::SpecInt32Only",
        u32, i64, u64 => "JSC::SpecInt52Any",
        f64 => "JSC::SpecDoubleReal",
        bool => "JSC::SpecBoolean",
        JSC.JSString => "JSC::SpecString",
        JSC.JSUint8Array => "JSC::SpecUint8Array",
        else => @compileError("Unknown DOM type: " ++ @typeName(Type)),
    };
}

fn DOMCallArgumentTypeWrapper(comptime Type: type) []const u8 {
    const ChildType = if (@typeInfo(Type) == .pointer) std.meta.Child(Type) else Type;
    return switch (ChildType) {
        i32 => "int32_t",
        f64 => "double",
        u64 => "uint64_t",
        i64 => "int64_t",
        bool => "bool",
        JSC.JSString => "JSC::JSString*",
        JSC.JSUint8Array => "JSC::JSUint8Array*",
        else => @compileError("Unknown DOM type: " ++ @typeName(Type)),
    };
}

fn DOMCallResultType(comptime Type: type) []const u8 {
    const ChildType = if (@typeInfo(Type) == .pointer) std.meta.Child(Type) else Type;
    return switch (ChildType) {
        i32 => "JSC::SpecInt32Only",
        bool => "JSC::SpecBoolean",
        JSC.JSString => "JSC::SpecString",
        JSC.JSUint8Array => "JSC::SpecUint8Array",
        JSC.JSCell => "JSC::SpecCell",
        u52, i52 => "JSC::SpecInt52Any",
        f64 => "JSC::SpecDoubleReal",
        else => "JSC::SpecHeapTop",
    };
}

pub fn DOMCall(
    comptime class_name: string,
    comptime Container: type,
    comptime functionName: string,
    comptime dom_effect: DOMEffect,
) type {
    return extern struct {
        const className = class_name;
        pub const is_dom_call = true;
        const Slowpath = @field(Container, functionName);
        const SlowpathType = @TypeOf(@field(Container, functionName));

        // Zig doesn't support @frameAddress(1)
        // so we have to add a small wrapper fujnction
        pub fn slowpath(
            globalObject: *JSC.JSGlobalObject,
            thisValue: JSC.JSValue,
            arguments_ptr: [*]const JSC.JSValue,
            arguments_len: usize,
        ) callconv(JSC.conv) JSC.JSValue {
            return JSC.toJSHostValue(globalObject, @field(Container, functionName)(globalObject, thisValue, arguments_ptr[0..arguments_len]));
        }

        pub const fastpath = @field(Container, functionName ++ "WithoutTypeChecks");
        pub const Fastpath = @TypeOf(fastpath);
        pub const Arguments = std.meta.ArgsTuple(Fastpath);
        const PutFnType = *const fn (globalObject: *JSC.JSGlobalObject, value: JSC.JSValue) callconv(.c) void;
        const put_fn = @extern(PutFnType, .{ .name = className ++ "__" ++ functionName ++ "__put" });

        pub fn put(globalObject: *JSC.JSGlobalObject, value: JSC.JSValue) void {
            put_fn(globalObject, value);
        }

        pub const effect = dom_effect;

        comptime {
            @export(&slowpath, .{ .name = className ++ "__" ++ functionName ++ "__slowpath" });
            @export(&fastpath, .{ .name = className ++ "__" ++ functionName ++ "__fastpath" });
        }
    };
}

pub fn InstanceMethodType(comptime Container: type) type {
    return fn (instance: *Container, globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSC.JSValue;
}

pub fn wrapInstanceMethod(
    comptime Container: type,
    comptime name: string,
    comptime auto_protect: bool,
) InstanceMethodType(Container) {
    return struct {
        const FunctionType = @TypeOf(@field(Container, name));
        const FunctionTypeInfo: std.builtin.Type.Fn = @typeInfo(FunctionType).@"fn";
        const Args = std.meta.ArgsTuple(FunctionType);
        const eater = if (auto_protect) JSC.Node.ArgumentsSlice.protectEatNext else JSC.Node.ArgumentsSlice.nextEat;

        pub fn method(
            this: *Container,
            globalThis: *JSC.JSGlobalObject,
            callframe: *JSC.CallFrame,
        ) bun.JSError!JSC.JSValue {
            const arguments = callframe.arguments_old(FunctionTypeInfo.params.len);
            var iter = JSC.Node.ArgumentsSlice.init(globalThis.bunVM(), arguments.slice());
            var args: Args = undefined;

            const has_exception_ref: bool = comptime brk: {
                for (FunctionTypeInfo.params) |param| {
                    if (param.type.? == JSC.C.ExceptionRef) {
                        break :brk true;
                    }
                }

                break :brk false;
            };
            var exception_value = [_]JSC.C.JSValueRef{null};
            const exception: JSC.C.ExceptionRef = if (comptime has_exception_ref) &exception_value else undefined;

            inline for (FunctionTypeInfo.params, 0..) |param, i| {
                const ArgType = param.type.?;
                switch (ArgType) {
                    *Container => {
                        args[i] = this;
                    },
                    *JSC.JSGlobalObject => {
                        args[i] = globalThis;
                    },
                    *JSC.CallFrame => {
                        args[i] = callframe;
                    },
                    JSC.Node.StringOrBuffer => {
                        const arg = iter.nextEat() orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("expected string or buffer", .{});
                        };
                        args[i] = try JSC.Node.StringOrBuffer.fromJS(globalThis, iter.arena.allocator(), arg) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("expected string or buffer", .{});
                        };
                    },
                    ?JSC.Node.StringOrBuffer => {
                        if (iter.nextEat()) |arg| {
                            if (!arg.isEmptyOrUndefinedOrNull()) {
                                args[i] = try JSC.Node.StringOrBuffer.fromJS(globalThis, iter.arena.allocator(), arg) orelse {
                                    iter.deinit();
                                    return globalThis.throwInvalidArguments("expected string or buffer", .{});
                                };
                            } else {
                                args[i] = null;
                            }
                        } else {
                            args[i] = null;
                        }
                    },
                    JSC.ArrayBuffer => {
                        if (iter.nextEat()) |arg| {
                            args[i] = arg.asArrayBuffer(globalThis) orelse {
                                iter.deinit();
                                return globalThis.throwInvalidArguments("expected TypedArray", .{});
                            };
                        } else {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("expected TypedArray", .{});
                        }
                    },
                    ?JSC.ArrayBuffer => {
                        if (iter.nextEat()) |arg| {
                            args[i] = arg.asArrayBuffer(globalThis) orelse {
                                iter.deinit();
                                return globalThis.throwInvalidArguments("expected TypedArray", .{});
                            };
                        } else {
                            args[i] = null;
                        }
                    },
                    JSC.ZigString => {
                        var string_value = eater(&iter) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Missing argument", .{});
                        };

                        if (string_value.isUndefinedOrNull()) {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Expected string", .{});
                        }

                        args[i] = try string_value.getZigString(globalThis);
                    },
                    ?JSC.Cloudflare.ContentOptions => {
                        if (iter.nextEat()) |content_arg| {
                            if (try content_arg.get(globalThis, "html")) |html_val| {
                                args[i] = .{ .html = html_val.toBoolean() };
                            }
                        } else {
                            args[i] = null;
                        }
                    },
                    *JSC.WebCore.Response => {
                        args[i] = (eater(&iter) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Missing Response object", .{});
                        }).as(JSC.WebCore.Response) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Expected Response object", .{});
                        };
                    },
                    *JSC.WebCore.Request => {
                        args[i] = (eater(&iter) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Missing Request object", .{});
                        }).as(JSC.WebCore.Request) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Expected Request object", .{});
                        };
                    },
                    JSC.JSValue => {
                        const val = eater(&iter) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Missing argument", .{});
                        };
                        args[i] = val;
                    },
                    ?JSC.JSValue => {
                        args[i] = eater(&iter);
                    },
                    JSC.C.ExceptionRef => {
                        args[i] = exception;
                    },
                    else => @compileError("Unexpected Type " ++ @typeName(ArgType)),
                }
            }

            defer iter.deinit();

            defer {
                if (comptime has_exception_ref) {
                    if (exception_value[0] != null) {
                        globalThis.throwValue(exception_value[0].?.value());
                    }
                }
            }

            return @call(.always_inline, @field(Container, name), args);
        }
    }.method;
}

pub fn wrapStaticMethod(
    comptime Container: type,
    comptime name: string,
    comptime auto_protect: bool,
) JSC.JSHostZigFunction {
    return struct {
        const FunctionType = @TypeOf(@field(Container, name));
        const FunctionTypeInfo: std.builtin.Type.Fn = @typeInfo(FunctionType).@"fn";
        const Args = std.meta.ArgsTuple(FunctionType);
        const eater = if (auto_protect) JSC.Node.ArgumentsSlice.protectEatNext else JSC.Node.ArgumentsSlice.nextEat;

        pub fn method(
            globalThis: *JSC.JSGlobalObject,
            callframe: *JSC.CallFrame,
        ) bun.JSError!JSC.JSValue {
            const arguments = callframe.arguments_old(FunctionTypeInfo.params.len);
            var iter = JSC.Node.ArgumentsSlice.init(globalThis.bunVM(), arguments.slice());
            var args: Args = undefined;

            inline for (FunctionTypeInfo.params, 0..) |param, i| {
                const ArgType = param.type.?;
                switch (param.type.?) {
                    *JSC.JSGlobalObject => {
                        args[i] = globalThis;
                    },
                    JSC.Node.StringOrBuffer => {
                        const arg = iter.nextEat() orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("expected string or buffer", .{});
                        };
                        args[i] = try JSC.Node.StringOrBuffer.fromJS(globalThis, iter.arena.allocator(), arg) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("expected string or buffer", .{});
                        };
                    },
                    ?JSC.Node.StringOrBuffer => {
                        if (iter.nextEat()) |arg| {
                            args[i] = try JSC.Node.StringOrBuffer.fromJS(globalThis, iter.arena.allocator(), arg) orelse brk: {
                                if (arg == .undefined) {
                                    break :brk null;
                                }

                                iter.deinit();
                                return globalThis.throwInvalidArguments("expected string or buffer", .{});
                            };
                        } else {
                            args[i] = null;
                        }
                    },
                    JSC.Node.BlobOrStringOrBuffer => {
                        if (iter.nextEat()) |arg| {
                            args[i] = try JSC.Node.BlobOrStringOrBuffer.fromJS(globalThis, iter.arena.allocator(), arg) orelse {
                                iter.deinit();
                                return globalThis.throwInvalidArguments("expected blob, string or buffer", .{});
                            };
                        } else {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("expected blob, string or buffer", .{});
                        }
                    },
                    JSC.ArrayBuffer => {
                        if (iter.nextEat()) |arg| {
                            args[i] = arg.asArrayBuffer(globalThis) orelse {
                                iter.deinit();
                                return globalThis.throwInvalidArguments("expected TypedArray", .{});
                            };
                        } else {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("expected TypedArray", .{});
                        }
                    },
                    ?JSC.ArrayBuffer => {
                        if (iter.nextEat()) |arg| {
                            args[i] = arg.asArrayBuffer(globalThis) orelse {
                                iter.deinit();
                                return globalThis.throwInvalidArguments("expected TypedArray", .{});
                            };
                        } else {
                            args[i] = null;
                        }
                    },
                    JSC.ZigString => {
                        var string_value = eater(&iter) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Missing argument", .{});
                        };

                        if (string_value.isUndefinedOrNull()) {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Expected string", .{});
                        }

                        args[i] = try string_value.getZigString(globalThis);
                    },
                    ?JSC.Cloudflare.ContentOptions => {
                        if (iter.nextEat()) |content_arg| {
                            if (try content_arg.get(globalThis, "html")) |html_val| {
                                args[i] = .{ .html = html_val.toBoolean() };
                            }
                        } else {
                            args[i] = null;
                        }
                    },
                    *JSC.WebCore.Response => {
                        args[i] = (eater(&iter) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Missing Response object", .{});
                        }).as(JSC.WebCore.Response) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Expected Response object", .{});
                        };
                    },
                    *JSC.WebCore.Request => {
                        args[i] = (eater(&iter) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Missing Request object", .{});
                        }).as(JSC.WebCore.Request) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Expected Request object", .{});
                        };
                    },
                    JSC.WebCore.JSValue => {
                        const val = eater(&iter) orelse {
                            iter.deinit();
                            return globalThis.throwInvalidArguments("Missing argument", .{});
                        };
                        args[i] = val;
                    },
                    ?JSC.WebCore.JSValue => {
                        args[i] = eater(&iter);
                    },
                    else => @compileError(std.fmt.comptimePrint("Unexpected Type " ++ @typeName(ArgType) ++ " at argument {d} in {s}#{s}", .{ i, @typeName(Container), name })),
                }
            }

            defer iter.deinit();

            return @call(.always_inline, @field(Container, name), args);
        }
    }.method;
}

/// Track whether an object should keep the event loop alive
pub const Ref = struct {
    has: bool = false,

    pub fn init() Ref {
        return .{};
    }

    pub fn unref(this: *Ref, vm: *JSC.VirtualMachine) void {
        if (!this.has)
            return;
        this.has = false;
        vm.active_tasks -= 1;
    }

    pub fn ref(this: *Ref, vm: *JSC.VirtualMachine) void {
        if (this.has)
            return;
        this.has = true;
        vm.active_tasks += 1;
    }
};

pub const Strong = @import("./Strong.zig");
pub const Weak = @import("./Weak.zig").Weak;
pub const WeakRefType = @import("./Weak.zig").WeakRefType;

pub const BinaryType = enum(u4) {
    Buffer,
    ArrayBuffer,
    Uint8Array,
    Uint16Array,
    Uint32Array,
    Int8Array,
    Int16Array,
    Int32Array,
    Float16Array,
    Float32Array,
    Float64Array,
    // DataView,

    pub fn toJSType(this: BinaryType) JSC.JSValue.JSType {
        return switch (this) {
            .ArrayBuffer => .ArrayBuffer,
            .Buffer => .Uint8Array,
            // .DataView => .DataView,
            .Float32Array => .Float32Array,
            .Float16Array => .Float16Array,
            .Float64Array => .Float64Array,
            .Int16Array => .Int16Array,
            .Int32Array => .Int32Array,
            .Int8Array => .Int8Array,
            .Uint16Array => .Uint16Array,
            .Uint32Array => .Uint32Array,
            .Uint8Array => .Uint8Array,
        };
    }

    pub fn toTypedArrayType(this: BinaryType) JSC.C.JSTypedArrayType {
        return this.toJSType().toC();
    }

    pub const Map = bun.ComptimeStringMap(
        BinaryType,
        .{
            .{ "ArrayBuffer", .ArrayBuffer },
            .{ "Buffer", .Buffer },
            // .{ "DataView", .DataView },
            .{ "Float32Array", .Float32Array },
            .{ "Float16Array", .Float16Array },
            .{ "Float64Array", .Float64Array },
            .{ "Int16Array", .Int16Array },
            .{ "Int32Array", .Int32Array },
            .{ "Int8Array", .Int8Array },
            .{ "Uint16Array", .Uint16Array },
            .{ "Uint32Array", .Uint32Array },
            .{ "Uint8Array", .Uint8Array },
            .{ "arraybuffer", .ArrayBuffer },
            .{ "buffer", .Buffer },
            // .{ "dataview", .DataView },
            .{ "float16array", .Float16Array },
            .{ "float32array", .Float32Array },
            .{ "float64array", .Float64Array },
            .{ "int16array", .Int16Array },
            .{ "int32array", .Int32Array },
            .{ "int8array", .Int8Array },
            .{ "nodebuffer", .Buffer },
            .{ "uint16array", .Uint16Array },
            .{ "uint32array", .Uint32Array },
            .{ "uint8array", .Uint8Array },
        },
    );

    pub fn fromString(input: []const u8) ?BinaryType {
        return Map.get(input);
    }

    pub fn fromJSValue(globalThis: *JSC.JSGlobalObject, input: JSC.JSValue) bun.JSError!?BinaryType {
        if (input.isString()) {
            return Map.getWithEql(try input.toBunString(globalThis), bun.String.eqlComptime);
        }

        return null;
    }

    /// This clones bytes
    pub fn toJS(this: BinaryType, bytes: []const u8, globalThis: *JSC.JSGlobalObject) JSC.JSValue {
        switch (this) {
            .Buffer => return JSC.ArrayBuffer.createBuffer(globalThis, bytes),
            .ArrayBuffer => return JSC.ArrayBuffer.create(globalThis, bytes, .ArrayBuffer),
            .Uint8Array => return JSC.ArrayBuffer.create(globalThis, bytes, .Uint8Array),

            // These aren't documented, but they are supported
            .Uint16Array, .Uint32Array, .Int8Array, .Int16Array, .Int32Array, .Float16Array, .Float32Array, .Float64Array => {
                const buffer = JSC.ArrayBuffer.create(globalThis, bytes, .ArrayBuffer);
                return JSC.JSValue.c(JSC.C.JSObjectMakeTypedArrayWithArrayBuffer(globalThis, this.toTypedArrayType(), buffer.asObjectRef(), null));
            },
        }
    }
};

pub const AsyncTaskTracker = struct {
    id: u64,

    pub fn init(vm: *JSC.VirtualMachine) AsyncTaskTracker {
        return .{ .id = vm.nextAsyncTaskID() };
    }

    pub fn didSchedule(this: AsyncTaskTracker, globalObject: *JSC.JSGlobalObject) void {
        if (this.id == 0) return;

        bun.JSC.Debugger.didScheduleAsyncCall(globalObject, bun.JSC.Debugger.AsyncCallType.EventListener, this.id, true);
    }

    pub fn didCancel(this: AsyncTaskTracker, globalObject: *JSC.JSGlobalObject) void {
        if (this.id == 0) return;

        bun.JSC.Debugger.didCancelAsyncCall(globalObject, bun.JSC.Debugger.AsyncCallType.EventListener, this.id);
    }

    pub fn willDispatch(this: AsyncTaskTracker, globalObject: *JSC.JSGlobalObject) void {
        if (this.id == 0) {
            return;
        }

        bun.JSC.Debugger.willDispatchAsyncCall(globalObject, bun.JSC.Debugger.AsyncCallType.EventListener, this.id);
    }

    pub fn didDispatch(this: AsyncTaskTracker, globalObject: *JSC.JSGlobalObject) void {
        if (this.id == 0) {
            return;
        }

        bun.JSC.Debugger.didDispatchAsyncCall(globalObject, bun.JSC.Debugger.AsyncCallType.EventListener, this.id);
    }
};

pub const MemoryReportingAllocator = struct {
    child_allocator: std.mem.Allocator,
    memory_cost: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    const log = Output.scoped(.MEM, false);

    fn alloc(context: *anyopaque, n: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const this: *MemoryReportingAllocator = @alignCast(@ptrCast(context));
        const result = this.child_allocator.rawAlloc(n, alignment, return_address) orelse return null;
        _ = this.memory_cost.fetchAdd(n, .monotonic);
        if (comptime Environment.allow_assert)
            log("malloc({d}) = {d}", .{ n, this.memory_cost.raw });
        return result;
    }

    pub fn discard(this: *MemoryReportingAllocator, buf: []const u8) void {
        _ = this.memory_cost.fetchSub(buf.len, .monotonic);
        if (comptime Environment.allow_assert)
            log("discard({d}) = {d}", .{ buf.len, this.memory_cost.raw });
    }

    fn resize(context: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const this: *MemoryReportingAllocator = @alignCast(@ptrCast(context));
        if (this.child_allocator.rawResize(buf, alignment, new_len, ret_addr)) {
            _ = this.memory_cost.fetchAdd(new_len -| buf.len, .monotonic);
            if (comptime Environment.allow_assert)
                log("resize() = {d}", .{this.memory_cost.raw});
            return true;
        } else {
            return false;
        }
    }

    fn free(context: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const this: *MemoryReportingAllocator = @alignCast(@ptrCast(context));
        this.child_allocator.rawFree(buf, alignment, ret_addr);

        if (comptime Environment.allow_assert) {
            // check for overflow, racily
            const prev = this.memory_cost.fetchSub(buf.len, .monotonic);
            _ = prev;
            // bun.assert(prev > this.memory_cost.load(.monotonic));

            log("free({d}) = {d}", .{ buf.len, this.memory_cost.raw });
        }
    }

    pub fn wrap(this: *MemoryReportingAllocator, allocator_: std.mem.Allocator) std.mem.Allocator {
        this.* = .{
            .child_allocator = allocator_,
        };

        return this.allocator();
    }

    pub fn allocator(this: *MemoryReportingAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = this,
            .vtable = &MemoryReportingAllocator.VTable,
        };
    }

    pub fn report(this: *MemoryReportingAllocator, vm: *JSC.VM) void {
        const mem = this.memory_cost.load(.monotonic);
        if (mem > 0) {
            vm.reportExtraMemory(mem);
            if (comptime Environment.allow_assert)
                log("report({d})", .{mem});
        }
    }

    pub inline fn assert(this: *const MemoryReportingAllocator) void {
        if (comptime !Environment.allow_assert) {
            return;
        }

        const memory_cost = this.memory_cost.load(.monotonic);
        if (memory_cost > 0) {
            Output.panic("MemoryReportingAllocator still has {d} bytes allocated", .{memory_cost});
        }
    }

    pub const VTable = std.mem.Allocator.VTable{
        .alloc = &MemoryReportingAllocator.alloc,
        .resize = &MemoryReportingAllocator.resize,
        .remap = &std.mem.Allocator.noRemap,
        .free = &MemoryReportingAllocator.free,
    };
};

/// According to https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Date,
/// maximum Date in JavaScript is less than Number.MAX_SAFE_INTEGER (u52).
pub const init_timestamp = std.math.maxInt(JSC.JSTimeType);
pub const JSTimeType = u52;

pub fn toJSTime(sec: isize, nsec: isize) JSTimeType {
    const millisec = @as(u64, @intCast(@divTrunc(nsec, std.time.ns_per_ms)));
    return @as(JSTimeType, @truncate(@as(u64, @intCast(sec * std.time.ms_per_s)) + millisec));
}
