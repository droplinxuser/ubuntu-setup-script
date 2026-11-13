# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Variables defined here are
# consumed by other modules, so SC2034 (unused) is not meaningful in a module.
# shellcheck disable=SC2034
# =============================================================================
# PHP version upgrade (--upgrade-php=X.Y)
# =============================================================================
# Replaces every installed PHP package with one target version while keeping
# the operator's extension set and custom configuration, then applies the same
# hardware-aware PHP profile a fresh `--basic ... --php ver=X.Y` install and a
# later `--optimize` would write.
#
# Order matters:
#   1. snapshot packages/extensions/configuration and record the old package
#      versions for a best-effort rollback;
#   2. add the Sury repository and verify the target is published;
#   3. purge every PHP package and the dependencies that were only there for
#      PHP (the pre/post `apt-get -s autoremove` delta, never pre-existing
#      orphans);
#   4. install the target through install_php(), appending the mapped
#      extension packages (PHP_EXTRA_PACKAGES);
#   5. carry over unowned .ini fragments and extra FPM pools;
#   6. run the shared PHP tuner (the same one install and --optimize use) and
#      reload Angie if it is active;
#   7. verify and write a Markdown report with the rollback paths.
#
# Only PHP (and the services that depend on its socket) is touched: the OS
# profile, MariaDB, Valkey and Elasticsearch are left to --optimize.

PHP_UPGRADE_MANIFEST_DIR=""
# Extensions a previous upgrade could not install on its target (one per line).
PHP_UPGRADE_PENDING_FILE="${STATE_DIR}/php-pending-extensions"
PHP_UPGRADE_OLD_VERSION=""
PHP_UPGRADE_OLD_PACKAGES=()
PHP_UPGRADE_OLD_PACKAGE_VERSIONS=()
PHP_UPGRADE_MODE=""
PHP_UPGRADE_TARGET_PKGS=()
PHP_UPGRADE_SKIPPED=()
PHP_UPGRADE_CUSTOM_INIS=()
PHP_UPGRADE_CUSTOM_POOLS=()
PHP_UPGRADE_PECL=()
PHP_UPGRADE_PRE_AUTOREMOVE=()
PHP_UPGRADE_ANGIE_ACTIVE=0
PHP_UPGRADE_OPTIMIZE_OK=0
PHP_UPGRADE_VERIFY_OK=0

# Installed PHP-FPM versions, newest last.  Uses the package database, not
# /etc/php, because a failed package purge can leave an empty tree behind.
php_upgrade_installed_versions() {
  dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null \
    | awk -F'\t' '$2 == "installed" {print $1}' \
    | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm$/\1/p' \
    | sort -Vu
}

# Every installed package this script treats as PHP: the language packages
# (php, php-common, phpX.Y-*), extension packages and the Apache module that
# pins a version.  libapache2-mod-php* does not match ^php, so it needs its own
# arm or a purge leaves a reverse dependency pointing at a nonexistent PHP.
php_upgrade_installed_packages() {
  dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null \
    | awk -F'\t' '$2 == "installed" {print $1}' \
    | grep -E '^(php([0-9]+\.[0-9]+)?(-|$)|libapache2-mod-php)' \
    | sort -u
}

