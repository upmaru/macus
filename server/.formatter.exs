[
  import_deps: [:phoenix],
  # TamaMCP.Server's tool DSL; tama_mcp exports no formatter configuration.
  locals_without_parens: [tool: 2],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"]
]
