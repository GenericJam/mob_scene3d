# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
SemVer. `mix.exs` is the single source of truth for the version.

## [Unreleased]

### Added

- Plugin core (beads `mob_scene3d-t05`, `mob_scene3d-nhf`): the
  `Mob.Scene3d` surface (scene IR in assigns, diff against last committed
  IR, versioned JSON wire with caps-based version-skew guards), the
  `Mob.Scene3d.Viewport` component (teardown rides mob #111 component
  reclamation), and the native NIF wire + Filament scene appliers on both
  platforms — shadow-registry patch validation on the BEAM thread
  (atomic reject-all, honest error taxonomy), ops applied between frames
  on the render thread (Choreographer / CADisplayLink), renderer fully
  rebuildable from the shadow on view re-attach. Filament pinned at
  1.75.1 on both platforms (newest version published to Maven Central).
  Animation ops are honestly unsupported (`{:error, {:unsupported,
  :set_animation}}` via the caps guard); Environment is accepted but
  IBL/skybox KTX loading awaits the asset pipeline (`mob_scene3d-392`).
