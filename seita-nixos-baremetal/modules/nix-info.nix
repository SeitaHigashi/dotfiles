{ config, lib, pkgs, ... }:

##############################################################################
# Exposes "what's installed on this machine right now" to Grafana. Bundles three
# concerns: the environment.systemPackages list, per-package upstream-update
# checks (by evaluating the tracked nixpkgs channel directly), and Hydra build
# status for the tracked nixpkgs/nixos channels.
#
# Docs:
#   docs/services/textfile-metrics.md#nix-infonix--installed-packages-upstream-diff-hydra-status
#   docs/decisions/2026-09-23-repology-to-direct-nix-eval.md
#   docs/runbooks/textfile-metrics.md
#
# Update the docs above in the same commit when you change this file.
##############################################################################

let
  # Directory read by node_exporter's textfile collector. Must match
  # modules/monitoring.nix's extraFlags and modules/zfs-snapshot-metrics.nix.
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  # Escape a value for embedding in a Prometheus label. Package names shouldn't
  # contain " or \, but this is defensive.
  escapeLabel = s:
    lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" " " ] s;

  # Same sanitization as escapeLabel, but for values (revision, version) only
  # known at run time — see nix-profile-info.nix's sanitizeLabelSh.
  sanitizeLabelSh = ''
    sanitize_label() {
      printf '%s' "$1" | tr -d '\\"' | tr '\n' ' '
    }
  '';

  # flake.lock's nixpkgs input ref (e.g. "nixos-25.05") is the single source of
  # truth here — distinct from stateVersion (see CLAUDE.md). Computed once
  # since flake.nix could change the tracked branch. nixpkgs-unstable itself is
  # pinned to a fixed revision in flake.nix, but this module wants "is there an
  # update on the branch's tip (nixos-unstable)", so it uses the branch name,
  # not the pinned revision.
  flakeLock = builtins.fromJSON (builtins.readFile ../flake.lock);
  stableChannelRef = flakeLock.nodes.nixpkgs.original.ref; # e.g. "nixos-25.05"

  # Tracked channel name -> flake reference. Only two are actually used (one
  # for unstable-sourced packages, one for stable-sourced packages).
  channels = {
    "nixos-unstable" = "github:NixOS/nixpkgs/nixos-unstable";
    ${stableChannelRef} = "github:NixOS/nixpkgs/${stableChannelRef}";
  };

  # Candidate scopes for attrPath identification: try the top level ("") first,
  # then KDE Plasma / Python / Node subsets. See
  # docs/decisions/2026-09-23-repology-to-direct-nix-eval.md for why this list
  # exists and the measured hit rate.
  candidateScopes = [ "" "kdePackages" "libsForQt5" "plasma5Packages" "python3Packages" "nodePackages" ];

  # Check via tryEval whether pname exists under base.scope with the same
  # drvPath as the installed derivation p. Both a throwing removed alias and a
  # nonexistent scope are treated as "not found".
  candidateFor = tag: base: scope: pname: drvPath:
    let
      scoped =
        if scope == "" then base
        else
          let attempt = builtins.tryEval (base.${scope} or null); in
          if attempt.success then attempt.value else null;
      attempt =
        if scoped == null then { success = false; }
        else builtins.tryEval (scoped.${pname}.drvPath or null);
    in
    if attempt.success && attempt.value != null && attempt.value == drvPath
    then { inherit tag scope; }
    else null;

  # Try every candidate scope under both bases this host actually uses
  # (unstable, stable), and take the first drvPath match. unstable is tried
  # first so a modules/unstable.nix package can't accidentally match the
  # same-named stable attribute (a different revision) — drvPath matching
  # should make that impossible anyway, but this makes the priority explicit.
  resolveAttr = p:
    let
      pname = p.pname or p.name or null;
      drvPath = p.drvPath or null;
    in
    if pname == null || drvPath == null then null
    else
      let
        bases = [
          { tag = stableChannelRef; unstable = false; }
          { tag = "nixos-unstable"; unstable = true; }
        ];
        pkgsFor = b: if b.unstable then pkgs.unstable else pkgs;
        candidates = lib.concatMap
          (b: map (scope: candidateFor b.tag (pkgsFor b) scope pname drvPath) candidateScopes)
          bases;
      in
      lib.findFirst (c: c != null) null candidates;

  # Single source of truth for name/version/attrPath/channel tuples — both the
  # textfile lines and the update-check TSV are built from this, so the two
  # can't disagree on how packages are counted.
  packages = lib.unique (map
    (p:
      let
        pname = p.pname or p.name or "unknown";
        match = resolveAttr p;
      in
      {
        name = escapeLabel pname;
        version = escapeLabel (p.version or "unknown");
        # attrPath is scope+pname joined with ".". Carried as a single TSV
        # field without splitting on the shell side — splitting into a list
        # for the --apply expression stays entirely on the Nix side.
        attrPath =
          if match == null then null
          else if match.scope == "" then pname
          else "${match.scope}.${pname}";
        channel = if match == null then null else match.tag;
      })
    (lib.filter lib.isDerivation config.environment.systemPackages));

  packageLines = map
    (p: ''nixos_installed_package_info{name="${p.name}",version="${p.version}"} 1'')
    packages;

  # A duplicate pname with a different version (measured: both fuse 2.9.9 and
  # 3.16.2 installed) would emit the same Prometheus label set twice, which
  # node_exporter rejects with "collected metric ... was collected before
  # with the same name and label values" (confirmed in the live journal,
  # 2026-09-06, repeating every 30s). Keep first-seen per name only.
  packagesByName = lib.attrValues
    (lib.foldl' (acc: p: acc // { ${p.name} = acc.${p.name} or p; }) { } packages);

  packagesProm = pkgs.writeText "nixos-packages.prom" ''
    # HELP nixos_installed_package_info Packages listed in environment.systemPackages (value is always 1)
    # TYPE nixos_installed_package_info gauge
    ${lib.concatStringsSep "\n" packageLines}
    # HELP nixos_installed_package_count Total number of packages listed in environment.systemPackages
    # TYPE nixos_installed_package_count gauge
    nixos_installed_package_count ${toString (lib.length packageLines)}
  '';

  # For the update check: one line "name\tversion\tchannel\tattrPath". A
  # package whose attrPath couldn't be identified gets empty channel/attrPath.
  packageAttrsTsv = pkgs.writeText "nixos-package-attrs.tsv"
    (lib.concatMapStringsSep "\n"
      (p: "${p.name}\t${p.version}\t${if p.channel == null then "" else p.channel}\t${if p.attrPath == null then "" else p.attrPath}")
      packagesByName);

  # Per-channel attrPath list, pre-split into "." components on the Nix side.
  # This is the one place attrPaths with dots (e.g. "kdePackages.dolphin") get
  # split — never done in shell or inside the --apply expression.
  attrPathPartsForChannel = channel: lib.unique
    (map (p: lib.splitString "." p.attrPath)
      (lib.filter (p: p.channel == channel && p.attrPath != null) packagesByName));

  # Build the expression passed to `nix eval --apply` for a channel's
  # legacyPackages. attrPath is embedded as a list of pre-split lists, so no
  # runtime string splitting happens. Every attribute lookup is tryEval-guarded
  # so (a) a missing scope, (b) a throwing removed alias, or (c) a missing/
  # non-string version attribute each just yield an empty string rather than
  # failing the whole evaluation.
  mkApplyExpr = channel:
    let
      partsList = attrPathPartsForChannel channel;
      partsToNixList = parts: "[ " + lib.concatMapStringsSep " " (s: builtins.toJSON s) parts + " ]";
      partsListNix = "[ " + lib.concatMapStringsSep " " partsToNixList partsList + " ]";
    in ''
      pkgSet:
      builtins.listToAttrs (map (parts:
        let
          get = builtins.foldl' (acc: k: if acc == null then null else acc.''${k} or null) pkgSet parts;
          got = builtins.tryEval get;
          versionAttempt =
            if got.success && got.value != null
            then builtins.tryEval (got.value.version or null)
            else { success = false; };
          version =
            if versionAttempt.success && builtins.isString versionAttempt.value
            then versionAttempt.value
            else "";
        in
        { name = builtins.concatStringsSep "." parts; value = version; }
      ) ${partsListNix})
    '';

  # Write the expression above out as a file at eval time. shellcheck
  # statically analyzes ExecStart's contents when building
  # writeShellApplication, and a raw Nix expression (full of ${...}, which
  # looks like shell interpolation) embedded directly into the ExecStart
  # string trips SC2016. Writing it to a file and `cat`-ing it at run time
  # keeps it out of shellcheck's reach.
  applyExprFileFor = channel:
    pkgs.writeText "nixos-package-upstream-apply-${channel}.nix" (mkApplyExpr channel);

  # Collector that diffs installed versions against the tracked channel's
  # current version. Only two `nix` calls per channel (metadata resolution +
  # one bulk eval). Sandboxing notes:
  # docs/services/textfile-metrics.md#systemd-sandboxing-notes-both-nix-infonix-and-nix-profile-infonix-upstream-collectors
  upstreamCollector = pkgs.writeShellApplication {
    name = "nixos-package-upstream-metrics";
    runtimeInputs = [ config.nix.package pkgs.jq pkgs.coreutils ];
    text = ''
      out="${textfileDir}/nixos-package-upstream-status.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      ${sanitizeLabelSh}

      {
        echo '# HELP nixos_package_upstream_attr_resolved Whether this package'"'"'s nixpkgs attrPath was identified by drvPath match (1/0)'
        echo '# TYPE nixos_package_upstream_attr_resolved gauge'
        echo '# HELP nixos_package_upstream_known Whether the tracked channel'"'"'s version for this package could be looked up (1/0). Not emitted when attr_resolved=0'
        echo '# TYPE nixos_package_upstream_known gauge'
        echo '# HELP nixos_package_upstream_version_info Current version on the tracked channel (value is always 1)'
        echo '# TYPE nixos_package_upstream_version_info gauge'
        echo '# HELP nixos_package_outdated Whether the tracked channel'"'"'s version differs from the installed version (1 = differs, may go up on flake update). Only emitted when upstream_known=1'
        echo '# TYPE nixos_package_outdated gauge'
        echo '# HELP nixos_channel_resolve_ok Whether the tracked channel'"'"'s current revision could be resolved (1/0)'
        echo '# TYPE nixos_channel_resolve_ok gauge'
        echo '# HELP nixos_channel_revision_info nixpkgs revision the tracked channel currently points at (value is always 1)'
        echo '# TYPE nixos_channel_revision_info gauge'

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList
          (channel: channelRef: ''
            # Without --refresh, the tarball-ttl cache (1h default) can return
            # a stale evaluation and under-report "no update" (same reasoning
            # as nix-profile-info.nix).
            if meta=$(nix flake metadata --json --refresh "${channelRef}" 2>/dev/null); then
              echo 'nixos_channel_resolve_ok{channel="${channel}"} 1'
              rev=$(echo "$meta" | jq -r '.locked.rev // empty')
              if [ -n "$rev" ]; then
                rev=$(sanitize_label "$rev")
                echo "nixos_channel_revision_info{channel=\"${channel}\",rev=\"$rev\"} 1"
              fi
            else
              # If resolution fails, the following nix eval may use a stale
              # cache. Surface resolve_ok=0 on the dashboard rather than
              # silently reporting a possibly-wrong result.
              echo 'nixos_channel_resolve_ok{channel="${channel}"} 0'
            fi

            # Evaluate all of this channel's attrPaths in one call — measured
            # ~0.6s for 216 attributes with a warm evaluation cache. No
            # --refresh here: the flake metadata --refresh above already
            # refreshed this channel's cache, so refreshing twice is wasted.
            nix eval --json "${channelRef}#legacyPackages.x86_64-linux" \
              --apply "$(cat ${applyExprFileFor channel})" \
              > "$work/versions-${channel}.json" 2>/dev/null || echo '{}' > "$work/versions-${channel}.json"
          '')
          channels)}

        while IFS=$'\t' read -r name installed_version channel attrPath; do
          [ -n "$name" ] || continue
          name=$(sanitize_label "$name")
          installed_version=$(sanitize_label "$installed_version")

          if [ -z "$channel" ] || [ -z "$attrPath" ]; then
            # attrPath identification failed (drvPath matched no candidate
            # scope). No guessing from the name, so no known/outdated either.
            echo "nixos_package_upstream_attr_resolved{name=\"$name\"} 0"
            continue
          fi
          echo "nixos_package_upstream_attr_resolved{name=\"$name\"} 1"

          versionsFile="$work/versions-''${channel}.json"
          upstream_version=""
          if [ -f "$versionsFile" ]; then
            upstream_version=$(jq -r --arg k "$attrPath" '.[$k] // empty' "$versionsFile")
          fi

          if [ -n "$upstream_version" ]; then
            upstream_version=$(sanitize_label "$upstream_version")
            echo "nixos_package_upstream_known{name=\"$name\"} 1"
            echo "nixos_package_upstream_version_info{name=\"$name\",version=\"$upstream_version\"} 1"
            if [ "$upstream_version" = "$installed_version" ]; then
              echo "nixos_package_outdated{name=\"$name\"} 0"
            else
              echo "nixos_package_outdated{name=\"$name\"} 1"
            fi
          else
            # Attribute was identified, but not found in that channel's
            # evaluation (renamed/removed) or evaluation failed. Not
            # "no update", so no outdated either.
            echo "nixos_package_upstream_known{name=\"$name\"} 0"
          fi
        done < ${packageAttrsTsv}

        echo "nixos_package_upstream_metrics_last_run_seconds $(date +%s)"
      } > "$work/out"

      staging=$(mktemp "${textfileDir}/.nixos-package-upstream-status.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };

  # flake.lock's nixpkgs (stable) / nixpkgs-unstable revisions. Same
  # single-source-of-truth principle as machine.nix: read flake.lock directly
  # rather than re-deriving it (flakeLock itself is already defined above).
  stableRev = flakeLock.nodes.nixpkgs.locked.rev;
  unstableRev = flakeLock.nodes."nixpkgs-unstable".locked.rev;

  # channel name -> the project/jobset and revision it uses. nixos-25.05 maps
  # to the NixOS release branch (nixos/release-25.05-small); nixos-unstable
  # maps to nixpkgs' master-branch evaluation (nixpkgs/unstable). The latter
  # is technically distinct from the nixos-unstable channel itself (which is
  # filtered post-tests), but it's the evaluation immediately upstream of
  # that split, so it's good enough as a "is Hydra evaluating this content
  # recently" signal.
  hydraChannels = {
    "nixos-25.05" = { jobset = "nixos/release-25.05-small"; rev = stableRev; };
    "nixos-unstable" = { jobset = "nixpkgs/unstable"; rev = unstableRev; };
  };

  hydraCollector = pkgs.writeShellApplication {
    name = "hydra-build-metrics";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    text = ''
      out="${textfileDir}/hydra-build-status.prom"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      {
        echo "# HELP hydra_channel_last_eval_timestamp_seconds When Hydra last evaluated this jobset (unix seconds)"
        echo "# TYPE hydra_channel_last_eval_timestamp_seconds gauge"
        echo "# HELP hydra_pinned_revision_evaluated Whether flake.lock's revision appears in the recent evaluation list (1/0)"
        echo "# TYPE hydra_pinned_revision_evaluated gauge"
        echo "# HELP hydra_fetch_ok Whether the Hydra API query for this channel succeeded (1/0)"
        echo "# TYPE hydra_fetch_ok gauge"

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList
          (channel: c: ''
            if json=$(curl -fsS -m 20 -H "Accept: application/json" "https://hydra.nixos.org/jobset/${c.jobset}/evals" 2>/dev/null); then
              echo 'hydra_fetch_ok{channel="${channel}"} 1'
              ts=$(echo "$json" | jq -r '.evals[0].timestamp // empty')
              if [ -n "$ts" ]; then
                echo "hydra_channel_last_eval_timestamp_seconds{channel=\"${channel}\"} $ts"
              fi
              found=$(echo "$json" | jq -r '([.evals[].jobsetevalinputs.nixpkgs.revision] | index("${c.rev}")) != null')
              if [ "$found" = "true" ]; then
                echo 'hydra_pinned_revision_evaluated{channel="${channel}"} 1'
              else
                echo 'hydra_pinned_revision_evaluated{channel="${channel}"} 0'
              fi
            else
              echo 'hydra_fetch_ok{channel="${channel}"} 0'
            fi
          '')
          hydraChannels)}

        echo "hydra_build_metrics_last_run_seconds $(date +%s)"
      } > "$work/out"

      # Same as zfs-snapshot-metrics.nix: build on textfileDir before renaming,
      # so a partial write is never visible.
      staging=$(mktemp "${textfileDir}/.hydra-build-status.XXXXXX")
      cat "$work/out" > "$staging"
      chmod 0444 "$staging"
      mv -f "$staging" "$out"
    '';
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"

    # Output filename changed when the Repology approach was dropped
    # (2026-09-23). See docs/decisions/2026-09-23-repology-to-direct-nix-eval.md.
    "r ${textfileDir}/repology-package-status.prom - - - -"
  ];

  # Package list: no timer. The content is fixed at Nix eval time, so a plain
  # `nixos-rebuild switch` re-triggers this unit automatically whenever the
  # content actually changes.
  systemd.services.nixos-package-metrics = {
    description = "Export the installed package list as a node_exporter textfile";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nixos-package-metrics" ''
        set -euo pipefail
        staging=$(mktemp "${textfileDir}/.nixos-packages.XXXXXX")
        cat ${packagesProm} > "$staging"
        chmod 0444 "$staging"
        mv -f "$staging" "${textfileDir}/nixos-packages.prom"
      '';
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  # Hydra build status: needs network access (querying hydra.nixos.org), unlike
  # zfs-snapshot-metrics.nix's AF_UNIX-only restriction. Channels don't move
  # often, so every 6h is plenty.
  systemd.services.hydra-build-metrics = {
    description = "Export Hydra build status of the pinned nixpkgs revision as a node_exporter textfile";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe hydraCollector;
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };

  systemd.timers.hydra-build-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "6h";
      RandomizedDelaySec = "5min";
      Persistent = true;
    };
  };

  # Package update check via direct nixpkgs evaluation: only two `nix` calls
  # per channel (metadata resolution + bulk eval). Without the old Repology
  # approach's "package count x ~1s" bottleneck, 10 minutes of TimeoutStartSec
  # comfortably covers the worst case (cold eval cache, fetching the nixpkgs
  # tarball). Running more often than daily wouldn't help — upstream releases
  # don't move that fast.
  systemd.services.nixos-package-upstream-metrics = {
    description = "Export whether installed packages are outdated (compared directly against the tracked nixpkgs) as a node_exporter textfile";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe upstreamCollector;
      TimeoutStartSec = "10min";
      StateDirectory = "nixos-package-upstream";
      Environment = [
        "HOME=/var/lib/nixos-package-upstream"
        "NIX_REMOTE=daemon"
      ];
      ProtectSystem = "strict";
      ReadWritePaths = [ textfileDir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      # AF_UNIX is the nix daemon socket, AF_INET/6 is for fetching the channel.
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    };
  };

  systemd.timers.nixos-package-upstream-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "24h";
      RandomizedDelaySec = "10min";
      Persistent = true;
    };
  };

  # Manual verification: docs/runbooks/textfile-metrics.md
}
