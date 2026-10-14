{ pkgs, lib, config, ... }:

let
  # Same OTP/Elixir pairing as ash_enterprise (and the ash-hq installer), so the
  # library is built against the combination the Ash ecosystem tests against.
  beam = pkgs.beam.packages.erlang_27;
in
{
  name = "ash_bpmn";

  languages.erlang = {
    enable = true;
    package = beam.erlang;
    lsp.enable = false;
  };

  languages.elixir = {
    enable = true;
    package = beam.elixir_1_18;
    lsp.enable = false;
  };

  # Node is here for the designer's npm deps (bpmn-js) when smoke-testing the
  # hook against a host app; the library itself ships plain ESM in priv/js.
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_22;
  };

  packages = with pkgs; [
    git
    jq
  ];

  # Cap open files at 65536, soft AND hard.
  #
  # ERTS raises its soft RLIMIT_NOFILE to the hard limit at boot and sizes its
  # fd and port tables from the result. Under a systemd user service the hard
  # limit is ~1.07e9, and every BEAM then reserved ~4 GB and sat at ~2 GB
  # resident before doing any work; several at once exhausted the host's memory
  # (2026-10-14). Lowering only the soft limit does nothing, because ERTS raises
  # it back. Same cap as ash_enterprise's devenv.nix.
  enterShell = ''
    if [ "$(ulimit -Hn)" = unlimited ] || [ "$(ulimit -Hn)" -gt 65536 ]; then
      ulimit -n 65536
    fi
  '';

  services.postgres = {
    enable = true;
    package = pkgs.postgresql_16;
    listen_addresses = "127.0.0.1";
    initialDatabases = [
      { name = "ash_bpmn_test"; }
    ];
    initialScript = ''
      CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';
    '';
  };
}
