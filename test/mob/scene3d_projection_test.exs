defmodule Mob.Scene3d.ProjectionTest do
  # Pure-math tests for the projection helpers (bead mob_scene3d-xzh).
  # No native NIF, no viewport — the point is to nail the matrix layout,
  # perspective build, and NDC-to-pixel conversion in isolation so the
  # `Mob.Scene3d.project/N` facade only has to worry about scene
  # decoding.
  use ExUnit.Case, async: true

  alias Mob.Scene3d.Projection

  # Filament column-major identity — reference matrix for the test suite.
  @identity [
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0
  ]

  # Camera at (0, 0, 5) looking at -Z (identity rotation, translated on Z).
  # In column-major layout, the translation lives at m03/m13/m23 which are
  # indices 12/13/14.
  @camera_at_0_0_5 [
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    5.0,
    1.0
  ]

  describe "mul_vec/2" do
    test "identity leaves the vector unchanged" do
      assert Projection.mul_vec(@identity, {1.0, 2.0, 3.0, 1.0}) == {1.0, 2.0, 3.0, 1.0}
    end

    test "column-major translation matrix moves the point correctly" do
      # Translate (0, 0, 0, 1) by (1, 2, 3) should give (1, 2, 3, 1).
      translate = [
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        1.0,
        2.0,
        3.0,
        1.0
      ]

      assert Projection.mul_vec(translate, {0.0, 0.0, 0.0, 1.0}) == {1.0, 2.0, 3.0, 1.0}
    end
  end

  describe "inverse/1" do
    test "identity is its own inverse" do
      {:ok, inv} = Projection.inverse(@identity)

      for {a, b} <- Enum.zip(inv, @identity), do: assert_in_delta(a, b, 1.0e-10)
    end

    test "inverse of a translation negates the translation" do
      {:ok, inv} = Projection.inverse(@camera_at_0_0_5)
      # Column-major: m03/m13/m23 are indices 12/13/14. The camera lives
      # at world +Z=5; its inverse (view matrix) should place the origin
      # at world -Z=5 relative to the camera — i.e. translate by (0,0,-5).
      assert_in_delta Enum.at(inv, 12), 0.0, 1.0e-10
      assert_in_delta Enum.at(inv, 13), 0.0, 1.0e-10
      assert_in_delta Enum.at(inv, 14), -5.0, 1.0e-10
    end

    test "singular matrix reports :singular rather than crashing" do
      zeros = List.duplicate(0.0, 16)
      assert Projection.inverse(zeros) == {:error, :singular}
    end
  end

  describe "perspective/4" do
    test "produces the expected diagonal entries for 90° fov, 1:1 aspect" do
      # fov_y=90° → f = 1/tan(45°) = 1. Aspect 1 leaves f/aspect = 1.
      m = Projection.perspective(90.0, 1.0, 0.1, 100.0)

      # m00 = f/aspect
      assert_in_delta Enum.at(m, 0), 1.0, 1.0e-6
      # m11 = f
      assert_in_delta Enum.at(m, 5), 1.0, 1.0e-6
      # The projection matrix's z row is well-defined but sensitive to
      # near/far — just check the range, not the exact algebra.
      assert Enum.at(m, 11) == -1.0
    end
  end

  describe "project_entity/6" do
    test "an entity at the world origin projects to the centre of the viewport" do
      # Camera at (0, 0, 5) looks at -Z; the world origin is 5 units in
      # front of it. Its projection is NDC (0, 0, some depth) which maps
      # to pixel (width/2, height/2).
      {:ok, %{x: x, y: y, in_frame?: true, depth: depth}} =
        Projection.project_entity(@camera_at_0_0_5, 90.0, 0.1, 100.0, {400.0, 300.0}, @identity)

      assert_in_delta x, 200.0, 1.0e-6
      assert_in_delta y, 150.0, 1.0e-6
      assert depth >= -1.0 and depth <= 1.0
    end

    test "an entity to the right of the camera projects to the right half" do
      # Entity translated to +X=1 in the world; camera at (0,0,5) still.
      # +X in world maps to +X in view (identity rotation), then to +X in
      # NDC, so pixel x > width/2.
      entity_at_1_0_0 = [
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        1.0,
        0.0,
        0.0,
        1.0
      ]

      {:ok, %{x: x, y: y}} =
        Projection.project_entity(
          @camera_at_0_0_5,
          90.0,
          0.1,
          100.0,
          {400.0, 300.0},
          entity_at_1_0_0
        )

      assert x > 200.0, "entity right of camera should land right of centre; got x=#{x}"
      assert_in_delta y, 150.0, 1.0e-6
    end

    test "an entity above the camera projects to the top half (smaller pixel y)" do
      entity_at_0_1_0 = [
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        1.0,
        0.0,
        1.0
      ]

      {:ok, %{x: x, y: y}} =
        Projection.project_entity(
          @camera_at_0_0_5,
          90.0,
          0.1,
          100.0,
          {400.0, 300.0},
          entity_at_0_1_0
        )

      assert_in_delta x, 200.0, 1.0e-6
      assert y < 150.0, "entity above camera should land above centre; got y=#{y}"
    end

    test "an entity behind the camera reports in_frame?=false" do
      # Camera at (0,0,5) looks at -Z; entity at (0,0,10) is BEHIND the
      # camera (further away in +Z). The view matrix (inverse of camera
      # world) sends it further into +Z (behind the camera plane).
      entity_at_0_0_10 = [
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        10.0,
        1.0
      ]

      {:ok, result} =
        Projection.project_entity(
          @camera_at_0_0_5,
          90.0,
          0.1,
          100.0,
          {400.0, 300.0},
          entity_at_0_0_10
        )

      refute result.in_frame?
    end

    test "singular camera reports :singular, not a crash" do
      zeros = List.duplicate(0.0, 16)

      assert {:error, :singular} =
               Projection.project_entity(zeros, 90.0, 0.1, 100.0, {100.0, 100.0}, @identity)
    end
  end
end
