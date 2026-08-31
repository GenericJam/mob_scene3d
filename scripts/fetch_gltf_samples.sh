#!/usr/bin/env bash
# Fetch the curated Khronos glTF-Sample-Assets subset for the conformance
# sweep documented in guides/assets.md, into vendor/gltf-samples/
# (gitignored — pulled by script, never committed).
#
# Coverage intent: plain meshes, PBR materials (factors + textures +
# spec-gloss legacy), vertex colors, normal/tangent handling, emissive
# strength, transmission/volume, animation (TRS + interpolation modes),
# skinning, morph targets, KTX2/Basis textures, Draco compression.
#
# Two derived assets exercise pipeline paths the corpus lacks as .glb:
#   - StainedGlassLamp.ktx2.glb — the KTX-BasisU variant repacked embedded
#     (KHR_texture_basisu) via `gltf-transform cp`
#   - Duck.draco.glb — Draco-compressed (KHR_draco_mesh_compression) via
#     `gltf-transform draco`
#
# Then run:  mise exec -- mix scene3d.assets vendor/gltf-samples/models
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/gltf-samples"
CHECKOUT="$DEST/repo"
MODELS_DIR="$DEST/models"
REPO_URL="https://github.com/KhronosGroup/glTF-Sample-Assets.git"

MODELS=(
  Box
  BoxTextured
  BoxVertexColors
  Duck
  Avocado
  DamagedHelmet
  BoomBox
  MetalRoughSpheres
  NormalTangentMirrorTest
  EmissiveStrengthTest
  SpecGlossVsMetalRough
  MosquitoInAmber
  BoxAnimated
  InterpolationTest
  AnimatedMorphCube
  MorphStressTest
  RiggedSimple
  CesiumMan
  BrainStem
  Fox
)

GLTF_TRANSFORM=(npx --no-install @gltf-transform/cli)
command -v gltf-transform >/dev/null 2>&1 && GLTF_TRANSFORM=(gltf-transform)

if [ ! -d "$CHECKOUT/.git" ]; then
  git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$CHECKOUT"
fi

sparse_paths=()
for model in "${MODELS[@]}"; do
  sparse_paths+=("Models/$model/glTF-Binary")
done
sparse_paths+=("Models/StainedGlassLamp/glTF-KTX-BasisU")

git -C "$CHECKOUT" sparse-checkout set "${sparse_paths[@]}"

mkdir -p "$MODELS_DIR"
for model in "${MODELS[@]}"; do
  glb="$CHECKOUT/Models/$model/glTF-Binary/$model.glb"
  if [ -f "$glb" ]; then
    cp "$glb" "$MODELS_DIR/$model.glb"
  else
    echo "warning: $model has no glTF-Binary variant in the corpus" >&2
  fi
done

if [ ! -f "$MODELS_DIR/StainedGlassLamp.ktx2.glb" ]; then
  "${GLTF_TRANSFORM[@]}" cp \
    "$CHECKOUT/Models/StainedGlassLamp/glTF-KTX-BasisU/StainedGlassLamp.gltf" \
    "$MODELS_DIR/StainedGlassLamp.ktx2.glb"
fi

if [ ! -f "$MODELS_DIR/Duck.draco.glb" ]; then
  "${GLTF_TRANSFORM[@]}" draco "$MODELS_DIR/Duck.glb" "$MODELS_DIR/Duck.draco.glb"
fi

echo "Fetched $(ls "$MODELS_DIR" | wc -l | tr -d ' ') sweep models into $MODELS_DIR"
