defmodule MixMib.Mixfile do
  use Mix.Project

  def project do
    [app: :mix_mib,
     version: "1.0.0",
     elixir: "~> 1.4",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: [],

     description: "Erlang SNMP MIB compiler for Mix",
     package: [
       licenses: ["MIT"],
       maintainers: ["RumataEstor"],
       links: %{"GitHub" => "https://github.com/RumataEstor/mix_mib"},
     ],
    ]
  end

  def application do
    [applications: []]
  end
end
