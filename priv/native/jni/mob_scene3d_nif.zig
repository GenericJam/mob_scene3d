//! mob_scene3d_nif — Android NIF wire for the scene3d applier.
//!
//! Thin JNI forwarder (the mob_camera pattern): every NIF marshals its
//! binary args to the Kotlin bridge `io.mob.scene3d.MobScene3dBridge` as
//! `byte[]` (NOT jstrings — NewStringUTF wants modified UTF-8; byte arrays
//! round-trip UTF-8 JSON verbatim) and returns the bridge's `byte[]` result
//! JSON as an Erlang binary. The bridge does the shadow-registry patch
//! validation synchronously on the calling (BEAM) thread — pure
//! bookkeeping, no Filament — and enqueues validated ops for the render
//! thread. BEAM schedulers never touch Filament (spike threading contract).
//!
//! Async traffic (scene readbacks, asset errors, surface-ready notices)
//! flows back through the exported deliver thunk as enif_send to the pid
//! captured at NIF-call time.
//!
//! Build path: compiled via `-Dplugin_zig_nifs`; `erts`/`jni` are mob-core
//! module imports, `get_jenv`/`g_jvm` are mob-core exports in the same .so.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Bridge class + method-id cache (filled by nativeRegister) ──────────────
var g_cls: jni.JClass = null;
var g_caps: jni.JMethodID = null;
var g_apply: jni.JMethodID = null;
var g_scene: jni.JMethodID = null;
var g_destroy: jni.JMethodID = null;

export fn Java_io_mob_scene3d_MobScene3dBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_cls = jni.newGlobalRef(jenv, cls);
    if (g_cls == null) return;
    g_caps = jni.getStaticMethodID(jenv, cls, "scene3dCaps", "()[B");
    g_apply = jni.getStaticMethodID(jenv, cls, "scene3dApply", "(J[B[B)[B");
    g_scene = jni.getStaticMethodID(jenv, cls, "scene3dScene", "(J[B[B)[B");
    g_destroy = jni.getStaticMethodID(jenv, cls, "scene3dDestroy", "([B)[B");
}

// ── Marshalling helpers ────────────────────────────────────────────────────

inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

/// Erlang binary/iolist term -> fresh Java byte[] (local ref).
fn termToByteArray(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, term: erts.ERL_NIF_TERM) ?jni.JByteArray {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) == 0 and
        erts.enif_inspect_iolist_as_binary(env, term, &bin) == 0) return null;
    const arr = jni.newByteArray(jenv, @intCast(bin.size)) orelse return null;
    if (bin.size > 0) {
        jni.setByteArrayRegion(jenv, arr, 0, @intCast(bin.size), @ptrCast(bin.data));
    }
    return arr;
}

/// Java byte[] -> Erlang binary term.
fn byteArrayToTerm(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, arr: jni.JByteArray) ?erts.ERL_NIF_TERM {
    const len_j = jni.getArrayLength(jenv, arr);
    if (len_j < 0) return null;
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(@intCast(len_j), &bin) == 0) return null;
    if (len_j > 0) {
        jni.getByteArrayRegion(jenv, arr, 0, len_j, @ptrCast(bin.data));
    }
    return erts.enif_make_binary(env, &bin);
}

/// A literal JSON error reply, for failures before the bridge is reachable.
fn literalBinary(env: ?*erts.ErlNifEnv, comptime json: []const u8) erts.ERL_NIF_TERM {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(json.len, &bin) == 0) return erts.badarg(env);
    @memcpy(bin.data[0..json.len], json);
    return erts.enif_make_binary(env, &bin);
}

const bridge_unregistered = "{\"error\":[\"bridge_unregistered\"]}";
const bridge_call_failed = "{\"error\":[\"bridge_call_failed\"]}";

// ── NIFs ───────────────────────────────────────────────────────────────────

fn nif_scene3d_caps(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_cls == null) return literalBinary(env, bridge_unregistered);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return literalBinary(env, bridge_call_failed);
    defer detachIfAttached(attached);
    const result = jenv.*.CallStaticObjectMethod.?(jenv, g_cls, g_caps);
    jni.exceptionClear(jenv);
    if (result == null) return literalBinary(env, bridge_call_failed);
    defer jni.deleteLocalRef(jenv, result);
    return byteArrayToTerm(env, jenv, result) orelse literalBinary(env, bridge_call_failed);
}