# Extension token from a package name: php8.5-redis -> redis, php-common ->
# common, libapache2-mod-php8.5 -> "" (not an extension).
php_upgrade_ext_name() {
  local pkg=$1
  [[ $pkg == php-* ]] && { printf '%s' "${pkg#php-}"; return 0; }
  if [[ $pkg =~ ^php[0-9]+\.[0-9]+-(.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
  return 0
}

# Packages apt would remove as no longer needed.  Used as a before/after delta
# so a pre-existing orphan is never removed by the upgrade.
php_upgrade_autoremove_set() {
  apt-get -s autoremove --purge 2>/dev/null \
    | awk '/^(Remv|Purg) /{print $2}' \
    | sort -u || true
}

# Snapshot the host before anything is purged.  Everything the report and the
# rollback need is written below PHP_UPGRADE_MANIFEST_DIR: the package list,
# exact versions, the extension classification, custom configuration and the
# old /etc/php tree.
php_upgrade_snapshot() {
  local old=$1 dir=$PHP_UPGRADE_MANIFEST_DIR manual=" " pkg ext flag
  mkdir -p "$dir"
  PHP_UPGRADE_OLD_VERSION=$old
  local -a pkgs=()
  mapfile -t pkgs < <(php_upgrade_installed_packages)
  PHP_UPGRADE_OLD_PACKAGES=("${pkgs[@]}")

  while IFS= read -r pkg; do
    [[ -n $pkg ]] && PHP_UPGRADE_OLD_PACKAGE_VERSIONS+=("$pkg")
  done < <(
    if (( ${#pkgs[@]} > 0 )); then
      dpkg-query -W -f='${binary:Package}=${Version}\n' "${pkgs[@]}" 2>/dev/null | sort
    fi
  )

  mapfile -t manual < <(apt-mark showmanual 2>/dev/null || true)
  local manual_set=" ${manual[*]} "
  printf '%s\n' "${manual[@]}" > "$dir/manual-packages.txt"

  {
    printf 'generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'mode: %s\n' "$PHP_UPGRADE_MODE"
    printf 'old_version: %s\n' "$old"
    printf 'target_version: %s\n' "${UPGRADE_PHP:-}"
    printf 'angie_active: %s\n' "$PHP_UPGRADE_ANGIE_ACTIVE"
    printf 'package_count: %s\n' "${#pkgs[@]}"
  } > "$dir/manifest.txt"
  printf '%s\n' "${pkgs[@]}" > "$dir/packages.txt"
  printf '%s\n' "${PHP_UPGRADE_OLD_PACKAGE_VERSIONS[@]}" > "$dir/package-versions.txt"

  # Extension inventory: name, manual=1/0, source package.  The manual flag is
  # informational (the report highlights extensions the operator asked for
  # explicitly); every installed extension is carried over, because removing
  # one could break a live site even when apt originally pulled it in.
  : > "$dir/extensions.txt"
  for pkg in "${pkgs[@]}"; do
    ext=$(php_upgrade_ext_name "$pkg")
    [[ -n $ext ]] || continue
    flag=0
    [[ $manual_set == *" $pkg "* ]] && flag=1
    printf '%s\t%s\t%s\n' "$ext" "$flag" "$pkg" >> "$dir/extensions.txt"
  done

  # Extensions an earlier upgrade had to leave out because its target did not
  # publish them yet (8.6 RC had no imagick): they are still wanted.  Without
  # this an 8.5 -> 8.6 -> 8.5 round trip silently lost imagick for good.
  local pending
  while IFS= read -r pending; do
    [[ $pending =~ ^[a-z0-9]+$ ]] || continue
    grep -qE "^${pending}"$'\t' "$dir/extensions.txt" && continue
    # A list written by an earlier release can name an unversioned-only
    # package (pear).  It is wanted under its own name, php-pear; mapped to
    # phpX.Y-pear it could never be satisfied and every upgrade ended with
    # exit 1.
    if php_upgrade_unversioned_only "$pending"; then
      printf '%s\t1\tphp-%s\n' "$pending" "$pending" >> "$dir/extensions.txt"
      continue
    fi
    printf '%s\t1\tphp%s-%s\n' "$pending" "${old:-0.0}" "$pending" >> "$dir/extensions.txt"
  done < <(cat -- "$PHP_UPGRADE_PENDING_FILE" 2>/dev/null || true)

  # Extension inventory is complete; the raw manual list is already saved
  # next to it for the audit trail.

  # Custom configuration is identified while the packages are still installed.
  # dpkg cannot help here: Sury creates mods-available/*.ini and php.ini from
  # postinst, so dpkg-query -S reports "no path found" even for package files.
  # Package-owned conf.d entries are symlinks, so a *regular* .ini dropped into
  # a conf.d directory is operator configuration.  The managed files are
  # regenerated and are skipped.
  : > "$dir/custom-inis.txt"
  local root="/etc/php/$old" rel base d f d2 links
  if [[ -d $root ]]; then
    for d in fpm/conf.d cli/conf.d apache2/conf.d; do
      [[ -d "$root/$d" ]] || continue
      for f in "$root/$d"/*.ini; do
        [[ -f $f && ! -L $f ]] || continue
        base=${f##*/}
        case $base in
          custom_dan.ini|zz-setup-optimize.ini|zzz-audit.ini) continue ;;
        esac
        links=""
        for d2 in fpm/conf.d cli/conf.d apache2/conf.d; do
          [[ $d2 == "$d" ]] && continue
          [[ -L "$root/$d2/$base" ]] && links+="${links:+,}$d2"
        done
        printf '%s/%s\t%s\n' "$d" "$base" "$links" >> "$dir/custom-inis.txt"
      done
    done
  fi

  : > "$dir/custom-pools.txt"
  if [[ -d "$root/fpm/pool.d" ]]; then
    find "$root/fpm/pool.d" -maxdepth 1 -type f -name '*.conf' ! -name 'www.conf' \
      -printf '%f\n' 2>/dev/null | sort > "$dir/custom-pools.txt"
  fi

  if command -v php >/dev/null 2>&1; then
    php -v 2>/dev/null | head -n 1 > "$dir/php-version.txt" || true
    php -m 2>/dev/null > "$dir/php-modules.txt" || true
    php --ini 2>/dev/null > "$dir/php-ini.txt" || true
  fi
  if command -v pecl >/dev/null 2>&1; then
    pecl list 2>/dev/null | awk 'NR > 3 && NF >= 2 {print $1 "-" $2}' > "$dir/pecl.txt" || true
    mapfile -t PHP_UPGRADE_PECL < "$dir/pecl.txt"
  fi

  # A recoverable copy of the live tree, next to the report.  purge uses its
  # own /tmp backup too; this one is deliberately in the state directory so an
  # operator can find it months later.
  if [[ -d /etc/php ]]; then
    cp -a /etc/php "$dir/php-config" 2>/dev/null \
      || warn "Could not copy /etc/php to ${dir}/php-config"
  fi
}

# Core extensions the default install_php() package set already installs.
readonly PHP_UPGRADE_CORE_EXT=" fpm cli common mysql gd curl xml zip gmp mbstring redis readline opcache "

# Classify one installed PHP package for TARGET.  One implementation serves
# the real plan and --dry-run, so a release that bundles an extension, or a
# repository that lags one, cannot be reported differently by the two paths
# (the dry run used to duplicate this table and mishandled OPcache on 9.x).
# Prints:
#   ignore            not an extension package
#   core:<ext>        covered by the default --php package set
#   bundled:<ext>     built into this PHP release (no package exists)
#   keep:<pkg>        install this target-version package
#   skip:<reason>     no target package; the caller reports it, never fails
php_upgrade_classify_package() {
  local target=$1 pkg=$2 ext pkg_target major minor
  ext=$(php_upgrade_ext_name "$pkg")
  [[ -n $ext ]] || { printf 'ignore'; return 0; }
  case $PHP_UPGRADE_CORE_EXT in
    *" $ext "*)
      if [[ $ext == redis ]] && ! apt-cache show "php${target}-redis" >/dev/null 2>&1; then
        printf 'skip:php%s-redis is not published yet' "$target"
      elif [[ $ext == opcache ]]; then
        # OPcache is mandatory and built in from PHP 8.5 on.
        major=${target%%.*}; minor=${target#*.}
        if (( major > 8 || (major == 8 && minor >= 5) )); then
          printf 'bundled:%s' "$ext"
        else
          printf 'core:%s' "$ext"
        fi
      else
        printf 'core:%s' "$ext"
      fi
      return 0
      ;;
  esac
  # An unversioned package with no per-version build keeps its own name:
  # php-pear used to be mapped to a php8.6-pear that never existed, was
  # reported as skipped, purged with the old PHP and never reinstalled.
  if [[ $pkg == php-* ]] && php_upgrade_unversioned_only "$ext"; then
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      printf 'keep:%s' "$pkg"
    else
      printf 'skip:%s is not installable from the configured repositories' "$pkg"
    fi
    return 0
  fi
  if [[ $ext == *[!a-z0-9]* ]]; then
    printf 'skip:unexpected package name'
    return 0
  fi
  pkg_target="php${target}-${ext}"
  if apt-cache show "$pkg_target" >/dev/null 2>&1; then
    printf 'keep:%s' "$pkg_target"
  else
    printf 'skip:%s is not published' "$pkg_target"
  fi
  return 0
}

# True when no phpX.Y-EXT package exists for any PHP version, i.e. EXT only
# ever ships as the unversioned php-EXT (php-pear, the php-composer-* and
# php-symfony-* libraries).  An extension that does have versioned builds
# (php-imagick next to php8.5-imagick) is not one of these: its unversioned
# package is a dependency stub that would pull another PHP version in.
# awk reads the whole list on purpose (no early exit, no SIGPIPE to
# apt-cache under pipefail).
php_upgrade_unversioned_only() {
  local ext=$1 hit
  hit=$(apt-cache pkgnames 2>/dev/null \
    | awk -v e="$ext" '{ n = $0; if (sub(/^php[0-9]+\.[0-9]+-/, "", n) && n == e) found = 1 } END { print found + 0 }' || true)
  if [[ $hit == 1 ]]; then
    return 1
  fi
  return 0
}

# Remember the extensions this upgrade could not carry over, so the next
# --upgrade-php installs them again once its target publishes them.  The list
# is rewritten on every real run and removed when nothing is missing.
php_upgrade_record_pending() {
  local entry ext
  local -a names=()
  for entry in "${PHP_UPGRADE_SKIPPED[@]}"; do
    ext=${entry%% *}
    [[ $ext =~ ^[a-z0-9]+$ ]] || continue
    # The pending list holds extensions waiting for a phpX.Y-EXT build.  An
    # unversioned-only package has none on any version; recorded here it
    # would be re-read as phpX.Y-EXT and fail every later upgrade.
    php_upgrade_unversioned_only "$ext" && continue
    names+=("$ext")
  done
  if (( ${#names[@]} > 0 )); then
    mkdir -p "$(dirname "$PHP_UPGRADE_PENDING_FILE")"
    printf '%s\n' "${names[@]}" | sort -u > "$PHP_UPGRADE_PENDING_FILE"
  else
    rm -f "$PHP_UPGRADE_PENDING_FILE"
  fi
  return 0
}

# systemd drop-ins of PHP-FPM versions that are no longer installed.  Each
# upgrade used to leave /etc/systemd/system/phpX.Y-fpm.service.d behind.
php_upgrade_remove_stale_dropins() {
  local dir ver removed=0
  for dir in /etc/systemd/system/php*-fpm.service.d; do
    [[ -d $dir ]] || continue
    ver=${dir##*/php}; ver=${ver%-fpm.service.d}
    [[ $ver =~ ^[0-9]+\.[0-9]+$ ]] || continue
    [[ -x "/usr/sbin/php-fpm${ver}" ]] && continue
    rm -f "$dir/limits.conf"
    rmdir "$dir" 2>/dev/null || true
    removed=1
  done
  (( removed )) && { systemctl daemon-reload 2>/dev/null || true; }
  return 0
}

# Build the extension mapping for the target version.  A package is only kept
# when the target repository publishes the same extension; anything missing is
# reported instead of failing the whole upgrade.
php_upgrade_plan_extensions() {
  local target=$1 dir=$PHP_UPGRADE_MANIFEST_DIR ext flag pkg class pkg_target
  PHP_UPGRADE_TARGET_PKGS=()
  PHP_UPGRADE_SKIPPED=()
  [[ -f "$dir/extensions.txt" ]] || return 0

  while IFS=$'\t' read -r ext flag pkg; do
    [[ -n $ext ]] || continue
    class=$(php_upgrade_classify_package "$target" "$pkg")
    case $class in
      keep:*)
        pkg_target=${class#keep:}
        [[ " ${PHP_UPGRADE_TARGET_PKGS[*]} " == *" ${pkg_target} "* ]] \
          || PHP_UPGRADE_TARGET_PKGS+=("$pkg_target")
        ;;
      skip:*)
        PHP_UPGRADE_SKIPPED+=("${ext} (${pkg}: ${class#skip:})")
        ;;
    esac
  done < "$dir/extensions.txt"
}

# Verify the requested version is a real package in the Sury repository.  A
# release candidate is allowed when the operator names it explicitly, with a
# warning: PHP 8.6 was still 8.6.0~rc5 at the time of this audit.
php_upgrade_validate_target() {
  local target=$1 candidate upstream
  # Do not make awk exit at the first match: with `set -o pipefail`, apt-cache
  # is then killed by SIGPIPE (141) and the whole dry run reports failure.
  candidate=$(apt-cache policy "php${target}-fpm" 2>/dev/null \
    | awk '/^[[:space:]]*Candidate:/{ if (!found) { print $2; found=1 } }')
  if [[ -z $candidate || $candidate == "(none)" ]]; then
    local -a known=()
    mapfile -t known < <(apt-cache pkgnames 2>/dev/null \
      | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm$/\1/p' | sort -Vu)
    die "PHP ${target} is not published by the Sury repository (available: ${known[*]:-none}). Use a version from that list, e.g. --upgrade-php=${known[-1]:-8.5}"
  fi
  upstream=${candidate#*:}
  if [[ $upstream =~ ^[0-9]+\.[0-9]+\.[0-9]+~ ]]; then
    warn "PHP ${target} candidate ${candidate} is a pre-release; packages built against the final release may need a rebuild"
  fi
  printf '%s' "$candidate"
}

# Record and purge every PHP package plus the dependencies that only PHP kept
# alive.  purge_php_installations() owns the package list, unit shutdown and
# the /tmp backup; the dependency delta is computed around it.
php_upgrade_purge() {
  local -a extra=() post=() newly=() purge=()
  # Before the first removal: apt must be able to run the purge, and it must
  # not take applications along (phpMyAdmin, Composer, ...).  Dies with PHP
  # still installed and serving.
  php_purge_preflight
  mapfile -t PHP_UPGRADE_PRE_AUTOREMOVE < <(php_upgrade_autoremove_set)

  # Packages outside the ^php pattern first: libapache2-mod-phpX.Y depends on
  # the PHP it pins and would otherwise be left broken.
  mapfile -t extra < <(php_upgrade_installed_packages | grep -E '^libapache2-mod-php' || true)
  if (( ${#extra[@]} > 0 )); then
    info "Purging Apache PHP module(s): ${extra[*]}"
    apt-get purge "${APT_OPTS[@]}" "${extra[@]}" >/dev/null 2>&1 || true
  fi

  purge_php_installations

  mapfile -t post < <(php_upgrade_autoremove_set)
  if (( ${#PHP_UPGRADE_PRE_AUTOREMOVE[@]} > 0 )); then
    mapfile -t newly < <(
      comm -13 \
        <(printf '%s\n' "${PHP_UPGRADE_PRE_AUTOREMOVE[@]}" | sort -u) \
        <(printf '%s\n' "${post[@]}" | sort -u)
    )
  else
    newly=("${post[@]}")
  fi

  local p
  for p in "${newly[@]}"; do
    [[ -n $p ]] || continue
    # Never remove the base system even if a simulation says it became
    # unneeded (it cannot while apt runs, but the guard keeps a parsing bug
    # from turning into a dead host).
    local denylist=" systemd libc6 apt dpkg ubuntu-minimal ubuntu-standard ca-certificates curl gnupg "
    case $denylist in
      *" $p "*) continue ;;
    esac
    purge+=("$p")
  done
  if (( ${#purge[@]} > 0 )); then
    info "Purging PHP-only dependencies: ${purge[*]}"
    apt-get purge "${APT_OPTS[@]}" "${purge[@]}" \
      || warn "Some PHP dependencies could not be purged automatically"
  fi
  apt-get clean >/dev/null 2>&1 || true
}

# Install the target version through the same installer a fresh --php run
# uses.  PHP_EXTRA_PACKAGES carries the mapped extension set.
php_upgrade_install() {
  local target=$1
  # shellcheck disable=SC2154  # associative key, not an unset variable
  OPT[php.ver]=$target
  ENABLED[php]=1
  PHP_EXTRA_PACKAGES=("${PHP_UPGRADE_TARGET_PKGS[@]}")
  PHP_FRESH_INSTALL=1
  run_service php install_php
  PHP_FRESH_INSTALL=0
  [[ ${SVC_STATUS[php]:-} == OK ]]
}

# Copy operator-owned .ini fragments and extra FPM pools into the new tree.
# Both are validated before they are kept: an incompatible fragment is moved
# back to the manifest directory with a warning instead of breaking php-fpm.
php_upgrade_migrate_custom() {
  local old=$1 new=$2 dir=$PHP_UPGRADE_MANIFEST_DIR
  local backup="$dir/php-config/$old" rel links base d dest migrated=0
  [[ -d $backup ]] || return 0

  if [[ -s "$dir/custom-inis.txt" ]]; then
    while IFS=$'\t' read -r rel links; do
      [[ -n $rel ]] || continue
      base=${rel##*/}
      dest="/etc/php/$new/$rel"
      if [[ -e $dest ]]; then
        warn "PHP ${new}: kept the package's ${rel}; the old fragment is in ${backup}/${rel}"
        continue
      fi
      mkdir -p "$(dirname "$dest")"
      if sed -E "s/php${old//./\\.}/php${new}/g" "$backup/$rel" > "$dest" 2>/dev/null; then
        migrated=$(( migrated + 1 ))
        local -a linkdirs=()
        IFS=, read -r -a linkdirs <<< "$links"
        for d in "${linkdirs[@]}"; do
          [[ -n $d && -d "/etc/php/$new/$d" ]] || continue
          ln -sfn "$dest" "/etc/php/$new/$d/$base"
        done
      else
        rm -f "$dest"
        warn "PHP ${new}: could not migrate ${rel}"
      fi
    done < "$dir/custom-inis.txt"
  fi

  if [[ -s "$dir/custom-pools.txt" ]]; then
    while IFS= read -r rel; do
      [[ -n $rel ]] || continue
      dest="/etc/php/$new/fpm/pool.d/$rel"
      [[ -e $dest ]] && continue
      # The listener keeps its path, as tune_php_fpm_version does for
      # www.conf: an operator vhost points at exactly this socket
      # (fastcgi_pass unix:/run/php/php8.3-fpm-shop.sock) and renaming it to
      # the new version would answer 502 while the upgrade reports success.
      sed -E "/^[[:space:]]*listen[[:space:]]*=/! s/php${old//./\\.}/php${new}/g" "$backup/fpm/pool.d/$rel" > "$dest" 2>/dev/null || {
        rm -f "$dest"
        warn "PHP ${new}: could not migrate pool ${rel}"
        continue
      }
      migrated=$(( migrated + 1 ))
    done < "$dir/custom-pools.txt"
  fi

  if (( migrated > 0 )); then
    local fpm_bin test_log
    fpm_bin=$(php_fpm_binary "$new" || true)
    test_log=$(tmp_file)
    if [[ -n $fpm_bin ]] && ! "$fpm_bin" -t >"$test_log" 2>&1; then
      # Move the migrated pools and ini links out of the live tree, keep the
      # package-managed configuration, and say exactly what was rejected.
      while IFS= read -r rel; do
        [[ -n $rel ]] && rm -f "/etc/php/$new/fpm/pool.d/$rel"
      done < "$dir/custom-pools.txt"
      while IFS=$'\t' read -r rel links; do
        [[ -n $rel ]] || continue
        rm -f "/etc/php/$new/$rel"
        local -a linkdirs=()
        IFS=, read -r -a linkdirs <<< "$links"
        for d in "${linkdirs[@]}"; do
          [[ -n $d ]] && rm -f "/etc/php/$new/$d/${rel##*/}"
        done
      done < "$dir/custom-inis.txt"
      warn "PHP ${new}: migrated custom configuration failed php-fpm -t; removed from the live tree (see ${backup})"
      sed 's/^/  /' "$test_log" >&2 || true
      migrated=0
    else
      ok "PHP ${new}: migrated ${migrated} custom configuration file(s)"
      mv "$dir/custom-inis.txt" "$dir/custom-inis.applied.txt" 2>/dev/null || true
      mv "$dir/custom-pools.txt" "$dir/custom-pools.applied.txt" 2>/dev/null || true
      # install_php started FPM before these files existed.  A reload re-reads
      # every pool so an extra pool binds its socket and the migrated conf.d
      # fragments reach the workers; without this the files exist but the
      # running processes never see them (an extra pool stayed socket-less
      # until the next --optimize reload).
      if systemctl is-active --quiet "php${new}-fpm"; then
        systemctl daemon-reload 2>/dev/null || true
        if systemctl reload "php${new}-fpm" 2>/dev/null \
           && systemctl is-active --quiet "php${new}-fpm"; then
          ok "PHP ${new}: reloaded to apply the migrated configuration"
        elif systemctl restart "php${new}-fpm" 2>/dev/null \
             && systemctl is-active --quiet "php${new}-fpm"; then
          warn "PHP ${new}: reload failed; restarted to apply the migrated configuration"
        else
          warn "PHP ${new}: could not reload after migrating configuration"
        fi
      fi
    fi
  fi
}

# Run the shared PHP tuner on the new tree.  install_php() already applied the
# hardware profile; this second pass is the --optimize path: systemd limits,
# ini template sync, pool normalization, listener migration and verification.
php_upgrade_optimize() {
  local rc=0 change
  detect_installed_services
  plan_memory_budget
  OPT_PHP_OK=0
  OPT_PHP_SOCKET=""
  tune_reset_changes
  if optimize_php_services; then
    for change in "${TUNE_CHANGES[@]}"; do info "${change}"; done
    for change in "${TUNE_MISSES[@]}"; do warn "Not applied: ${change}"; done
  else
    warn "PHP optimization reported a failure"
    rc=1
  fi
  verify_optimized_services || rc=1
  PHP_UPGRADE_OPTIMIZE_OK=$(( rc == 0 ? 1 : 0 ))
  return "$rc"
}

# Reload Angie so its upstream pool reconnects to the new FPM master.  A Unix
# socket survives the PHP restart, but a keepalive upstream can hold a dead
# worker until it notices; a graceful reload is cheap and makes the cutover
# deterministic.
php_upgrade_reload_angie() {
  PHP_UPGRADE_ANGIE_ACTIVE=0
  systemctl is-active --quiet angie 2>/dev/null || return 0
  PHP_UPGRADE_ANGIE_ACTIVE=1
  if ! /usr/sbin/angie -t >/dev/null 2>&1; then
    warn "Angie configuration test failed; not reloading"
    return 1
  fi
  if systemctl reload angie 2>/dev/null && systemctl is-active --quiet angie; then
    ok "Angie reloaded against PHP-FPM"
    return 0
  fi
  if systemctl restart angie 2>/dev/null && systemctl is-active --quiet angie; then
    warn "Angie reload failed; restarted instead"
    return 0
  fi
  warn "Angie did not come back after the PHP upgrade"
  return 1
}

# Post-conditions: the right version is the CLI default, FPM is active, its
# socket exists, every migrated package is installed and the managed profile
# carries the JIT.  Reports failures instead of aborting so the summary and
# the report are still written.
php_upgrade_verify() {
  local new=$1 rc=0 ver socket pkg missing=()
  ver=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)
  if [[ $ver != "$new" ]]; then
    warn "CLI PHP is ${ver:-unknown}, expected ${new}"
    rc=1
  fi
  if ! systemctl is-active --quiet "php${new}-fpm"; then
    warn "php${new}-fpm is not active"
    rc=1
  fi
  socket=$(php_pool_listen "$new")
  if [[ $socket == /* && ! -S $socket ]]; then
    warn "PHP-FPM socket ${socket} was not created"
    rc=1
  fi
  # Extra pools migrated from the old host must have bound their listeners
  # too, not only the primary www pool.
  local pool listen
  if [[ -d "/etc/php/${new}/fpm/pool.d" ]]; then
    for pool in "/etc/php/${new}/fpm/pool.d"/*.conf; do
      [[ -f $pool ]] || continue
      listen=$(ini_get "$pool" listen)
      if [[ $listen == /* && ! -S $listen ]]; then
        warn "Pool $(basename "$pool"): socket ${listen} was not created"
        rc=1
      fi
    done
  fi
  for pkg in "${PHP_UPGRADE_TARGET_PKGS[@]}"; do
    dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed || missing+=("$pkg")
  done
  if (( ${#missing[@]} > 0 )); then
    warn "Missing extension package(s): ${missing[*]}"
    rc=1
  fi
  if [[ -f "/etc/php/${new}/fpm/conf.d/zz-setup-optimize.ini" ]]; then
    grep -q '^opcache.jit = tracing' "/etc/php/${new}/fpm/conf.d/zz-setup-optimize.ini" \
      || { warn "Managed profile does not enable the tracing JIT"; rc=1; }
  fi
  PHP_UPGRADE_VERIFY_OK=$(( rc == 0 ? 1 : 0 ))
  return "$rc"
}

# Best effort only: reinstall the exact old packages and restore the old
# /etc/php tree.  Runs when the new version cannot be installed or started.
php_upgrade_rollback() {
  local old=$PHP_UPGRADE_OLD_VERSION dir=$PHP_UPGRADE_MANIFEST_DIR
  [[ -n $old ]] || { warn "No previous PHP version to roll back to"; return 1; }
  warn "Rolling back to PHP ${old} (best effort)"
  # Remove a partially installed target first, so the host does not end up
  # with two PHP versions and a stray tree that can claim the shared socket.
  local target=${UPGRADE_PHP:-}
  if [[ -n $target && $target != "$old" ]]; then
    systemctl disable --now "php${target}-fpm" 2>/dev/null || true
    local -a target_pkgs=()
    mapfile -t target_pkgs < <(
      dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null \
        | awk -F'\t' '$2 == "installed" {print $1}' \
        | grep -E "^php${target//./\\.}(-|$)" || true
    )
    if (( ${#target_pkgs[@]} > 0 )); then
      apt-get purge "${APT_OPTS[@]}" "${target_pkgs[@]}" >/dev/null 2>&1 \
        || warn "Could not purge the partial PHP ${target} packages"
    fi
    rm -rf "/etc/php/${target}"
  fi
  if (( ${#PHP_UPGRADE_OLD_PACKAGE_VERSIONS[@]} > 0 )); then
    # One pkg=version the archive no longer serves fails the whole
    # transaction, and Sury drops a point release as soon as the next one is
    # published.  The same packages at their current point release still
    # bring the old branch back, so try that before giving up.
    if ! apt-get install "${APT_OPTS[@]}" --allow-downgrades \
         "${PHP_UPGRADE_OLD_PACKAGE_VERSIONS[@]}" >/dev/null 2>&1; then
      local -a old_names=("${PHP_UPGRADE_OLD_PACKAGE_VERSIONS[@]%%=*}")
      info "The exact old package versions are no longer in the repository; installing the current PHP ${old} packages instead"
      apt-get install "${APT_OPTS[@]}" "${old_names[@]}" >/dev/null 2>&1 \
        || warn "Could not reinstall every old package; check apt history"
    fi
  fi
  if [[ -d "$dir/php-config/$old" ]]; then
    rm -rf "/etc/php/${old}"
    mkdir -p /etc/php
    cp -a "$dir/php-config/$old" "/etc/php/${old}" 2>/dev/null \
      || warn "Could not restore /etc/php/${old}"
  fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now "php${old}-fpm" 2>/dev/null || true
  if systemctl is-active --quiet "php${old}-fpm"; then
    ok "PHP ${old} is active again"
  else
    warn "PHP ${old} did not start; inspect journalctl -u php${old}-fpm"
  fi
  /usr/sbin/angie -t >/dev/null 2>&1 && systemctl reload angie 2>/dev/null || true
}

# Markdown report kept next to the state, plus a copy under /var/log so the
# usual log-collection command picks it up.
php_upgrade_write_report() {
  local new=$1 rc=$2 report ts ext flag pkg pool_summary="" jit_summary="" cli_version=""
  ts=$(date -u +%Y%m%d-%H%M%S)
  report="/var/log/setup-php-upgrade-${ts}.md"
  pool_summary=$(
    if [[ -r "/etc/php/${new}/fpm/pool.d/www.conf" ]]; then
      awk -F= '
        /^[[:space:]]*pm[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); pm = $2 }
        /^[[:space:]]*pm\.max_children/ { gsub(/[[:space:]]/, "", $2); mc = $2 }
        /^[[:space:]]*listen\.backlog/ { gsub(/[[:space:]]/, "", $2); bl = $2 }
        END { if (pm != "") printf "pm=%s max_children=%s backlog=%s", pm, mc, bl }
      ' "/etc/php/${new}/fpm/pool.d/www.conf" 2>/dev/null
    fi
  )
  [[ -r "/etc/php/${new}/fpm/conf.d/zz-setup-optimize.ini" ]] && jit_summary=$(
    grep -h '^opcache.jit' "/etc/php/${new}/fpm/conf.d/zz-setup-optimize.ini" 2>/dev/null | paste -sd' ' -
  )
  cli_version=$(php -v 2>/dev/null | head -n1 || true)
  {
    printf '# PHP upgrade report\n\n'
    printf -- '- Generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Mode: %s\n' "$PHP_UPGRADE_MODE"
    printf -- '- From: %s\n' "${PHP_UPGRADE_OLD_VERSION:-none (fresh install)}"
    printf -- '- To: %s\n' "$new"
    printf -- '- Result: %s\n' "$([[ $rc -eq 0 ]] && printf PASS || printf ATTENTION)"
    printf -- '- Backup: `%s/php-config`\n' "$PHP_UPGRADE_MANIFEST_DIR"
    printf -- '- Angie active/reloaded: %s\n\n' "$PHP_UPGRADE_ANGIE_ACTIVE"
    printf '## Extensions carried over\n\n'
    printf '| Extension | Manual | Old package | New package |\n|---|---|---|---|\n'
    if [[ -f "$PHP_UPGRADE_MANIFEST_DIR/extensions.txt" ]]; then
      while IFS=$'\t' read -r ext flag pkg; do
        local target="php${new}-${ext}"
        local state=yes
        if ! dpkg-query -W -f='${db:Status-Status}' "$target" 2>/dev/null | grep -qx installed; then
          # An unversioned package (php-pear) is carried over under its own
          # name; there is no phpX.Y-pear to look for.
          if [[ $pkg == php-* ]] \
             && dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed; then
            state="yes (${pkg})"
          else
            state="no (not published)"
          fi
        fi
        if [[ $ext == opcache ]]; then
          local mj=${new%%.*} mn=${new#*.}
          if (( mj > 8 || (mj == 8 && mn >= 5) )); then state="bundled in PHP ${new}"; fi
        fi
        printf '| %s | %s | %s | %s |\n' "$ext" "$([[ $flag == 1 ]] && printf yes || printf auto)" "$pkg" "$state"
      done < "$PHP_UPGRADE_MANIFEST_DIR/extensions.txt"
    fi
    printf '\n## Custom configuration\n\n'
    if [[ -f "$PHP_UPGRADE_MANIFEST_DIR/custom-inis.applied.txt" ]]; then
      printf -- '- .ini fragments migrated: `%s`\n' "$(cut -f1 "$PHP_UPGRADE_MANIFEST_DIR/custom-inis.applied.txt" | paste -sd', ' -)"
    else
      printf -- '- No unowned .ini fragments were migrated.\n'
    fi
    if [[ -f "$PHP_UPGRADE_MANIFEST_DIR/custom-pools.applied.txt" ]]; then
      printf -- '- FPM pools migrated: `%s`\n' "$(paste -sd', ' - < "$PHP_UPGRADE_MANIFEST_DIR/custom-pools.applied.txt")"
    else
      printf -- '- No extra FPM pools were migrated.\n'
    fi
    if (( ${#PHP_UPGRADE_SKIPPED[@]} > 0 )); then
      printf '\n## Extensions not available for %s\n\n' "$new"
      printf -- '- %s\n' "${PHP_UPGRADE_SKIPPED[@]}"
    fi
    if (( ${#PHP_UPGRADE_PECL[@]} > 0 )); then
      printf '\n## PECL extensions (manual rebuild needed)\n\n'
      printf -- '- %s\n' "${PHP_UPGRADE_PECL[@]}"
      printf '\nThe APT upgrade cannot rebuild PECL modules.  After install: `php-dev`/`pecl` are needed, then `pecl install <name>` for each module and re-run `--optimize`.\n'
    fi
    printf '\n## Verification\n\n'
    printf -- '- CLI: `%s`\n' "${cli_version:-unknown}"
    printf -- '- php-fpm active: %s\n' "$(systemctl is-active "php${new}-fpm" 2>/dev/null || echo unknown)"
    printf -- '- Socket: `%s`\n' "$(php_pool_listen "$new")"
    printf -- '- Pool: `%s`\n' "${pool_summary:-unavailable}"
    printf -- '- JIT: `%s`\n' "${jit_summary:-unavailable}"
    printf -- '- Optimize pass: %s\n' "$([[ $PHP_UPGRADE_OPTIMIZE_OK == 1 ]] && echo OK || echo reported-a-failure)"
    printf -- '- Verification: %s\n' "$([[ $PHP_UPGRADE_VERIFY_OK == 1 ]] && echo OK || echo reported-a-failure)"
    printf '\n## Rollback\n\n'
    if [[ -n $PHP_UPGRADE_OLD_VERSION && -d "$PHP_UPGRADE_MANIFEST_DIR/php-config/$PHP_UPGRADE_OLD_VERSION" ]]; then
      printf 'The old tree is at `%s/php-config/%s`.\n\n' "$PHP_UPGRADE_MANIFEST_DIR" "$PHP_UPGRADE_OLD_VERSION"
      printf '```sh\napt-get install -y %s\ncp -a %s/php-config/%s /etc/php/\nsystemctl restart php%s-fpm\n```\n' \
        "${PHP_UPGRADE_OLD_PACKAGE_VERSIONS[*]}" "$PHP_UPGRADE_MANIFEST_DIR" "$PHP_UPGRADE_OLD_VERSION" "$PHP_UPGRADE_OLD_VERSION"
    else
      printf 'No previous version was installed; the package and tree backups above are the recovery point.\n'
    fi
  } > "$report"
  chmod 640 "$report" 2>/dev/null || true
  [[ -n ${SUDO_GID:-} ]] && chown "root:${SUDO_GID}" "$report" 2>/dev/null || true
  printf '%s' "$report"
}

# --dry-run: show the exact plan without touching the host.  Works as a normal
# user and on a host with no PHP installed (the real run would install it).
php_upgrade_plan() {
  local target=$UPGRADE_PHP old="" candidate="" pkg ext flag
  local dir
  dir=$(mktemp -d /tmp/php-upgrade-plan.XXXXXX)
  local -a versions=()
  mapfile -t versions < <(php_upgrade_installed_versions)
  (( ${#versions[@]} > 0 )) && old=${versions[-1]}
  printf '\n%sDRY RUN%s - PHP upgrade plan, no changes will be made.\n' "$C_BOLD" "$C_RESET"
  printf 'Target PHP : %s\n' "$target"
  if [[ -n $old ]]; then
    printf 'Current    : %s\n' "$old"
    printf 'Packages   : %s installed PHP package(s)\n' "$(php_upgrade_installed_packages | wc -l | tr -d ' ')"
    printf '\nExtensions to carry over (mapped to php%s-*):\n' "$target"
    php_upgrade_installed_packages > "$dir/pkgs.txt"
    local class
    while IFS= read -r pkg; do
      class=$(php_upgrade_classify_package "$target" "$pkg")
      ext=$(php_upgrade_ext_name "$pkg")
      case $class in
        ignore) continue ;;
        core:*)    printf '  %-14s (core/default)\n' "$ext" ;;
        bundled:*) printf '  %-14s (bundled in PHP %s)\n' "$ext" "$target" ;;
        keep:*)    printf '  %-14s -> %s\n' "$ext" "${class#keep:}" ;;
        skip:*)    printf '  %-14s !! %s\n' "$ext" "${class#skip:}" ;;
      esac
    done < "$dir/pkgs.txt"
  else
    printf 'Current    : none (no PHP-FPM installed; the run installs %s fresh)\n' "$target"
  fi
  candidate=$( { apt-cache policy "php${target}-fpm" 2>/dev/null || true; } \
    | awk '/^[[:space:]]*Candidate:/{ if (!found) { print $2; found=1 } }')
  printf '\nRepository : %s\n' "${candidate:-not configured yet; the real run adds the Sury repository and re-checks}"
  printf '\nSteps:\n'
  printf '  1. snapshot packages, extension flags, custom .ini/pools and /etc/php\n'
  printf '  2. purge every PHP package and PHP-only dependencies (autoremove delta)\n'
  printf '  3. install php%s-fpm/cli plus the extension list above\n' "$target"
  printf '  4. migrate operator-owned .ini fragments and extra FPM pools\n'
  printf '  5. run the shared PHP tuner (pool, OPcache, tracing JIT) and reload Angie if active\n'
  printf '  6. verify version/socket/extensions and write /var/log/setup-php-upgrade-*.md\n'
  rm -rf "$dir"
}

# Mode driver.  A plain return keeps set -e and the ERR trap live inside the
# helpers; handled_return() marks an explained failure for the EXIT trap.
run_php_upgrade() {
  local target=$UPGRADE_PHP old="" start rc=0 report
  local -a _upgrade_versions=()
  start=$(date +%s)
  PHP_UPGRADE_MANIFEST_DIR="${STATE_DIR}/php-upgrade-$(date -u +%Y%m%d-%H%M%S)"
  mkdir -p "$PHP_UPGRADE_MANIFEST_DIR"
  PHP_UPGRADE_MODE=upgrade

  step "PHP upgrade to ${target}"
  mapfile -t _upgrade_versions < <(php_upgrade_installed_versions)
  if (( ${#_upgrade_versions[@]} == 0 )); then
    PHP_UPGRADE_MODE=install
    info "No PHP installation found; installing PHP ${target} as a fresh install"
  else
    old=$(php_primary_version 2>/dev/null || true)
    [[ -n $old ]] || old=${_upgrade_versions[-1]}
    info "Current PHP: ${old} (installed: ${_upgrade_versions[*]})"
    php_upgrade_snapshot "$old"
    ok "Snapshot: ${PHP_UPGRADE_MANIFEST_DIR}"
    # Keep the PHP timezone the old tree used.  --upgrade-php has no --basic
    # time= to pass, and falling back to the host zone can silently move a
    # site's dates when /etc/timezone and timedatectl disagree.
    PHP_INI_TZ=$(ini_get "/etc/php/${old}/fpm/conf.d/custom_dan.ini" date.timezone)
    [[ -n $PHP_INI_TZ ]] && info "Keeping PHP timezone: ${PHP_INI_TZ}"
  fi
  unset _upgrade_versions

  # The Sury repository owns phpX.Y packages on every supported Ubuntu; both
  # the purge and the install resolve from it.
  configure_php_repo || die "Could not configure the Sury APT repository"
  apt_update
  local candidate
  candidate=$(php_upgrade_validate_target "$target")
  info "Target package candidate: ${candidate}"
  php_upgrade_plan_extensions "$target"
  if (( ${#PHP_UPGRADE_SKIPPED[@]} > 0 )); then
    warn "Extension(s) without a ${target} package: ${PHP_UPGRADE_SKIPPED[*]}"
  fi

  if [[ -n $old ]]; then
    step "Purging PHP ${old} and its dependencies"
    php_upgrade_purge
    ok "Old PHP packages purged (tree backup: ${PHP_UPGRADE_MANIFEST_DIR}/php-config)"
  fi

  step "Installing PHP ${target}"
  if ! php_upgrade_install "$target"; then
    warn "PHP ${target} installation failed"
    [[ -n $old ]] && php_upgrade_rollback
    report=$(php_upgrade_write_report "$target" 1)
    warn "Report: ${report}"
    handled_return 1
    return 1
  fi
  ok "PHP ${target} installed"

  if [[ -n $old ]]; then
    step "Migrating operator configuration"
    php_upgrade_migrate_custom "$old" "$target"
  fi

  step "Applying the shared PHP profile"
  php_upgrade_optimize || rc=1
  php_upgrade_reload_angie || rc=1
  php_upgrade_verify "$target" || rc=1
  php_upgrade_remove_stale_dropins
  php_upgrade_record_pending
  if (( ${#PHP_UPGRADE_SKIPPED[@]} > 0 )); then
    # Everything the host had should exist on the target.  A repository that
    # has not published an extension for a brand-new release leaves the site
    # without it, so the run reports ATTENTION instead of a clean success.
    warn "Extension(s) unavailable for PHP ${target}: ${PHP_UPGRADE_SKIPPED[*]}"
    rc=1
  fi

  report=$(php_upgrade_write_report "$target" "$rc")
  printf '\n%sPHP upgrade summary%s\n' "$C_BOLD" "$C_BLUE"
  printf '%-24s %s\n' 'From' "${old:-none}"
  printf '%-24s %s\n' 'To' "$target"
  printf '%-24s %s\n' 'Extensions carried' "${#PHP_UPGRADE_TARGET_PKGS[@]}"
  printf '%-24s %s\n' 'Extensions skipped' "${#PHP_UPGRADE_SKIPPED[@]}"
  printf '%-24s %s\n' 'FPM' "$(systemctl is-active "php${target}-fpm" 2>/dev/null || printf unknown)"
  printf '%-24s %s\n' 'Angie' "$([[ $PHP_UPGRADE_ANGIE_ACTIVE == 1 ]] && printf reloaded || printf not-running)"
  printf '%-24s %s\n' 'Backup' "${PHP_UPGRADE_MANIFEST_DIR}"
  printf '%-24s %s\n' 'Report' "$report"
  printf '%-24s %s\n' 'Duration' "$(format_duration $(( $(date +%s) - start )))"
  if (( rc == 0 )); then
    ok "PHP ${target} is installed, tuned and serving"
  elif (( PHP_UPGRADE_VERIFY_OK == 1 && PHP_UPGRADE_OPTIMIZE_OK == 1 )); then
    warn "PHP ${target} is installed and tuned, but ${#PHP_UPGRADE_SKIPPED[@]} extension(s) are not published for it yet; re-run --upgrade-php=${target} once they appear"
  else
    warn "PHP ${target} is installed but one or more checks failed; see the report"
  fi
  handled_return "$rc"
  return "$rc"
}
