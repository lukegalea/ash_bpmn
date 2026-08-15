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
