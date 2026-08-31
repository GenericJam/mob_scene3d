%% mob_scene3d_nif — NIF stub for the scene3d native applier.
%%
%% The native half ships per platform (priv/native/ios/mob_scene3d_nif.m,
%% priv/native/jni/mob_scene3d_nif.zig) and is linked statically into the
%% host app's driver tab. On a host/dev BEAM there is no native half, so
%% on_load tolerates the failed load and every call raises nif_not_loaded —
%% the Elixir boundary (Mob.Scene3d.Native.NIF) turns that into an honest
%% {error, nif_not_loaded}.
%%
%% Contract (see Mob.Scene3d.Wire for the byte layout):
%%   scene3d_caps/0        -> caps JSON binary {"schema":N,"ops":[...]}
%%   scene3d_apply/2       -> result JSON binary; validates the whole patch
%%                            against the native shadow registry
%%                            synchronously (atomic reject-all), enqueues the
%%                            validated ops for the render thread. BEAM
%%                            schedulers never touch Filament.
%%   scene3d_scene/2       -> result JSON binary; on ok the applied-scene
%%                            readback arrives as
%%                            {scene3d_scene, ViewportId, ReqId, SceneJson}
%%                            sent to the calling process.
%%   scene3d_destroy/1     -> result JSON binary; tears down the viewport's
%%                            scene state and buffered patches.
-module(mob_scene3d_nif).

-export([scene3d_caps/0, scene3d_apply/2, scene3d_scene/2, scene3d_destroy/1]).

-on_load(init/0).

init() ->
    case erlang:load_nif("mob_scene3d_nif", 0) of
        ok -> ok;
        %% Host/dev BEAM: no native half linked. Calls raise nif_not_loaded.
        {error, _} -> ok
    end.

-spec scene3d_caps() -> binary().
scene3d_caps() ->
    erlang:nif_error(nif_not_loaded).

-spec scene3d_apply(binary(), binary()) -> binary().
scene3d_apply(_ViewportId, _PatchJson) ->
    erlang:nif_error(nif_not_loaded).

-spec scene3d_scene(binary(), binary()) -> binary().
scene3d_scene(_ViewportId, _ReqId) ->
    erlang:nif_error(nif_not_loaded).

-spec scene3d_destroy(binary()) -> binary().
scene3d_destroy(_ViewportId) ->
    erlang:nif_error(nif_not_loaded).
