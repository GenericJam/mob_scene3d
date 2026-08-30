%{
  configs: [
    %{
      name: "default",
      # ex_slop is a credo PLUGIN (registers its whole check bundle), not a
      # check — listing it under checks.enabled is silently ignored. Same
      # wiring as mob's .credo.exs.
      plugins: [{ExSlop, []}],
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: %{
        enabled: [
          {Credo.Check.Readability.Specs, files: %{excluded: ["test/"]}},
          {Credo.Check.Refactor.UnlessWithElse, []},
          # jump_credo_checks
          {Jump.CredoChecks.AvoidFunctionLevelElse, []},
          {Jump.CredoChecks.AvoidLoggerConfigureInTest, []},
          {Jump.CredoChecks.TestHasNoAssertions, []},
          {Jump.CredoChecks.TooManyAssertions, []},
          {Jump.CredoChecks.TopLevelAliasImportRequire, []},
          {Jump.CredoChecks.WeakAssertion, []},
          {Jump.CredoChecks.VacuousTest, []}
          # ex_slop's bundle is appended below — an explicit `enabled` list is
          # authoritative and would otherwise silently discard the plugin's
          # checks (credo warns about exactly this).
        ] ++ Enum.map(ExSlop.recommended_checks(), &{&1, []}),
        disabled: [
          # Pipes with single function calls are fine in this codebase
          {Credo.Check.Readability.SinglePipe, []}
        ]
      }
    }
  ]
}
