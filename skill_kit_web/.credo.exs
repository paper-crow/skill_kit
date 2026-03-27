%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      checks: %{
        enabled: [
          {Credo.Check.Readability.ModuleDoc, false}
        ]
      }
    }
  ]
}
