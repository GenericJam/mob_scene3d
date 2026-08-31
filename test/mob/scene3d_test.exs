defmodule Mob.Scene3dTest do
  use ExUnit.Case, async: true

  alias Mob.Scene3d
  alias Mob.Scene3d.IR
  alias Mob.Scene3d.IR.{Camera, Entity, Light, Material, Model, Transform}
  alias Mob.Scene3d.NativeMock
  alias Mob.Scene3d.Wire

  defp probe_scene do
    IR.new([
      %Entity{id: "cam", transform: %Transform{position: {0.0, 1.8, 4.8}}, data: %Camera{}},
      %Entity{id: "sun", data: %Light{type: :directional, intensity: 110_000.0}},
      %Entity{id: "probe", data: %Model{asset: "probe.glb"}}
    ])
  end

  describe "commit/3 — patch shipping" do
    test "bootstrap commit ships the full diff and returns the new committed IR" do
      next = probe_scene()
      assert {:ok, ^next} = Scene3d.commit("vp", IR.empty(), next)

      ops = NativeMock.shipped_ops()
      assert [_first, _second, _third] = ops
      assert Enum.all?(ops, &(hd(&1) == "add_entity"))
    end

    test "an unchanged scene ships nothing" do
      scene = probe_scene()
      assert {:ok, ^scene} = Scene3d.commit("vp", scene, scene)
      refute Enum.any?(NativeMock.calls(), &match?({:apply_patch, _, _}, &1))
    end

    test "incremental commit ships only the delta, diffed against committed" do
      committed = probe_scene()

      moved =
        update_in(committed.entities["probe"], fn %Entity{} = probe ->
          %Entity{probe | transform: %Transform{position: {1.0, 0.0, 0.0}}}
        end)

      assert {:ok, _next} = Scene3d.commit("vp", committed, moved)

      assert [["set_transform", "probe", %{"position" => [1.0, +0.0, +0.0]}]] =
               NativeMock.shipped_ops()
    end

    test "the native rejection propagates decoded and committed does not advance" do
      NativeMock.stub(:apply_patch, {:ok, ~s({"error":["unknown_entity","probe"]})})

      assert {:error, {:unknown_entity, "probe"}} =
               Scene3d.commit("vp", IR.empty(), probe_scene())
    end

    test "an invalid scene is rejected before anything reaches the wire" do
      invalid = IR.new([%Entity{id: "a", parent: "ghost"}])

      assert {:error, {:invalid_scene, {:unknown_parent, "a", "ghost"}}} =
               Scene3d.commit("vp", IR.empty(), invalid)

      assert NativeMock.calls() == []
    end

    test "relative model assets resolve against the configured root at the wire boundary" do
      Application.put_env(:mob_scene3d, :asset_root, "/data/app/priv/scene3d_assets")
      on_exit(fn -> Application.delete_env(:mob_scene3d, :asset_root) end)

      assert {:ok, committed} = Scene3d.commit("vp", IR.empty(), probe_scene())

      [["add_entity", %{"data" => data}]] =
        Enum.filter(
          NativeMock.shipped_ops(),
          &match?(["add_entity", %{"data" => %{"kind" => "model"}}], &1)
        )

      assert data["asset"] == "/data/app/priv/scene3d_assets/probe.glb"
      # The committed IR keeps the logical ref — diffs compare intent.
      assert committed.entities["probe"].data.asset == "probe.glb"
    end
  end

  describe "commit/3 — version-skew guards" do
    test "an op the native caps do not declare is refused loudly" do
      partial_caps =
        %{"schema" => Wire.schema(), "ops" => ["add_entity", "remove_entity"]}
        |> :json.encode()
        |> IO.iodata_to_binary()

      NativeMock.stub(:caps, {:ok, partial_caps})

      # probe_scene bootstrap needs set-free adds only — those pass:
      assert {:ok, committed} = Scene3d.commit("vp", IR.empty(), probe_scene())
      # ...but a transform poke needs set_transform, which this applier lacks:
      moved =
        update_in(committed.entities["probe"], fn %Entity{} = probe ->
          %Entity{probe | transform: %Transform{position: {1.0, 0.0, 0.0}}}
        end)

      assert {:error, {:unsupported, :set_transform}} = Scene3d.commit("vp", committed, moved)
      # Nothing shipped for the refused patch.
      assert [{_caps1}, {:apply_patch, _, _}, {_caps2}] =
               Enum.filter(NativeMock.calls(), &(elem(&1, 0) in [:caps, :apply_patch]))
    end

    test "set_animation against an applier that predates it degrades loudly" do
      # The exact skew this lane creates: an old native build whose caps
      # predate animation support. New op support is ADDITIVE (declared via
      # caps ops, schema unchanged) — the guard refuses before the wire.
      pre_animation_caps =
        %{"schema" => Wire.schema(), "ops" => Wire.v1_op_names() -- ["set_animation"]}
        |> :json.encode()
        |> IO.iodata_to_binary()

      NativeMock.stub(:caps, {:ok, pre_animation_caps})

      committed = probe_scene()

      animated =
        update_in(committed.entities["probe"], fn %Entity{data: %Model{} = model} = probe ->
          animation = %Mob.Scene3d.IR.Animation{name: "throw_k4_v0", play_id: "roll-1"}
          %Entity{probe | data: %Model{model | animation: animation}}
        end)

      assert {:error, {:unsupported, :set_animation}} = Scene3d.commit("vp", committed, animated)
      refute Enum.any?(NativeMock.calls(), &match?({:apply_patch, _, _}, &1))
    end

    test "a scoped override against an applier without material_scope degrades loudly" do
      # The exact skew this lane creates: an old native build whose caps
      # predate scoped overrides would silently tint EVERY material instance
      # (the bug scoping exists to fix), so the guard refuses before the
      # wire. Feature support is ADDITIVE (declared via caps features,
      # schema and op set unchanged).
      pre_scope_caps =
        %{"schema" => Wire.schema(), "ops" => Wire.v1_op_names()}
        |> :json.encode()
        |> IO.iodata_to_binary()

      NativeMock.stub(:caps, {:ok, pre_scope_caps})

      committed = probe_scene()

      tinted =
        update_in(committed.entities["probe"], fn %Entity{data: %Model{} = model} = probe ->
          material = %Material{base_color: {0.9, 0.3, 0.1, 1.0}, scope: "pawn_body"}
          %Entity{probe | data: %Model{model | material: material}}
        end)

      assert {:error, {:unsupported, :material_scope}} = Scene3d.commit("vp", committed, tinted)
      refute Enum.any?(NativeMock.calls(), &match?({:apply_patch, _, _}, &1))
    end

    test "an override list needs material_scope even inside an entity payload" do
      pre_scope_caps =
        %{"schema" => Wire.schema(), "ops" => Wire.v1_op_names()}
        |> :json.encode()
        |> IO.iodata_to_binary()

      NativeMock.stub(:caps, {:ok, pre_scope_caps})

      pawn =
        IR.new([
          %Entity{
            id: "pawn",
            data: %Model{
              asset: "pawn.glb",
              material: [%Material{base_color: {0.9, 0.3, 0.1, 1.0}, scope: "pawn_body"}]
            }
          }
        ])

      assert {:error, {:unsupported, :material_scope}} = Scene3d.commit("vp", IR.empty(), pawn)
      refute Enum.any?(NativeMock.calls(), &match?({:apply_patch, _, _}, &1))
    end

    test "an unscoped override still ships against pre-scope caps" do
      # Back-compat: scope nil is today's wire shape and semantics — an old
      # applier handles it correctly, so the guard must not over-refuse.
      pre_scope_caps =
        %{"schema" => Wire.schema(), "ops" => Wire.v1_op_names()}
        |> :json.encode()
        |> IO.iodata_to_binary()

      NativeMock.stub(:caps, {:ok, pre_scope_caps})

      committed = probe_scene()

      tinted =
        update_in(committed.entities["probe"], fn %Entity{data: %Model{} = model} = probe ->
          %Entity{probe | data: %Model{model | material: %Material{base_color: {1, 0, 0, 1}}}}
        end)

      assert {:ok, _committed} = Scene3d.commit("vp", committed, tinted)
      assert [["set_material", "probe", %{"scope" => nil}]] = NativeMock.shipped_ops()
    end

    test "a scoped override list ships once the applier declares material_scope" do
      committed = probe_scene()

      tinted =
        update_in(committed.entities["probe"], fn %Entity{data: %Model{} = model} = probe ->
          materials = [
            %Material{base_color: {0.9, 0.3, 0.1, 1.0}, scope: "pawn_body"},
            %Material{emissive: {0.2, 0.2, 0.0}, scope: "pawn_accent"}
          ]

          %Entity{probe | data: %Model{model | material: materials}}
        end)

      # The default mock caps declare material_scope (the shipping caps).
      assert {:ok, _committed} = Scene3d.commit("vp", committed, tinted)

      assert [["set_material", "probe", [%{"scope" => "pawn_body"}, %{"scope" => "pawn_accent"}]]] =
               NativeMock.shipped_ops()
    end

    test "a schema mismatch is refused loudly" do
      alien = %{"schema" => 99, "ops" => Wire.v1_op_names()}
      NativeMock.stub(:caps, {:ok, alien |> :json.encode() |> IO.iodata_to_binary()})

      assert {:error, {:schema_mismatch, 99, 1}} = Scene3d.commit("vp", IR.empty(), probe_scene())
    end

    test "a missing native half degrades honestly" do
      NativeMock.stub(:caps, {:error, :nif_not_loaded})
      assert {:error, :nif_not_loaded} = Scene3d.commit("vp", IR.empty(), probe_scene())
    end

    test "garbage caps are an error, not a guess" do
      NativeMock.stub(:caps, {:ok, "junk"})
      assert {:error, {:bad_caps, _}} = Scene3d.commit("vp", IR.empty(), probe_scene())
    end
  end

  describe "scene/2" do
    test "returns the decoded native readback" do
      scene_json = ~s({"entities":{"probe":{"kind":"model","status":"ready"}}})

      NativeMock.stub(:request_scene, fn viewport_id, request_id ->
        send(self(), {:scene3d_scene, viewport_id, request_id, scene_json})
        {:ok, ~s({"ok":true})}
      end)

      assert {:ok, scene} = Scene3d.scene("vp", 200)
      assert scene["entities"]["probe"]["status"] == "ready"
    end

    test "a reply for a different viewport or request is not consumed" do
      NativeMock.stub(:request_scene, fn _viewport_id, _request_id ->
        send(self(), {:scene3d_scene, "other_vp", "other_req", "{}"})
        {:ok, ~s({"ok":true})}
      end)

      assert {:error, :timeout} = Scene3d.scene("vp", 50)
      assert_received {:scene3d_scene, "other_vp", "other_req", "{}"}
    end

    test "a no-viewport reply surfaces as the taxonomy error" do
      NativeMock.stub(:request_scene, {:ok, ~s({"error":["no_viewport","vp"]})})
      assert {:error, {:no_viewport, "vp"}} = Scene3d.scene("vp", 10)
    end
  end

  describe "pick/4 (device-local)" do
    test "resolves to the picked entity id" do
      NativeMock.stub(:pick, fn viewport_id, query_json ->
        query = Wire.decode!(query_json)
        assert query["x"] == 120.0
        assert query["y"] == 200.0
        send(self(), {:scene3d_pick, viewport_id, query["request_id"], ~s({"entity":"probe"})})
        {:ok, ~s({"ok":true})}
      end)

      assert {:ok, "probe"} = Scene3d.pick("vp", 120, 200)
    end

    test "a miss is the documented honest error, echoing the query point" do
      NativeMock.stub(:pick, fn viewport_id, query_json ->
        query = Wire.decode!(query_json)
        send(self(), {:scene3d_pick, viewport_id, query["request_id"], ~s({"miss":true})})
        {:ok, ~s({"ok":true})}
      end)

      assert {:error, {:no_entity_at_point, 5, 5}} = Scene3d.pick("vp", 5, 5)
    end

    test "no attached viewport is a sync taxonomy error" do
      NativeMock.stub(:pick, {:ok, ~s({"error":["no_viewport","vp"]})})
      assert {:error, {:no_viewport, "vp"}} = Scene3d.pick("vp", 1, 1)
    end

    test "an unresolved pick times out honestly" do
      assert {:error, :timeout} = Scene3d.pick("vp", 1, 1, 20)
    end

    test "a reply for another request is not consumed" do
      NativeMock.stub(:pick, fn viewport_id, _query_json ->
        send(self(), {:scene3d_pick, viewport_id, "stale_req", ~s({"entity":"ghost"})})
        {:ok, ~s({"ok":true})}
      end)

      assert {:error, :timeout} = Scene3d.pick("vp", 1, 1, 20)
      assert_received {:scene3d_pick, "vp", "stale_req", _json}
    end
  end

  describe "sample_region/3 (device-local)" do
    test "reduces the GPU readback through Mob.Test.reduce_rgba/3" do
      # 2×1 px, both solid red — the reducer shape is Mob.Test's.
      rgba = <<255, 0, 0, 255, 255, 0, 0, 255>>

      NativeMock.stub(:sample, fn viewport_id, query_json ->
        query = Wire.decode!(query_json)
        assert %{"x" => 10.0, "y" => 20.0, "w" => 2.0, "h" => 1.0} = query

        payload =
          ~s({"width":2,"height":1,"rgba":"#{Base.encode64(rgba)}"})

        send(self(), {:scene3d_sample, viewport_id, query["request_id"], payload})
        {:ok, ~s({"ok":true})}
      end)

      assert {:ok, stats} = Scene3d.sample_region("vp", {10, 20, 2, 1})

      assert stats == %{
               average: 0xFFFF0000,
               dominant: 0xFFFF0000,
               dominant_share: 1.0,
               distinct: 1,
               pixels: 2
             }
    end

    test "an offscreen rect is the taxonomy error, not a zero-pixel guess" do
      NativeMock.stub(:sample, fn viewport_id, query_json ->
        query = Wire.decode!(query_json)

        send(
          self(),
          {:scene3d_sample, viewport_id, query["request_id"], ~s({"error":["offscreen"]})}
        )

        {:ok, ~s({"ok":true})}
      end)

      assert {:error, :offscreen} = Scene3d.sample_region("vp", {-500, -500, 10, 10})
    end

    test "a readback that does not match its dimensions is refused" do
      NativeMock.stub(:sample, fn viewport_id, query_json ->
        query = Wire.decode!(query_json)
        # claims 4 pixels, carries 1
        payload = ~s({"width":2,"height":2,"rgba":"#{Base.encode64(<<0, 0, 0, 255>>)}"})
        send(self(), {:scene3d_sample, viewport_id, query["request_id"], payload})
        {:ok, ~s({"ok":true})}
      end)

      assert {:error, :size_mismatch} = Scene3d.sample_region("vp", {0, 0, 2, 2})
    end
  end

  describe "frame_stats/2 (device-local)" do
    test "decodes the render-thread stats with atom keys" do
      payload =
        ~s({"frames":118,"avg_ms":16.7,"p95_ms":17.4,"dropped":2,"entities":4,"renderables":1})

      NativeMock.stub(:frame_stats, fn viewport_id, request_id ->
        send(self(), {:scene3d_frame_stats, viewport_id, request_id, payload})
        {:ok, ~s({"ok":true})}
      end)

      assert {:ok, stats} = Scene3d.frame_stats("vp")

      assert stats == %{
               frames: 118,
               avg_ms: 16.7,
               p95_ms: 17.4,
               dropped: 2,
               entities: 4,
               renderables: 1
             }
    end

    test "a partial stats payload is a bad reply, never a guess" do
      NativeMock.stub(:frame_stats, fn viewport_id, request_id ->
        send(self(), {:scene3d_frame_stats, viewport_id, request_id, ~s({"frames":1})})
        {:ok, ~s({"ok":true})}
      end)

      assert {:error, {:bad_native_reply, %{"frames" => 1}}} = Scene3d.frame_stats("vp")
    end

    test "no attached viewport is a sync taxonomy error" do
      NativeMock.stub(:frame_stats, {:ok, ~s({"error":["no_viewport","vp"]})})
      assert {:error, {:no_viewport, "vp"}} = Scene3d.frame_stats("vp")
    end
  end

  describe "viewports/0" do
    test "decodes the attached viewport ids" do
      NativeMock.stub(:viewports, {:ok, ~s({"viewports":["board","hud"]})})
      assert {:ok, ["board", "hud"]} = Scene3d.viewports()
    end

    test "garbage is an error, not a guess" do
      NativeMock.stub(:viewports, {:ok, ~s({"nope":1})})
      assert {:error, {:bad_native_reply, %{"nope" => 1}}} = Scene3d.viewports()
    end
  end

  describe "destroy/1" do
    test "decodes the native reply" do
      assert :ok = Scene3d.destroy("vp")
      assert [{:destroy, "vp"}] = NativeMock.calls()
    end
  end

  describe "Native.NIF without a native half" do
    test "every entry point degrades to {:error, :nif_not_loaded}" do
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.caps()
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.apply_patch("vp", "{}")
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.request_scene("vp", "r")
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.destroy("vp")
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.pick("vp", "{}")
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.sample("vp", "{}")
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.frame_stats("vp", "r")
      assert {:error, :nif_not_loaded} = Mob.Scene3d.Native.NIF.viewports()
    end
  end
end