/// Shared shape for the two (pid, viewport, arg) -> byte[] bridge calls.
fn callPidTwoBins(env: ?*erts.ErlNifEnv, method: jni.JMethodID, argv: [*]const erts.ERL_NIF_TERM) erts.ERL_NIF_TERM {
    if (g_cls == null) return literalBinary(env, bridge_unregistered);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return literalBinary(env, bridge_call_failed);
    defer detachIfAttached(attached);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    const vid = termToByteArray(env, jenv, argv[0]) orelse return erts.badarg(env);
    defer jni.deleteLocalRef(jenv, vid);
    const arg = termToByteArray(env, jenv, argv[1]) orelse return erts.badarg(env);
    defer jni.deleteLocalRef(jenv, arg);

    const result = jenv.*.CallStaticObjectMethod.?(jenv, g_cls, method, pidToJlong(pid), vid, arg);
    jni.exceptionClear(jenv);
    if (result == null) return literalBinary(env, bridge_call_failed);
    defer jni.deleteLocalRef(jenv, result);
    return byteArrayToTerm(env, jenv, result) orelse literalBinary(env, bridge_call_failed);
}

fn nif_scene3d_apply(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callPidTwoBins(env, g_apply, argv);
}

fn nif_scene3d_scene(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callPidTwoBins(env, g_scene, argv);
}

fn nif_scene3d_destroy(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_cls == null) return literalBinary(env, bridge_unregistered);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return literalBinary(env, bridge_call_failed);
    defer detachIfAttached(attached);

    const vid = termToByteArray(env, jenv, argv[0]) orelse return erts.badarg(env);
    defer jni.deleteLocalRef(jenv, vid);

    const result = jenv.*.CallStaticObjectMethod.?(jenv, g_cls, g_destroy, vid);
    jni.exceptionClear(jenv);
    if (result == null) return literalBinary(env, bridge_call_failed);
    defer jni.deleteLocalRef(jenv, result);
    return byteArrayToTerm(env, jenv, result) orelse literalBinary(env, bridge_call_failed);
}

// ── Inbound delivery — Kotlin calls this from the main thread ──────────────
// kind = "scene": {:scene3d_scene, Viewport, A, B}   (A=request id, B=json)
// kind = "error": {:scene3d_error, Viewport, A}      (A=error json)
// kind = "ready": {:scene3d_ready, Viewport}
export fn Java_io_mob_scene3d_MobScene3dBridge_nativeDeliverScene3d(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    kind: jni.JString,
    viewport: jni.JString,
    a: jni.JString,
    b: jni.JString,
) callconv(.c) void {
    _ = cls;
    if (kind == null or viewport == null) return;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const kind_c = jenv.*.GetStringUTFChars.?(jenv, kind, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, kind, kind_c);

    const vid_term = stringToBinaryTerm(env, jenv, viewport) orelse return;
    const kind_s = std.mem.sliceTo(kind_c, 0);

    const msg = if (std.mem.eql(u8, kind_s, "scene")) blk: {
        const a_term = stringToBinaryTerm(env, jenv, a) orelse return;
        const b_term = stringToBinaryTerm(env, jenv, b) orelse return;
        break :blk erts.makeTuple(env, .{ erts.atom(env, "scene3d_scene"), vid_term, a_term, b_term });
    } else if (std.mem.eql(u8, kind_s, "error")) blk: {
        const a_term = stringToBinaryTerm(env, jenv, a) orelse return;
        break :blk erts.makeTuple(env, .{ erts.atom(env, "scene3d_error"), vid_term, a_term });
    } else if (std.mem.eql(u8, kind_s, "ready")) blk: {
        break :blk erts.makeTuple(env, .{ erts.atom(env, "scene3d_ready"), vid_term });
    } else {
        return;
    };

    _ = erts.enif_send(null, &pid, env, msg);
}

fn stringToBinaryTerm(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, str: jni.JString) ?erts.ERL_NIF_TERM {
    if (str == null) return null;
    const chars = jenv.*.GetStringUTFChars.?(jenv, str, null) orelse return null;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, str, chars);
    const len = std.mem.len(chars);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(len, &bin) == 0) return null;
    @memcpy(bin.data[0..len], chars[0..len]);
    return erts.enif_make_binary(env, &bin);
}

// ── NIF table + init entry point ───────────────────────────────────────────

fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "scene3d_caps", .arity = 0, .fptr = nif_scene3d_caps, .flags = 0 },
    .{ .name = "scene3d_apply", .arity = 2, .fptr = nif_scene3d_apply, .flags = 0 },
    .{ .name = "scene3d_scene", .arity = 2, .fptr = nif_scene3d_scene, .flags = 0 },
    .{ .name = "scene3d_destroy", .arity = 1, .fptr = nif_scene3d_destroy, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_scene3d_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_scene3d_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
