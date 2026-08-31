import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# S3dSpike.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :s3d_spike, ecto_repos: [S3dSpike.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, S3dSpike.Repo

# mob_scene3d: resolve logical .glb refs against this app's priv assets
# (working layout until the asset-pipeline bead, mob_scene3d-392).
config :mob_scene3d, asset_root: {:s3d_spike, "priv/scene3d_assets"}
