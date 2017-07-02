# Erlang SNMP MIB compiler for Mix

[![Build Status](https://travis-ci.org/RumataEstor/mix_mib.svg?branch=master)](https://travis-ci.org/RumataEstor/mix_mib)

This project provides a Mix compiler that simplifies usage of [Erlang SNMP MIB compiler](http://erlang.org/doc/apps/snmp/snmp_mib_compiler.html).

## Installation

The package can be installed by adding `mix_mib` to your list of dependencies in `mix.exs`
and added to `compilers` list:

```elixir
def project do
  [
    # ...
    compilers: [:mix_mib] ++ Mix.compilers,
    deps: [
      # ...
      {:mix_mib, "~> 1.0.0", runtime: false},
    ]
  ]
end
```

The default compiler's behaviour can be modified by putting the following options in the project options:

* `mib_paths` (default: `["mibs", "src"]`) - source directories for `.mib` and `.func` files;
* `mib_output` (default: `"priv/mibs/"`) - directory to put compiled `.bin` file;
* `mib_options` (default: `[il: ['otp_mibs/priv/mibs/']]`) - additional options for the compiler, but `outdir` and `i` options will be overriden.

## License

MIT
