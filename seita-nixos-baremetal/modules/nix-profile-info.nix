{ config, lib, pkgs, ... }:

##############################################################################
# Exposes the contents of user's `nix profile` (imperatively installed
# packages) to Grafana, plus a per-package upstream-update check.
#
# Unlike modules/nix-info.nix (environment.systemPackages), profile contents
# are not known at Nix eval time, so this module polls manifest.json on a
# timer rather than relying on switch to re-trigger a unit.
#
# Docs:
#   docs/services/textfile-metrics.md#nix-profile-infonix--nix-profile-imperative-installs
#   docs/decisions/2026-09-23-repology-to-direct-nix-eval.md
#   docs/runbooks/textfile-metrics.md
#
# Update the docs above in the same commit when you change this file.
##############################################################################

let
  # Directory read by node_exporter's textfile collector. Same path as
  # modules/nix-info.nix / modules/zfs-snapshot-metrics.nix.
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  # Monitored users. Profiles are per-user, so adding a user here is enough
  # for both collectors to pick them up.
  profileUsers = [ "seita" ];

  # Username -> path to that profile's manifest.json. Home directory is taken
  # from users.users.<name>.home as the single source of truth, never
  # hardcoded as /home/<name>.
  manifestPathFor = user:
    "${config.users.users.${user}.home}/.local/state/nix/profiles/profile/manifest.json";

  # manifest.json -> "name\tversion\ttracked-ref\tattrPath\toriginalUrl" TSV.
  # Used by both the package-list collector and the update-check collector, so
  # version-string parsing can't disagree between the two.
  manifestToTsv = pkgs.writeText "nix-profile-manifest-to-tsv.jq" ''
    .elements | to_entries[]
    | .key as $name
    | ((.value.storePaths // [])[0] // "") as $storePath
    # A nix store path's hash is always 32 [a-z0-9] characters. Without fixing
    # the length, ^[a-z0-9]+- greedily eats up to "...-ccusage-", breaking the
    # match against the element name.
    | ($storePath | split("/") | last | sub("^[a-z0-9]{32}-"; "")) as $base
    | (if ($base | startswith($name + "-")) then
         ($base | ltrimstr($name + "-"))
       else
         # Element name and the store path's pname disagree (e.g. installed
         # under a different attribute name) -- treat everything from the
         # first "-<digit>" onward as the version.
         ([$base | capture("-(?<v>[0-9][^/]*)$")] | (.[0].v // "unknown"))
       end) as $version
    | (.value.originalUrl // "") as $originalUrl
    | ($originalUrl | split("/") | last) as $ref
    | (.value.attrPath // "") as $attrPath
    | [$name, $version, $ref, $attrPath, $originalUrl] | @tsv
  '';

  # Strip characters that would break a Prometheus label value. Same role as
  # nix-info.nix's escapeLabel, but that one runs at Nix eval time; this one
  # has to run at run time instead.
  sanitizeLabelSh = ''
    sanitize_label() {
      printf '%s' "$1" | tr -d '\\"' | tr '\n' ' '
    }
  '';

  profileCollector = pkgs.writeShellApplication {
    name = "nix-profile-metrics";
    runtimeInputs = [ pkgs.jq pkgs.coreutils ];
    text = ''
      out="${textfileDir}/nix-profile-packages.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      ${sanitizeLabelSh}

      {
        echo '# HELP nix_profile_collector_ok Whether this user'"'"'s profile manifest.json could be read (1/0)'
        echo '# TYPE nix_profile_collector_ok gauge'
        echo '# HELP nix_profile_package_info Packages in user'"'"'s nix profile (value is always 1)'
        echo '# TYPE nix_profile_package_info gauge'
        echo '# HELP nix_profile_package_count Total number of packages in user'"'"'s nix profile'
        echo '# TYPE nix_profile_package_count gauge'
        echo '# HELP nix_profile_generation Currently active profile generation number'
        echo '# TYPE nix_profile_generation gauge'
        echo '# HELP nix_profile_generation_mtime_seconds When the currently active profile generation was created (unix seconds)'
        echo '# TYPE nix_profile_generation_mtime_seconds gauge'

        ${lib.concatMapStringsSep "\n" (user: ''
          manifest="${manifestPathFor user}"

          if [ ! -r "$manifest" ]; then
            # A user who has never created a profile is not an error case.
            # Omit count rather than reporting 0, so "no packages" and
            # "couldn't read" aren't confused.
            echo 'nix_profile_collector_ok{user="${user}"} 0'
          else
            echo 'nix_profile_collector_ok{user="${user}"} 1'

            count=0
            while IFS=$'\t' read -r name version ref _attrPath _originalUrl; do
              [ -n "$name" ] || continue
              name=$(sanitize_label "$name")
              version=$(sanitize_label "$version")
              ref=$(sanitize_label "$ref")
              echo "nix_profile_package_info{user=\"${user}\",name=\"$name\",version=\"$version\",channel=\"$ref\"} 1"
              count=$((count + 1))
            done < <(jq -r -f ${manifestToTsv} "$manifest")

            echo "nix_profile_package_count{user=\"${user}\"} $count"

            # profile is a symlink to profile-N-link. N is the generation
            # number, which changes with every nix profile install/rollback.
            profileLink="${config.users.users.${user}.home}/.local/state/nix/profiles/profile"
            link=$(readlink "$profileLink" || true)
            generation=''${link#profile-}
            generation=''${generation%-link}
            case "$generation" in
              ""|*[!0-9]*) ;;
              *)
                echo "nix_profile_generation{user=\"${user}\"} $generation"
                # manifest.json's mtime does NOT tell you "when was this
                # swapped in" -- it's a /nix/store artifact, always
                # normalized to 1 (epoch+1); confirmed by stat on the live
                # host, 2026-09-23. The real timestamp lives on the
                # generation symlink itself (its own lstat mtime).
                gen_mtime=$(stat -c %Y "$(dirname "$profileLink")/$link")
                echo "nix_profile_generation_mtime_seconds{user=\"${user}\"} $gen_mtime"
                ;;
            esac
          fi
        '') profileUsers}

        echo "nix_profile_metrics_last_run_seconds $(date +%s)"
      } > "$work/out"

      # Build on textfileDir before renaming, so node_exporter never reads a
      # partial write.
      staging=$(mktemp "${textfileDir}/.nix-profile-packages.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };

  # Collector that diffs installed versions against the tracked channel's
  # current version. Sandboxing notes:
  # docs/services/textfile-metrics.md#systemd-sandboxing-notes-both-nix-infonix-and-nix-profile-infonix-upstream-collectors
  upstreamCollector = pkgs.writeShellApplication {
    name = "nix-profile-upstream-metrics";
    runtimeInputs = [ config.nix.package pkgs.jq pkgs.coreutils ];
    text = ''
      out="${textfileDir}/nix-profile-upstream-status.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      ${sanitizeLabelSh}

      # originalUrl -> already resolved this run? Avoid re-resolving the same
      # channel repeatedly.
      declare -A channel_done=()

      {
        echo '# HELP nix_profile_package_upstream_known Whether the tracked channel'"'"'s version for this package could be looked up (1/0)'
        echo '# TYPE nix_profile_package_upstream_known gauge'
        echo '# HELP nix_profile_package_upstream_version_info Current version on the tracked channel (value is always 1)'
        echo '# TYPE nix_profile_package_upstream_version_info gauge'
        echo '# HELP nix_profile_package_outdated Whether the tracked channel'"'"'s version differs from the installed version (1 = differs, raised by nix profile upgrade)'
        echo '# TYPE nix_profile_package_outdated gauge'
        echo '# HELP nix_profile_channel_resolve_ok Whether the tracked channel'"'"'s current revision could be resolved (1/0)'
        echo '# TYPE nix_profile_channel_resolve_ok gauge'
        echo '# HELP nix_profile_channel_revision_info nixpkgs revision the tracked channel currently points at (value is always 1)'
        echo '# TYPE nix_profile_channel_revision_info gauge'

        ${lib.concatMapStringsSep "\n" (user: ''
          manifest="${manifestPathFor user}"

          if [ -r "$manifest" ]; then
            while IFS=$'\t' read -r name installed_version ref attrPath originalUrl; do
              [ -n "$name" ] || continue
              name=$(sanitize_label "$name")
              installed_version=$(sanitize_label "$installed_version")
              ref=$(sanitize_label "$ref")

              if [ -z "$attrPath" ] || [ -z "$originalUrl" ]; then
                # Elements without attrPath/originalUrl in the manifest (old
                # install format, direct store-path install) have nothing to
                # look up.
                echo "nix_profile_package_upstream_known{user=\"${user}\",name=\"$name\"} 0"
                continue
              fi

              # Resolve the channel's current position only once.
              # Without --refresh, the tarball-ttl cache (1h default) can
              # return a stale evaluation and under-report "no update".
              if [ -z "''${channel_done[$originalUrl]+set}" ]; then
                channel_done[$originalUrl]=1
                if meta=$(nix flake metadata --json --refresh "$originalUrl" 2>/dev/null); then
                  echo "nix_profile_channel_resolve_ok{channel=\"$ref\"} 1"
                  rev=$(echo "$meta" | jq -r '.locked.rev // empty')
                  if [ -n "$rev" ]; then
                    rev=$(sanitize_label "$rev")
                    echo "nix_profile_channel_revision_info{channel=\"$ref\",rev=\"$rev\"} 1"
                  fi
                else
                  # If resolution fails, the following nix eval may use a
                  # stale cache. Surface resolve_ok=0 on the dashboard rather
                  # than silently reporting a possibly-wrong result.
                  echo "nix_profile_channel_resolve_ok{channel=\"$ref\"} 0"
                fi
              fi

              # No --refresh here: the flake metadata --refresh above already
              # refreshed this originalUrl's cache, so refreshing twice is
              # wasted.
              if upstream_version=$(nix eval --raw "''${originalUrl}#''${attrPath}.version" 2>/dev/null) \
                && [ -n "$upstream_version" ]; then
                upstream_version=$(sanitize_label "$upstream_version")
                echo "nix_profile_package_upstream_known{user=\"${user}\",name=\"$name\"} 1"
                echo "nix_profile_package_upstream_version_info{user=\"${user}\",name=\"$name\",version=\"$upstream_version\"} 1"
                if [ "$upstream_version" = "$installed_version" ]; then
                  echo "nix_profile_package_outdated{user=\"${user}\",name=\"$name\"} 0"
                else
                  echo "nix_profile_package_outdated{user=\"${user}\",name=\"$name\"} 1"
                fi
              else
                # The attribute disappeared (renamed/removed), or evaluation
                # failed. Neither is "no update", so no outdated either.
                echo "nix_profile_package_upstream_known{user=\"${user}\",name=\"$name\"} 0"
              fi
            done < <(jq -r -f ${manifestToTsv} "$manifest")
          fi
        '') profileUsers}

        echo "nix_profile_upstream_metrics_last_run_seconds $(date +%s)"
      } > "$work/out"

      staging=$(mktemp "${textfileDir}/.nix-profile-upstream-status.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"

    # Old output from when the profile side moved from Repology to
    # direct-eval. See
    # docs/decisions/2026-09-23-repology-to-direct-nix-eval.md.
    "r ${textfileDir}/nix-profile-repology-status.prom - - - -"
  ];

  # Profile contents: `nix profile install` doesn't go through switch, so the
  # "switch re-triggers automatically" trick from nix-info.nix doesn't apply
  # here -- a timer is needed instead. Reading one manifest.json is cheap
  # enough that 15 minutes is negligible load.
  #
  # ProtectHome can't be true here -- the whole point is reading into the
  # user's home. Set to read-only instead, to prevent accidental writes into
  # the profile.
  systemd.services.nix-profile-metrics = {
    description = "Export the contents of the user's nix profile as a node_exporter textfile";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe profileCollector;
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.timers.nix-profile-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "15min";
      RandomizedDelaySec = "1min";
      Persistent = true;
    };
  };

  # Diff against the tracked channel: one nix eval per element (measured
  # ~0.3s). The channel itself moves only a few times a day, so once a day
  # is enough.
  #
  # Runs under ProtectSystem=strict, so HOME is redirected to StateDirectory
  # and NIX_REMOTE=daemon delegates store writes to the daemon.
  systemd.services.nix-profile-upstream-metrics = {
    description = "Export whether packages in the user's nix profile are outdated (compared directly against the tracked nixpkgs) as a node_exporter textfile";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe upstreamCollector;
      # Extra headroom in case the channel tarball needs re-fetching.
      TimeoutStartSec = "30min";
      StateDirectory = "nix-profile-upstream";
      Environment = [
        "HOME=/var/lib/nix-profile-upstream"
        "NIX_REMOTE=daemon"
      ];
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
      # AF_UNIX is the nix daemon socket, AF_INET/6 is for fetching the channel.
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    };
  };

  systemd.timers.nix-profile-upstream-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "12min";
      OnUnitActiveSec = "24h";
      RandomizedDelaySec = "10min";
      Persistent = true;
    };
  };

  # Manual verification: docs/runbooks/textfile-metrics.md
}
