# Host-side animation acceptance battery for bead mob_scene3d-al6 — the
# Chopaat cowrie-throw contract, asserted against tumble_manifest.json.
#
# Usage:
#   S3D_NODE=s3d_spike_android_buildpool1@127.0.0.1 \
#     mise exec -- elixir --name probe_anim@127.0.0.1 --cookie mob_secret \
#     -S mix run scripts/probe_animation.exs
#
# Prints labelled readback values — the values ARE the evidence. Exits
# non-zero on any contract violation.

defmodule TumbleProbe do
  def run do
    node = String.to_atom(System.fetch_env!("S3D_NODE"))
    manifest = load_manifest()

    IO.inspect(Node.connect(node), label: "connect")
    navigate(node)
    Process.sleep(1_500)
    IO.inspect(Mob.Scene3d.viewports(node), label: "viewports")

    {:ok, scene} = Mob.Scene3d.scene(node)
    tumbles = scene["entities"]["tumbles"]
    IO.inspect(tumbles["status"], label: "tumbles status")
    node_names = tumbles["nodes"] |> Map.keys() |> Enum.sort()
    IO.inspect(node_names, label: "named nodes")

    check!(
      node_names == Enum.map(0..6, &"shell_#{&1}"),
      "readback exposes the seven slot nodes"
    )

    # ── the Chopaat contract: play, await done, classify, cross-check ──────
    for clip <- ["throw_k0_v0", "throw_k4_v0", "throw_k7_v0"] do
      throw_and_assert(node, clip, manifest)
    end

    loop_probe(node)
    seek_pause_probe(node, manifest)
    replay_probe(node, manifest)
    unknown_probe(node)

    IO.puts("\nALL ANIMATION CONTRACT CHECKS PASSED")
  end

  # Play a mode-:once clip, await {:animation_done, play_id} (surfaced via
  # the :done assign), read the settled slot orientations back, classify
  # aperture-up with tumble.py's rule, and assert the manifest's array.
  defp throw_and_assert(node, clip, manifest) do
    play_id = "#{clip}-#{System.unique_integer([:positive])}"
    entry = manifest["animations"][clip]

    Mob.Test.send_message(node, {:s3d_anim, :play, clip, play_id, []})
    await_done(node, play_id, round(entry["duration_s"] * 1000) + 5_000)

    {:ok, scene} = Mob.Scene3d.scene(node)
    tumbles = scene["entities"]["tumbles"]
    IO.inspect(tumbles["animation_state"], label: "#{clip} animation_state")

    check!(
      tumbles["animation_state"]["done"] == true and
        tumbles["animation_state"]["play_id"] == play_id,
      "#{clip}: readback shows done for #{play_id}"
    )

    ups = classify(tumbles["nodes"], manifest["up_axis_tolerance"])
    expected = entry["aperture_up"]
    IO.inspect(ups, label: "#{clip} aperture_up (classified from readback)")
    IO.inspect(expected, label: "#{clip} aperture_up (manifest)")

    IO.inspect(up_components(tumbles["nodes"]),
      label: "#{clip} per-slot local+Y world-Y components"
    )

    check!(Enum.count(ups, & &1) == entry["count"], "#{clip}: exactly #{entry["count"]} up")
    check!(ups == expected, "#{clip}: per-slot aperture_up matches the manifest")
  end

  # Loop mode keeps playing: frames advance, the clock moves, done never
  # fires and the readback never reports done.
  defp loop_probe(node) do
    play_id = "loop-#{System.unique_integer([:positive])}"
    Mob.Test.send_message(node, {:s3d_anim, :play, "throw_k4_v1", play_id, [loop: true]})
    Process.sleep(3_000)

    {:ok, stats_a} = Mob.Scene3d.frame_stats(node)
    {:ok, scene_a} = Mob.Scene3d.scene(node)
    Process.sleep(1_200)
    {:ok, stats_b} = Mob.Scene3d.frame_stats(node)
    {:ok, scene_b} = Mob.Scene3d.scene(node)

    state_a = scene_a["entities"]["tumbles"]["animation_state"]
    state_b = scene_b["entities"]["tumbles"]["animation_state"]
    IO.inspect({state_a, state_b}, label: "loop animation_state (t, t+1.2s)")
    IO.inspect(stats_b, label: "loop frame_stats (1.2s window)")

    check!(state_a["loop"] == true and state_b["done"] == false, "loop: never done")
    check!(state_a["time"] != state_b["time"], "loop: clip clock advances")
    check!(stats_b[:frames] > 0, "loop: frames rendered between queries")
    check!(play_id not in done_list(node), "loop: no {:animation_done, ...} delivered")
    _ = stats_a
  end

  # Paused + seek renders the expected static pose: the clock reads exactly
  # the seek, node geometry moves between the two poses, and pixel truth
  # corroborates (sample_region distinguishes them).
  defp seek_pause_probe(node, manifest) do
    duration = manifest["animations"]["throw_k4_v0"]["duration_s"]
    play_id = "seek-#{System.unique_integer([:positive])}"

    Mob.Test.send_message(
      node,
      {:s3d_anim, :play, "throw_k4_v0", play_id, [paused: true, seek: 0.05]}
    )

    Process.sleep(800)
    {:ok, scene_a} = Mob.Scene3d.scene(node)
    state_a = scene_a["entities"]["tumbles"]["animation_state"]
    nodes_a = scene_a["entities"]["tumbles"]["nodes"]
    {:ok, sample_a} = Mob.Scene3d.sample_region(node, {140, 180, 60, 60})

    Mob.Test.send_message(
      node,
      {:s3d_anim, :play, "throw_k4_v0", play_id, [paused: true, seek: duration]}
    )

    Process.sleep(800)
    {:ok, scene_b} = Mob.Scene3d.scene(node)
    state_b = scene_b["entities"]["tumbles"]["animation_state"]
    nodes_b = scene_b["entities"]["tumbles"]["nodes"]
    {:ok, sample_b} = Mob.Scene3d.sample_region(node, {140, 180, 60, 60})

    IO.inspect({state_a, state_b}, label: "seek+paused animation_state (0.05, duration)")
    IO.inspect(sample_a, label: "seek+paused sample @0.05s")
    IO.inspect(sample_b, label: "seek+paused sample @settle")

    check!(state_a["paused"] == true and abs(state_a["time"] - 0.05) < 0.001, "seek: t=0.05 held")

    # The clip's baked duration may differ from the manifest's by a frame;
    # the held clock clamps to the clip end, so assert the band, not a bit.
    check!(
      state_b["time"] >= duration - 0.05 and state_b["time"] <= duration + 0.001,
      "seek: t=duration held (same play_id, no restart)"
    )

    deltas =
      for slot <- 0..6 do
        [ax, ay, az] = Enum.slice(nodes_a["shell_#{slot}"], 12, 3)
        [bx, by, bz] = Enum.slice(nodes_b["shell_#{slot}"], 12, 3)
        Float.round(:math.sqrt((ax - bx) ** 2 + (ay - by) ** 2 + (az - bz) ** 2), 4)
      end

    IO.inspect(deltas, label: "seek: per-slot node travel between the two poses (m)")
    check!(Enum.any?(deltas, &(&1 > 0.01)), "seek: node geometry differs between poses")

    check!(
      sample_a[:dominant] != sample_b[:dominant] or
        abs(sample_a[:dominant_share] - sample_b[:dominant_share]) > 0.02 or
        sample_a[:average] != sample_b[:average],
      "seek: sample_region distinguishes the two static poses"
    )

    check!(play_id not in done_list(node), "seek+paused: no done event (clock frozen)")
  end

  # Replay = play_id change: the same clip re-fires with the new token.
  defp replay_probe(node, manifest) do
    duration = manifest["animations"]["throw_k4_v0"]["duration_s"]
    play_a = "replay-a-#{System.unique_integer([:positive])}"
    play_b = "replay-b-#{System.unique_integer([:positive])}"
    deadline = round(duration * 1000) + 5_000

    Mob.Test.send_message(node, {:s3d_anim, :play, "throw_k4_v0", play_a, []})
    await_done(node, play_a, deadline)
    Mob.Test.send_message(node, {:s3d_anim, :play, "throw_k4_v0", play_b, []})
    await_done(node, play_b, deadline)

    done = done_list(node)
    IO.inspect(Enum.take(done, 4), label: "replay done list (newest first)")
    check!(play_a in done and play_b in done, "replay: both play_ids completed")
  end

  # Unknown clip name: the asset is loaded, so the shadow rejects the whole
  # patch SYNCHRONOUSLY with the taxonomy error. The reply_to pid is this
  # host process — the screen's send crosses distribution directly.
  defp unknown_probe(node) do
    anim = %Mob.Scene3d.IR.Animation{name: "no_such_clip", play_id: "ghost-1"}

    Mob.Test.send_message(
      node,
      {:s3d_anim, :commit_raw, [{:set_animation, "tumbles", anim}], self()}
    )

    assert_receive_raw(:unknown, {:error, {:unknown_animation, "tumbles", "no_such_clip"}})
  end

  # ── plumbing ─────────────────────────────────────────────────────────────

  defp navigate(node) do
    IO.inspect(Mob.Test.screen(node), label: "screen")

    if Mob.Test.screen(node) != S3dSpike.TumbleScreen do
      if Mob.Test.screen(node) != S3dSpike.HomeScreen do
        Mob.Test.send_message(node, {:tap, :back})
        Process.sleep(600)
      end

      Mob.Test.tap(node, :open_tumble)
      Mob.Test.settle(node)
      IO.inspect(Mob.Test.screen(node), label: "screen after nav")
    end
  end

  defp await_done(node, play_id, deadline_ms) do
    started = System.monotonic_time(:millisecond)

    poll = fn poll ->
      cond do
        play_id in done_list(node) ->
          elapsed = System.monotonic_time(:millisecond) - started
          IO.puts("animation_done #{play_id} observed after ~#{elapsed}ms")

        System.monotonic_time(:millisecond) - started > deadline_ms ->
          check!(false, "await_done #{play_id}: no completion within #{deadline_ms}ms")

        true ->
          Process.sleep(150)
          poll.(poll)
      end
    end

    poll.(poll)
  end

  defp done_list(node), do: Mob.Test.assigns(node).done

  defp assert_receive_raw(tag, expected) do
    receive do
      {:s3d_anim_raw_result, result} ->
        IO.inspect(result, label: "commit_raw #{tag}")
        check!(result == expected, "commit_raw #{tag}: #{inspect(expected)}")
    after
      6_000 -> check!(false, "commit_raw #{tag}: no reply")
    end
  end

  # tumble.py's classifier, glTF frame: local +Y in world space is column 1
  # of the node's world matrix; aperture-up ⇔ its world-Y component <= -tol.
  defp classify(nodes, tolerance) do
    for slot <- 0..6 do
      up_component(nodes["shell_#{slot}"]) <= -tolerance
    end
  end

  defp up_components(nodes) do
    for slot <- 0..6, do: {slot, Float.round(up_component(nodes["shell_#{slot}"]), 4)}
  end

  defp up_component(matrix) do
    [yx, yy, yz] = Enum.slice(matrix, 4, 3)
    yy / :math.sqrt(yx * yx + yy * yy + yz * yz)
  end

  defp load_manifest do
    [__DIR__, "..", "priv", "tumble_manifest.json"]
    |> Path.join()
    |> Path.expand()
    |> File.read!()
    |> :json.decode()
  end

  defp check!(true, label), do: IO.puts("OK   #{label}")

  defp check!(other, label) do
    IO.puts("FAIL #{label} (got #{inspect(other)})")
    System.halt(1)
  end
end

TumbleProbe.run()
