defmodule Mob.Scene3d.Projection do
  @moduledoc """
  Camera + entity world-transform → pixel projection math for
  `Mob.Scene3d.project/N` (bead `mob_scene3d-xzh`).

  Split out so the matrix pieces (inverse, multiply, perspective build,
  NDC-to-pixel) can be exercised as pure functions in host tests without
  standing up a viewport. The whole surface is private to `Mob.Scene3d`;
  external callers use `Mob.Scene3d.project/N`.

  ## Matrix layout

  Every 4×4 matrix in this module is the flat 16-float column-major list
  Filament's `TransformManager` emits — `[m00, m10, m20, m30, m01, m11,
  m21, m31, m02, m12, m22, m32, m03, m13, m23, m33]`. Column j starts at
  index `j * 4`; element (row `i`, col `j`) is index `j * 4 + i`.

  Vectors are flat 4-element lists, treated as column vectors under
  matrix multiplication: `M · v` where `M` is the matrix and `v = {x, y,
  z, w}`. World positions use `w = 1`; direction vectors use `w = 0`.
  """

  @typedoc "Column-major flat 4×4 matrix — 16 floats in Filament's order."
  @type mat4 :: [float()]

  @typedoc "Homogeneous 4-vector `{x, y, z, w}`."
  @type vec4 :: {float(), float(), float(), float()}

  @doc """
  Multiply a 4×4 matrix by a column vector: returns `M · v`.
  """
  @spec mul_vec(mat4(), vec4()) :: vec4()
  def mul_vec([m00, m10, m20, m30, m01, m11, m21, m31, m02, m12, m22, m32, m03, m13, m23, m33], {
        vx,
        vy,
        vz,
        vw
      }) do
    {
      m00 * vx + m01 * vy + m02 * vz + m03 * vw,
      m10 * vx + m11 * vy + m12 * vz + m13 * vw,
      m20 * vx + m21 * vy + m22 * vz + m23 * vw,
      m30 * vx + m31 * vy + m32 * vz + m33 * vw
    }
  end

  @doc """
  Invert a 4×4 matrix via cofactor expansion. Returns `{:ok, m_inv}` or
  `{:error, :singular}` when the determinant is (effectively) zero.

  General-purpose because a camera's world transform might carry a
  non-unit scale — this covers the case without asking the caller to
  swear the transform is rigid.
  """
  @spec inverse(mat4()) :: {:ok, mat4()} | {:error, :singular}
  def inverse([m00, m10, m20, m30, m01, m11, m21, m31, m02, m12, m22, m32, m03, m13, m23, m33]) do
    # Cofactors and determinant via the standard 4×4 adjugate formula.
    # Element indexing is (row, col) - m[c][r] in column-major storage.
    # Written out longhand so the arithmetic is auditable without a
    # generic loop hiding the order.
    a2323 = m22 * m33 - m32 * m23
    a1323 = m12 * m33 - m32 * m13
    a1223 = m12 * m23 - m22 * m13
    a0323 = m02 * m33 - m32 * m03
    a0223 = m02 * m23 - m22 * m03
    a0123 = m02 * m13 - m12 * m03
    a2313 = m21 * m33 - m31 * m23
    a1313 = m11 * m33 - m31 * m13
    a1213 = m11 * m23 - m21 * m13
    a2312 = m21 * m32 - m31 * m22
    a1312 = m11 * m32 - m31 * m12
    a1212 = m11 * m22 - m21 * m12
    a0313 = m01 * m33 - m31 * m03
    a0213 = m01 * m23 - m21 * m03
    a0312 = m01 * m32 - m31 * m02
    a0212 = m01 * m22 - m21 * m02
    a0113 = m01 * m13 - m11 * m03
    a0112 = m01 * m12 - m11 * m02

    det =
      m00 * (m11 * a2323 - m21 * a1323 + m31 * a1223) -
        m10 * (m01 * a2323 - m21 * a0323 + m31 * a0223) +
        m20 * (m01 * a1323 - m11 * a0323 + m31 * a0123) -
        m30 * (m01 * a1223 - m11 * a0223 + m21 * a0123)

    if abs(det) < 1.0e-12 do
      {:error, :singular}
    else
      inv_det = 1.0 / det

      {:ok,
       [
         # Column 0 (m00..m30 of the inverse)
         inv_det * (m11 * a2323 - m21 * a1323 + m31 * a1223),
         inv_det * -(m10 * a2323 - m20 * a1323 + m30 * a1223),
         inv_det * (m10 * a2313 - m20 * a1313 + m30 * a1213),
         inv_det * -(m10 * a2312 - m20 * a1312 + m30 * a1212),
         # Column 1
         inv_det * -(m01 * a2323 - m21 * a0323 + m31 * a0223),
         inv_det * (m00 * a2323 - m20 * a0323 + m30 * a0223),
         inv_det * -(m00 * a2313 - m20 * a0313 + m30 * a0213),
         inv_det * (m00 * a2312 - m20 * a0312 + m30 * a0212),
         # Column 2
         inv_det * (m01 * a1323 - m11 * a0323 + m31 * a0123),
         inv_det * -(m00 * a1323 - m10 * a0323 + m30 * a0123),
         inv_det * (m00 * a1313 - m10 * a0313 + m30 * a0113),
         inv_det * -(m00 * a1312 - m10 * a0312 + m30 * a0112),
         # Column 3
         inv_det * -(m01 * a1223 - m11 * a0223 + m21 * a0123),
         inv_det * (m00 * a1223 - m10 * a0223 + m20 * a0123),
         inv_det * -(m00 * a1213 - m10 * a0213 + m20 * a0113),
         inv_det * (m00 * a1212 - m10 * a0212 + m20 * a0112)
       ]}
    end
  end

  @doc """
  Right-handed OpenGL-style perspective projection matrix in column-major
  order. `fov_y` in degrees (matches `Mob.Scene3d.IR.Camera`'s field).

  Filament's default camera uses the same convention — NDC z ∈ [-1, 1],
  y up, right-handed view space with `-z` into the screen — so the same
  formulas the render thread uses for `Camera::setProjection` produce the
  same clip-space math here.
  """
  @spec perspective(number(), number(), number(), number()) :: mat4()
  def perspective(fov_y_deg, aspect, near, far)
      when is_number(fov_y_deg) and is_number(aspect) and is_number(near) and is_number(far) do
    fov_rad = fov_y_deg * :math.pi() / 180.0
    f = 1.0 / :math.tan(fov_rad / 2.0)
    nf = 1.0 / (near - far)

    [
      # column 0
      f / aspect, 0.0, 0.0, 0.0,
      # column 1
      0.0, f, 0.0, 0.0,
      # column 2
      0.0, 0.0, (far + near) * nf, -1.0,
      # column 3
      0.0, 0.0, 2.0 * far * near * nf, 0.0
    ]
  end

  @doc """
  Convert an NDC point (each coord in `[-1, 1]`) plus the viewport's
  dp/pt size to viewport-local pixel coordinates. Origin is top-left, so
  y flips (NDC y=+1 is the top of the viewport, pixel y=0 is the top).
  """
  @spec ndc_to_pixel(vec4(), number(), number()) :: {float(), float()}
  def ndc_to_pixel({ndc_x, ndc_y, _ndc_z, _}, width, height) do
    {(ndc_x + 1.0) * width / 2.0, (1.0 - ndc_y) * height / 2.0}
  end

  @doc """
  End-to-end: given a `camera_world_transform` (16 floats), camera
  intrinsics (fov_y in degrees, near, far), viewport dp/pt `{width,
  height}`, and an `entity_world_transform`, return
  `{:ok, %{x, y, depth, in_frame?}}` or `{:error, :singular}` if the
  camera transform can't be inverted.

  The entity's *origin* is projected — column 3 of its world transform
  in Filament's TransformManager, which is where the mesh anchors. For
  models with a substantial extent the caller pairs this with
  `sample_region/N` around the origin.
  """
  @spec project_entity(mat4(), number(), number(), number(), {number(), number()}, mat4()) ::
          {:ok, %{x: float(), y: float(), depth: float(), in_frame?: boolean()}}
          | {:error, :singular}
  def project_entity(camera_world, fov_y_deg, near, far, {width, height}, entity_world) do
    with {:ok, view} <- inverse(camera_world) do
      # Entity origin — column 3 of its world transform.
      origin = {
        Enum.at(entity_world, 12),
        Enum.at(entity_world, 13),
        Enum.at(entity_world, 14),
        1.0
      }

      proj = perspective(fov_y_deg, width / height, near, far)
      view_pos = mul_vec(view, origin)
      clip_pos = mul_vec(proj, view_pos)
      {cx, cy, cz, cw} = clip_pos

      # Divide by w to get NDC. If w <= 0 the point is on or behind the
      # camera plane; still return coords for reframing but flag out-of-frame.
      {ndc, in_frame?} =
        if cw > 0.0 do
          ndc_x = cx / cw
          ndc_y = cy / cw
          ndc_z = cz / cw

          on_screen? =
            ndc_x >= -1.0 and ndc_x <= 1.0 and ndc_y >= -1.0 and ndc_y <= 1.0 and
              ndc_z >= -1.0 and ndc_z <= 1.0

          {{ndc_x, ndc_y, ndc_z, 1.0}, on_screen?}
        else
          # w <= 0 — the point is at or behind the camera plane. Report
          # the clip coords so an agent can still compare frames but with
          # in_frame?=false so it does not act on them as visible.
          {{cx, cy, cz, cw}, false}
        end

      {px, py} = ndc_to_pixel(ndc, width, height)
      {_, _, depth, _} = ndc
      {:ok, %{x: px, y: py, depth: depth, in_frame?: in_frame?}}
    end
  end
end
