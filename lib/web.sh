# shellcheck shell=bash
# Sourced by setup.sh (not executed directly).  Variables defined here are
# consumed by other modules, so SC2034 (unused) is not meaningful in a module.
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------
# NGINX
# ---------------------------------------------------------------------------
# =============================================================================
# HARDWARE-AWARE LIVE TUNING
# -----------------------------------------------------------------------------
# These helpers are used both by the installers and by `--optimize`.  They
# only rewrite live configuration; they never install packages.
# =============================================================================
TUNE_CHANGES=()
TUNE_MISSES=()
TUNE_DIRTY=0
# Only repoint nginx's FastCGI upstream when the optimized PHP pool already
# owns a Unix socket.  --optimize preserves an existing TCP listener so a live
# site is never pointed at a socket that does not exist.
OPT_PHP_OK=0
OPT_PHP_SOCKET=""

# The compiled nginx (lib/nginx-build.sh sets NGINX_BIN; it is sourced after
# this file, so every use resolves it at call time).  Never /usr/sbin/nginx:
# that is the distro package path, which 1.22 never uses (R2.1), and the
# migration installs a temporary shim there while a function still names it.
NGINX_WEB_BIN_DEFAULT=/usr/local/lib/setup-nginx/sbin/nginx

# Binary for `nginx -t` / `nginx -V` of a rendered tree: the migration's
# candidate (NGINX_TEST_BIN, set while nothing serves from /etc/nginx yet)
# first, then the installed build.
nginx_test_bin() {
  printf '%s' "${NGINX_TEST_BIN:-${NGINX_BIN:-$NGINX_WEB_BIN_DEFAULT}}"
}

# True when BIN is runnable (tests may stub it with a function of that name).
nginx_bin_usable() {
  [[ -n ${1:-} ]] && { [[ -x $1 ]] || declare -F "$1" >/dev/null 2>&1; }
}

# `nginx -t` of the tree whose main file is CONF (default /etc/nginx), with
# the test binary.  Relative includes resolve against dirname(CONF).  Output
# goes to the caller's stdout/stderr.  Status 2 when there is no binary.
nginx_test_tree() {
  local conf=${1:-/etc/nginx/nginx.conf} bin
  bin=$(nginx_test_bin)
  nginx_bin_usable "$bin" || { printf 'no nginx binary at %s\n' "$bin" >&2; return 2; }
  "$bin" -t -c "$conf"
}
tune_reset_changes() { TUNE_CHANGES=(); TUNE_MISSES=(); TUNE_DIRTY=0; }
tune_note() { TUNE_CHANGES+=("$*"); TUNE_DIRTY=1; }
# Informational line that must not count as a configuration change (and must
# not trigger a service restart on an otherwise unchanged run).
tune_summary() { TUNE_CHANGES+=("$*"); }
# A directive that was expected in an existing file but could not be found.
# Recorded instead of silently doing nothing, so config drift is visible in
# the report without forcing a restart.
tune_miss() { TUNE_MISSES+=("$*"); }

tune_clamp() {
  local value=$1 min=$2 max=$3
  (( value < min )) && value=$min
  (( value > max )) && value=$max
  printf '%s' "$value"
}

# Tuner-facing name for mb_to_config(); one implementation keeps the installer
# and --optimize reporting identical.
tune_size_value() { mb_to_config "$1"; }

# Cache budget in MB: 25% of RAM, capped at 5% of free disk, then rounded
# down to 256 MB.  The rounding keeps small free-space changes between runs
# (backups, logs) from resizing every cache zone and forcing a restart.
# An optional fifth argument is a hard ceiling in MB, applied after the
# floor: nginx_cache_budget_mb passes half of the space actually free, so a
# nearly full disk never gets a max_size it cannot hold (the 10% share of an
# nginx-only host on the 10x-free basis, or the 256 MB floor, could reach all
# of it).  It only binds on a nearly full disk, so normal hosts keep a stable
# budget between runs.
tune_cache_total_mb() {
  local ram_mb=$1 disk_free_mb=$2 ram_pct=${3:-25} disk_pct=${4:-5} cap=${5:-} total
  total=$(( ram_mb * ram_pct / 100 ))
  (( total > 65536 )) && total=65536
  (( total > disk_free_mb * disk_pct / 100 )) && total=$(( disk_free_mb * disk_pct / 100 ))
  (( total < 256 )) && total=256
  total=$(( total / 256 * 256 ))
  (( total < 256 )) && total=256
  if [[ $cap =~ ^[0-9]+$ ]] && (( total > cap )); then
    total=$(( cap / 64 * 64 ))
    (( total < 64 )) && total=64
  fi
  printf '%s' "$total"
}

# Half of the space free on the cache filesystem, in MB (empty if unknown).
nginx_cache_disk_cap_mb() {
  local dir=/home avail
  [[ -d $dir ]] || dir=/var/www
  avail=$(df -Pm "$dir" 2>/dev/null | awk 'NR==2{print $4}' || true)
  [[ $avail =~ ^[0-9]+$ ]] && printf '%s' $(( avail / 2 ))
  return 0
}

# nginx cache budget for the current service set.  A dedicated nginx proxy
# gets 50% of RAM (10% of the cache disk); nginx+PHP gets 30%; a host with a
# data or search tier gets 25% (5% of the cache disk, see nginx_disk_free_mb).
# Callers pass the live RAM and disk basis so --dry-run and the real tuner
# report the same number.
nginx_cache_budget_mb() {
  local ram_mb=$1 disk_free_mb=$2 pct=25 disk_pct=5 svc
  local has_php=0 has_maria=0 has_cache=0 has_es=0
  if (( ${#OPT_DETECTED[@]} > 0 )); then
    for svc in "${OPT_DETECTED[@]}"; do
      case $svc in
        php:*) has_php=1 ;;
        mariadb) has_maria=1 ;;
        valkey|redis) has_cache=1 ;;
        elastic) has_es=1 ;;
      esac
    done
    if (( !has_php && !has_maria && !has_cache && !has_es )); then
      pct=50
      disk_pct=10
    elif (( has_php && !has_maria && !has_cache && !has_es )); then
      pct=30
    fi
  fi
  tune_cache_total_mb "$ram_mb" "$disk_free_mb" "$pct" "$disk_pct" "$(nginx_cache_disk_cap_mb)"
}

# Pick the first existing file from a list.  Older server-configs-nginx
# releases installed http.d files with underscore names (fastcgi_cache_conf);
# current releases use dots (fastcgi_cache.conf).  --optimize must tune a live
# server regardless of which layout it was installed with.
tune_first_file() {
  local dir=$1 name
  shift
  for name in "$@"; do
    [[ -f "${dir}/${name}" ]] && { printf '%s' "${dir}/${name}"; return 0; }
  done
  return 1
}

# Files under http.d that nginx actually includes.  Hosts upgraded from older
# layouts often keep inert *_conf leftovers next to the active *.conf files;
# tuning those leftovers changes nothing and hides the real cache/limit files.
TUNE_ACTIVE_HTTP=()
nginx_active_http_files() {
  local target=$1 conf="${1}/nginx.conf" pattern path
  [[ -f $conf ]] || return 0
  while IFS= read -r pattern; do
    pattern=${pattern#*include}
    pattern=${pattern%%;*}
    pattern=$(printf '%s' "$pattern" | tr -d '"' | awk '{print $1}')
    [[ -n $pattern ]] || continue
    [[ $pattern == /* ]] || pattern="${target}/${pattern}"
    while IFS= read -r path; do
      [[ -n $path && -f $path ]] || continue
      case "$path" in
        "${target}/http.d/"*) printf '%s\n' "$path" ;;
      esac
    done < <(compgen -G "$pattern" 2>/dev/null | sort || true)
  done < <(grep -hE '^[[:space:]]*include[[:space:]]+' "$conf" 2>/dev/null || true)
}

# The repository ships both .conf and legacy *_conf http.d filenames.  New
# managed files must use the same suffix as the files nginx.conf includes,
# otherwise they are inert (and a duplicate cache zone is never loaded).
nginx_http_suffix() {
  local target=$1 file
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    case "$file" in
      *_conf) printf '_conf'; return 0 ;;
    esac
  done < <(nginx_active_http_files "$target")
  printf '.conf'
}

tune_active_file() {
  local pattern=$1 file
  for file in "${TUNE_ACTIVE_HTTP[@]}"; do    [[ -f $file ]] || continue
    grep -qE "$pattern" "$file" && { printf '%s' "$file"; return 0; }
  done
  return 1
}

# Cache or limiter files under http.d that nginx.conf never includes.  Older
# deployments kept the *_conf names after the repository renamed them to
# *.conf; those files look active but silently change nothing, which is why
# --optimize reports "no active fastcgi_cache_path" on such a host.
nginx_inert_cache_files() {
  local target=$1 file active is_active
  local -a active_files=()
  mapfile -t active_files < <(nginx_active_http_files "$target")
  for file in "$target"/http.d/*; do
    [[ -f $file ]] || continue
    grep -qE '^[[:space:]]*(fastcgi_cache_path|proxy_cache_path|limit_req_zone)[[:space:]]' "$file" || continue
    is_active=0
    for active in "${active_files[@]}"; do
      [[ $file == "$active" ]] && { is_active=1; break; }
    done
    (( is_active )) || printf '%s\n' "$file"
  done
  return 0
}

# Directories backing the cache paths nginx actually includes.  Used after a
# service restart to drop objects written while a backend was unavailable.
nginx_cache_dirs() {
  local target=${1:-/etc/nginx} file
  local -a files=()
  mapfile -t files < <(nginx_active_http_files "$target")
  files+=("${target}/nginx.conf")
  for file in "${files[@]}"; do
    [[ -f $file ]] || continue
    awk '
      {
        for (i = 1; i < NF; i++) {
          if ($i ~ /^(fastcgi|proxy|scgi|uwsgi)_cache_path$/) {
            print $(i + 1)
            break
          }
        }
      }
    ' "$file"
  done | tr -d ';' | grep -E '^/' | sort -u
  return 0
}

# Disk-cache max_size is planned from RAM, but a live cache can already hold
# more than that plan (and may be configured larger by the operator).  Writing
# a smaller value makes nginx's cache manager evict hot objects immediately,
# and chasing usage every run would ratchet the value upward forever.  Rule:
# never shrink below the existing max_size or the live usage (+5% headroom).
# A full cache always measures slightly above its max_size: du counts the
# levels=1:2 directory blocks (up to 4096 directories) and the objects the
# cache manager has not evicted yet, neither of which nginx charges to
# max_size.  Usage within 5% of the configured size is therefore "the cache
# is full", not "the cache needs more": keeping the size as it is stops a
# busy cache from gaining 256 MB on every run.
# Sets NGINX_CACHE_MB (size to write) and NGINX_CACHE_NOTE (report line, if
# the planned value was raised).  A global result is used instead of command
# substitution so the note reaches the caller's TUNE_CHANGES array.
# nginx_cache_keep_mb FILE PLANNED_MB [ZONE] [CAP_MB]: with ZONE, only the
# *_cache_path directive whose keys_zone is ZONE is considered (a proxy file
# carries two paths); the directive may wrap onto several lines.  CAP_MB is
# the RAM/disk-capped cache budget of the host: a kept value is bounded by
# the same ceiling a freshly planned one gets (0 or absent: no ceiling).
nginx_cache_keep_mb() {
  local file=$1 planned=$2 zone=${3:-} cap=${4:-0} dir usage existing=0 candidate val directive
  local capped=0
  NGINX_CACHE_MB=$planned
  NGINX_CACHE_NOTE=""
  [[ -f $file ]] || return 0
  # Join each *_cache_path directive onto one line, then pick the first (or
  # the one naming ZONE).
  directive=$(awk -v zone="$zone" '
    collecting { buf = buf " " $0 }
    !collecting && $1 ~ /^(fastcgi|proxy|scgi|uwsgi)_cache_path$/ { buf = $0; collecting = 1 }
    collecting && buf ~ /;[[:space:]]*$/ {
      collecting = 0
      if (zone == "" || index(buf, "keys_zone=" zone ":") > 0) { print buf; exit }
      buf = ""
    }
  ' "$file")
  [[ -n $directive ]] || return 0
  dir=$(printf '%s\n' "$directive" | awk '{print $2}' | tr -d ';')
  # Existing max_size in MB (k/m/g suffix); 0 when the directive has none.
  val=$(printf '%s\n' "$directive" | grep -m1 -oE 'max_size=[0-9]+[kKmMgG]' 2>/dev/null || true)
  val=${val#max_size=}
  if [[ $val =~ ^([0-9]+)([kKmMgG])$ ]]; then
    case ${BASH_REMATCH[2]} in
      k|K) existing=$(( BASH_REMATCH[1] / 1024 )) ;;
      m|M) existing=${BASH_REMATCH[1]} ;;
      g|G) existing=$(( BASH_REMATCH[1] * 1024 )) ;;
    esac
  fi
  candidate=$planned
  usage=$(du -sm -- "$dir" 2>/dev/null | awk '{print $1}' || true)
  [[ $usage =~ ^[0-9]+$ ]] || usage=0
  if (( usage > planned )); then
    if (( existing > 0 && usage <= existing + existing / 20 )); then
      # The configured cache already covers its live objects (a full cache
      # reads up to 5% above max_size, see above): keep it rather than
      # writing a value that would evict them or grow it again.
      candidate=$existing
    else
      candidate=$(( usage * 105 / 100 ))
    fi
  fi
  (( candidate > planned )) || return 0
  candidate=$(( (candidate + 255) / 256 * 256 ))
  # The planned value is already inside the budget; only a kept one can
  # exceed it (an adopted host with a 16g cache path on a small disk).
  [[ $cap =~ ^[0-9]+$ ]] || cap=0
  if (( cap > 0 && candidate > cap )); then
    candidate=$cap
    capped=1
  fi
  (( candidate > planned )) || return 0
  NGINX_CACHE_MB=$candidate
  if (( capped )); then
    NGINX_CACHE_NOTE="kept cache max_size=${candidate}M for ${dir:-cache} (live ${usage}MB; RAM plan was ${planned}M; capped at the ${cap}M cache budget of this host)"
  else
    NGINX_CACHE_NOTE="kept cache max_size=${candidate}M for ${dir:-cache} (live ${usage}MB; RAM plan was ${planned}M)"
  fi
  return 0
}

# A backend that restarts during --optimize can send a truncated/empty 200
# while connections are cut over, and the guest cache stores 200 responses
# for minutes: every visitor then receives a blank page.  Older releases
# deleted objects written during the run.  setup.sh now only reports them: a
# cache file is still a file, and deleting the wrong entry is not recoverable.
count_optimize_cache_entries() {
  local epoch=${1:-0} target=${2:-/etc/nginx} dir count total=0
  [[ $epoch =~ ^[0-9]+$ ]] && (( epoch > 0 )) || { printf '0'; return 0; }
  while IFS= read -r dir; do
    [[ -n $dir && $dir == /* && $dir != / && -d $dir ]] || continue
    count=$(find "$dir" -type f -newermt "@$epoch" 2>/dev/null | wc -l)
    total=$(( total + count ))
  done < <(nginx_cache_dirs "$target")
  printf '%s' "$total"
}

tune_replace() {
  local file=$1 pattern=$2 replacement=$3 desc=$4 tmp
  if [[ ! -f $file ]]; then
    tune_miss "file not found for ${desc}: ${file}"
    return 0
  fi
  if ! grep -qE "$pattern" "$file"; then
    tune_miss "no match for ${desc}"
    return 0
  fi
  tmp=$(tmp_file) || return 1
  # Use a delimiter that does not collide with regex alternation (`|`) or
  # common path characters in these directives.  A '#' in either part is
  # escaped (1.22.12): the CPU-pinning comment "\1# worker_cpu_affinity
  # auto; # setup.sh: ..." ended the s command early, its " w..." tail ran
  # as sed's w flag (a junk file named "orker_cpu_affinity ..." in the
  # working directory) and the directive was deleted instead of commented.
  sed -E "s#${pattern//#/\\#}#${replacement//#/\\#}#" "$file" > "$tmp" || return 1
  commit_if_changed "$file" "$tmp" && tune_note "$desc"
  return 0
}

tune_insert_after() {
  local file=$1 anchor=$2 line=$3 desc=$4
  if [[ ! -f $file ]]; then
    tune_miss "file not found for ${desc}: ${file}"
    return 0
  fi
  if ! grep -qE "$anchor" "$file"; then
    tune_miss "no insertion anchor for ${desc}"
    return 0
  fi
  local tmp
  tmp=$(tmp_file)
  awk -v anchor="$anchor" -v line="$line" '
    $0 ~ anchor && !done { print; print line; done=1; next }
    { print }
  ' "$file" > "$tmp"
  if commit_if_changed "$file" "$tmp"; then
    tune_note "$desc"
  fi
}

# Append a directive only when the file has no active copy.  Used by the
# guest-cache repair so an older include that is missing one line (for
# example fastcgi_no_cache) is completed without duplicating the rest.
tune_ensure_line() {
  local file=$1 pattern=$2 line=$3 desc=$4
  [[ -f $file ]] || { tune_miss "file not found for ${desc}: ${file}"; return 0; }
  grep -qE "$pattern" "$file" && return 0
  printf '%s\n' "$line" >> "$file"
  tune_note "$desc"
  return 0
}

# Like tune_ensure_line, but the directive is inserted before the last
# closing brace so it lands inside the include's location block (the h5bp
# php_*.conf includes are one `location ~ \.php` each).  Appending after the
# brace put cache directives in the server context, where they also applied
# to the admin/login locations that deliberately include plain php.conf.
tune_ensure_in_location() {
  local file=$1 pattern=$2 line=$3 desc=$4 tmp last
  [[ -f $file ]] || { tune_miss "file not found for ${desc}: ${file}"; return 0; }
  grep -qE "$pattern" "$file" && return 0
  last=$(grep -nE '^[[:space:]]*\}[[:space:]]*$' "$file" | tail -n1 | cut -d: -f1 || true)
  if [[ -z $last ]]; then
    tune_ensure_line "$file" "$pattern" "$line" "$desc"
    return 0
  fi
  tmp=$(tmp_file) || return 1
  awk -v n="$last" -v line="$line" 'NR == n { print line } { print }' "$file" > "$tmp"
  cat -- "$tmp" > "$file"
  tune_note "$desc"
  return 0
}

# A cached 500 (or a stale 500 served by fastcgi_cache_use_stale) hides a
# recovered application and makes the error look permanent.  Older installs
# carry the original policy; --optimize upgrades them in place so an existing
# server gets the fix without a full reinstall.
tune_cache_error_policy() {
  local file=$1 label=$2 before after tmp
  [[ -f $file ]] || return 0
  # An include without a cache (h5bp/php_chev.conf since the guest cache moved
  # to php_chev_cache.conf) has no error policy to repair.
  grep -qE '^[[:space:]]*(fastcgi|proxy)_cache[[:space:]]' "$file" || return 0
  before=$(file_md5 "$file")
  sed_in_place -E '/^[[:space:]]*fastcgi_cache_use_stale/ s/[[:space:]]+http_500([[:space:]]|;)/\1/g' "$file"
  # fastcgi_cache_valid is first-match in file order: a 5xx line placed after
  # "any" is never reached and the error is cached for the "any" TTL.  Put
  # (or move) the 0s line in front of the first fastcgi_cache_valid.
  local l5 lany
  l5=$(grep -nE '^[[:space:]]*fastcgi_cache_valid[[:space:]]+500([[:space:]]+[0-9]+)+[[:space:]]+0s;' "$file" | head -n1 | cut -d: -f1 || true)
  lany=$(grep -nE '^[[:space:]]*fastcgi_cache_valid[[:space:]]+any[[:space:]]' "$file" | head -n1 | cut -d: -f1 || true)
  if [[ -z $l5 ]] || { [[ -n $lany ]] && (( l5 > lany )); }; then
    tmp=$(tmp_file)
    awk '
      /^[[:space:]]*fastcgi_cache_valid[[:space:]]+500([[:space:]]+[0-9]+)+[[:space:]]+0s;/ { next }
      /^[[:space:]]*fastcgi_cache_valid[[:space:]]/ && !done {
        print "fastcgi_cache_valid 500 502 503 504 0s;"
        done = 1
      }
      { print }
      END { if (!done) print "\nfastcgi_cache_valid 500 502 503 504 0s;" }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
  fi
  after=$(file_md5 "$file")
  [[ $before != "$after" ]] \
    && tune_note "${label}: never cache error responses; stale 500 disabled"
  return 0
}

# The shared FastCGI snippet historically captured PATH_INFO with
# ^(.+?\.php)(/.*)$; that requires a trailing "/..." and can leave
# $fastcgi_script_name empty for a bare /index.php.  try_files then sees the
# document root, passes it to PHP-FPM, and security.limit_extensions returns
# "Access denied" for every pretty URL.  Make PATH_INFO optional; the
# try_files test and SCRIPT_FILENAME stay unchanged so PATH_INFO apps keep
# working.
tune_fastcgi_snippet() {
  local file=$1 tmp
  [[ -f $file ]] || { tune_miss "FastCGI snippet missing: ${file}"; return 0; }
  grep -qE '^[[:space:]]*fastcgi_split_path_info[[:space:]]+' "$file" || {
    tune_miss "FastCGI snippet has no fastcgi_split_path_info: ${file}"
    return 0
  }
  tmp=$(tmp_file) || return 1
  awk '
    function lead(s) { match(s, /^[[:space:]]*/); return substr(s, 1, RLENGTH) }
    /^[[:space:]]*fastcgi_split_path_info[[:space:]]+/ {
      print lead($0) "fastcgi_split_path_info ^(.+?\\.php)(/.*)?$;"
      next
    }
    { print }
  ' "$file" > "$tmp"
  commit_if_changed "$file" "$tmp" \
    && tune_note "snippets/fastcgi-php.conf: PATH_INFO capture is optional"
  return 0
}

# PHP-FPM uses PATH_TRANSLATED instead of SCRIPT_FILENAME when
# cgi.fix_pathinfo=0. The shared WordPress/Polr includes used to set it to
# $document_root$fastcgi_path_info, which is the document root for a normal
# /index.php request. Point it at the script so enabling fix_pathinfo later
# cannot turn the document root into an attempted PHP script.
tune_fastcgi_path_translated() {
  local file=$1 tmp
  [[ -f $file ]] || return 0
  grep -qE '^[[:space:]]*fastcgi_param[[:space:]]+PATH_TRANSLATED[[:space:]]+\$document_root\$fastcgi_path_info[[:space:]]*;' "$file" || return 0
  tmp=$(tmp_file) || return 1
  awk '
    function lead(s) { match(s, /^[[:space:]]*/); return substr(s, 1, RLENGTH) }
    /^[[:space:]]*fastcgi_param[[:space:]]+PATH_TRANSLATED[[:space:]]+\$document_root\$fastcgi_path_info[[:space:]]*;/ {
      print lead($0) "fastcgi_param PATH_TRANSLATED $document_root$fastcgi_script_name;"
      next
    }
    { print }
  ' "$file" > "$tmp"
  commit_if_changed "$file" "$tmp" \
    && tune_note "${file##*/}: PATH_TRANSLATED uses the PHP script"
  return 0
}

# Apply the PATH_TRANSLATED repair to every deployed PHP location include:
# php.conf plus all php_*.conf (php_xf.conf, php_xf_proxy.conf, php_wp.conf,
# php_polr.conf, and any future variant).
tune_fastcgi_path_translated_all() {
  local target=$1 file
  tune_fastcgi_path_translated "${target}/h5bp/php.conf"
  for file in "${target}"/h5bp/php_*.conf; do
    [[ -f $file ]] || continue
    tune_fastcgi_path_translated "$file"
  done
  return 0
}

# A per-request `PHP_ADMIN_VALUE open_basedir=...` is cached by the FPM worker
# that handled the request and is never reset, so one vhost that sets it
# silently restricts every other vhost served by the shared pool.  The next
# WordPress request on that worker then sees file_exists(wp-config.php) == false
# and redirects to /wp-admin/setup-config.php (denied -> 403), and PHP cannot
# open the primary script at all ("Unable to open primary script ...
# Operation not permitted" -> 404).  Tenant isolation belongs in a dedicated
# pool, never in a fastcgi_param, so comment out every deployed copy.
tune_strip_php_admin_open_basedir() {
  local file=$1 label=${2:-${1##*/}} before
  [[ -f $file ]] || return 0
  before=$(file_md5 "$file")
  sed_in_place -E 's|^([[:space:]]*)(fastcgi_param[[:space:]]+PHP_ADMIN_VALUE[[:space:]]+"?open_basedir=.*)$|\1# \2|' "$file"
  if [[ $(file_md5 "$file") != "$before" ]]; then
    tune_note "${label}: per-request open_basedir disabled (it leaks across the shared PHP-FPM pool)"
  fi
  return 0
}

# Apply the repair to every deployed PHP location include and to any vhost
# that inlined the param itself.
tune_strip_php_admin_open_basedir_all() {
  local target=$1 file
  for file in "${target}"/h5bp/php*.conf "${target}"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    tune_strip_php_admin_open_basedir "$file"
  done
  return 0
}

# A bare `location / { try_files ... }` with no index directive resolves "/"
# to the directory instead of index.php on older vhosts.  Add a server-level
# index to the shared WordPress and Polr includes when they lack one.
tune_ensure_index() {
  local file=$1 tmp
  [[ -f $file ]] || return 0
  if grep -qE '^[[:space:]]*index[[:space:]]' "$file"; then
    return 0
  fi
  tmp=$(tmp_file) || return 1
  {
    printf 'index index.php index.html;\n'
    cat "$file"
  } > "$tmp"
  cat "$tmp" > "$file"
  tune_note "${file##*/}: index index.php index.html"
  return 0
}

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
# XenForo's own page cache varies on style_id and language_id (see
# src/XF/PageCache.php).  The deployed nginx vhost only keyed on the style
# variation, so a guest who picked a non-default style or language could
# receive another guest's cached HTML.  Add both cookies to the key and enable
# a background refresh so an expiring entry does not make one visitor wait on
# PHP while cache_lock serializes the stampede.
# The guest-cache key.  Cookie values are attacker-chosen, so only validated
# tokens (maps in zz-setup-fastcgi-cache-map) enter it, each behind a
# delimiter: with the raw cookies appended to $request_uri, "GET /" with
# xf_style_variation=threads/x.1/ stored the forum index under the thread's
# key for every guest.
XF_CACHE_KEY='"$request_method|$scheme|$host|$request_uri|$setup_xf_key_variation|$setup_xf_key_style|$setup_xf_key_language|$setup_cache_enc"'
# The catch-all 443 server (conf.d/1.https.default.conf) used to finish the
# handshake with the self-signed default certificate, whose CN/SAN is
# `hostname -f`; a scanner hitting the bare IP learned the host name.  Hosts
# deployed before server-configs-nginx 1.6.46 gain `ssl_reject_handshake on;`
# (the default_ssl include stays: it carries the TLS session cache that
# SNI vhosts resume from).  Only the shipped catch-all shape is touched.
#
# A reverse proxy in front of the origin must send the site name as SNI, or
# every handshake it makes is refused and the site answers 502 through it.
# Cloudflare always does; a self-run proxy often does not (nginx/nginx
# default to proxy_ssl_server_name off, and proxy_ssl_name defaults to the
# proxy_pass address).  This took site-a.example (2026-11-20) and site-d.example
# (2026-11-21) down.  SSL_REJECT_UNKNOWN_SNI (/etc/default/setup-tuning,
# SETUP_SSL_REJECT_UNKNOWN_SNI for one run):
#   auto (default)  on, unless a loaded vhost trusts a reverse proxy outside
#                   the Cloudflare ranges (tls_reject_front_proxies)
#   1               on: every proxy in front sends SNI (proxy_ssl_server_name
#                   on; proxy_ssl_name $host)
#   0               off
# "Off" comments the directive out with a marker; "on" restores a line this
# function commented out, or inserts one into a pre-1.6.46 catch-all.
TLS_REJECT_OFF_MARK='# setup.sh: off, a reverse proxy in front may connect without SNI (SSL_REJECT_UNKNOWN_SNI)'

# Reverse proxies the loaded configuration trusts or admits, one
# "file:address" per line.  Read from conf.d/*.conf, http.d/*.conf and every
# file they include (globs expanded, a few levels deep):
#   set_real_ip_from ADDR             the proxy's X-Forwarded-For is trusted
#   allow ADDR                        origin locked down to the proxy
#   $realip_remote_addr != "ADDR"     the Pingvin-template 444 gate
#   ADDR 1; # setup.sh exempt         rate-limit exemption a pre-1.21.71
#                                     limit_req.conf still carries
#   ADDR:https on;                    custom.d/https_trusted_peers.map
# plus every LIMIT_REQ_EXEMPT entry an older release persisted in
# /etc/default/setup-tuning ("setup-tuning:ADDR"): the 1.6.61 tree has no
# exemption list left, and such an address was usually a proxy in front.
# Directives sharing a line are split on ';' first.  Skipped: unix: sources
# (a local socket never makes a TLS handshake), loopback, `all`, and
# addresses inside a Cloudflare range of http.d/cloudflare.conf (a CIDR only
# when it fits inside the range).  A source that is not an IP literal, or any
# source when the ranges file is missing, counts as a proxy: a missed proxy
# is an outage, an extra one only leaves the catch-all as before 1.6.46.
# Not detectable here: a proxy the origin configuration never mentions (an
# application that reads X-Forwarded-For itself); SSL_REJECT_UNKNOWN_SNI=0
# covers that.
tls_reject_addr_is_cf() {
  local src=$1 ip bits r rbits
  shift
  ip=${src%/*}
  if [[ $ip == *:* ]]; then bits=128; else bits=32; fi
  [[ $src == */* ]] && bits=${src#*/}
  [[ $bits =~ ^[0-9]+$ ]] || return 1
  for r in "$@"; do
    if [[ $ip == *:* ]]; then
      [[ $r == *:* ]] || continue
      rbits=128; [[ $r == */* ]] && rbits=${r#*/}
      ipv6_in_cidr "$ip" "$r" && (( bits >= rbits )) && return 0
    else
      [[ $r == *:* ]] && continue
      rbits=32; [[ $r == */* ]] && rbits=${r#*/}
      ipv4_in_cidr "$ip" "$r" && (( bits >= rbits )) && return 0
    fi
  done
  return 1
}

tls_reject_front_proxies() {
  local target=$1 ranges="$1/http.d/cloudflare.conf" f g inc src depth=0
  local -a cf=() queue=() next=() globbed=()
  local -A seen=()
  mapfile -t cf < <(cf_tls_ranges "$ranges" 4; cf_tls_ranges "$ranges" 6)
  queue=("$target"/conf.d/*.conf "$target"/http.d/*.conf)
  while (( ${#queue[@]} > 0 && depth < 4 )); do
    next=()
    for f in "${queue[@]}"; do
      [[ -f $f && $f != "$ranges" && -z ${seen[$f]:-} ]] || continue
      seen[$f]=1
      # One directive per line, comments gone (the exempt marker is a
      # comment, so it is read from the raw file below).
      while IFS= read -r src; do
        [[ -z $src || $src == unix:* || $src == all ]] && continue
        [[ $src =~ ^(127\.|::1(/|$)) ]] && continue
        tls_reject_addr_is_cf "$src" "${cf[@]}" || printf '%s:%s\n' "${f##*/}" "$src"
      done < <(
        {
          sed -E 's/#.*//' "$f" | tr ';{}' '\n\n\n' | sed -nE \
            -e 's/^[[:space:]]*(set_real_ip_from|allow)[[:space:]]+"?([^"[:space:]]+)"?[[:space:]]*$/\2/p' \
            -e 's/.*\$realip_remote_addr[[:space:]]*!?[=~][[:space:]]*"?([0-9A-Fa-f.:\/]+)"?.*/\1/p' \
            -e 's/^[[:space:]]*"?([0-9A-Fa-f.:]+):https"?[[:space:]]+on[[:space:]]*$/\1/p'
          sed -nE 's/^[[:space:]]*([0-9A-Fa-f.:\/]+)[[:space:]]+1[[:space:]]*;[[:space:]]*# setup\.sh exempt.*/\1/p' "$f"
        } 2>/dev/null)
      while IFS= read -r inc; do
        [[ $inc == /* ]] || inc="$target/$inc"
        # Intended pathname expansion (include globs); nullglob keeps an
        # unmatched pattern out.
        mapfile -t globbed < <(shopt -s nullglob; for g in $inc; do printf '%s\n' "$g"; done)
        next+=("${globbed[@]}")
      done < <(sed -E 's/#.*//' "$f" | tr ';{}' '\n\n\n' \
                 | sed -nE 's/^[[:space:]]*include[[:space:]]+"?([^"[:space:]]+)"?[[:space:]]*$/\1/p')
    done
    queue=("${next[@]}")
    depth=$(( depth + 1 ))
  done
  local -a exempt=()
  IFS=', ' read -r -a exempt <<< "${LIMIT_REQ_EXEMPT:-}"
  for src in "${exempt[@]}"; do
    [[ -n $src ]] || continue
    [[ $src =~ ^(127\.|::1(/|$)) ]] && continue
    tls_reject_addr_is_cf "$src" "${cf[@]}" || printf 'setup-tuning:%s\n' "$src"
  done
  return 0
}

tune_default_tls_reject() {
  local target=$1 f="$1/conf.d/1.https.default.conf" mode=${SSL_REJECT_UNKNOWN_SNI:-auto} proxies=""
  [[ -f $f ]] || return 0
  grep -qE '^[[:space:]]*listen[[:space:]].*443.*default_server' "$f" || return 0
  # The off path needs only the directive: an operator-edited catch-all
  # (another return code, no `server_name _;`) is still switched off.  The
  # insert path below keeps the strict shipped-shape checks.
  [[ $mode =~ ^(auto|0|1)$ ]] || mode=auto
  if [[ $mode == auto ]]; then
    proxies=$(tls_reject_front_proxies "$target" | sort -u | head -n 5 | paste -sd' ' -)
  fi
  if [[ $mode == 0 || -n $proxies ]]; then
    local why="SSL_REJECT_UNKNOWN_SNI=0"
    [[ -n $proxies ]] && why="a vhost trusts a reverse proxy outside Cloudflare (${proxies}); set SSL_REJECT_UNKNOWN_SNI=1 in /etc/default/setup-tuning once every proxy sends the site name as SNI (proxy_ssl_server_name on; proxy_ssl_name \$host)"
    if grep -qE '^[[:space:]]*ssl_reject_handshake[[:space:]]+on[[:space:]]*;' "$f"; then
      sed_in_place -E "s|^([[:space:]]*)ssl_reject_handshake[[:space:]]+on[[:space:]]*;.*|\1# ssl_reject_handshake on;  $(sed_replacement_escape "$TLS_REJECT_OFF_MARK")|" "$f"
      tune_note "1.https.default.conf: unknown/missing SNI is not refused: ${why}"
    else
      tune_summary "1.https.default.conf: unknown/missing SNI is not refused: ${why}"
    fi
    return 0
  fi
  if grep -qF "$TLS_REJECT_OFF_MARK" "$f"; then
    sed_in_place -E "s|^([[:space:]]*)# ssl_reject_handshake on;  # setup\.sh: off,.*|\1ssl_reject_handshake on;|" "$f"
    tune_note "1.https.default.conf: unknown/missing SNI refused again (no reverse proxy outside Cloudflare, or SSL_REJECT_UNKNOWN_SNI=1)"
    return 0
  fi
  grep -qE '^[[:space:]]*ssl_reject_handshake[[:space:]]' "$f" && return 0
  grep -qE '^[[:space:]]*server_name[[:space:]]+_;' "$f" || return 0
  grep -qE '^[[:space:]]*return[[:space:]]+444;' "$f" || return 0
  tune_insert_before "$f" '^[[:space:]]*include[[:space:]]+h5bp/default_ssl\.conf;' \
    '  ssl_reject_handshake on;' \
    "1.https.default.conf: unknown/missing SNI refused before a certificate is sent" || true
  return 0
}

# The 1.22 nginx is built without an ACME module, so an active `acme_client`
# fails nginx -t ("unknown directive").  server-configs-nginx shipped
# http.d/letsencrypt.conf as an active file for a few hours on 2026-07-22
# (d2bf9ac..6b0ac3a) before renaming it to the inactive letsencrypt_conf, and
# the sync never removes a file that left the repository, so hosts synced
# that day kept an `acme_client letsencrypt` (two live hosts, 2026-11-20).
# Every http.d/*.conf whose only active content is acme_client definitions
# is retired (moved to /tmp, never deleted) while no vhost uses `acme` or an
# $acme_cert_* variable.  Such a vhost is left to the migration's ACME ->
# self-signed rewrite (lib/migrate.sh, step 6) and reported here: retiring
# its client alone would not make the tree load, and the operator must see
# why nginx -t fails.
tune_retire_unused_acme_client() {
  local target=$1 f moved
  [[ -d $target/http.d ]] || return 0
  if grep -rqsE '^[^#]*(\$acme_cert_|(^|[[:space:];{])acme[[:space:]]+[A-Za-z0-9_]+[[:space:]]*;)' \
       "$target/conf.d" "$target/http.d" "$target/snippets" "$target/custom.d" 2>/dev/null; then
    info "A vhost under ${target} still uses acme/\$acme_cert_*; this nginx has no ACME module"
    tune_miss "ACME: a vhost under ${target} still uses acme or \$acme_cert_*; this nginx has no ACME module (the 1.22 migration moves such vhosts to the self-signed certificate)"
    return 0
  fi
  for f in "$target"/http.d/*.conf; do
    [[ -f $f && ! -L $f ]] || continue
    nginx_conf_only_acme_client "$f" || continue
    moved=$(preserve_to_tmp "$f") || continue
    [[ -n $moved ]] || continue
    # info as well: the sync calls this before the tuner, which resets its notes.
    info "Retired unused ACME client ${f#"$target"/} -> ${moved} (not deleted)"
    tune_note "${f#"$target"/}: ACME client retired to ${moved} (this nginx has no ACME module)"
  done
  return 0
}

# True when FILE has at least one acme_client definition (one line, several
# lines, or a block) and no other active directive.
nginx_conf_only_acme_client() {
  awk '
    { s = $0; sub(/#.*/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", s) }
    s == "" { next }
    depth == 0 && !inside && s ~ /^acme_client([ \t]|$)/ { seen = 1; inside = 1 }
    {
      if (!inside && depth == 0) other = 1
      t = s; n = gsub(/\{/, "", t); t = s; m = gsub(/\}/, "", t); depth += n - m
      if (depth == 0 && s ~ /[;}]$/) inside = 0
    }
    END { exit !(seen && !other) }' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Cloudflare-proxied vhosts: the host's self-signed certificate, not certbot
# ---------------------------------------------------------------------------
# A site whose DNS points only at Cloudflare is reached through Cloudflare's
# edge, and in SSL mode "Full" Cloudflare accepts any origin certificate,
# self-signed or expired.  certbot then only adds failure modes: on a live
# nginx host its renewals had failed since September (`authenticator =
# nginx`, no nginx plugin on nginx) and the origin served an expired
# certificate.  --optimize points such server blocks at the host's
# self-signed /etc/nginx/ssl/default pair (only the two certificate paths
# change; the TLS policy includes stay), proves through Cloudflare after
# the reload that the edge still reaches the origin (otherwise the vhost is
# put back and marked so later runs leave it alone), and purges certbot
# once nothing can still depend on /etc/letsencrypt.
#
# Every decision fails closed.  A block moves only when it carries its own
# certbot certificate and key and every name it serves is an exact host
# name resolving solely to Cloudflare; a wildcard, regex or `.suffix` name
# keeps the block where it is (a proxied wildcard record does not prove that
# explicit grey-cloud records below it are proxied).  certbot stays while
# the loaded nginx configuration cannot be read, while any file, hook or
# symlink outside its tree refers to it, or while a vhost was put back.
# CF_SELF_SIGNED=0 (SETUP_CF_SELF_SIGNED=0) skips all of it.
CF_TLS_DEFAULT_CERT=/etc/nginx/ssl/default/fullchain.pem
CF_TLS_DEFAULT_KEY=/etc/nginx/ssl/default/privkey.pem
# First line written into a vhost that had to be put back; the migration
# never touches a file carrying it.  Deleting the line allows another try.
CF_TLS_KEEP_MARKER='# setup-cf-tls: keep'
# Origin probe added to each migrated block (see cf_tls_probe): digits only,
# so the echoed header can carry nothing but a number.  It stays in place so
# a later run can prove the block again; it answers 204 with no body.
# shellcheck disable=SC2016
CF_TLS_PROBE_LOCATION='location ~ "^/\.setup-cf-tls-probe-(?<setup_cf_probe>[0-9]{1,40})$" { access_log off; add_header X-Setup-CF-Probe $setup_cf_probe always; return 204; } # setup-cf-tls probe'
CF_TLS_FILES=()      # vhosts rewritten this run
CF_TLS_ORIG=()       # copy of each file before the rewrite (same index)
CF_TLS_NAMES=()      # names proved through Cloudflare (same index)
CF_TLS_DRY_FULL=()   # dry run: files left with no /etc/letsencrypt reference
# A non-comment reference to the certbot tree as a whole path component:
# `/etc/letsencrypt/live/...`, a bind mount `/etc/letsencrypt:/...` or a
# bare `LE_DIR=/etc/letsencrypt` all count.
# shellcheck disable=SC2016
CF_TLS_LE_ERE='^[^#]*/etc/letsencrypt([/:"'"'"'[:space:];]|$)'

# CIDRs from the generated Cloudflare real-IP file, one per line; $2 = 4|6.
cf_tls_ranges() {
  local file=$1 fam=$2
  [[ -r $file ]] || return 0
  sed -nE 's/^[[:space:]]*set_real_ip_from[[:space:]]+([^;[:space:]]+)[[:space:]]*;.*/\1/p' "$file" \
    | if [[ $fam == 6 ]]; then grep ':' || true; else grep -v ':' || true; fi
}

ipv4_to_int() {
  local a b c d
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$1"
  (( 10#$a < 256 && 10#$b < 256 && 10#$c < 256 && 10#$d < 256 )) || return 1
  printf '%s' $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

ipv4_in_cidr() {
  local ip net bits mask
  ip=$(ipv4_to_int "$1") || return 1
  bits=32; [[ $2 == */* ]] && bits=${2#*/}
  [[ $bits =~ ^[0-9]+$ ]] && (( bits <= 32 )) || return 1
  net=$(ipv4_to_int "${2%/*}") || return 1
  (( bits == 0 )) && return 0
  mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( (ip & mask) == (net & mask) ))
}

# 32 lowercase hex digits for an IPv6 address.  Zone ids and the embedded
# IPv4 form are refused (never a Cloudflare edge address).
ipv6_expand() {
  local a=${1,,} head tail out="" g fill
  local -a hs=() ts=()
  [[ $a =~ ^[0-9a-f:]+$ && $a == *:* ]] || return 1
  if [[ $a == *::* ]]; then
    head=${a%%::*}; tail=${a#*::}
    [[ $tail != *::* ]] || return 1
    [[ -n $head ]] && IFS=: read -ra hs <<<"$head"
    [[ -n $tail ]] && IFS=: read -ra ts <<<"$tail"
    (( ${#hs[@]} + ${#ts[@]} <= 7 )) || return 1
    fill=$(( 8 - ${#hs[@]} - ${#ts[@]} ))
    for g in "${hs[@]}"; do [[ $g =~ ^[0-9a-f]{1,4}$ ]] || return 1; out+=$(printf '%04x' "0x$g"); done
    for (( ; fill > 0; fill-- )); do out+='0000'; done
    for g in "${ts[@]}"; do [[ $g =~ ^[0-9a-f]{1,4}$ ]] || return 1; out+=$(printf '%04x' "0x$g"); done
  else
    IFS=: read -ra hs <<<"$a"
    (( ${#hs[@]} == 8 )) || return 1
    for g in "${hs[@]}"; do [[ $g =~ ^[0-9a-f]{1,4}$ ]] || return 1; out+=$(printf '%04x' "0x$g"); done
  fi
  [[ ${#out} -eq 32 ]] || return 1
  printf '%s' "$out"
}

ipv6_in_cidr() {
  local ip net bits full rem a b mask
  ip=$(ipv6_expand "$1") || return 1
  bits=128; [[ $2 == */* ]] && bits=${2#*/}
  [[ $bits =~ ^[0-9]+$ ]] && (( bits <= 128 )) || return 1
  net=$(ipv6_expand "${2%/*}") || return 1
  full=$(( bits / 4 )); rem=$(( bits % 4 ))
  [[ ${ip:0:full} == "${net:0:full}" ]] || return 1
  (( rem == 0 )) && return 0
  a=$(( 0x${ip:full:1} )); b=$(( 0x${net:full:1} ))
  mask=$(( (0xF << (4 - rem)) & 0xF ))
  (( (a & mask) == (b & mask) ))
}

# Addresses a name resolves to, one per line (tests replace this function).
# /etc/hosts often maps a host's own site names to 127.0.1.1 (cloud-init's
# manage_etc_hosts with the site as FQDN): getent then answers loopback
# only, and a Cloudflare-proxied site looked "not behind Cloudflare" (a
# false migration warning, certbot kept, SNI guard off; 1.22.8).  When
# every local answer is loopback, the public DNS answer is used instead
# (systemd-resolved without /etc/hosts or other synthesized records); with
# no such answer the loopback result stands, which never counts as
# Cloudflare.
cf_tls_resolve() {
  local out dns
  out=$(getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u || true)
  if [[ -n $out ]] && ! grep -qvE '^(127\.|::1$|::ffff:127\.)' <<<"$out" && command -v resolvectl >/dev/null 2>&1; then
    dns=$(timeout 10 resolvectl query --synthesize=no --legend=no "$1" 2>/dev/null \
      | awk -v n="$1:" '{ for (i = 1; i <= NF; i++) { if ($i == "--") break; if ($i == n) continue
          if ($i ~ /^[0-9a-fA-F:.]+$/ && $i ~ /[.:]/) print $i } }' \
      | sort -u || true)
    [[ -n $dns ]] && out=$dns
  fi
  [[ -z $out ]] || printf '%s\n' "$out"
}

# 0 when NAME resolves and every address is inside a Cloudflare range.
cf_tls_name_behind_cloudflare() {
  local name=$1 ranges_file=$2 addr cidr ok any=0
  local -a v4 v6
  mapfile -t v4 < <(cf_tls_ranges "$ranges_file" 4)
  mapfile -t v6 < <(cf_tls_ranges "$ranges_file" 6)
  (( ${#v4[@]} > 0 )) || return 1
  while IFS= read -r addr; do
    [[ -n $addr ]] || continue
    any=1; ok=0
    if [[ ${addr,,} == ::ffff:*.* ]]; then addr=${addr:7}; fi
    if [[ $addr == *:* ]]; then
      for cidr in "${v6[@]}"; do ipv6_in_cidr "$addr" "$cidr" && { ok=1; break; }; done
    else
      for cidr in "${v4[@]}"; do ipv4_in_cidr "$addr" "$cidr" && { ok=1; break; }; done
    fi
    (( ok )) || return 1
  done < <(cf_tls_resolve "$name")
  (( any ))
}

# Server blocks of a vhost file, one line each:
#   <index> TAB <eligible> TAB <names>
# eligible=1 only when the block (not a nested location, not an include)
# sets exactly one ssl_certificate and one ssl_certificate_key and both are
# under /etc/letsencrypt; any other certificate/key directive, or a cert
# without its key here, makes it 0.  Directives are matched as whole words
# (proxy_ssl_certificate is not ssl_certificate).  Comments are stripped
# before parsing; conf.d files are http context, so only top-level
# `server {` blocks count.
cf_tls_server_blocks() {
  awk '
    function strip(s) { sub(/#.*/, "", s); return s }
    function count(s, re,   n) { n = 0; while (match(s, re)) { n++; s = substr(s, RSTART + RLENGTH) } return n }
    {
      code = strip($0)
      if (depth == 0 && code ~ /^[ \t]*server[ \t]*\{/) {
        idx++; inblk = 1; names = ""; collecting = 0; lec = 0; lek = 0; tc = 0; tk = 0; other = 0
        # Directives on the `server {` line itself are not rewritten: such a
        # block is left alone rather than half-migrated.
        tail = code; sub(/^[ \t]*server[ \t]*\{/, "", tail)
        if (tail ~ /[^ \t]/) other++
      }
      if (inblk) {
        lec += count(code, "(^|[ \t;{])ssl_certificate[ \t]+/etc/letsencrypt/[^;]*;")
        lek += count(code, "(^|[ \t;{])ssl_certificate_key[ \t]+/etc/letsencrypt/[^;]*;")
        tc  += count(code, "(^|[ \t;{])ssl_certificate[ \t]+[^;]*;")
        tk  += count(code, "(^|[ \t;{])ssl_certificate_key[ \t]+[^;]*;")
        # An include that brings its own certificate pair (h5bp hostname_ssl).
        other += count(code, "(^|[ \t;{])include[ \t]+[^;]*hostname_ssl[^;]*;")
        # Already carries a probe (migrated by hand, or edited back).
        if ($0 ~ /setup-cf-tls probe/) other++
        if (depth == 1 && code ~ /(^|[ \t;{])server_name[ \t]/) {
          collecting = 1; s = code; sub(/.*server_name[ \t]+/, "", s); rest = s
        } else if (collecting) { rest = code }
        if (collecting) {
          s = rest; fin = (s ~ /;/); sub(/;.*/, "", s)
          n = split(s, parts, /[ \t]+/)
          for (i = 1; i <= n; i++) if (parts[i] != "") names = names (names == "" ? "" : " ") parts[i]
          if (fin) collecting = 0
        }
      }
      o = gsub(/\{/, "{", code); c = gsub(/\}/, "}", code)
      depth += o - c
      if (inblk && depth == 0 && (o > 0 || c > 0)) {
        printf "%d\t%d\t%s\n", idx, (lec == 1 && lek == 1 && tc == 1 && tk == 1 && other == 0) ? 1 : 0, names
        inblk = 0
      }
    }' "$1"
}

# Rewrite the listed server blocks (comma-separated indexes) of FILE to the
# self-signed pair.  certbot-only directives (its options include, dhparam,
# trusted chain) are removed; everything else is left byte for byte.  Every
# directive is matched as a whole word, so proxy_ssl_certificate and
# proxy_ssl_trusted_certificate are never touched, and a one-line
# `ssl_certificate ...; ssl_certificate_key ...;` is rewritten together.
# Right after the block's `server {` line goes the origin probe location
# (CF_TLS_PROBE_LOCATION): placed first, so no other regex location wins.
cf_tls_rewrite_blocks() {
  local file=$1 list=$2 out
  out=$(tmp_file) || return 1
  # The probe arrives through ENVIRON: awk -v would eat its backslashes.
  CF_TLS_AWK_PROBE=$CF_TLS_PROBE_LOCATION \
  awk -v want=",${list}," -v crt="$CF_TLS_DEFAULT_CERT" -v key="$CF_TLS_DEFAULT_KEY" '
    BEGIN { probe = ENVIRON["CF_TLS_AWK_PROBE"] }
    function strip(s) { sub(/#.*/, "", s); return s }
    # Replace (val != "") or remove (val == "") every whole-word
    # DIR /etc/letsencrypt/...; in s.  mawk has no capture groups, so the
    # line is rebuilt around match(), keeping the boundary character.
    function edit(s, dir, val,   re, out, st, piece) {
      re = "(^|[ \t;{])" dir "[ \t]+/etc/letsencrypt/[^;]*;"
      out = ""
      while (match(s, re)) {
        st = RSTART
        if (substr(s, st, 1) != substr(dir, 1, 1)) { out = out substr(s, 1, st); st++ } else out = out substr(s, 1, st - 1)
        piece = (val == "") ? "" : dir " " val ";"
        out = out piece
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    {
      line = $0; code = strip(line)
      opening = 0
      if (depth == 0 && code ~ /^[ \t]*server[ \t]*\{/) { idx++; hit = (index(want, "," idx ",") > 0); opening = hit }
      o = gsub(/\{/, "{", code); c = gsub(/\}/, "}", code)
      if (hit && !opening) {
        before = line
        if (code ~ /(^|[ \t;{])ssl_certificate_key[ \t]+\/etc\/letsencrypt\//) line = edit(line, "ssl_certificate_key", key)
        if (code ~ /(^|[ \t;{])ssl_certificate[ \t]+\/etc\/letsencrypt\//)     line = edit(line, "ssl_certificate", crt)
        line = edit(line, "include", "")
        line = edit(line, "ssl_dhparam", "")
        line = edit(line, "ssl_trusted_certificate", "")
        if (line != before) {
          sub(/[ \t]*#[ \t]*managed by Certbot[ \t]*$/, "", line)
          rest = line; sub(/#.*/, "", rest)
          if (rest ~ /^[ \t]*$/) { depth += o - c; if (depth == 0) hit = 0; next }
        }
      }
      print line
      if (opening && probe != "") print "    " probe
      depth += o - c
      if (depth == 0) hit = 0
    }' "$file" > "$out" || { rm -f "$out"; return 1; }
  cat -- "$out" > "$file"
  rm -f "$out"
}

# Proof that Cloudflare reaches the origin with the self-signed certificate:
# the migrated block answers /.setup-cf-tls-probe-<digits> itself with 204
# and echoes the digits in X-Setup-CF-Probe.  Only a worker started after
# the reload has that location, and the TLS handshake of a connection is
# done by the worker that serves it, so the echo through public DNS proves
# that Cloudflare connected to a new worker and accepted its certificate.
# A cached answer, a Cloudflare challenge/WAF/redirect/Worker response, an
# old worker or a 52x carries no echo.  A few attempts cover the reload.
# Prints the last status; returns 0 only with the echo (tests replace it).
cf_tls_probe() {
  local name=$1 hdr status="000" nonce try
  command -v curl >/dev/null 2>&1 || { printf 'no-curl'; return 1; }
  for try in 1 2 3 4 5; do
    nonce="${RANDOM}${RANDOM}${try}$$"
    hdr=$(curl -s -o /dev/null -D - --max-time 15 -H 'Cache-Control: no-cache' \
          "https://${name}/.setup-cf-tls-probe-${nonce}" 2>/dev/null) || hdr=""
    hdr=$(printf '%s\n' "$hdr" | tr -d '\r')
    status=$(printf '%s\n' "$hdr" | awk 'toupper($1) ~ /^HTTP\// { s = $2 } END { print s }')
    [[ $status =~ ^[0-9]{3}$ ]] || status=000
    if printf '%s\n' "$hdr" | grep -qix "x-setup-cf-probe: ${nonce}"; then
      printf '%s' "$status"
      return 0
    fi
    (( try < 5 )) && sleep 2
  done
  printf '%s' "$status"
  return 1
}

# One report line: printed in a dry run, collected for the report otherwise.
cf_tls_say() {
  if (( $1 )); then printf '  %s\n' "${2#- }"; else opt_report "$2"; fi
}

# 0 when FILE still has an active (non-comment) /etc/letsencrypt reference.
cf_tls_file_uses_letsencrypt() {
  awk '{ s = $0; sub(/#.*/, "", s); if (s ~ /\/etc\/letsencrypt([\/:" \t;]|$)/) { f = 1; exit } } END { exit !f }' "$1"
}

# Plan or apply the migration for every vhost under TARGET/conf.d.
#   $2 = 1 for a dry run (prints the plan, changes nothing).
# Applied changes are recorded in CF_TLS_* for cloudflare_tls_finish.
cloudflare_tls_migrate() {
  local target=${1:-/etc/nginx} dry=${2:-0} ranges f b idx el names name list orig ok copy
  local -a blocks=() keep_names=() checked=() vhosts=()
  CF_TLS_FILES=(); CF_TLS_ORIG=(); CF_TLS_NAMES=(); CF_TLS_DRY_FULL=()
  # Keep an explicit SETUP_CF_SELF_SIGNED=0/1 on the host so a later plain
  # --optimize honours it (README: persisted as CF_SELF_SIGNED).  A dry run
  # never writes.
  if (( ${CF_SELF_SIGNED_PERSIST:-0} )) && (( dry == 0 )); then
    persist_tuning_var CF_SELF_SIGNED "$CF_SELF_SIGNED"
  fi
  [[ ${CF_SELF_SIGNED:-1} != 0 ]] || return 0
  ranges="$target/http.d/cloudflare.conf"
  shopt -s nullglob
  vhosts=("$target"/conf.d/*.conf)
  shopt -u nullglob
  for f in "${vhosts[@]}"; do
    [[ -f $f && ! -L $f ]] || continue
    cf_tls_file_uses_letsencrypt "$f" || continue
    if head -n 1 -- "$f" | grep -qF -- "$CF_TLS_KEEP_MARKER"; then
      cf_tls_say "$dry" "- Cloudflare TLS: \`${f}\` kept on its certificate (${CF_TLS_KEEP_MARKER} marker; delete that line to retry)"
      continue
    fi
    if [[ ! -s $target/ssl/default/fullchain.pem || ! -s $target/ssl/default/privkey.pem ]]; then
      cf_tls_say "$dry" "- Cloudflare TLS: skipped (no self-signed pair in ${target}/ssl/default)"
      return 0
    fi
    if [[ -z $(cf_tls_ranges "$ranges" 4) ]]; then
      cf_tls_say "$dry" "- Cloudflare TLS: skipped (no Cloudflare ranges in ${ranges}; run /etc/nginx/scripts/cloudflare.sh)"
      return 0
    fi
    list=""; keep_names=()
    mapfile -t blocks < <(cf_tls_server_blocks "$f")
    for b in "${blocks[@]}"; do
      IFS=$'\t' read -r idx el names <<<"$b"
      [[ $el == 1 ]] || continue
      ok=1; checked=()
      # read -a: no pathname expansion, so a wildcard name such as
      # *.example.com is never matched against files in the current directory.
      local -a name_list=()
      read -ra name_list <<<"$names"
      for name in "${name_list[@]}"; do
        case $name in
          _|localhost|'""') continue ;;
        esac
        # Exact host names only: a wildcard, regex, `.suffix`, variable or
        # IP literal cannot be proved to sit behind Cloudflare.
        if [[ ! ${name,,} =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ \
              || $name =~ ^[0-9.]+$ ]]; then
          ok=0; break
        fi
        cf_tls_name_behind_cloudflare "$name" "$ranges" || { ok=0; break; }
        checked+=("$name")
      done
      (( ok && ${#checked[@]} > 0 )) || continue
      list+="${list:+,}${idx}"
      keep_names+=("${checked[@]}")
    done
    [[ -n $list ]] || continue
    if (( dry )); then
      # Simulate on a copy so the certbot line below tells the truth.
      copy=$(tmp_file) || return 1
      cp -p -- "$f" "$copy"
      if cf_tls_rewrite_blocks "$copy" "$list" && ! cf_tls_file_uses_letsencrypt "$copy"; then
        CF_TLS_DRY_FULL+=("$f")
      fi
      rm -f -- "$copy"
      printf '  Cloudflare TLS: would point %s (%s) at the host self-signed certificate\n' \
        "${f#"$target"/}" "${keep_names[*]}"
      continue
    fi
    orig=$(tmp_file) || return 1
    cp -p -- "$f" "$orig"
    if cf_tls_rewrite_blocks "$f" "$list"; then
      CF_TLS_FILES+=("$f"); CF_TLS_ORIG+=("$orig"); CF_TLS_NAMES+=("${keep_names[*]}")
    else
      cat -- "$orig" > "$f"
      rm -f -- "$orig"
      opt_report "- Cloudflare TLS: could not rewrite \`${f}\`; left unchanged"
    fi
  done
  return 0
}

# After the reload: prove each migrated name through Cloudflare
# (cf_tls_probe).  Any name without the proof puts its vhost back byte for
# byte, with the keep marker on top so later runs leave it alone, and
# reloads.  Then certbot is retired when nothing needs it.
cloudflare_tls_finish() {
  local dry=${1:-0} i name status restored=0 bad
  if (( ! dry )); then
    for i in "${!CF_TLS_FILES[@]}"; do
      bad=""
      for name in ${CF_TLS_NAMES[i]}; do
        status=$(cf_tls_probe "$name") || bad+="${bad:+ }${name}(${status:-000})"
      done
      if [[ -n $bad ]]; then
        {
          printf '%s (no proof through Cloudflare that the origin answered with the self-signed certificate: %s; "Full (strict)", a challenge/WAF rule or a redirect on the probe path? Delete this line to let --optimize retry)\n' \
            "$CF_TLS_KEEP_MARKER" "$bad"
          cat -- "${CF_TLS_ORIG[i]}"
        } > "${CF_TLS_FILES[i]}"
        restored=1
        opt_report "- **FAILED** Cloudflare TLS: \`${CF_TLS_FILES[i]}\` put back on its certificate and marked to keep it; no proof through Cloudflare for ${bad} (a 526 means SSL mode \"Full (strict)\": set \"Full\", or keep a trusted certificate)"
      else
        opt_report "- Cloudflare TLS: \`${CF_TLS_FILES[i]}\` (${CF_TLS_NAMES[i]}) now uses the host self-signed certificate; Cloudflare reached the origin with it (probe location /.setup-cf-tls-probe-* added)"
      fi
      rm -f -- "${CF_TLS_ORIG[i]}"
    done
    if (( restored )); then
      if "${NGINX_BIN:-$NGINX_WEB_BIN_DEFAULT}" -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null; then
        opt_report "- Cloudflare TLS: restored vhost(s) reloaded"
      else
        opt_report "- **FAILED** Cloudflare TLS: reload after the restore failed; check \`nginx -t\`"
      fi
    fi
  fi
  certbot_retire_if_unused "$dry"
}

# docker with a time limit (tests replace this function).
cf_tls_docker() { timeout 20 docker "$@"; }

# Everything outside the certbot tree that may depend on it, one per line;
# it stops at the first one found (one is enough to keep certbot).  Returns
# 2 (fail closed) when the loaded nginx configuration cannot be read.
#   - the loaded nginx configuration (nginx -T; comments dropped)
#   - renewal hooks (scripts, or hook settings in renewal/*.conf): certbot
#     then feeds another service
#   - containers with a mount from the tree (docker inspect)
#   - any non-comment /etc/letsencrypt/ reference (dhparam files count, not
#     only certificates) in text files up to 1 MB under /etc, /opt, /srv,
#     /usr/local, /root, /home and the crontabs, plus config-like files near
#     the top of /var/www; one filesystem each, no node_modules/.git/vendor,
#     AppArmor policy skipped (read rules there are not consumers)
#   - symlinks into the tree under the same roots
certbot_letsencrypt_users() {
  local etc=${CERTBOT_ETC:-/etc} le=${CERTBOT_DIR:-/etc/letsencrypt}
  local nginx_bin=${NGINX_BIN:-$NGINX_WEB_BIN_DEFAULT} dump root lnk hit hook
  # The setup.sh state tree holds vhost copies that are put back live later;
  # they count as consumers too.
  local -a roots=("$etc") extra=(/opt /srv /usr/local /root /home /var/spool/cron "${STATE_DIR:-/var/lib/setup.sh}")
  [[ -n ${CERTBOT_EXTRA_ROOTS+x} ]] && read -ra extra <<<"$CERTBOT_EXTRA_ROOTS"
  roots+=("${extra[@]}")
  if [[ -x $nginx_bin ]] || declare -F "$nginx_bin" >/dev/null; then
    dump=$("$nginx_bin" -T 2>/dev/null) || return 2
    grep -q '^# configuration file ' <<<"$dump" || return 2
    hit=$(awk '
      /^# configuration file / { f = $4; sub(/:$/, "", f); next }
      { s = $0; sub(/#.*/, "", s); if (s ~ /\/etc\/letsencrypt([\/:" \t;]|$)/) { print f; exit } }' <<<"$dump")
    [[ -n $hit ]] && { printf '%s\n' "$hit"; return 0; }
  fi
  for hook in "$le"/renewal-hooks/pre/* "$le"/renewal-hooks/deploy/* "$le"/renewal-hooks/post/*; do
    [[ -e $hook || -L $hook ]] && { printf '%s\n' "$hook"; return 0; }
  done
  hit=$(grep -lsE '^[[:space:]]*(renew_hook|deploy_hook|pre_hook|post_hook)[[:space:]]*=' \
          "$le"/renewal/*.conf 2>/dev/null | head -n 1 || true)
  [[ -n $hit ]] && { printf '%s\n' "$hit"; return 0; }
  if command -v docker >/dev/null 2>&1; then
    # Bounded: a wedged daemon must not stall --optimize.  A daemon that
    # does not answer keeps certbot (its containers cannot be checked).
    local -a cids=()
    local ids
    if ! ids=$(cf_tls_docker ps -aq 2>/dev/null); then
      if systemctl is-active --quiet docker 2>/dev/null; then
        printf '%s\n' "docker:unreachable"; return 0
      fi
      ids=""
    fi
    mapfile -t cids < <(printf '%s\n' "$ids" | sed '/^$/d')
    if (( ${#cids[@]} > 0 )); then
      hit=$(cf_tls_docker inspect -f '{{.Name}} {{range .Mounts}}{{.Source}} {{end}}' "${cids[@]}" 2>/dev/null \
              | awk -v le="$le" '{ for (i = 2; i <= NF; i++) if ($i == le || index($i, le "/") == 1) { print "docker:" $1; exit } }' || true)
      [[ -n $hit ]] && { printf '%s\n' "$hit"; return 0; }
    fi
  fi
  # Copies of this project (the running checkout, fleet-update's dated
  # previous checkouts) quote /etc/letsencrypt in lib/web.sh and the
  # changelog, and run logs quote it in report lines: none of them reads the
  # tree, and counting them kept certbot on every fleet host.  A project
  # copy is a directory holding both setup.sh and lib/web.sh.  An nginx
  # configuration tree outside /etc/nginx (a server-configs-nginx checkout:
  # nginx.conf next to conf.d/templates, whose samples name certbot paths)
  # is not loaded; the loaded configuration is read through `nginx -T` above.
  # A checkout of the 1.21 tree (SCN main) has angie.conf there instead.
  local -a own=() own_prune=()
  local d
  for root in "${roots[@]}"; do
    [[ -d $root ]] || continue
    while IFS= read -r -d '' d; do
      case $d in
        */lib/web.sh) d=${d%/lib/web.sh}; [[ -f $d/setup.sh ]] && own+=("$d") ;;
        */conf.d/templates) d=${d%/conf.d/templates}; [[ -f $d/nginx.conf || -f $d/angie.conf ]] && own+=("$d") ;;
      esac
    done < <(find "$root" -xdev -maxdepth 4 \( -path '*/lib/web.sh' -type f \
               -o -path '*/conf.d/templates' -type d \) -print0 2>/dev/null || true)
  done
  for d in "${own[@]}"; do own_prune+=(-o -path "$d"); done
  for root in "${roots[@]}"; do
    [[ -d $root ]] || continue
    hit=$(find "$root" -xdev \( -path "$le" -o -path "$etc/nginx" -o -path "$etc/apparmor.d" \
              -o -name node_modules -o -name .git -o -name vendor "${own_prune[@]}" \) -prune \
            -o -type f -size -1024k ! -name '*.dpkg-*' ! -name '*.bak' ! -name '*~' ! -name '*.log' -print0 2>/dev/null \
          | xargs -0 -r grep -lIE "$CF_TLS_LE_ERE" 2>/dev/null | head -n 1 || true)
    [[ -n $hit ]] && { printf '%s\n' "$hit"; return 0; }
    while IFS= read -r lnk; do
      case $(readlink -f -- "$lnk" 2>/dev/null || true) in
        "$le"|"$le"/*) printf '%s\n' "$lnk"; return 0 ;;
      esac
    done < <(find "$root" -xdev \( -path "$le" -o -name node_modules -o -name .git \) -prune \
               -o -type l -print 2>/dev/null || true)
  done
  if [[ -d ${CERTBOT_WWW:-/var/www} ]]; then
    hit=$(find "${CERTBOT_WWW:-/var/www}" -xdev -maxdepth 3 -type f \
            \( -name '.env' -o -name '*.env' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' \
               -o -name '*.conf' -o -name '*.ini' -o -name '*.toml' -o -name '*.config.js' \) \
            -size -1024k -print0 2>/dev/null \
          | xargs -0 -r grep -lIE "$CF_TLS_LE_ERE" 2>/dev/null | head -n 1 || true)
    [[ -n $hit ]] && { printf '%s\n' "$hit"; return 0; }
  fi
  return 0
}

# Purge certbot when it is installed and nothing can still depend on it.
# The tree moves to a dated directory under /var/backups (mode 0700; /tmp
# is emptied at boot and would lose the account and private keys) and
# comes back if the purge fails.  Otherwise say why certbot stays, and warn
# when its renewals cannot run.
certbot_retire_if_unused() {
  local dry=${1:-0} pkg moved="" le=${CERTBOT_DIR:-/etc/letsencrypt} out u k dest
  local -a pkgs=() users=() left=()
  [[ ${CF_SELF_SIGNED:-1} != 0 ]] || return 0
  while IFS= read -r pkg; do [[ -n $pkg ]] && pkgs+=("$pkg"); done < <(
    dpkg-query -W -f='${Package} ${Status}\n' 'certbot' 'python3-certbot*' 2>/dev/null \
      | awk '$NF == "installed" { print $1 }' || true)
  (( ${#pkgs[@]} > 0 )) || return 0
  if ! out=$(certbot_letsencrypt_users); then
    cf_tls_say "$dry" "- certbot: kept; the loaded nginx configuration could not be read (nginx -T failed)"
    return 0
  fi
  mapfile -t users < <(printf '%s\n' "$out" | sed '/^$/d' | sort -u)
  if (( dry && ${#CF_TLS_DRY_FULL[@]} > 0 )); then
    for u in "${users[@]}"; do
      for k in "${CF_TLS_DRY_FULL[@]}"; do [[ $u == "$k" ]] && continue 2; done
      left+=("$u")
    done
    users=("${left[@]}")
    # The scan stops at its first hit; with that hit planned away, look
    # again past it in the real run instead of promising a purge here.
    if (( ${#users[@]} == 0 )) && [[ -n $out ]]; then
      printf '  certbot: purged after the move if nothing else uses %s (checked again after the reload)\n' "$le"
      return 0
    fi
  fi
  if (( ${#users[@]} > 0 )); then
    cf_tls_say "$dry" "- certbot: kept; ${le} is still used by ${users[*]}"
    certbot_renewal_health "$dry"
    return 0
  fi
  if (( dry )); then
    printf '  certbot: would be purged (%s); nothing uses %s\n' "${pkgs[*]}" "$le"
    return 0
  fi
  if [[ -d $le ]]; then
    # mktemp -d: unique even for two runs in one second, and mode 0700.
    dest=$(mktemp -d "${CERTBOT_BACKUP_ROOT:-/var/backups}/setup-letsencrypt-$(date +%Y%m%d-%H%M%S)-XXXX" 2>/dev/null) || dest=""
    if [[ -n $dest ]] && mv -- "$le" "$dest/" 2>/dev/null; then
      moved="$dest/$(basename -- "$le")"
    else
      opt_report "- certbot: kept; could not move ${le} under ${CERTBOT_BACKUP_ROOT:-/var/backups}"
      return 0
    fi
  fi
  if DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}" >/dev/null 2>&1; then
    systemctl reset-failed certbot.service certbot.timer >/dev/null 2>&1 || true
    opt_report "- certbot: purged (${pkgs[*]}); nothing uses ${le}${moved:+; the old tree (account and keys) is kept in \`${moved}\`}. Leftover libraries go with the next \`apt autoremove\`"
  else
    if [[ -n $moved ]]; then mv -- "$moved" "$le" 2>/dev/null || true; fi
    opt_report "- **FAILED** certbot purge (apt-get); ${le} put back"
  fi
  return 0
}

# A renewal that names the nginx plugin cannot run on an nginx host without
# python3-certbot-nginx: say so, with the certificate end date.
certbot_renewal_health() {
  local dry=${1:-0} conf name end le=${CERTBOT_DIR:-/etc/letsencrypt}
  if dpkg-query -W -f='${Status}' python3-certbot-nginx 2>/dev/null | grep -q 'ok installed'; then
    return 0
  fi
  for conf in "$le"/renewal/*.conf; do
    [[ -f $conf ]] || continue
    grep -qE '^[[:space:]]*(authenticator|installer)[[:space:]]*=[[:space:]]*nginx' "$conf" || continue
    name=$(basename -- "$conf" .conf)
    end=$(openssl x509 -noout -enddate -in "${le}/live/${name}/cert.pem" 2>/dev/null | cut -d= -f2 || true)
    cf_tls_say "$dry" "- **WARNING** certbot: \`${name}\` renews with the nginx plugin, which is not installed (nginx host); renewal fails${end:+, the certificate ends ${end}}. Put the site behind Cloudflare (self-signed origin) or use nginx's ACME client"
  done
  return 0
}

# Names a file defines that would clash if it were loaded next to another
# one: cache zones, limit_req zones and map target variables, one per line.
nginx_http_defined_names() {
  sed -E 's/#.*//' "$@" 2>/dev/null | awk '
    { for (i = 1; i <= NF; i++) {
        if ($i ~ /^keys_zone=/) { v = $i; sub(/^keys_zone=/, "", v); sub(/:.*/, "", v); print "zone:" v }
        else if ($i ~ /^zone=/ && $0 ~ /limit_req_zone/) { v = $i; sub(/^zone=/, "", v); sub(/:.*/, "", v); print "zone:" v }
      }
      if ($1 == "map" && $3 ~ /^\$/) { v = $3; sub(/[{;].*/, "", v); print "var:" v }
    }' | sort -u
}

# Old setup.sh releases generated http.d/zz-setup-*_conf files (inactive:
# nginx.conf includes only *.conf) whose content later moved into active
# files.  --optimize then reported them as "not included" with the advice to
# re-run the deployment, which never changed anything; activating one would
# even break `nginx -t` with a duplicate zone (zz-setup-wordpress-cache_conf
# redefines keys_zone=fastcgicache, live host 2026-11-20).  An inactive
# zz-setup-* file is retired (moved to /tmp, never deleted) only when every
# zone and map variable it defines is already defined by a loaded file.
tune_retire_superseded_setup_files() {
  local target=$1 f name moved
  local -a active=()
  mapfile -t active < <(nginx_active_http_files "$target")
  (( ${#active[@]} > 0 )) || return 0
  local defined
  defined=$(nginx_http_defined_names "${active[@]}")
  for f in "$target"/http.d/zz-setup-*; do
    [[ -f $f && $f != *.conf ]] || continue
    local -a mine=()
    mapfile -t mine < <(nginx_http_defined_names "$f")
    (( ${#mine[@]} > 0 )) || continue
    local superseded=1
    for name in "${mine[@]}"; do
      grep -qxF -- "$name" <<<"$defined" || { superseded=0; break; }
    done
    (( superseded )) || continue
    moved=$(preserve_to_tmp "$f") || continue
    [[ -n $moved ]] || continue
    info "Retired superseded ${f#"$target"/} -> ${moved} (not deleted; its zones/maps are defined by loaded files)"
    tune_note "${f#"$target"/}: superseded legacy file retired to ${moved}"
  done
  return 0
}

# server-configs-nginx 1.6.43-1.6.45 shipped
# `if ($flarum_guest_cacheable$req_encoded_path)` in h5bp/php_flarum.conf.
# An `if` reads a lone variable, so nginx looks up a variable literally named
# "flarum_guest_cacheable$req_encoded_path" and `nginx -t` fails for every
# Flarum vhost.  The encoded-path flag moves into the map (one 0/1 variable,
# as XenForo/Chevereto do) and a missing background cache update is added.
tune_flarum_cache_gate() {
  local target=$1 inc map before_inc tmp
  inc="$target/h5bp/php_flarum.conf"
  map="$target/http.d/fastcgi_cache_flarum.conf"
  [[ -f $inc ]] || return 0
  before_inc=$(file_md5 "$inc")
  if grep -qF 'if ($flarum_guest_cacheable$req_encoded_path)' "$inc" && [[ -f $map ]]; then
    # Rewrite the map on a copy; both files change only when the copy has
    # the shipped layout (an operator-edited map is left alone).
    tmp=$(tmp_file)
    sed -e 's/^map "\$guest_cache_method:\$flarum_guest_cookie:\$flarum_nocache_uri:\$http_authorization" \$flarum_guest_cacheable {$/map "$guest_cache_method:$flarum_guest_cookie:$flarum_nocache_uri:$req_encoded_path:$http_authorization" $flarum_guest_cacheable {/' \
        -e 's/^\([[:space:]]*\)"1:0:0:" 1;$/\1"1:0:0:0:" 1;/' "$map" > "$tmp"
    if grep -qF ':$req_encoded_path:$http_authorization" $flarum_guest_cacheable' "$tmp" \
       && grep -qF '"1:0:0:0:" 1;' "$tmp"; then
      cat "$tmp" > "$map"
      sed_in_place 's/if (\$flarum_guest_cacheable\$req_encoded_path)/if ($flarum_guest_cacheable)/' "$inc"
    else
      tune_miss "Flarum guest-cache map not recognised; fix the if (\$flarum_guest_cacheable...) line in h5bp/php_flarum.conf by hand"
    fi
  fi
  if grep -qE '^[[:space:]]*fastcgi_cache_lock[[:space:]]+on;' "$inc" \
     && ! grep -qE '^[[:space:]]*fastcgi_cache_background_update' "$inc"; then
    tune_insert_after "$inc" '^[[:space:]]*fastcgi_cache_lock[[:space:]]+on;' \
      'fastcgi_cache_background_update on;' \
      "php_flarum.conf: background cache update"
  fi
  if [[ $(file_md5 "$inc") != "$before_inc" ]]; then
    tune_note "php_flarum.conf: guest-cache gate is one 0/1 variable; background cache update"
  fi
  return 0
}

tune_xf_cache_vary() {
  local file=$1
  [[ -f $file ]] || return 0
  local before tmp
  before=$(file_md5 "$file")
  if grep -qE '^[[:space:]]*fastcgi_cache_key[[:space:]]' "$file"; then
    tmp=$(tmp_file)
    # A key built from validated tokens (the repository's $xf_key_* or this
    # script's $setup_xf_key_* maps) is left alone.  Any other key, including
    # the forms that appended raw $cookie_xf_* values, is replaced.
    awk -v key="$XF_CACHE_KEY" '
      /^[[:space:]]*fastcgi_cache_key[[:space:]]/ && index($0, "xf_key_language") == 0 {
        match($0, /^[[:space:]]*/)
        print substr($0, 1, RLENGTH) "fastcgi_cache_key " key ";"
        next
      }
      { print }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
  fi
  if grep -qE '^[[:space:]]*fastcgi_cache_lock[[:space:]]+on;' "$file" \
     && ! grep -qE '^[[:space:]]*fastcgi_cache_background_update' "$file"; then
    tune_insert_after "$file" '^[[:space:]]*fastcgi_cache_lock[[:space:]]+on;' \
      'fastcgi_cache_background_update on;' \
      "$(basename "$file"): background cache update"
  fi
  if [[ $(file_md5 "$file") != "$before" ]]; then
    tune_note "$(basename "$file"): cache key varies on style/language/encoding"
  fi
  return 0
}

# XenForo serves its own JS/CSS/images from /js, /styles and /data.  The
# generated vhost only limits the methods, so browsers revalidate every asset.
# Add one immutable, 30-day regex location (regex beats the existing prefix
# blocks).  Idempotent and re-applied after the repository sync on every run.
tune_xf_static_assets() {
  local file=${1:-/etc/nginx/h5bp/xf2.conf}
  [[ -f $file ]] || { tune_miss "XenForo include missing: ${file}"; return 0; }
  grep -q 'setup.sh: static asset cache' "$file" && return 0
  local tmp
  tmp=$(tmp_file) || return 1
  awk '
    /^[[:space:]]*### End Xenforo/ && !done {
      print "    # setup.sh: static asset cache (XenForo /js, /styles, /data)"
      print "    location ~* ^/(?:js|styles|data)/(?:.*\\.(?:js|css|png|jpe?g|gif|svg|webp|avif|woff2?|ttf|eot|ico))$ {"
      print "        # One Cache-Control header: `expires` would add a second one."
      print "        expires off;"
      print "        add_header Cache-Control \"public, max-age=2592000, immutable\";"
      print "        # add_header and a regex location replace the inherited header set and"
      print "        # the method limits of the /data/, /js/ and /styles/ prefix blocks."
      print "        include h5bp/security/x-content-type-options.conf;"
      print "        include h5bp/security/strict-transport-security.conf;"
      print "        limit_except GET OPTIONS { deny all; }"
      print "        access_log off;"
      print "        try_files $uri =404;"
      print "    }"
      print ""
      done = 1
    }
    { print }
  ' "$file" > "$tmp"
  commit_if_changed "$file" "$tmp" \
    && tune_note "$(basename "$file"): static assets cached 30d (immutable)"
  return 0
}

# Directives that may appear only once in the http context.  A custom
# http.d file (for example zz-site-e-ratelimit.conf) can predate the canonical
# limit_req.conf and carry its own limit_req_status/limit_req_log_level; the
# repository sync then makes `nginx -t` fail with "directive is duplicate"
# and the whole tree rolls back.  Keep the canonical definition and comment
# the operator copy with a marker; --optimize already snapshots /etc/nginx.
# Vhosts rendered from the XenForo and Chevereto templates before
# server-configs-nginx 1.6.26 carry an unanchored route location:
# "^/(admin.php|install)" also claims /install.sh or /install.log and
# "^/(dashboard|update)" claims /update.log, ahead of the file-access deny
# rules, and serves the file.  Existing vhosts are operator-owned and are not
# re-rendered, so anchor exactly those two generated lines in place.
tune_vhost_route_anchors() {
  local target=${1:-/etc/nginx} file tmp
  [[ -f $target/h5bp/location/security_leftover_files.conf ]] || return 0
  for file in "$target"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    grep -qF -e 'location ~ ^/(admin.php|install) {' \
             -e 'location ~ ^/(dashboard|update) {' "$file" || continue
    tmp=$(tmp_file) || return 1
    awk '
      function anchored(old, new,    at, ind) {
        at = index($0, old)
        if (!at) return 0
        ind = substr($0, 1, at - 1)
        print ind new
        print ind "    include h5bp/location/security_leftover_files.conf;"
        return 1
      }
      anchored("location ~ ^/(admin.php|install) {", "location ~ ^/(?:admin\\.php$|install(?:/|$)) {") { next }
      anchored("location ~ ^/(dashboard|update) {", "location ~ ^/(?:dashboard|update)(?:/|$) {") { next }
      { print }
    ' "$file" > "$tmp"
    commit_if_changed "$file" "$tmp" \
      && tune_note "$(basename "$file"): route location anchored (leftover files no longer served)"
  done
  return 0
}

# The QUIC catch-all (conf.d/1.https.default.conf, server-configs-nginx
# 1.7.4) sets reuseport rcvbuf=4m sndbuf=4m on UDP 443.  nginx accepts socket
# options on only one listen per address, so a vhost made from an older
# template or the pre-1.7.4 h5bp/tls/http3.conf (`listen 443 quic
# reuseport;`) fails nginx -t with "duplicate listen options" after the
# sync.  Strip the socket options from such operator lines (every *.conf
# under conf.d/, templates included, never the managed catch-all) and keep
# the original line as a '# setup.sh: ' comment above it.  Not the
# '# setup-nginx-build-off: ' marker: `nginx-build.sh restore` uncomments
# that one, which would bring the duplicate back.  MODE scan prints
# FILE:LINE for each line that still carries options and changes nothing.
NGINX_QUIC_OPTS_MARK='# setup.sh: QUIC socket options are set by conf.d/1.https.default.conf: '
_nginx_quic_listen_awk() { # mode file
  awk -v mode="$1" -v mark="$NGINX_QUIC_OPTS_MARK" '
    function keep() { if (mode != "scan") print }
    {
      semi = index($0, ";")
      if ($0 !~ /^[[:space:]]*listen[[:space:]]/ || !semi) { keep(); next }
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
      body = substr($0, RLENGTH + 1, semi - RLENGTH - 1); rest = substr($0, semi)
      n = split(body, t, /[[:space:]]+/)
      if (n < 3 || t[2] !~ /(^|:)443$/) { keep(); next }
      q = 0
      for (i = 3; i <= n; i++) if (t[i] == "quic") q = 1
      if (!q) { keep(); next }
      out = t[1] " " t[2]; dropped = 0
      for (i = 3; i <= n; i++) {
        if (t[i] == "") continue
        if (t[i] ~ /^(reuseport|deferred|bind)$/ \
            || t[i] ~ /^(rcvbuf|sndbuf|backlog|fastopen|so_keepalive|ipv6only)=/) { dropped = 1; continue }
        out = out " " t[i]
      }
      if (!dropped) { keep(); next }
      if (mode == "scan") { print FILENAME ":" FNR; next }
      print ind mark substr($0, length(ind) + 1)
      print ind out rest
    }
  ' "$2"
}

tune_vhost_quic_listen_options() {
  local target=${1:-/etc/nginx} file tmp
  [[ -d $target/conf.d ]] || return 0
  while IFS= read -r file; do
    [[ $file == "$target/conf.d/1.https.default.conf" ]] && continue
    grep -qE '^[[:space:]]*listen[[:space:]][^#]*quic' "$file" 2>/dev/null || continue
    tmp=$(tmp_file) || return 1
    _nginx_quic_listen_awk fix "$file" > "$tmp" || continue
    if commit_if_changed "$file" "$tmp"; then
      info "nginx: ${file#"$target"/}: QUIC listen socket options removed (set by the catch-all in conf.d/1.https.default.conf; original kept as a comment)"
      tune_note "${file#"$target"/}: HTTP/3 listen socket options removed (owned by the QUIC catch-all)"
    fi
  done < <(find "$target/conf.d" -type f -name '*.conf' 2>/dev/null | sort)
  return 0
}

# HTTP/3 on by default (1.22.5, server-configs-nginx 1.7.4): the templates
# include h5bp/tls/http3.conf in every TLS server; existing vhosts get the
# same line from --optimize.  A server block qualifies when it listens on
# plain 443 (or [::]:443) with ssl, has no QUIC listen of its own and no
# http3.conf include, active or commented out.  Commenting the include out
# (`#include h5bp/tls/http3.conf;`) keeps HTTP/3 off for that vhost; a deleted
# line comes back on the next run.  Only top-level conf.d/*.conf files are
# edited (not the catch-alls, not templates/, which the sync owns).
NGINX_HTTP3_MARK='# setup.sh: HTTP/3 on by default; comment this line out to turn it off'
_nginx_http3_include_awk() { # file
  awk -v mark="$NGINX_HTTP3_MARK" '
    function code(s) { sub(/#.*/, "", s); return s }
    function opens(s,   t) { t = code(s); return gsub(/\{/, "{", t) }
    function closes(s,   t) { t = code(s); return gsub(/\}/, "}", t) }
    function flush(   i, last, tls, quic, inc, n, tok, j, ssl, port) {
      tls = 0; quic = 0; inc = 0; last = 0
      for (i = 1; i <= nb; i++) {
        if (buf[i] ~ /^[[:space:]]*#?[[:space:]]*include[[:space:]]+h5bp\/tls\/http3\.conf;/) inc = 1
        if (bdepth[i] != 1 || code(buf[i]) !~ /^[[:space:]]*listen([[:space:]]|$)/) continue
        # A listen directive continued on the next line: inserting after
        # this line would split it, so leave the whole server block alone.
        if (index(code(buf[i]), ";") == 0) { quic = 1; continue }
        n = split(code(buf[i]), tok, /[[:space:];]+/)
        ssl = 0; port = ""
        for (j = 1; j <= n; j++) {
          if (tok[j] == "listen" && port == "") { port = tok[j + 1] }
          if (tok[j] == "quic") quic = 1
          if (tok[j] == "ssl") ssl = 1
        }
        if (ssl && (port == "443" || port == "[::]:443")) { tls = 1; last = i }
      }
      for (i = 1; i <= nb; i++) {
        print buf[i]
        if (i == last && tls && !quic && !inc) {
          match(buf[i], /^[[:space:]]*/)
          print substr(buf[i], 1, RLENGTH) mark
          print substr(buf[i], 1, RLENGTH) "include h5bp/tls/http3.conf;"
        }
      }
      nb = 0
    }
    {
      if (!inserver && depth == 0 && code($0) ~ /^[[:space:]]*server[[:space:]]*\{/) { inserver = 1 }
      if (inserver) { nb++; buf[nb] = $0; bdepth[nb] = depth }
      else print
      depth += opens($0) - closes($0)
      if (inserver && depth <= 0) { depth = 0; inserver = 0; flush() }
    }
    END { if (nb) for (i = 1; i <= nb; i++) print buf[i] }
  ' "$1"
}

# FILE... -> the files under TARGET/conf.d (top level) the HTTP/3 default
# would change.  Read-only.
nginx_http3_candidates() {
  local target=${1:-/etc/nginx} file tmp
  [[ -f $target/h5bp/tls/http3.conf ]] || return 0
  for file in "$target"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    case ${file##*/} in 1.http.default.conf|1.https.default.conf) continue ;; esac
    grep -qE '^[[:space:]]*listen[[:space:]][^#;]*[[:space:]]ssl' "$file" 2>/dev/null || continue
    tmp=$(tmp_file) || return 1
    _nginx_http3_include_awk "$file" > "$tmp" || continue
    cmp -s "$file" "$tmp" || printf '%s\n' "$file"
  done
  return 0
}

# Add the include to every qualifying vhost, but only on a tree that passes
# nginx -t before and after: the edit is undone (inode kept) when the test
# fails afterwards, so an unusual vhost (an indirect QUIC listen, an
# address-specific 443 elsewhere) can never block --optimize.
tune_vhost_http3_default() {
  local target=${1:-/etc/nginx} file tmp bak
  local -a files=() baks=()
  mapfile -t files < <(nginx_http3_candidates "$target")
  (( ${#files[@]} )) || return 0
  if ! nginx_test_tree "$target/nginx.conf" >/dev/null 2>&1; then
    tune_note "nginx: HTTP/3 not added to ${#files[@]} vhost(s): the tree fails nginx -t without it"
    return 0
  fi
  for file in "${files[@]}"; do
    tmp=$(tmp_file) || return 1
    bak=$(tmp_file) || return 1
    cat "$file" > "$bak"
    _nginx_http3_include_awk "$file" > "$tmp" && cat "$tmp" > "$file"
    baks+=("$bak")
  done
  if nginx_test_tree "$target/nginx.conf" >/dev/null 2>&1; then
    for file in "${files[@]}"; do
      tune_note "${file#"$target"/}: HTTP/3 enabled (include h5bp/tls/http3.conf; comment it out to turn it off)"
    done
    return 0
  fi
  local i
  for i in "${!files[@]}"; do cat "${baks[$i]}" > "${files[$i]}"; done
  warn "nginx: adding HTTP/3 (h5bp/tls/http3.conf) made nginx -t fail; ${#files[@]} vhost(s) left unchanged: ${files[*]#"$target"/}"
  return 0
}

# After a failed nginx -t: name every listen line under TARGET (outside the
# catch-all) that still sets socket options on QUIC 443, so the failure says
# what to edit instead of only "configuration test failed".
nginx_quic_listen_conflicts() {
  local target=${1:-/etc/nginx} file
  while IFS= read -r file; do
    [[ $file == "$target/conf.d/1.https.default.conf" ]] && continue
    grep -qE '^[[:space:]]*listen[[:space:]][^#]*quic' "$file" 2>/dev/null || continue
    _nginx_quic_listen_awk scan "$file"
  done < <(find "$target" -type f -name '*.conf' 2>/dev/null | sort)
  return 0
}

# server-configs-nginx 1.6.48 moved every deny rule of the four application
# includes into one regex location per application
# (h5bp/location/security_{xf,wp,chev,flarum}.conf, included by
# php_xf.conf, php_wp.conf, php_chev_cache.conf/php_chev.conf and
# php_flarum.conf).  Existing vhosts were rendered from the older templates
# and still include the full basic*.conf (about twenty more regex locations
# per request, tried twice) plus template blocks that only repeat what the
# new rule does.  Bring a vhost onto the lean chain only where that is
# provably safe:
#   * basic_xf.conf / basic_flarum.conf / basic.conf become their
#     header-only twins only when the same server block includes the app's
#     PHP file directly (depth 1), so the new deny regex is in force there;
#     a vhost whose PHP include was nested or rewritten to php.conf keeps
#     the full set and is reported.
#   * the XenForo template's admin.php|install block and the Chevereto
#     template's app/importing/composer lines, dashboard|update block and
#     CHEVERETO_LICENSE_KEY block are removed only in their shipped shape
#     (comments, the security_* includes and php.conf/php_chev.conf only);
#     a block with active auth_basic or other directives is kept.
#   * the Chevereto /images/ nested denies are folded into one allowlist
#     regex (a media extension on a path without "/."), which refuses
#     everything the two deny lines refused.
# Unchanged vhosts keep working and keep every deny rule; they only pay the
# extra regex calls.  Every change is behind the caller's nginx -t gate.
tune_vhost_lean_locations() {
  local target=${1:-/etc/nginx} file tmp name counts switched removed kept
  [[ -f $target/h5bp/location/security_xf.conf && -f $target/h5bp/basic_headers.conf ]] || return 0
  for file in "$target"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    name=${file##*/}
    grep -qE '^[[:space:]]*include[[:space:]]+h5bp/(basic(_xf|_flarum)?\.conf|php_(xf|wp|chev_cache|chev|flarum)\.conf);' "$file" || continue
    tmp=$(tmp_file) || return 1
    awk '
      function strip(s) { sub(/#.*/, "", s); return s }
      function braces(s,   t, a, b) { t = s; a = gsub(/{/, "{", t); t = s; b = gsub(/}/, "}", t); return a - b }
      function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
      # 1 when every directive of a removable route block is one the new
      # deny location already covers (no auth_basic, no nested location).
      function body_allowed(b,   parts, np, p, x) {
        if (index(b, "{") || index(b, "}")) return 0
        np = split(b, parts, ";")
        for (p = 1; p <= np; p++) {
          x = trim(parts[p])
          if (x == "") continue
          if (x ~ /^include[ \t]+h5bp\/(location\/security_(root_archives|leftover_files|backup_files)|php|php_chev)\.conf$/) continue
          if (x ~ /^try_files[ \t]/ || x == "internal") continue
          return 0
        }
        return 1
      }
      function route_opener(c) {
        return index(c, "location ~ ^/(?:admin\\.php$|install(?:/|$)) {") || index(c, "location ~ ^/(?:dashboard|update)(?:/|$) {") || index(c, "location /app/CHEVERETO_LICENSE_KEY {")
      }
      function flush(   i, j, k, line, code, depth, end, body, ok, inimg, imgopen, shape, imgstart, rest) {
        # Pass 1: what the block includes at depth 1, nested PHP includes, and
        # whether ^~ /images/ has exactly the shipped shape (deny, deny, media,
        # return 403).
        app = ""; nested = 0; depth = 0; imgopen = 0; imgok = 0; shape = ""
        for (i = 1; i <= n; i++) {
          code = strip(buf[i])
          if (depth == 1 && code ~ /^[ \t]*include[ \t]+h5bp\/php_xf\.conf;/) app = app " xf"
          if (depth == 1 && code ~ /^[ \t]*include[ \t]+h5bp\/php_flarum\.conf;/) app = app " flarum"
          if (depth == 1 && code ~ /^[ \t]*include[ \t]+h5bp\/php_(wp|chev_cache|chev)\.conf;/) app = app " generic"
          if (depth > 1 && code ~ /^[ \t]*include[ \t]+h5bp\/php(_xf|_wp|_chev_cache|_chev|_flarum)?\.conf;/) nested = 1
          if (depth == 1 && index(code, "location ^~ /images/ {")) { imgopen = 1; shape = ""; imgstart = i }
          else if (imgopen && depth == 2) {
            if (index(code, DENY1)) shape = shape "1"
            else if (index(code, DENY2)) shape = shape "2"
            else if (index(code, MEDIA)) shape = shape "3"
            else if (code ~ /^[ \t]*return[ \t]+403;[ \t]*$/) shape = shape "R"
            else if (code ~ /^[ \t]*location[ \t]/) shape = shape "X"
          }
          depth += braces(code)
          if (imgopen && i > imgstart && depth <= 1) { imgopen = 0; if (shape == "123R") imgok = 1 }
        }
        # Pass 2: emit with the edits.
        depth = 0; inimg = 0
        for (i = 1; i <= n; i++) {
          line = buf[i]; code = strip(line)
          if (depth == 1 && route_opener(code) && ((app ~ /xf/ && index(code, "admin")) || (app ~ /generic/ && !index(code, "admin")))) {
            if (braces(code) == 0) {
              # One-line block: its body is between the braces.
              rest = code; sub(/^[^{]*{/, "", rest); sub(/}[^}]*$/, "", rest)
              if (body_allowed(rest)) { removed++; continue }
            } else {
              k = depth + braces(code); body = ""; end = 0
              for (j = i + 1; j <= n; j++) {
                k += braces(strip(buf[j]))
                if (k <= depth) { end = j; break }
                body = body " " strip(buf[j])
              }
              if (end && body_allowed(body)) {
                print "    # setup.sh: route block removed (h5bp/location/security_*.conf covers it)"
                removed++
                i = end
                continue
              }
            }
          }
          if (depth == 1 && app ~ /generic/ && (index(code, "location ~ /(?:app|importing)/ { internal; }") || index(code, "location ~* /(app|content|lib)/.*\\.(po|php|lock|sql)$  { internal; }") || index(code, "location ~* /(?:composer\\.(?:json|lock)|\\.gitignore)$ { internal; }"))) {
            removed++
            continue
          }
          if (depth == 1 && app ~ /generic/ && index(line, "# app/ and importing/ are \"Require all denied\" upstream (.htaccess).")) continue
          if (depth == 1 && index(code, "location ^~ /images/ {")) inimg = 1
          if (inimg && imgok && app ~ /generic/ && depth == 2) {
            if (index(code, DENY1) || index(code, DENY2)) continue
            if (index(line, "# Nested deny: ^~ skips the server-level regex locations") || index(line, "# such as /images/.env or /images/x.sql would otherwise be served.")) continue
            if (index(code, MEDIA)) {
              match(line, /^[ \t]*/)
              print substr(line, 1, RLENGTH) "location ~* \"(?s)^(?!.*/\\.).*\\.(?:gif|jpg|jpe|jpeg|png|ico|webp|avif|avifs|jxl|heic|heif|apng|bmp|svg|mov|mp4|webm|mkv|m4v|avi|mp3|ogg|oga|opus|m4a|wav)$\" {"
              depth += braces(code)
              continue
            }
          }
          # basic*.conf -> header-only twin when the deny regex is in force.
          if (depth == 1 && code ~ /^[ \t]*include[ \t]+h5bp\/basic_xf\.conf;/ && app ~ /xf/) { sub(/basic_xf\.conf;/, "basic_xf_headers.conf;", line); switched++ }
          else if (depth == 1 && code ~ /^[ \t]*include[ \t]+h5bp\/basic_flarum\.conf;/ && app ~ /flarum/) { sub(/basic_flarum\.conf;/, "basic_flarum_headers.conf;", line); switched++ }
          else if (depth == 1 && code ~ /^[ \t]*include[ \t]+h5bp\/basic\.conf;/ && app ~ /generic/) { sub(/basic\.conf;/, "basic_headers.conf;", line); switched++ }
          else if (depth == 1 && code ~ /^[ \t]*include[ \t]+h5bp\/basic(_xf|_flarum)?\.conf;/ && nested) kept++
          print line
          depth += braces(code)
          if (inimg && depth <= 1) inimg = 0
        }
        n = 0
      }
      BEGIN {
        n = 0; inb = 0
        DENY1 = "location ~* /\\.(?!well-known/) { deny all; }"
        DENY2 = "location ~* \\.(?:env|bak|old|orig|sql|sql\\.gz|log|ini|conf|sh|php|phtml|phar)$ { deny all; }"
        MEDIA = "location ~* \\.(gif|jpg|jpe|jpeg|png|ico|webp|avif|avifs|jxl|heic|heif|apng|bmp|svg|mov|mp4|webm|mkv|m4v|avi|mp3|ogg|oga|opus|m4a|wav)$ {"
      }
      {
        code = strip($0)
        if (!inb && code ~ /^[ \t]*server[ \t]*{/) { inb = 1; d = 0; n = 0 }
        if (inb) {
          buf[++n] = $0
          d += braces(code)
          if (d <= 0) { flush(); inb = 0 }
          next
        }
        print
      }
      END {
        if (inb) flush()
        printf "%d %d %d\n", switched + 0, removed + 0, kept + 0 > "/dev/stderr"
      }
    ' "$file" > "$tmp" 2> "${tmp}.counts"
    counts=$(cat "${tmp}.counts" 2>/dev/null); rm -f "${tmp}.counts"
    read -r switched removed kept <<<"${counts:-0 0 0}"
    if commit_if_changed "$file" "$tmp"; then
      tune_note "${name}: lean deny chain (${switched} basic include(s) switched, ${removed} template rule(s) folded)"
    fi
    if (( kept > 0 )); then
      tune_miss "${name}: deny rules kept server-wide (the application PHP include is nested); only the per-request cost differs"
    fi
  done
  return 0
}

NGINX_SINGLE_HTTP_DIRECTIVES=(limit_req_status limit_conn_status
                              limit_req_log_level limit_conn_log_level
                              limit_req_dry_run limit_conn_dry_run)

tune_nginx_dedupe_http() {
  local target=${1:-/etc/nginx} directive file keep rel before
  local -a files=() hits=()
  [[ -d $target/http.d ]] || return 0
  mapfile -t files < <(find "$target/http.d" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)
  for directive in "${NGINX_SINGLE_HTTP_DIRECTIVES[@]}"; do
    hits=()
    for file in "${files[@]}"; do
      grep -qE "^[[:space:]]*${directive}[[:space:]]" "$file" 2>/dev/null || continue
      hits+=("$file")
    done
    (( ${#hits[@]} > 1 )) || continue
    # The repository's limit file owns the global limiter values; otherwise
    # keep the first file in include order (lexical in http.d).
    keep=${hits[0]}
    for file in "${hits[@]}"; do
      [[ ${file##*/} == limit_req.conf ]] && { keep=$file; break; }
    done
    rel=${keep#"$target"/}
    for file in "${hits[@]}"; do
      [[ $file == "$keep" ]] && continue
      before=$(file_md5 "$file")
      sed_in_place -E \
        "s|^([[:space:]]*)(${directive}[[:space:]].*)\$|\\1# setup.sh: duplicate \\2 (kept in ${rel})|" \
        "$file"
      [[ $(file_md5 "$file") != "$before" ]] \
        && info "nginx: commented duplicate ${directive} in ${file#"$target"/} (kept in ${rel})"
    done
  done
  return 0
}

# Record one KEY="VALUE" line in /etc/default/setup-tuning (the host file
# every run sources at startup), replacing an existing line for the key.
# Shared by every environment-supplied option that must survive a plain
# --optimize: the OPcache JIT mode, the Node.js major
# and the build modes.
persist_tuning_var() {
  local key=$1 value=$2 f=${SETUP_TUNING_FILE:-/etc/default/setup-tuning} line
  # SETUP_TUNING_FILE is a test hook (a temporary file); the production path
  # is only written as root.
  [[ ${EUID} -eq 0 || -n ${SETUP_TUNING_FILE:-} ]] || return 0
  # The host file is sourced as root on every run, so the value is written
  # shell-quoted (%q) rather than wrapped in double quotes: a value that
  # contains a quote, $(...) or a backtick (an operator typo in
  # SETUP_PHP_PAGE_GZIP, say) must stay data, not become a command.
  printf -v line '%s=%q' "$key" "$value"
  if [[ -f $f ]] && grep -qE "^${key}=" "$f"; then
    sed_in_place -E "s|^${key}=.*|$(sed_replacement_escape "$line")|" "$f"
  else
    printf '%s\n' "$line" >> "$f"
  fi
  chmod 644 "$f" 2>/dev/null || true
}

# Keep SETUP_XF_JOB_CRON in /etc/default/setup-tuning the same way.  Called
# from write_cron, which runs more than once per install, so the flag is
# cleared after the first write to keep the report to one line.
persist_xf_job_cron() {
  (( XF_JOB_CRON_PERSIST )) || return 0
  [[ ${EUID} -eq 0 ]] || return 0
  persist_tuning_var XF_JOB_CRON "$XF_JOB_CRON"
  XF_JOB_CRON_PERSIST=0
  tune_note "cron: XF_JOB_CRON=${XF_JOB_CRON} persisted in /etc/default/setup-tuning"
}

# Document root of an nginx vhost file ("" when none).  Shared by the
# WordPress/XenForo vhost scanners and the worker cap.
# A generated vhost can legitimately have no root directive (a redirect-only
# block or a generated terminator).  Under `set -e` with inherit_errexit a
# failing `grep -m1` inside the command substitution aborted the callers and
# printed false "[ERR] command failed ... sed" lines during --upgrade-php (the
# preflight walks every conf.d file, including those terminators), so the
# lookup is an awk that always succeeds.
nginx_vhost_root() {
  local root=""
  if [[ -r ${1:-} ]]; then
    root=$(awk '
      /^[[:space:]]*root[[:space:]]+/ {
        line = $0
        sub(/^[[:space:]]*root[[:space:]]+/, "", line)
        sub(/;.*/, "", line)
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    ' "$1" 2>/dev/null)
  fi
  root=${root%\"}; root=${root#\"}
  printf '%s' "${root%/}"
}

# True when an application's database host is this machine (loopback, a
# socket path, or the default empty value), i.e. its PHP workers spend the
# request on the CPU instead of waiting on a network round trip.
app_db_host_is_local() {
  local host=${1:-}
  host=${host#p:}
  case "$host" in
    ""|localhost|127.0.0.1|::1|/*|unix:*) return 0 ;;
    *) return 1 ;;
  esac
}

# Remove the FastCGI upstream keepalive cache from nginx.conf.  Every idle
# connection in that cache occupies one PHP-FPM worker (FPM waits on the open
# socket for the next request), and the cache is per nginx worker, so the
# total can reach keepalive x worker_processes and pin the whole FPM pool.
# A request that then lands on an nginx worker without a cached connection
# waits for keepalive_timeout (60 s upstream default) before a worker frees.
# Measured on the live XenForo origin: 4-7 of 64 non-cacheable /login
# requests stalled 60-112 s with keepalive 16; with the cache removed, 3 x
# 128 requests stayed at p99 33-38 ms / max 93 ms and p50 was unchanged.
nginx_disable_php_keepalive() {
  local file=${1:-} tmp
  [[ -n $file && -f $file ]] || return 0
  tmp=$(tmp_file) || return 1
  awk '
    /^[[:space:]]*upstream[[:space:]]+local_php[[:space:]]*\{/ { in_php = 1 }
    in_php && /^[[:space:]]*keepalive([[:space:]]|_timeout[[:space:]])/ { next }
    in_php && /^[[:space:]]*#[[:space:]]*Reuse enough idle FastCGI/ { next }
    in_php && /^[[:space:]]*\}/ { in_php = 0 }
    { print }
  ' "$file" > "$tmp" || return 1
  commit_if_changed "$file" "$tmp" \
    && tune_note "nginx.conf: removed the PHP upstream keepalive cache (idle connections pin FPM workers)"
  return 0
}

# `fastcgi_keep_conn on` only has an effect when an upstream keepalive cache
# exists (nginx's documentation requires the keepalive directive).  Set it to
# off in every PHP include so a future keepalive value cannot silently pin
# the pool again, and so an old config tree gets the same behaviour as the
# current repository default.
nginx_disable_php_keep_conn() {
  local target=${1:-/etc/nginx} file
  for file in "$target"/h5bp/php*.conf; do
    [[ -f $file ]] || continue
    # The current repository already ships `off`; only an old tree has
    # something to rewrite, and "nothing to do" is not a missed tune.
    grep -qE '^[[:space:]]*fastcgi_keep_conn[[:space:]]+on;' "$file" || continue
    tune_replace "$file" '^([[:space:]]*fastcgi_keep_conn[[:space:]]+)on;' '\1off;' \
      "${file#"$target"/}: fastcgi_keep_conn=off"
  done
  return 0
}

# Point the server of `upstream local_php` in nginx.conf at a PHP-FPM
# listen value (TCP host:port, bare port, or a Unix socket path).  Only that
# block is touched: another upstream may legitimately use a different socket.
# PHP-FPM's `listen = 9000` and wildcard listeners accept connections on the
# loopback address, which is what nginx must dial.  An empty or unrecognised
# value leaves the file alone.
nginx_local_php_follow_pool() {
  local conf=${1:-} listen=${2:-} addr tmp
  [[ -n $conf && -f $conf ]] || return 0
  if [[ $listen == /* ]]; then
    addr="unix:${listen}"
  elif [[ $listen =~ ^[0-9]+$ ]]; then
    addr="127.0.0.1:${listen}"
  elif [[ $listen =~ ^0\.0\.0\.0:([0-9]+)$ ]]; then
    addr="127.0.0.1:${BASH_REMATCH[1]}"
  elif [[ $listen =~ ^\[::\]:([0-9]+)$ ]]; then
    addr="[::1]:${BASH_REMATCH[1]}"
  elif [[ $listen =~ ^([0-9.]+|localhost|\[[0-9a-fA-F:]+\]):[0-9]+$ ]]; then
    addr=$listen
  else
    return 0
  fi
  tmp=$(tmp_file) || return 1
  awk -v addr="$addr" '
    /^[[:space:]]*upstream[[:space:]]+local_php[[:space:]]*\{/ { in_php = 1 }
    in_php && /^[[:space:]]*server[[:space:]]/ {
      sub(/server[[:space:]]+[^;[:space:]]+/, "server " addr)
    }
    in_php && /^[[:space:]]*\}/ { in_php = 0 }
    { print }
  ' "$conf" > "$tmp" || return 1
  commit_if_changed "$conf" "$tmp" \
    && tune_note "nginx.conf: local_php upstream -> ${addr} (the live PHP-FPM listener)"
  return 0
}

# Number of CPUs in a sysfs CPU list such as "0-3,8-11" (empty when not a list).
cpu_list_count() {
  local list=$1 part n=0 a b
  [[ $list =~ ^[0-9,-]+$ ]] || return 0
  local IFS=,
  for part in $list; do
    if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
      (( b >= a )) && n=$(( n + b - a + 1 ))
    elif [[ $part =~ ^[0-9]+$ ]]; then
      n=$(( n + 1 ))
    fi
  done
  (( n > 0 )) && printf '%s' "$n"
  return 0
}

# Why `worker_cpu_affinity auto` must not pin on this host (empty: pin).
# auto binds worker N to CPU N counting from 0, which is wrong when
#   - a cgroup CPU quota leaves fewer CPUs than the affinity mask allows
#     (the other services float while nginx sits on CPUs 0..N-1),
#   - a cpuset restricts the process to part of the online CPUs (nproc
#     honours the mask, so it cannot see this; the targets may lie outside
#     the set: sched_setaffinity EINVAL and floating workers),
#   - the host has more than one NUMA node (the numbering follows neither
#     node nor NIC locality).
# $1: effective CPUs (effective_cpus).  SETUP_SYS_CPU_ONLINE and
# SETUP_SYS_NODE_DIR point at fixtures in tests.  A normal host prints
# nothing, so nginx.conf keeps the template's line.
nginx_cpu_pin_block_reason() {
  local eff=$1 mask online="" nodes=0 f
  mask=$(unset OMP_NUM_THREADS OMP_THREAD_LIMIT; nproc 2>/dev/null || true)
  f=${SETUP_SYS_CPU_ONLINE:-/sys/devices/system/cpu/online}
  [[ -r $f ]] && online=$(cpu_list_count "$(tr -d '[:space:]' < "$f")")
  [[ -n $online ]] || online=$(nproc --all 2>/dev/null || true)
  if [[ $mask =~ ^[0-9]+$ && $eff =~ ^[0-9]+$ ]] && (( eff < mask )); then
    printf 'cgroup CPU quota'
    return 0
  fi
  if [[ $mask =~ ^[0-9]+$ && $online =~ ^[0-9]+$ ]] && (( mask < online )); then
    printf 'cpuset of %s of %s CPUs' "$mask" "$online"
    return 0
  fi
  # Only nodes with CPUs count: a memory-only node (CXL, some VMs) has an
  # empty cpulist and says nothing about worker locality.
  for f in "${SETUP_SYS_NODE_DIR:-/sys/devices/system/node}"/node[0-9]*; do
    [[ -d $f && -r $f/cpulist ]] || continue
    [[ -n $(tr -d '[:space:]' < "$f/cpulist") ]] && nodes=$(( nodes + 1 ))
  done
  if (( nodes > 1 )); then
    printf '%s NUMA nodes' "$nodes"
  fi
  return 0
}

tune_nginx_configs() {
  local target=${1:-/etc/nginx}
  local nginx_conf="${target}/nginx.conf"
  [[ -f $nginx_conf ]] || return 1

  # Repair the shared PHP include and the two server-level includes that old
  # deployments left without an index.  Also normalise PATH_TRANSLATED in
  # every PHP location include so cgi.fix_pathinfo=0 cannot make PHP-FPM
  # execute the document root.
  tune_fastcgi_snippet "${target}/snippets/fastcgi-php.conf"
  tune_ensure_index "${target}/h5bp/wordpress.conf"
  tune_ensure_index "${target}/h5bp/php_polr.conf"
  tune_fastcgi_path_translated_all "$target"
  tune_strip_php_admin_open_basedir_all "$target"

  local nproc mem_mb disk_free_mb disk_class
  local worker_rlimit worker_connections open_files
  local fastcgi_buffers fastcgi_busy body_buffer ssl_cache_mb
  local cache_total_mb fcgi_mb chev_mb xf_mb proxy_mb cdn_mb
  local fcgi_zone chev_zone xf_zone proxy_zone cdn_zone
  local fcgi_size chev_size xf_size proxy_size cdn_size

  nproc=$(effective_cpus)
  (( nproc > 0 )) || nproc=1
  mem_mb=$(mem_total_mb)
  (( mem_mb > 0 )) || mem_mb=1024

  disk_class=$(storage_class)
  disk_free_mb=$(nginx_disk_free_mb)

  nginx_worker_limits "$nproc"
  worker_rlimit=$NGINX_WORKER_RLIMIT
  worker_connections=$NGINX_WORKER_CONNECTIONS
  # The open-file cache holds static assets, templates and cache objects;
  # size it with RAM (and the file count that implies), not the core count.
  # Cached descriptors are real fds of the worker, so the cache can never
  # exceed what worker_rlimit_nofile leaves after the connections themselves
  # (a 4-core/32 GB host used to get 200000 entries against a 65536 limit).
  open_files=$(nginx_open_file_cache_max "$mem_mb" "$worker_rlimit" "$worker_connections")
  # The connections also hold an upstream socket each (FastCGI/proxy):
  # raise the limit so that worst case fits too (1.22.5 fd plan).
  worker_rlimit=$(nginx_worker_rlimit_fit "$worker_rlimit" "$worker_connections" "$open_files")

  if (( mem_mb < 2048 )); then
    fastcgi_buffers='32 16k'; fastcgi_busy='256k'; body_buffer='64k'
  elif (( mem_mb < 8192 )); then
    fastcgi_buffers='64 32k'; fastcgi_busy='1m'; body_buffer='128k'
  else
    fastcgi_buffers='128 32k'; fastcgi_busy='2m'; body_buffer='256k'
  fi

  ssl_cache_mb=$(tune_clamp $(( mem_mb / 512 )) 10 256)

  # Scale the disk-cache budget with the services actually present.  A
  # dedicated nginx proxy has no PHP/DB/search tier to share RAM with, and an
  # nginx+PHP host has no database/search tier.  The helper is shared with
  # --dry-run so the plan and the applied value match.
  cache_total_mb=$(nginx_cache_budget_mb "$mem_mb" "$disk_free_mb")

  # Resolve the cache files nginx actually includes before sizing them, so a
  # host that only runs one cache type can use the whole cache budget instead
  # of leaving most of it assigned to caches that do not exist.
  local f_fcgi f_chev f_xf f_proxy f_limit
  TUNE_ACTIVE_HTTP=()
  mapfile -t TUNE_ACTIVE_HTTP < <(nginx_active_http_files "$target")
  if (( ${#TUNE_ACTIVE_HTTP[@]} > 0 )); then
    f_fcgi=$(tune_active_file 'keys_zone=fastcgicache:') || f_fcgi=""
    f_chev=$(tune_active_file 'keys_zone=fastcgicache_chev:') || f_chev=""
    f_xf=$(tune_active_file 'keys_zone=xfproxycache:') || f_xf=""
    f_proxy=$(tune_active_file 'keys_zone=(proxy_cache|proxy_cdn|cdn_proxy):') || f_proxy=""
    f_limit=$(tune_active_file 'limit_req_zone') || f_limit=""
  else
    f_fcgi=$(tune_first_file "$target/http.d" fastcgi_cache.conf fastcgi_cache_conf) || f_fcgi=""
    f_chev=$(tune_first_file "$target/http.d" fastcgi_cache_chev.conf fastcgi_cache_chev_conf) || f_chev=""
    f_xf=$(tune_first_file "$target/http.d" xf_proxy_cache.conf xf_proxy_cache_conf) || f_xf=""
    f_proxy=$(tune_first_file "$target/http.d" proxy_cache.conf proxy_cache_conf) || f_proxy=""
    f_limit=$(tune_first_file "$target/http.d" limit_req.conf limit_req_conf) || f_limit=""
  fi

  local have_fcgi=0 have_chev=0 have_xf=0 have_proxy=0 have_cdn=0 active_weight=0
  [[ -n $f_fcgi ]] && have_fcgi=1
  [[ -n $f_chev ]] && have_chev=1
  [[ -n $f_xf ]] && have_xf=1
  if [[ -n $f_proxy ]]; then
    grep -qE 'keys_zone=proxy_cache:' "$f_proxy" && have_proxy=1
    grep -qE 'keys_zone=(proxy_cdn|cdn_proxy):' "$f_proxy" && have_cdn=1
  fi
  (( have_fcgi )) && active_weight=$(( active_weight + 50 ))
  (( have_chev )) && active_weight=$(( active_weight + 25 ))
  (( have_xf )) && active_weight=$(( active_weight + 15 ))
  (( have_proxy )) && active_weight=$(( active_weight + 5 ))
  (( have_cdn )) && active_weight=$(( active_weight + 5 ))

  fcgi_mb=0; chev_mb=0; xf_mb=0; proxy_mb=0; cdn_mb=0
  if (( active_weight > 0 )); then
    (( have_fcgi )) && fcgi_mb=$(( cache_total_mb * 50 / active_weight ))
    (( have_chev )) && chev_mb=$(( cache_total_mb * 25 / active_weight ))
    (( have_xf )) && xf_mb=$(( cache_total_mb * 15 / active_weight ))
    (( have_proxy )) && proxy_mb=$(( cache_total_mb * 5 / active_weight ))
    (( have_cdn )) && cdn_mb=$(( cache_total_mb * 5 / active_weight ))
    # A proxy file containing only one of the standard paths must not rewrite
    # the other path to max_size=0.
    (( have_proxy && !have_cdn )) && cdn_mb=$proxy_mb
    (( have_cdn && !have_proxy )) && proxy_mb=$cdn_mb
  fi
  (( have_fcgi && fcgi_mb < 64 )) && fcgi_mb=64
  (( have_chev && chev_mb < 32 )) && chev_mb=32
  (( have_xf && xf_mb < 32 )) && xf_mb=32
  (( have_proxy && proxy_mb < 16 )) && proxy_mb=16
  (( have_cdn && cdn_mb < 16 )) && cdn_mb=16

  # Do not force the cache manager to evict a cache that is already larger
  # than the RAM-derived plan (live usage wins on an existing server).
  if [[ -n $f_fcgi ]]; then
    nginx_cache_keep_mb "$f_fcgi" "$fcgi_mb" "" "$cache_total_mb"
    fcgi_mb=$NGINX_CACHE_MB
    [[ -n $NGINX_CACHE_NOTE ]] && tune_summary "${f_fcgi#"${target}"/}: ${NGINX_CACHE_NOTE}"
  fi
  if [[ -n $f_chev ]]; then
    nginx_cache_keep_mb "$f_chev" "$chev_mb" "" "$cache_total_mb"
    chev_mb=$NGINX_CACHE_MB
    [[ -n $NGINX_CACHE_NOTE ]] && tune_summary "${f_chev#"${target}"/}: ${NGINX_CACHE_NOTE}"
  fi
  if [[ -n $f_xf ]]; then
    nginx_cache_keep_mb "$f_xf" "$xf_mb" "" "$cache_total_mb"
    xf_mb=$NGINX_CACHE_MB
    [[ -n $NGINX_CACHE_NOTE ]] && tune_summary "${f_xf#"${target}"/}: ${NGINX_CACHE_NOTE}"
  fi
  # The proxy/CDN caches ship at 16g and may hold a populated cache on an
  # adopted host; the same live-usage rule applies to them.
  if (( have_proxy )); then
    nginx_cache_keep_mb "$f_proxy" "$proxy_mb" proxy_cache "$cache_total_mb"
    proxy_mb=$NGINX_CACHE_MB
    [[ -n $NGINX_CACHE_NOTE ]] && tune_summary "${f_proxy#"${target}"/}: ${NGINX_CACHE_NOTE}"
  fi
  if (( have_cdn )); then
    nginx_cache_keep_mb "$f_proxy" "$cdn_mb" proxy_cdn "$cache_total_mb"
    cdn_mb=$NGINX_CACHE_MB
    [[ -n $NGINX_CACHE_NOTE ]] && tune_summary "${f_proxy#"${target}"/}: ${NGINX_CACHE_NOTE}"
  fi

  fcgi_zone=$(tune_clamp $(( cache_total_mb / 4 )) 16 512)
  chev_zone=$(tune_clamp $(( cache_total_mb / 8 )) 8 512)
  xf_zone=$(tune_clamp $(( cache_total_mb / 8 )) 8 256)
  proxy_zone=$(tune_clamp $(( cache_total_mb / 16 )) 8 128)
  cdn_zone=$(tune_clamp $(( cache_total_mb / 16 )) 8 128)

  fcgi_size=$(tune_size_value "$fcgi_mb")
  chev_size=$(tune_size_value "$chev_mb")
  xf_size=$(tune_size_value "$xf_mb")
  proxy_size=$(tune_size_value "$proxy_mb")
  cdn_size=$(tune_size_value "$cdn_mb")

  tune_replace "$nginx_conf" '^([[:space:]]*worker_processes[[:space:]]+)[^;]+;' "\\1${NGINX_WORKER_PROCESSES};" "nginx.conf: worker_processes=${NGINX_WORKER_PROCESSES}"
  # With a cgroup CPU quota below the host's core count, `auto` affinity
  # would pin the N workers to CPUs 0..N-1 while every other service floats;
  # let the scheduler place them instead.  The same for a cpuset (the online
  # count, not nproc, which already honours the affinity mask) and for a
  # host with several NUMA nodes (auto walks CPU numbers, not nodes).
  local pin_why
  pin_why=$(nginx_cpu_pin_block_reason "$nproc")
  if [[ -n $pin_why ]]; then
    tune_replace "$nginx_conf" '^([[:space:]]*)worker_cpu_affinity[[:space:]]+auto;' \
      "\\1# worker_cpu_affinity auto; # setup.sh: ${pin_why}, no pinning" \
      "nginx.conf: worker_cpu_affinity disabled (${pin_why})"
  fi
  # Storage-class dependent file I/O: on flash the page cache serves hot
  # files cheaply, so only very large files bypass it (directio 16m); a
  # rotational disk keeps the 4m threshold so big downloads do not evict the
  # cache.  aio threads + sendfile stay on for every class.
  local directio_mb=4
  case $disk_class in nvme|ssd) directio_mb=16 ;; esac
  tune_replace "$nginx_conf" '^([[:space:]]*directio[[:space:]]+)[0-9]+[mMkK];' "\\1${directio_mb}m;" "nginx.conf: directio=${directio_mb}m (${disk_class})"
  local gzip_level
  gzip_level=$(nginx_gzip_level)
  tune_replace "$target/h5bp/web_performance/compression.conf" '^([[:space:]]*gzip_comp_level[[:space:]]+)[0-9]+;' "\\1${gzip_level};" "h5bp/web_performance/compression.conf: gzip_comp_level=${gzip_level}"
  tune_replace "$nginx_conf" '^([[:space:]]*worker_rlimit_nofile[[:space:]]+)[0-9]+;' "\\1${worker_rlimit};" "nginx.conf: worker_rlimit_nofile=${worker_rlimit}"
  tune_replace "$nginx_conf" '^([[:space:]]*worker_connections[[:space:]]+)[0-9]+;' "\\1${worker_connections};" "nginx.conf: worker_connections=${worker_connections}"
  tune_replace "$nginx_conf" '^([[:space:]]*client_body_buffer_size[[:space:]]+).*;' "\\1${body_buffer};" "nginx.conf: client_body_buffer_size=${body_buffer}"
  nginx_disable_php_keepalive "$nginx_conf"
  nginx_disable_php_keep_conn "$target"

  if ! grep -qE '^[[:space:]]*worker_rlimit_nofile[[:space:]]' "$nginx_conf"; then
    tune_insert_after "$nginx_conf" '^[[:space:]]*worker_processes[[:space:]]' \
      "worker_rlimit_nofile ${worker_rlimit};" "nginx.conf: inserted worker_rlimit_nofile=${worker_rlimit}"
  fi
  if ! grep -qE '^[[:space:]]*worker_connections[[:space:]]' "$nginx_conf"; then
    tune_insert_after "$nginx_conf" '^[[:space:]]*events[[:space:]]*[{]' \
      "  worker_connections ${worker_connections};" "nginx.conf: inserted worker_connections=${worker_connections}"
  fi
  if ! grep -qE '^[[:space:]]*client_body_buffer_size[[:space:]]' "$nginx_conf"; then
    # Anchor on the real block opener: a bare `http[[:space:]]*` also matches
    # directives such as `http2 on;` and would insert inside a server block.
    tune_insert_after "$nginx_conf" '^[[:space:]]*http[[:space:]]*[{]' \
      "  client_body_buffer_size ${body_buffer};" "nginx.conf: inserted client_body_buffer_size=${body_buffer}"
  fi

  # Point any remaining TCP FastCGI handlers at the pool's Unix socket, but
  # only when optimize_php_services found an existing socket listener.  A pool
  # kept on TCP (the usual live-server case) must keep nginx on TCP as well.
  if [[ -n ${OPT_PHP_SOCKET:-} ]]; then
    local file php_socket=${OPT_PHP_SOCKET}
    while IFS= read -r file; do
      [[ -n $file ]] || continue
      local before after
      before=$(file_md5 "$file")
      sed_in_place -E "s#^([[:space:]]*fastcgi_pass[[:space:]]+)(127\.0\.0\.1|localhost):9000;#\\1unix:${php_socket};#g" "$file"
      after=$(file_md5 "$file")
      [[ $before != "$after" ]] && tune_note "${file#"${target}"/}: fastcgi_pass -> unix:${php_socket}"
    done < <(grep -rlE '^[[:space:]]*fastcgi_pass[[:space:]]+(127\.0\.0\.1|localhost):9000;' "$target" 2>/dev/null || true)

    if grep -qE '^([[:space:]]*server[[:space:]]+)(127\.0\.0\.1|localhost):9000;' "$nginx_conf"; then
      tune_replace "$nginx_conf" \
        '^([[:space:]]*server[[:space:]]+)(127\.0\.0\.1|localhost):9000;' \
        "\\1unix:${php_socket};" "nginx.conf: local_php upstream -> Unix socket"
    fi
  elif [[ $target == /etc/nginx ]]; then
    # No socket was handed over: the pool stayed where it was (TCP kept, the
    # migration skipped or rolled back, PHP stopped).  The repository sync has
    # just rewritten nginx.conf to `server unix:/run/php/php-fpm.sock;`, and
    # nothing else points it back, so a live TCP pool left every PHP site on
    # 502.  Follow the live pool's listener instead.  Only the live tree is
    # described by the live pool; a staged or test tree is left as synced.
    local live_listen
    live_listen=$(php_pool_listen "$(php_primary_version 2>/dev/null || true)" 2>/dev/null || true)
    # A socket path is only worth following once the pool has created it.
    if [[ $live_listen == /* && ! -S $live_listen ]]; then
      live_listen=""
    fi
    nginx_local_php_follow_pool "$nginx_conf" "$live_listen"
  fi

  if [[ -n $f_fcgi ]]; then
    tune_replace "$f_fcgi" \
      '^(.*keys_zone=fastcgicache:)[0-9]+m( max_size=[0-9]+[mgMG])?(.*)$' \
      "\\1${fcgi_zone}m max_size=${fcgi_size}\\3" \
      "${f_fcgi#"${target}"/}: ${fcgi_zone}m zone / ${fcgi_size} max"
  else
    tune_miss "http.d: no active fastcgi_cache_path"
  fi
  if [[ -n $f_chev ]]; then
    tune_replace "$f_chev" \
      '^(.*keys_zone=fastcgicache_chev:)[0-9]+m( max_size=[0-9]+[mgMG])?(.*)$' \
      "\\1${chev_zone}m max_size=${chev_size}\\3" \
      "${f_chev#"${target}"/}: ${chev_zone}m zone / ${chev_size} max"
  else
    tune_miss "http.d: no active fastcgicache_chev cache_path"
  fi
  if [[ -n $f_xf ]]; then
    tune_replace "$f_xf" \
      '^(.*keys_zone=xfproxycache:)[0-9]+m( max_size=[0-9]+[mgMG])?(.*)$' \
      "\\1${xf_zone}m max_size=${xf_size}\\3" \
      "${f_xf#"${target}"/}: ${xf_zone}m zone / ${xf_size} max"
  else
    tune_miss "http.d: no active xfproxycache cache_path"
  fi
  if [[ -n $f_proxy ]]; then
    tune_replace "$f_proxy" \
      'keys_zone=proxy_cache:[0-9]+m' "keys_zone=proxy_cache:${proxy_zone}m" \
      "${f_proxy#"${target}"/}: proxy zone=${proxy_zone}m"
    tune_replace "$f_proxy" \
      'keys_zone=proxy_cdn:[0-9]+m' "keys_zone=proxy_cdn:${cdn_zone}m" \
      "${f_proxy#"${target}"/}: cdn zone=${cdn_zone}m"

    local before tmp
    before=$(file_md5 "$f_proxy")
    tmp=$(tmp_file)
    # proxy_cache_path directives commonly wrap onto a second line, so track
    # the active cache path and rewrite the first max_size seen afterwards
    # instead of only looking at the line that starts the directive.
    awk -v a="$proxy_size" -v b="$cdn_size" '
      {
        if ($0 ~ /proxy_cache_path/ && $0 ~ /keys_zone=proxy_cache:/) cache = a
        else if ($0 ~ /proxy_cache_path/ && $0 ~ /keys_zone=proxy_cdn:/) cache = b
        if (cache != "" && $0 ~ /max_size=[0-9]+[mgMG]/) {
          sub(/max_size=[0-9]+[mgMG]/, "max_size=" cache)
          cache = ""
        }
        print
        if ($0 ~ /;[[:space:]]*$/) cache = ""
      }
    ' "$f_proxy" > "$tmp"
    cat "$tmp" > "$f_proxy"
    [[ $(file_md5 "$f_proxy") != "$before" ]] \
      && tune_note "${f_proxy#"${target}"/}: proxy=${proxy_size} cdn=${cdn_size}"
  else
    tune_miss "http.d: no active proxy_cache_path"
  fi

  # Only the credential zone is left (1.6.61); its fixed 16m holds ~128k
  # client keys, so it is not sized from memory like the old GET/POST zones.
  if [[ -n $f_limit ]]; then
    # A flood of rejected requests must not turn into a flood of log writes:
    # at 20k req/s the per-rejection warning wrote 266 MB of error log in two
    # minutes (measured), which is a self-inflicted disk bottleneck.  Log
    # rejections at info level (below the configured warn error_log level);
    # the 429 count stays visible in the nginx status and access metrics.
    tune_replace "$f_limit" \
      '^([[:space:]]*limit_req_log_level[[:space:]]+)[a-z]+;' '\1info;' \
      "${f_limit#"${target}"/}: limit_req_log_level=info"
    tune_ensure_line "$f_limit" '^[[:space:]]*limit_req_log_level[[:space:]]' \
      'limit_req_log_level info;' "${f_limit#"${target}"/}: added limit_req_log_level=info"
  else
    tune_miss "http.d: no active limit_req_zone"
  fi

  # Bound custom cache paths that are not part of the standard set.  Scan
  # only files nginx includes, so inert legacy leftovers are left untouched.
  local extra_zone extra_max file tmp
  local -a cache_files=()
  extra_zone=$(tune_clamp $(( cache_total_mb / 16 )) 8 128)
  if (( active_weight == 0 )); then
    # No standard cache type is present: the whole budget is available to
    # whatever custom cache path the host actually uses.
    extra_max=$cache_total_mb
    (( extra_max < 64 )) && extra_max=64
  else
    extra_max=$(tune_clamp $(( cache_total_mb / 8 )) 64 1024)
  fi
  if (( ${#TUNE_ACTIVE_HTTP[@]} > 0 )); then
    cache_files=("${TUNE_ACTIVE_HTTP[@]}")
  else
    mapfile -t cache_files < <(grep -rlE '^[[:space:]]*(fastcgi|proxy)_cache_path[[:space:]]' \
      "$target/http.d" 2>/dev/null || true)
  fi
  for file in "${cache_files[@]}"; do
    [[ -n $file ]] || continue
    if [[ $file == "${f_fcgi:-}" || $file == "${f_chev:-}" || \
          $file == "${f_xf:-}" || $file == "${f_proxy:-}" ]]; then
      continue
    fi
    tmp=$(tmp_file)
    awk -v zcap="$extra_zone" -v mcap="$extra_max" '
      function cap_zone(line,    s, n, unit, mb, repl) {
        if (!match(line, /keys_zone=[A-Za-z0-9_]+:[0-9]+[mMgG]/)) return line
        s = substr(line, RSTART, RLENGTH)
        n = s; sub(/^.*:/, "", n)
        unit = substr(n, length(n), 1); sub(/[mMgG]$/, "", n)
        mb = (unit == "g" || unit == "G") ? n * 1024 : n
        if (mb + 0 <= zcap) return line
        repl = s; sub(/:[0-9]+[mMgG]$/, ":" zcap "m", repl)
        return substr(line, 1, RSTART - 1) repl substr(line, RSTART + RLENGTH)
      }
      {
        line = cap_zone($0)
        if (match(line, /max_size=[0-9]+[mMgG]/)) {
          s = substr(line, RSTART, RLENGTH)
          n = s; sub(/^max_size=/, "", n)
          unit = substr(n, length(n), 1); sub(/[mMgG]$/, "", n)
          mb = (unit == "g" || unit == "G") ? n * 1024 : n
          if (mb + 0 > mcap) {
            repl = "max_size=" mcap "M"
            line = substr(line, 1, RSTART - 1) repl substr(line, RSTART + RLENGTH)
          }
        } else if (line ~ /^[[:space:]]*(fastcgi|proxy)_cache_path[[:space:]]/ \
                   && line ~ /;[[:space:]]*$/) {
          sub(/;[[:space:]]*$/, " max_size=" mcap "M;", line)
        }
        print line
      }
    ' "$file" > "$tmp"
    if commit_if_changed "$file" "$tmp"; then
      tune_note "${file#"${target}"/}: custom cache capped at ${extra_zone}m zone / ${extra_max}M max"
    fi
  done

  tune_replace "$target/h5bp/tls/ssl_engine.conf" \
    '^([[:space:]]*ssl_session_cache[[:space:]]+shared:SSL:)[0-9]+m;' \
    "\\1${ssl_cache_mb}m;" "h5bp/tls/ssl_engine.conf: SSL cache=${ssl_cache_mb}m"
  tune_replace "$target/h5bp/web_performance/cache-file-descriptors.conf" \
    'open_file_cache max=[0-9]+' "open_file_cache max=${open_files}" \
    "h5bp/web_performance/cache-file-descriptors.conf: max=${open_files}"
  tune_replace "$target/h5bp/web_performance/cache-file-descriptors.conf" \
    'open_log_file_cache max=[0-9]+' "open_log_file_cache max=$(( open_files / 4 ))" \
    "h5bp/web_performance/cache-file-descriptors.conf: log max=$(( open_files / 4 ))"

  local php_conf
  for php_conf in "$target"/h5bp/php*.conf; do
    [[ -f $php_conf ]] || continue
    # Only an include that actually hands a request to FastCGI needs these
    # buffers.  A file that only carries locations (and includes the handler
    # from h5bp/php_wp_handler.conf, as h5bp/php_wp.conf does) has nothing to
    # tune, so a missing directive is not a missed tune.
    grep -qE '^[[:space:]]*fastcgi_pass[[:space:]]' "$php_conf" || continue
    tune_replace "$php_conf" '^([[:space:]]*fastcgi_buffer_size[[:space:]]+).*;' "\\1${body_buffer};" "${php_conf#"${target}"/}: fastcgi_buffer_size=${body_buffer}"
    tune_replace "$php_conf" '^([[:space:]]*fastcgi_buffers[[:space:]]+).*;' "\\1${fastcgi_buffers};" "${php_conf#"${target}"/}: fastcgi_buffers=${fastcgi_buffers}"
    tune_replace "$php_conf" '^([[:space:]]*fastcgi_busy_buffers_size[[:space:]]+).*;' "\\1${fastcgi_busy};" "${php_conf#"${target}"/}: fastcgi_busy_buffers_size=${fastcgi_busy}"
  done

  tune_cache_error_policy "$target/h5bp/wordpress_cache.conf" "h5bp/wordpress_cache.conf"
  tune_cache_error_policy "$target/h5bp/php_xf.conf" "h5bp/php_xf.conf"
  tune_cache_error_policy "$target/h5bp/php_xf_proxy.conf" "h5bp/php_xf_proxy.conf"
  tune_cache_error_policy "$target/h5bp/php_chev.conf" "h5bp/php_chev.conf"
  tune_cache_error_policy "$target/h5bp/php_chev_cache.conf" "h5bp/php_chev_cache.conf"
  tune_cache_error_policy "$target/h5bp/php_flarum.conf" "h5bp/php_flarum.conf"
  # The cache key references $setup_cache_enc, so the map that defines it
  # must exist before the first XenForo vhost is tested (a fresh install
  # tunes the include long before --domain app=xf runs).
  ensure_xf_cookie_bypass_map "$target" || true
  tune_flarum_cache_gate "$target"
  tune_default_tls_reject "$target"
  tune_retire_unused_acme_client "$target"
  tune_xf_cache_vary "$target/h5bp/php_xf.conf"
  tune_xf_cache_vary "$target/h5bp/php_xf_proxy.conf"
  tune_xf_static_assets "$target/h5bp/xf2.conf"
  tune_vhost_route_anchors "$target"
  tune_vhost_lean_locations "$target"

  tune_summary "nginx summary: ${nproc} CPU / ${mem_mb}MB RAM / ${disk_class} / cache_budget=${cache_total_mb}MB"
  # The tuner may have added or rewritten an http-context directive that an
  # operator file also sets; resolve any duplicate before the caller's
  # nginx -t (deploy_nginx_tree already does this before tuning too).
  tune_nginx_dedupe_http "$target"
  return 0
}

# ---------------------------------------------------------------------------
# PHP-FPM
# ---------------------------------------------------------------------------
tune_pool_set() {
  local file=$1 key=$2 value=$3 desc=$4 tmp
  local escaped=${key//./\\.}
  tmp=$(tmp_file) || return 1
  if grep -qE "^[[:space:]]*${escaped}[[:space:]]*=" "$file"; then
    sed -E "s|^[[:space:]]*${escaped}[[:space:]]*=.*|${key} = ${value}|" "$file" > "$tmp" \
      || return 1
  else
    cat -- "$file" > "$tmp" || return 1
    printf '%s = %s\n' "$key" "$value" >> "$tmp"
  fi
  commit_if_changed "$file" "$tmp" && tune_note "$desc"
  return 0
}

# Collapse duplicate directives for keys this script owns, keeping the last
# occurrence (php-fpm's own precedence), without reordering unrelated lines.
tune_pool_dedupe() {
  local file=$1
  shift
  local keys="$*" tmp
  [[ -f $file ]] || return 0
  tmp=$(tmp_file)
  awk -v keys="$keys" '
    BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) managed[k[i]] = 1 }
    {
      # Directives are only duplicates inside the same [section]; rlimit_files
      # is valid both globally (master) and in a pool (workers).
      if (match($0, /^[ \t]*\[[^]]+\]/)) {
        section = substr($0, RSTART, RLENGTH)
        gsub(/^[ \t]+|[ \t]+$/, "", section)
      }
      key = ""
      if (match($0, /^[ \t]*[^ \t=]+/)) {
        key = substr($0, RSTART, RLENGTH)
        gsub(/^[ \t]+|[ \t]+$/, "", key)
      }
      if (key in managed) last[section SUBSEP key] = NR
      lines[NR] = $0
    }
    END {
      for (i = 1; i <= NR; i++) {
        if (match(lines[i], /^[ \t]*\[[^]]+\]/)) {
          section = substr(lines[i], RSTART, RLENGTH)
          gsub(/^[ \t]+|[ \t]+$/, "", section)
        }
        key = ""
        if (match(lines[i], /^[ \t]*[^ \t=]+/)) {
          key = substr(lines[i], RSTART, RLENGTH)
          gsub(/^[ \t]+|[ \t]+$/, "", key)
        }
        if ((key in managed) && last[section SUBSEP key] != i) continue
        print lines[i]
      }
    }' "$file" > "$tmp"
  commit_if_changed "$file" "$tmp" \
    && tune_note "$(basename "$file"): removed duplicate managed directives"
  return 0
}

# PHP-FPM opens the pool slowlog/access log when the master starts.  A pool
# upgraded from an older package can still point at a directory that no
# longer exists; enabling request_slowlog_timeout then makes `php-fpm -t`
# fail.  Create the configured parent directory first and, for a fixed path,
# the file itself.  Paths containing a runtime variable (for example
# "$pool.access.log") only get their directory created.
ensure_fpm_log_path() {
  local path=$1 user=${2:-www-data} group=${3:-www-data} dir
  [[ $path == /* ]] || return 0
  dir=$(dirname -- "$path")
  mkdir -p "$dir" 2>/dev/null || return 0
  if [[ ${path##*/} != *'$'* ]]; then
    # Symlink-safe; the owner is set only on a file created here.
    secure_log_file "$path" "$user" "$group" created
  fi
  return 0
}

# The php-fpm master waits forever for workers when process_control_timeout is
# 0 (the package default).  On a busy pool a stop/restart then sits in
# systemd's "deactivating" state until TimeoutStopSec, and the shared socket
# is gone for the whole window (all PHP vhosts return 502).  Bound it.
ensure_fpm_global_timeout() {
  local ver=$1
  local conf="/etc/php/${ver}/fpm/php-fpm.conf"
  [[ -f $conf ]] || return 0
  if grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=' "$conf"; then
    grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=[[:space:]]*10s' "$conf" \
      && return 0
    sed_in_place -E 's|^[[:space:]]*process_control_timeout[[:space:]]*=.*|process_control_timeout = 10s|' "$conf"
  elif grep -qE '^[[:space:]]*include[[:space:]]*=' "$conf"; then
    # Everything after the pool include is parsed inside the last included
    # pool section, so a global directive must go *before* it.
    sed_in_place -E '/^[[:space:]]*include[[:space:]]*=/i\
; setup.sh: bound master/worker shutdown so a busy pool restarts in seconds\
process_control_timeout = 10s' "$conf"
  else
    printf '\n; setup.sh: bound master/worker shutdown so a busy pool restarts in seconds\nprocess_control_timeout = 10s\n' >> "$conf"
  fi
  tune_note "PHP ${ver}: process_control_timeout=10s"
  return 0
}

# Old hosts can still carry a pre-1.8.41 custom_dan.ini (2 GB memory_limit,
# OPcache JIT off, curl_exec/exec disabled).  The managed
# zz-setup-optimize.ini overrides some values, but not allow_url_fopen or
# disable_functions, and removing the managed file would expose the stale
# limits.  --optimize refreshes the managed template while keeping the
# host's existing date.timezone.
sync_php_ini_template() {
  local ver=$1 target=${2:-} template=${3:-}
  if [[ -z $target ]]; then
    [[ -d /etc/php/${ver}/fpm ]] || return 0
    target="/etc/php/${ver}/fpm/conf.d/custom_dan.ini"
  fi
  [[ -n $template ]] || template="${SCRIPT_DIR}/configs/php/custom_dan.ini"
  [[ -f $template ]] || { tune_miss "PHP ${ver}: custom_dan.ini template not found"; return 0; }

  # Precedence: an explicit install timezone (--basic time=), then the live
  # ini value, then the host's timezone.  timedatectl is the authority on
  # current Ubuntu: /etc/timezone can stay stale after `timedatectl
  # set-timezone` (observed on 26.04: /etc/timezone said America/Los_Angeles
  # while the live zone was Asia/Manila), and reading it made --optimize
  # rewrite the timezone an install had just written.
  local tz=${PHP_INI_TZ:-}
  if [[ -z $tz && -f $target ]]; then
    tz=$(ini_get "$target" date.timezone)
  fi
  if [[ -z $tz ]]; then
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    tz=${tz//[[:space:]]/}
  fi
  if [[ -z $tz && -r /etc/timezone ]]; then
    tz=$(head -n1 /etc/timezone | tr -d '[:space:]')
  fi

  local tmp
  tmp=$(tmp_file) || return 1
  if [[ -n $tz ]]; then
    awk -v tz="$tz" '
      /^[[:space:]]*date\.timezone[[:space:]]*=/ {
        print "date.timezone = " tz
        done = 1
        next
      }
      { print }
      END { if (!done) print "date.timezone = " tz }
    ' "$template" > "$tmp"
  else
    cat "$template" > "$tmp"
  fi

  # Never leave a global cgi.fix_pathinfo override in the default template.
  # With fix_pathinfo=0 PHP-FPM prefers PATH_TRANSLATED; the deployed PHP
  # includes used to map that to the document root, so every pretty URL was
  # denied.
  if grep -qE '^[[:space:]]*cgi\.fix_pathinfo[[:space:]]*=' "$tmp"; then
    local cleaned
    cleaned=$(tmp_file) || return 1
    grep -vE '^[[:space:]]*cgi\.fix_pathinfo[[:space:]]*=' "$tmp" > "$cleaned" || true
    cat "$cleaned" > "$tmp"
  fi

  if [[ -f $target ]] && cmp -s "$tmp" "$target"; then
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  cat "$tmp" > "$target"
  chmod 644 "$target"
  tune_note "PHP ${ver}: custom_dan.ini refreshed from template"
  return 0
}

# Path of the php-fpm binary for a version, or non-zero when the version is
# not installed.  The 1.22 build (ROOT/X.Y/sbin/php-fpm, lib/php-build.sh)
# is the answer whenever X.Y is ours.  The package binary
# (/usr/sbin/php-fpmX.Y) is returned only while X.Y is still a Sury/Ubuntu
# version: no build.info of our own for it and no finished migration of it
# (migrate state php-X.Y=done).  Once X.Y is ours a missing compiled php-fpm
# is reported (status 1), never hidden behind the package's binary and
# config layout.
php_fpm_binary() {
  local ver=$1 bin root=${PHP_BUILD_ROOT:-/usr/local/lib/setup-php}
  if declare -F php_fpm_bin >/dev/null 2>&1; then
    bin=$(php_fpm_bin "$ver")
  else
    bin="${root}/${ver}/sbin/php-fpm"
  fi
  if [[ -x $bin ]]; then
    printf '%s' "$bin"
    return 0
  fi
  [[ -f ${root}/${ver}/build.info ]] && return 1
  if declare -F migrate_state_get >/dev/null 2>&1 \
     && [[ $(migrate_state_get "php-${ver}" 2>/dev/null || true) == "done" ]]; then
    return 1
  fi
  if [[ -x "/usr/sbin/php-fpm${ver}" ]]; then
    printf '%s' "/usr/sbin/php-fpm${ver}"
    return 0
  fi
  return 1
}

# Point a pool at its listener (socket path or address) with the socket
# owner, group and mode nginx expects.  Shared by the pool tuner and the
# TCP-to-socket migration.  listen.allowed_clients is meaningless (and noisy)
# for a Unix socket, so it is dropped there.
php_pool_set_listener() {
  local pool=$1 ver=$2 socket=$3
  tune_pool_set "$pool" listen "$socket" "PHP ${ver}: listen=${socket}"
  if [[ $socket == /* ]] && grep -qE '^[[:space:]]*listen\.allowed_clients[[:space:]]*=' "$pool"; then
    sed_in_place -E '/^[[:space:]]*listen\.allowed_clients[[:space:]]*=/d' "$pool"
    tune_note "PHP ${ver}: removed listen.allowed_clients (Unix socket)"
  fi
  tune_pool_set "$pool" listen.owner www-data "PHP ${ver}: listen.owner=www-data"
  tune_pool_set "$pool" listen.group www-data "PHP ${ver}: listen.group=www-data"
  tune_pool_set "$pool" listen.mode 0660 "PHP ${ver}: listen.mode=0660"
}

# OPcache JIT mode and buffer for the pool: always the tracing JIT with a
# buffer of an eighth of the OPcache (32..128 MB).  Shared by the ini writer
# and the dry run.  Argument: opcache.memory_consumption in MB.
#
# The buffer lives inside OPcache's one shared segment (memory_consumption
# plus jit_buffer_size), which the master maps once and every worker shares:
# it is reserved once per PHP-FPM pool, not per worker (vm.nr_hugepages and
# the memory plan count it once, lib/os.sh).  512 MB OPcache / 8 = 64 MB of
# JIT buffer; the old quarter-size buffer asked for 128 MB.  Measured on the dev host (PHP 8.5.12,
# tracing JIT, 32 workers, 20 s runs): 64 MB and 128 MB were within 0.5% of
# each other on every tier (XenForo member 909 vs 906 req/s, WordPress
# member 234 vs 229); 256 MB was slower (899 / 225).  Function JIT lost 6-8%
# against tracing (guest 990 vs 1035 req/s, member 852 vs 913, thread 437 vs
# 485, WordPress 251 vs 262) and had a much worse p99 (554 ms vs 188 ms).
# JIT off cost ~5% on XenForo members (864 vs 910 req/s, p50 73 vs 69 ms) and
# was neutral on WordPress members, which is why WordPress roots can still be
# exempted with SETUP_PHP_JIT_WORDPRESS=0.
php_jit_settings() {
  local opcache_mb=${1:-128} buf
  [[ $opcache_mb =~ ^[0-9]+$ ]] || opcache_mb=128
  buf=$(tune_clamp $(( opcache_mb / 8 )) 32 128)
  # A whole number of 2 MB: PHP 8.6's tracing JIT aborts with "mprotect()
  # failed [22]" on some odd sizes (61 MB, the size a 495 MB OPcache gave,
  # took php8.6-fpm down after the 1.22.3 migration test of an 8.6 host;
  # 33 and 63 fail too, every even size tested works).  8.1-8.5 accept
  # either, so the rounding costs nothing there.
  buf=$(( buf / 2 * 2 ))
  # Newline-terminated: callers `read` it, and read returns 1 at EOF without one.
  printf 'tracing %s\n' "$buf"
}

# True when the reserved 2 MB huge pages can hold the OPcache code arena plus
# the JIT buffer.  A kernel that allocated only part of vm.nr_hugepages (87 of
# 512 pages on a fragmented provider image) is not a failure, but enabling
# opcache.huge_code_pages with too few pages makes OPcache fall back anyway;
# keeping the ini at 0 is the honest, warning-free setting.
php_hugepages_ok() {
  local pages=${1:-0} opcache_mb=${2:-128} jit_mb=${3:-0}
  [[ $pages =~ ^[0-9]+$ ]] || return 1
  [[ $opcache_mb =~ ^[0-9]+$ ]] || opcache_mb=128
  [[ $jit_mb =~ ^[0-9]+$ ]] || jit_mb=0
  (( pages * 2 >= opcache_mb + jit_mb ))
}

# Tracing-JIT hotness thresholds.  Higher values compile later (less CPU
# spent in the JIT, more in the interpreter); lower values compile sooner.
# Hosts with three or more effective CPUs get a tuned set (64/127/16/64):
# loop and func are PHP's defaults, while return and side_exit are raised from
# PHP's 8/8 so rarely taken return paths and side exits are not traced.  An
# aggressive set (16/64/8/32) measured within noise of it on the dev host,
# while the conservative set (128/255/32/128) lost 3-4% on the member tiers.
# A 1-2 CPU host pays proportionally more for compilation, so it gets the
# conservative set, which keeps the single PHP worker serving requests.
# No override: no other value measured faster (the SETUP_PHP_JIT_HOT_*
# variables were removed in 1.22.5 and are ignored with a warning).
php_jit_threshold_lines() {
  local cpu=${1:-0} loop=64 func=127 ret=16 side=64
  [[ $cpu =~ ^[0-9]+$ ]] && (( cpu > 0 )) || cpu=$(effective_cpus)
  if (( cpu <= 2 )); then
    loop=128; func=255; ret=32; side=128
  fi
  printf 'opcache.jit_hot_loop = %s\nopcache.jit_hot_func = %s\nopcache.jit_hot_return = %s\nopcache.jit_hot_side_exit = %s\n' \
    "$loop" "$func" "$ret" "$side"
}

# Document roots whose guest cache may store PHP's own gzip output.  A cached
# WordPress or Chevereto page used to be stored uncompressed and compressed
# again by nginx on every hit (about 1 ms of CPU; 14.8k req/s with all 16
# threads busy on the audit host).  With zlib.output_compression on for the
# document root the cache stores the gzip body and a hit costs 0.12 ms (72k
# req/s), the way XenForo's self-compressed pages always did.  Only roots
# whose deployed cache key carries the encoding token are listed, so a gzip
# body can never be handed to a client that did not ask for one.
# SETUP_PHP_PAGE_GZIP=0 (persisted as PHP_PAGE_GZIP) turns it off.
# The vhost decides, not the files in its root: a site created with --domain
# app=wordpress|chevereto and filled afterwards (the usual order) used to get
# no section until the next --optimize found wp-config.php / app/env.php.
# Compressing PHP output is safe for any root behind an encoding-aware key.
php_page_gzip_roots() {
  local target=${1:-/etc/nginx} file root
  (( PHP_PAGE_GZIP )) || return 0
  [[ -d $target/conf.d ]] || return 0
  local -a incs=()
  grep -qE '^[[:space:]]*fastcgi_cache_key[[:space:]].*_cache_enc' "$target/h5bp/wordpress_cache.conf" 2>/dev/null \
    && incs+=(wordpress_cache)
  grep -qE '^[[:space:]]*fastcgi_cache_key[[:space:]].*_cache_enc' "$target/h5bp/php_chev_cache.conf" 2>/dev/null \
    && incs+=(php_chev_cache)
  (( ${#incs[@]} )) || return 0
  local re
  re="^[[:space:]]*include[[:space:]]+h5bp/($(IFS='|'; printf '%s' "${incs[*]}"))\\.conf;"
  for file in "$target"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    grep -qE "$re" "$file" || continue
    root=$(nginx_vhost_root "$file")
    [[ -n $root ]] && printf '%s\n' "$root"
  done
  return 0
}

# Document roots of Chevereto vhosts: the vhost includes one of the Chevereto
# PHP locations and the root holds app/env.php.
nginx_chevereto_roots() {
  local target=${1:-/etc/nginx} file root
  for file in "$target"/conf.d/*.conf; do
    [[ -f $file ]] || continue
    grep -qE '^[[:space:]]*include[[:space:]]+h5bp/php_chev(_cache)?\.conf;' "$file" || continue
    root=$(nginx_vhost_root "$file")
    [[ -n $root && -f "${root}/app/env.php" ]] && printf '%s\n' "$root"
  done
  return 0
}

# File-session directories of the Chevereto roots, one "DEPTH DIR" line each:
# CHEVERETO_SESSION_SAVE_PATH (default /tmp) for every root whose
# CHEVERETO_SESSION_SAVE_HANDLER is unset or `files`.  PHP's files handler
# accepts "N;/path" and "N;MODE;/path" and then stores the sessions N
# directory levels below /path: DEPTH is that N (0 for a plain path).  A site
# that keeps sessions in Valkey/Redis has none.  Commented-out env.php lines
# are ignored.
chevereto_session_dirs() {
  local target=${1:-/etc/nginx} root env handler path depth live
  while IFS= read -r root; do
    [[ -n $root ]] || continue
    env="${root}/app/env.php"
    live=$(sed -E '/^[[:space:]]*(\/\/|#|\/\*|\*)/d' "$env" 2>/dev/null || true)
    handler=$(sed -nE "s/.*['\"]CHEVERETO_SESSION_SAVE_HANDLER['\"][[:space:]]*=>[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" <<<"$live" | tail -n1 || true)
    [[ -z $handler || $handler == files ]] || continue
    path=$(sed -nE "s/.*['\"]CHEVERETO_SESSION_SAVE_PATH['\"][[:space:]]*=>[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" <<<"$live" | tail -n1 || true)
    depth=0
    [[ $path == *';'* && ${path%%;*} =~ ^[0-9]+$ ]] && depth=${path%%;*}
    path=${path##*;}
    [[ -n $path ]] || path=/tmp
    [[ $path == /* ]] && printf '%s %s\n' "$depth" "${path%/}"
  done < <(nginx_chevereto_roots "$target")
  return 0
}

# The longest session.gc_maxlifetime (seconds) any PHP-FPM configuration on
# this host sets: the managed INI given, and every php.ini, conf.d/*.ini and
# pool (php_value / php_admin_value) under /etc/php/*/fpm.  The timer must
# never delete a session PHP still considers alive, so an operator's own
# (longer) value wins; 1440 (PHP's default) when nothing sets it.
php_session_max_lifetime() {
  local ini=${1:-} etc=${SETUP_PHP_SESSIONCLEAN_ETC:-/etc/php} f
  local -a files=()
  [[ -n $ini && -f $ini ]] && files+=("$ini")
  for f in "$etc"/*/fpm/php.ini "$etc"/*/fpm/conf.d/*.ini "$etc"/*/fpm/pool.d/*.conf; do
    [[ -f $f ]] && files+=("$f")
  done
  (( ${#files[@]} )) || { printf 1440; return 0; }
  sed -nE 's/^[[:space:]]*(php_(admin_)?value\[)?session\.gc_maxlifetime\]?[[:space:]]*=[[:space:]]*"?([0-9]+).*/\3/p' "${files[@]}" 2>/dev/null \
    | awk 'BEGIN { m = 0 } $1 + 0 > m { m = $1 + 0 } END { print (m >= 60 ? m : 1440) }'
}

# setup-php-sessionclean.timer: every 10 minutes, delete the sess_* files of
# the Chevereto file-session directories that are older than the managed
# session.gc_maxlifetime (Debian's phpsessionclean design, for the
# directories its timer never visited).  Installed while such a directory
# exists, removed when none is left; --purge php removes it with the last
# PHP version.  Called after every managed php.ini write.
#   php_session_clean_timer_sync INI [NGINX_DIR]
SETUP_PHP_SESSIONCLEAN_DIR=${SETUP_PHP_SESSIONCLEAN_DIR:-/etc/systemd/system}
SETUP_PHP_SESSIONCLEAN_LIST=${SETUP_PHP_SESSIONCLEAN_LIST:-/etc/php/setup-sessionclean.dirs}
php_session_clean_timer_sync() {
  local ini=$1 target=${2:-/etc/nginx} life mins dirs unit timer tmp changed=0
  local svc=setup-php-sessionclean
  unit="${SETUP_PHP_SESSIONCLEAN_DIR}/${svc}.service"
  timer="${SETUP_PHP_SESSIONCLEAN_DIR}/${svc}.timer"
  dirs=$(chevereto_session_dirs "$target" | sort -u)
  if [[ -z $dirs ]]; then
    if [[ -f $timer || -f $unit || -f $SETUP_PHP_SESSIONCLEAN_LIST ]]; then
      systemctl disable --now "${svc}.timer" >/dev/null 2>&1 || true
      rm -f "$timer" "$unit" "$SETUP_PHP_SESSIONCLEAN_LIST"
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    return 0
  fi
  life=$(php_session_max_lifetime "$ini")
  [[ $life =~ ^[0-9]+$ ]] && (( life >= 60 )) || life=1440
  mins=$(( (life + 59) / 60 ))
  mkdir -p "$(dirname "$SETUP_PHP_SESSIONCLEAN_LIST")" "$SETUP_PHP_SESSIONCLEAN_DIR"
  tmp=$(tmp_file) || return 1
  printf '%s\n' "$dirs" | awk -v m="$mins" 'NF { print m, $0 }' > "$tmp"
  commit_if_changed "$SETUP_PHP_SESSIONCLEAN_LIST" "$tmp" && changed=1
  chmod 644 "$SETUP_PHP_SESSIONCLEAN_LIST" 2>/dev/null || true
  tmp=$(tmp_file) || return 1
  cat > "$tmp" <<EOF
# setup.sh: expired PHP session files of Chevereto sites (no GC in requests).
[Unit]
Description=Remove expired Chevereto PHP session files (setup.sh)
ConditionPathExists=${SETUP_PHP_SESSIONCLEAN_LIST}

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/bin/sh -c 'while read -r m n d; do [ -d "\$\$d" ] && find "\$\$d" -xdev -maxdepth "\$\$((\$\$n + 1))" -type f -name "sess_*" -mmin "+\$\$m" -delete; done < ${SETUP_PHP_SESSIONCLEAN_LIST}; exit 0'
EOF
  commit_if_changed "$unit" "$tmp" && changed=1
  tmp=$(tmp_file) || return 1
  cat > "$tmp" <<'EOF'
# setup.sh: see setup-php-sessionclean.service.
[Unit]
Description=Remove expired Chevereto PHP session files every 10 minutes (setup.sh)

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
EOF
  commit_if_changed "$timer" "$tmp" && changed=1
  chmod 644 "$unit" "$timer" 2>/dev/null || true
  (( changed )) && systemctl daemon-reload >/dev/null 2>&1
  systemctl enable --now "${svc}.timer" >/dev/null 2>&1 || return 1
  return 0
}

# [PATH=] sections of the managed ini, one per document root:
#   * `opcache.jit = off` for every WordPress root when
#     SETUP_PHP_JIT_WORDPRESS=0 asks for it;
#   * `zlib.output_compression` for the roots php_page_gzip_roots lists.
#   * PHP's own session GC for Chevereto roots.
# php-fpm applies a PATH section at request start and restores the global
# value afterwards, so the setting cannot leak to the next vhost the way a
# fastcgi_param PHP_VALUE / PHP_ADMIN_VALUE does (measured: a PHP_VALUE set
# for one vhost was still active for another vhost on the same worker).
php_jit_path_sections() {
  local target=${1:-/etc/nginx} file root
  local -A body=()
  [[ -d $target/conf.d ]] || return 0
  if (( ! PHP_JIT_WORDPRESS )); then
    while IFS= read -r file; do
      root=$(nginx_vhost_root "$file")
      [[ -n $root ]] || continue
      body[$root]+=$'; WordPress keeps the bytecode cache only (SETUP_PHP_JIT_WORDPRESS=1 lifts this)\nopcache.jit = off\n'
    done < <(nginx_wordpress_vhosts "$target" | sort -u)
  fi
  # Chevereto keeps its PHP sessions in its own directory (/tmp unless
  # CHEVERETO_SESSION_SAVE_PATH says otherwise) and starts one for every
  # cookie-less request.  Nothing visited that directory (one load test left
  # 585,000 files, 2.4 GB of tmpfs, behind), and turning PHP's own GC on for
  # these roots (1.22.0-1.22.3) moved the cost into requests: each GC call
  # lists and stats the whole directory while its request holds the session
  # lock.  On the EPYC 24.04 replica (1.22.4) that cut the member explore
  # tier from 2,220 to ~1,100 req/s (p99 48 -> 457-753 ms) and uncached
  # guests from 4,324 to ~3,400 (p99 37 -> 300-420 ms).  The GC stays off in
  # requests; setup-php-sessionclean.timer removes the expired files instead
  # (php_session_clean_timer_sync).
  while IFS= read -r root; do
    [[ -n $root ]] || continue
    body[$root]+=$'; Chevereto session files are removed by setup-php-sessionclean.timer, not in requests\nsession.gc_probability = 0\n'
  done < <(nginx_chevereto_roots "$target" | sort -u)
  # Level 6: the stored page is compressed once per MISS and sent on every
  # hit, so its size is what guests pay.  Measured (1.21.58) on the cached
  # WordPress post / Chevereto explore pages: 14.9 / 12.7 KB at level 4,
  # 14.2 / 12.0 KB at 6 (-5 %), 14.1 / 11.9 KB at 9, for ~0.35 ms more per
  # MISS or member page (0.5 % of a 73 ms WordPress member page).
  while IFS= read -r root; do
    [[ -n $root ]] || continue
    body[$root]+=$'; guest cache stores the compressed page (SETUP_PHP_PAGE_GZIP=0 turns this off)\nzlib.output_compression = On\nzlib.output_compression_level = 6\n'
  done < <(php_page_gzip_roots "$target" | sort -u)
  (( ${#body[@]} > 0 )) || return 0
  while IFS= read -r root; do
    printf '\n[PATH=%s]\n%s' "$root" "${body[$root]}"
  done < <(printf '%s\n' "${!body[@]}" | sort)
}

# Keep the operator's WordPress JIT and page-gzip choices in
# /etc/default/setup-tuning so a plain --optimize does not silently change
# them.  Written once per run.
PHP_JIT_PERSISTED=0

# OPcache knob (1.22.5), persisted like the choices above and read back from
# /etc/default/setup-tuning on a later --optimize.  validate_timestamps is
# always 1 (revalidate_freq 60): the =0 option was removed before release
# (operator decision: stale code after deploys costs more than it gains).
#   SETUP_PHP_OPCACHE_FILE_OVERRIDE=0|1 (default 1 since 1.22.5: XenForo
#     member pages +2-4 % on the Intel host, no tier slower;
#     PHP_OPCACHE_FILE_OVERRIDE): 1 writes opcache.enable_file_override = 1,
#     0 leaves it out.
# The environment wins over the host file; any value other than the
# non-default one means the default.
PHP_OPCACHE_FILE_OVERRIDE_PERSIST=0
php_opcache_opts_load() {
  if [[ -n ${SETUP_PHP_OPCACHE_FILE_OVERRIDE+x} ]]; then
    PHP_OPCACHE_FILE_OVERRIDE=$SETUP_PHP_OPCACHE_FILE_OVERRIDE
    PHP_OPCACHE_FILE_OVERRIDE_PERSIST=1
  fi
  if [[ ${PHP_OPCACHE_FILE_OVERRIDE:-1} == 0 ]]; then PHP_OPCACHE_FILE_OVERRIDE=0; else PHP_OPCACHE_FILE_OVERRIDE=1; fi
  return 0
}
php_opcache_opts_load

# Persist one OPcache choice: always when the environment set it this run;
# otherwise re-write a non-default value read from the host file when the
# file no longer carries it (the --optimize profile reset moves pins that
# are not on its keep-list out of the way), so the choice survives.
php_opcache_persist_one() {
  local key=$1 value=$2 explicit=$3 default=$4 f=${SETUP_TUNING_FILE:-/etc/default/setup-tuning}
  if (( explicit )); then
    persist_tuning_var "$key" "$value"
    tune_summary "PHP: ${key}=${value} persisted in /etc/default/setup-tuning"
  elif [[ $value != "$default" ]] && ! grep -qx "${key}=${value}" "$f" 2>/dev/null; then
    persist_tuning_var "$key" "$value"
  fi
  return 0
}

persist_php_jit() {
  # PHP_BUILD / PHP_FPM_MODULES are no longer persisted: 1.22 always builds
  # PHP from source with a static extension set (lib/php-build.sh).
  # The session/cgi hardening option was removed in 1.22.5: drop its pin.
  local tf=${SETUP_TUNING_FILE:-/etc/default/setup-tuning}
  if [[ -f $tf ]] && grep -qE '^PHP_SESSION_HARDENING=' "$tf" 2>/dev/null \
     && { [[ ${EUID} -eq 0 || -n ${SETUP_TUNING_FILE:-} ]]; }; then
    sed_in_place -E '/^PHP_SESSION_HARDENING=/d' "$tf"
    tune_note "PHP: PHP_SESSION_HARDENING removed from /etc/default/setup-tuning (the session/cgi hardening option was removed in 1.22.5; zz-setup-optimize.ini no longer carries the block)"
  fi
  if (( PHP_JIT_WORDPRESS_PERSIST )); then
    persist_tuning_var PHP_JIT_WORDPRESS "$PHP_JIT_WORDPRESS"
    tune_note "PHP: PHP_JIT_WORDPRESS=${PHP_JIT_WORDPRESS} persisted in /etc/default/setup-tuning"
  fi
  if (( PHP_PAGE_GZIP_PERSIST )); then
    persist_tuning_var PHP_PAGE_GZIP "$PHP_PAGE_GZIP"
    tune_note "PHP: PHP_PAGE_GZIP=${PHP_PAGE_GZIP} persisted in /etc/default/setup-tuning"
  fi
  php_opcache_persist_one PHP_OPCACHE_FILE_OVERRIDE "${PHP_OPCACHE_FILE_OVERRIDE:-1}" "${PHP_OPCACHE_FILE_OVERRIDE_PERSIST:-0}" 1
}

# RAM-derived php.ini values shared by the tuner and the dry-run preview so
# the plan and the written file cannot disagree.
php_ini_profile() {
  local ram_mb=${1:-1024}
  [[ $ram_mb =~ ^[0-9]+$ ]] && (( ram_mb > 0 )) || ram_mb=1024
  PHP_PROFILE_OPCACHE_MB=$(( ram_mb / 16 ))
  (( PHP_PROFILE_OPCACHE_MB < 128 )) && PHP_PROFILE_OPCACHE_MB=128
  (( PHP_PROFILE_OPCACHE_MB > 512 )) && PHP_PROFILE_OPCACHE_MB=512
  # Whole 2 MB, like the JIT buffer (php_jit_settings): with huge code pages
  # an odd arena plus an odd JIT buffer (495 + 61 MB, an 8 GB host) leaves
  # the JIT region unaligned; PHP 8.1 workers then segfaulted running JIT
  # code and 8.6 refused to start (mprotect() failed [22]), 1.22.3 tests.
  PHP_PROFILE_OPCACHE_MB=$(( PHP_PROFILE_OPCACHE_MB / 2 * 2 ))
  PHP_PROFILE_MEMORY_MB=$(( ram_mb / 8 ))
  (( PHP_PROFILE_MEMORY_MB < 256 )) && PHP_PROFILE_MEMORY_MB=256
  (( PHP_PROFILE_MEMORY_MB > 512 )) && PHP_PROFILE_MEMORY_MB=512
  # Under 2 GB a 256M per-request ceiling lets a handful of workers claim
  # the whole host; XenForo and WordPress run within 128M.
  (( ram_mb < 2048 )) && PHP_PROFILE_MEMORY_MB=128
  PHP_PROFILE_REALPATH_KB=$(( ram_mb * 2 ))
  (( PHP_PROFILE_REALPATH_KB < 4096 )) && PHP_PROFILE_REALPATH_KB=4096
  (( PHP_PROFILE_REALPATH_KB > 16384 )) && PHP_PROFILE_REALPATH_KB=16384
  # Called plainly under set -e: a false clamp test above must not become
  # the function's exit status.
  return 0
}
PHP_PROFILE_OPCACHE_MB=128
PHP_PROFILE_MEMORY_MB=256
PHP_PROFILE_REALPATH_KB=4096

# opcache.max_accelerated_files for the PHP files under the nginx vhost
# roots (plus /var/www/*/public without nginx): count * 1.5, clamped to
# 16384..128256, then written as the prime PHP itself rounds the value up to
# (OPcache sizes its hash table from a fixed prime list).  The effective
# table is unchanged, but the ini text only moves when the file count
# crosses a table step: an exact count rewrote zz-setup-optimize.ini and
# reloaded PHP-FPM (resetting OPcache) whenever a template or add-on was
# compiled between two --optimize runs.  130987 when no root is found.
php_opcache_table_size() {
  local want=$1 p
  for p in 223 463 983 1979 3907 7963 16229 32531 65407 130987 262237 524521 1048793; do
    (( p >= want )) && { printf '%s' "$p"; return 0; }
  done
  printf '1048793'
}

php_accelerated_files_target() {
  local file root count=0 n
  local -a roots=()
  for file in /etc/nginx/conf.d/*.conf; do
    [[ -f $file ]] || continue
    root=$(nginx_vhost_root "$file" 2>/dev/null || true)
    [[ -n $root && -d $root ]] && roots+=("$root")
  done
  if (( ${#roots[@]} == 0 )); then
    for root in /var/www/*/public; do
      [[ -d $root ]] && roots+=("$root")
    done
  fi
  if (( ${#roots[@]} == 0 )); then
    printf '130987'
    return 0
  fi
  # A www/apex pair often shares one document root; find does not
  # de-duplicate its operands, so count each tree once or the script table is
  # sized 2x (and clamped at the ceiling).
  mapfile -t roots < <(printf '%s\n' "${roots[@]}" | sort -u)
  n=$(find "${roots[@]}" -xdev -type f -name '*.php' 2>/dev/null | wc -l | tr -d ' ')
  [[ $n =~ ^[0-9]+$ ]] && count=$n
  (( count == 0 )) && { printf '130987'; return 0; }
  php_opcache_table_size "$(tune_clamp $(( count * 3 / 2 )) 16384 128256)"
}

tune_php_fpm_version() {
  local ver=$1
  local socket=${2:-}
  local pool="/etc/php/${ver}/fpm/pool.d/www.conf"
  local ini_dir="/etc/php/${ver}/fpm/conf.d"
  local ini="${ini_dir}/zz-setup-optimize.ini"
  [[ -d /etc/php/${ver}/fpm ]] || return 0
  [[ -f $pool ]] || { tune_miss "PHP ${ver}: no pool.d/www.conf, skipped"; return 0; }  # With no explicit socket request, keep whatever the pool already listens on
  # (TCP for a standalone PHP host, Unix socket for an nginx deployment).
  if [[ -z $socket ]]; then
    socket=$(php_pool_listen "$ver")
    [[ -n $socket ]] || socket=/run/php/php-fpm.sock
  fi

  local nproc ram_mb max_children max_requests php_budget backlog
  local opcache_mb memory_mb realpath_kb
  local current_children
  nproc=$(effective_cpus)
  (( nproc > 0 )) || nproc=1
  ram_mb=$(mem_total_mb)
  backlog=$(effective_backlog)

  php_budget=${OPT_PHP_BUDGET_MB:-0}
  # Capacity and reservation are different numbers.  A live pool keeps its
  # worker count even when the measured per-worker allowance rises; a fresh
  # pool is derived from the budget at the standard 96 MB divisor.  The 50%
  # of RAM ceiling still prevents a small host from overcommitting.
  current_children=$(php_pool_max_children)
  # install_php() sets PHP_FRESH_INSTALL: the package may have auto-started
  # its stock 64-worker pool, and that placeholder must not override the
  # hardware-sized pool.
  [[ ${PHP_FRESH_INSTALL:-0} == 1 ]] && current_children=0
  local live_children="" explicit_value
  if (( current_children > 0 )) \
     && systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
    # A live pool keeps its worker count: the reservation is a memory
    # estimate, not a worker quota.
    live_children=$current_children
  fi
  # An explicit --php children=/max_requests= written at install time is an
  # operator decision, not a hardware guess: keep it across --optimize runs.
  explicit_value=$(explicit_option php_children 2>/dev/null || true)
  # The plan reserved `children x allowance`, so the budget must be divided by
  # the same allowance, not the 64 MB install floor.
  local plan_allowance
  plan_allowance=$(php_worker_allowance_mb "$ver" 2>/dev/null || true)
  [[ $plan_allowance =~ ^[0-9]+$ ]] && (( plan_allowance > 0 )) || plan_allowance=64
  max_children=$(php_plan_max_children "$nproc" "$ram_mb" "$live_children" "$explicit_value" "$php_budget" "$plan_allowance")
  # Two running versions (an inherited host with one site per version) each
  # run a static pool.  The plan booked one pool's RAM, and live_children
  # above is their sum, so split it: each version gets its share and the
  # total stays what was planned (stable across runs, unlike writing the full
  # pool into each).
  local active_versions=0
  active_versions=$(php_fpm_active_versions | grep -c . || true)
  if [[ -z $explicit_value ]] && (( active_versions > 1 )) \
     && systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
    max_children=$(php_split_children "$max_children" "$active_versions")
    tune_summary "PHP ${ver}: ${active_versions} PHP-FPM versions are running; the planned pool is split between them (${max_children} workers each)"
  fi
  if [[ -z $explicit_value ]]; then
    # Informational: the note must not mark the pool dirty, or every
    # --optimize on a host already at the target reloads an unchanged PHP-FPM.
    local per_cpu
    per_cpu=$(awk -v t="$(php_workers_per_cpu_tenths)" 'BEGIN{printf "%.1f", t/10}')
    tune_summary "PHP ${ver}: max_children=${max_children} (hardware target: ${per_cpu} workers per logical CPU; --php children= overrides)"
  fi
  PHP_WRITTEN_CHILDREN=$max_children
  # A pool far larger than the plan is the most expensive misconfiguration
  # seen in the field: a 64-thread host ran 512 static workers (51.8 GB
  # resident, ~103 MB each) and served the same ~850 thread-page req/s as 64
  # workers with a 4x better p50.  Report the delta so the operator sees the
  # memory and latency the next reload returns.
  if (( current_children > 0 )) && (( current_children > max_children * 2 )); then
    local per_worker was_gb now_gb
    per_worker=$(php_worker_allowance_mb "$ver" 2>/dev/null || true)
    [[ $per_worker =~ ^[0-9]+$ ]] && (( per_worker > 0 )) || per_worker=96
    was_gb=$(( current_children * per_worker / 1024 ))
    now_gb=$(( max_children * per_worker / 1024 ))
    tune_summary "PHP ${ver}: pool right-sized ${current_children} -> ${max_children} workers (~${was_gb} GB -> ~${now_gb} GB resident at ${per_worker} MB each; a pool deeper than the thread count only queues on the scheduler)"
  fi
  max_requests=$(( nproc * 1024 ))
  if explicit_value=$(explicit_option php_max_requests); then
    [[ $explicit_value =~ ^[0-9]+$ ]] && (( explicit_value > 0 )) && max_requests=$explicit_value
  fi

  php_ini_profile "$ram_mb"
  opcache_mb=$PHP_PROFILE_OPCACHE_MB
  # The tracing JIT is always on (see the top of the file); WordPress roots
  # can be exempted through [PATH=] sections with SETUP_PHP_JIT_WORDPRESS=0.
  local jit_mode jit_buffer_mb jit_buffer
  read -r jit_mode jit_buffer_mb < <(php_jit_settings "$opcache_mb")
  jit_buffer="${jit_buffer_mb}M"
  # Map OPcache code into the 2 MB huge pages the kernel reserved in
  # vm.nr_hugepages (configure_sysctl): fewer TLB misses on a code-heavy
  # application.  Measured +3.5% on the XenForo member/thread tiers
  # (808 -> 835, 645 -> 670 req/s).  Only enabled when the reservation covers
  # OPcache plus the JIT buffer: a kernel that could allocate only part of
  # the request (common on a fragmented provider image) would otherwise leave
  # OPcache trying to use huge pages it does not have.  With too few pages it
  # falls back to normal pages (the safe default), not a partial mapping.
  local opcache_hugepages=0
  if [[ -r /proc/meminfo ]]; then
    local hp_total
    hp_total=$(awk '/^HugePages_Total:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if php_hugepages_ok "$hp_total" "$opcache_mb" "$jit_buffer_mb"; then
      opcache_hugepages=1
    fi
  fi
  memory_mb=$PHP_PROFILE_MEMORY_MB
  realpath_kb=$PHP_PROFILE_REALPATH_KB

  # /run/php belongs to tmpfiles.d/setup-php.conf (root:root 0755) and the
  # unit's RuntimeDirectory=, which re-chowns it on every start; the sockets
  # inside carry listen.owner/group.  Only create it when it is missing, so
  # the tuner does not fight the unit over its owner.
  [[ -d /run/php ]] || install -d -m 755 /run/php

  # Always a static pool: the worker count is already sized to the host
  # (php_plan_max_children), resident workers answer the first request after
  # an idle period without a fork, and a fixed footprint is what the shared
  # memory plan budgets for.
  tune_pool_set "$pool" pm static "PHP ${ver}: pm=static"
  tune_pool_set "$pool" pm.max_children "$max_children" "PHP ${ver}: max_children=${max_children}"
  tune_pool_set "$pool" pm.max_requests "$max_requests" "PHP ${ver}: max_requests=${max_requests}"
  php_pool_set_listener "$pool" "$ver" "$socket"
  tune_pool_set "$pool" listen.backlog "$backlog" "PHP ${ver}: listen.backlog=${backlog}"
  # Ensure the pool's log destinations exist before enabling slow logging.  A
  # pool upgraded from an older package may still point slowlog at a
  # directory that no longer exists (seen on Ubuntu 24.04); php-fpm -t then
  # fails as soon as request_slowlog_timeout is set.
  local fpm_user fpm_group slowlog accesslog poollog
  fpm_user=$(ini_get "$pool" user)
  fpm_group=$(ini_get "$pool" group)
  slowlog=$(ini_get "$pool" slowlog)
  accesslog=$(ini_get "$pool" access.log)
  poollog=$(ini_get "$pool" error_log)
  if [[ -z $slowlog ]]; then
    slowlog=/var/www/logs/php/php-fpm-slow.log
    tune_pool_set "$pool" slowlog "$slowlog" "PHP ${ver}: slowlog=${slowlog}"
  fi
  ensure_fpm_log_path "$slowlog" "${fpm_user:-www-data}" "${fpm_group:-www-data}"
  ensure_fpm_log_path "$accesslog" "${fpm_user:-www-data}" "${fpm_group:-www-data}"
  ensure_fpm_log_path "$poollog" "${fpm_user:-www-data}" "${fpm_group:-www-data}"
  tune_pool_set "$pool" request_terminate_timeout 300s "PHP ${ver}: request_terminate_timeout=300s"
  tune_pool_set "$pool" request_slowlog_timeout 10s "PHP ${ver}: request_slowlog_timeout=10s"
  tune_pool_set "$pool" catch_workers_output yes "PHP ${ver}: catch_workers_output=yes"
  tune_pool_set "$pool" security.limit_extensions .php "PHP ${ver}: security.limit_extensions=.php"
  # The service watchdog's liveness probe (lib/watchdog.sh) sends one
  # FastCGI request for this path over the pool socket; FPM answers it
  # itself ("pong"), no script runs.  nginx cannot pass it: every
  # fastcgi_pass location matches *.php only.  An existing ping.path stays.
  if ! grep -qE '^[[:space:]]*ping\.path[[:space:]]*=' "$pool"; then
    tune_pool_set "$pool" ping.path /setup-fpm-ping "PHP ${ver}: ping.path=/setup-fpm-ping (service watchdog liveness probe)"
  fi
  tune_pool_set "$pool" rlimit_files "${NOFILE_PHP_RLIMIT_FILES:-524288}" "PHP ${ver}: rlimit_files=${NOFILE_PHP_RLIMIT_FILES:-524288}"
  tune_pool_set "$pool" rlimit_core 0 "PHP ${ver}: rlimit_core=0"
  # Bound master/worker shutdown; see ensure_fpm_global_timeout().
  ensure_fpm_global_timeout "$ver"
  # Older pool templates carried a [global] block inside pool.d/www.conf.
  # pool.d is included after the global settings, so that copy wins over the
  # 10s written above.  Normalise it in place so a restart cannot reintroduce
  # the 60s shutdown wait.
  if grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=' "$pool"; then
    if ! grep -qE '^[[:space:]]*process_control_timeout[[:space:]]*=[[:space:]]*10s[[:space:]]*(;.*)?$' "$pool"; then
      sed_in_place -E 's|^[[:space:]]*process_control_timeout[[:space:]]*=.*|process_control_timeout = 10s|' "$pool"
      tune_note "PHP ${ver}: pool-level process_control_timeout=10s"
    fi
  fi

  # Older releases appended the same directive more than once (the live
  # 8.3 pool carried two rlimit_files/rlimit_core pairs).  php-fpm lets the
  # last value win, but duplicates make the file confusing and hide drift.
  tune_pool_dedupe "$pool" \
    user group listen listen.allowed_clients listen.backlog listen.owner \
    listen.group listen.mode pm pm.max_children pm.max_requests \
    request_terminate_timeout catch_workers_output security.limit_extensions \
    rlimit_files rlimit_core process_control_timeout
  # OPcache's script table is sized from the PHP files the vhosts actually
  # hold (XenForo ~8k, WordPress ~5k, plus 50% for plugins and updates),
  # instead of the 128k ceiling that reserved shared memory for scripts that
  # never exist; the ceiling stays for a host whose roots cannot be found.
  local accel_files
  accel_files=$(php_accelerated_files_target)

  mkdir -p "$ini_dir"
  # The pool template names its own version (pid path); rewrite any phpN.N,
  # not only php8.x, so a 9.x pool is handled the same way.  The listener is
  # excluded: php_pool_set_listener already wrote the path nginx points at,
  # and renaming a versioned socket here would leave the upstream dangling.
  sed_in_place -E "/^[[:space:]]*listen[[:space:]]*=/! s|php[0-9]+\.[0-9]+|php${ver}|g" "$pool"
  local ini_before=""
  [[ -f $ini ]] && ini_before=$(file_md5 "$ini")
  # opcache.file_cache is written explicitly empty so a stray ini sorting
  # earlier cannot turn it on: scripts restored from the file cache are
  # never JIT-compiled (measured 3-5% slower on 8.4).
  cat > "$ini" <<EOF
; Managed by setup.sh --optimize (hardware-aware PHP tuning).
; This file sorts last in conf.d so it wins over earlier defaults.
memory_limit = ${memory_mb}M
max_execution_time = 300
max_input_time = 300
realpath_cache_size = ${realpath_kb}k
realpath_cache_ttl = 43200
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = ${opcache_mb}
opcache.interned_strings_buffer = $(( opcache_mb / 8 < 16 ? 16 : (opcache_mb / 8 > 64 ? 64 : opcache_mb / 8) ))
opcache.jit = ${jit_mode}
opcache.jit_buffer_size = ${jit_buffer}
opcache.huge_code_pages = ${opcache_hugepages}
$(php_jit_threshold_lines "$nproc")
opcache.max_accelerated_files = ${accel_files}
opcache.validate_timestamps = 1
opcache.revalidate_freq = 60
opcache.file_cache =
opcache.file_cache_only = 0
mysqlnd.net_cmd_buffer_size = 524288
mysqli.default_socket = /run/mysqld/mysqld.sock
pdo_mysql.default_socket = /run/mysqld/mysqld.sock
EOF
  # OPcache knobs (php_opcache_opts_load).  enable_file_override is on by
  # default (1.22.5); SETUP_PHP_OPCACHE_FILE_OVERRIDE=0 leaves it out.
  if [[ ${PHP_OPCACHE_FILE_OVERRIDE:-1} == 1 ]]; then
    printf '; file_exists/is_file/is_readable on cached scripts answered from OPcache (SETUP_PHP_OPCACHE_FILE_OVERRIDE=0 turns it off)\nopcache.enable_file_override = 1\n' >> "$ini"
  fi
  # Per-directory sections must come last: everything after a section header
  # belongs to that section.
  php_jit_path_sections /etc/nginx >> "$ini"
  chmod 644 "$ini"
  php_session_clean_timer_sync "$ini" /etc/nginx || warn "PHP ${ver}: the Chevereto session cleanup timer could not be updated"
  if (( ! PHP_JIT_PERSISTED )); then
    persist_php_jit
    PHP_JIT_PERSISTED=1
  fi
  local ini_after jit_desc="${jit_mode}/${jit_buffer}"
  (( PHP_JIT_WORDPRESS )) || jit_desc+=" (WordPress roots off)"
  ini_after=$(file_md5 "$ini")
  if [[ $ini_before != "$ini_after" ]]; then
    tune_note "PHP ${ver}: memory_limit=${memory_mb}M opcache=${opcache_mb}M jit=${jit_desc}"
  fi

  # Test exactly what the unit starts.  The compiled php-fpm has no Debian
  # defaults: a bare `-t` opens ROOT/X.Y/etc/php-fpm.conf and the CLI's ini
  # scan dir, so php_fpm_test (-y, -c and PHP_INI_SCAN_DIR) is used for our
  # build, and a package binary still gets the same explicit paths.
  local fpm_bin fpm_test fpm_ok=1
  fpm_bin=$(php_fpm_binary "$ver" || true)
  if [[ -z $fpm_bin ]]; then
    # Only a version with a php-fpm reaches the tuner (install_php after its
    # build, --optimize for a detected build): a missing binary is a broken
    # build, and an untested pool must not be reported as tuned.
    printf 'PHP %s: no php-fpm binary to test the pool with (%s missing); re-run --php or --optimize to rebuild\n' \
      "$ver" "${PHP_BUILD_ROOT:-/usr/local/lib/setup-php}/${ver}/sbin/php-fpm" >&2
    return 1
  fi
  if [[ -n $fpm_bin ]]; then
    fpm_test=$(tmp_file)
    if declare -F php_fpm_test >/dev/null 2>&1 && declare -F php_fpm_bin >/dev/null 2>&1 \
       && [[ $fpm_bin == "$(php_fpm_bin "$ver")" ]]; then
      php_fpm_test "$ver" >"$fpm_test" 2>&1 || fpm_ok=0
    else
      "$fpm_bin" -t -y "/etc/php/${ver}/fpm/php-fpm.conf" -c "/etc/php/${ver}/fpm/php.ini" \
        >"$fpm_test" 2>&1 || fpm_ok=0
    fi
    if (( ! fpm_ok )); then
      printf 'PHP %s: php-fpm -t failed:\n' "$ver" >&2
      sed 's/^/  /' "$fpm_test" >&2 || true
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# nginx dynamic compression: Brotli, then gzip
# ---------------------------------------------------------------------------
# Every response is compressed per request (dynamic gzip and Brotli).  The
# static-asset precompression of 1.21.58-1.22.0 (.br/.gz siblings for
# gzip_static and brotli_static) was removed in 1.22.1 with those modules:
# the build has neither, so brotli.conf never carries brotli_static, and a
# generated brotli.conf that still does is rewritten without it.
#
# Brotli is compiled into the 1.22 nginx as a static module (--add-module,
# tools/nginx-build.sh): no package, no load_module, no modules-enabled
# stanza.  SCN's nginx.conf no longer includes modules-enabled, and a
# load_module of a Brotli .so would fail nginx -t (there is no such file
# under the build prefix).  ensure_nginx_compression therefore asks
# `nginx -V` for the static ngx_brotli, writes http.d/brotli.conf as plain
# directives, and retires the managed module stanzas and every live
# load_module of Brotli or zstd (R45, R69).
#
# zstd was shipped in 1.21.58 and removed in 1.21.59.  It is cheaper than
# Brotli for the same bytes (XenForo member thread: 19.4 KB at 0.84 ms of
# nginx CPU vs Brotli 4's 18.3 KB at 2.1 ms), but Cloudflare asks origins for
# "br, gzip" only, so on Cloudflare-fronted hosts the module never answered a
# request.  The 1.22 build has no zstd module at all, so the managed zstd
# stanzas are always retired, and an operator file that still uses zstd
# directives is reported (nginx -t rejects it).
NGINX_COMPRESSION_CHANGED=0
NGINX_COMPRESSION_SKIPPED=0
NGINX_BROTLI_OK=0
NGINX_BROTLI_LEVEL=4
NGINX_ZSTD_RETIRED=0
NGINX_MODULE_LOADS_RETIRED=0
# Prefix of a load_module line commented out for the static build; deleting
# the prefix restores the line.
NGINX_LOAD_MODULE_OFF='# setup-1.22 static build: '

# Move the managed zstd stanzas of 1.21.58 (60-zstd.conf, http.d/zstd.conf,
# and an older 40-zstd.conf) out of the tree.  Only files that carry the
# "Managed by setup.sh" header move; an operator's own zstd use is reported,
# because this nginx cannot load the module whatever the stanza says.
nginx_retire_zstd() {
  local target=${1:-/etc/nginx} f moved users
  NGINX_ZSTD_RETIRED=0
  for f in "${target}/modules-enabled/40-zstd.conf" "${target}/modules-enabled/60-zstd.conf" \
           "${target}/http.d/zstd.conf"; do
    [[ -e $f ]] && grep -q '^# Managed by setup.sh' "$f" 2>/dev/null || continue
    moved=$(preserve_to_tmp "$f" 2>/dev/null || true)
    [[ -n $moved ]] && info "Moved retired Zstandard file to ${moved}"
    NGINX_ZSTD_RETIRED=1
  done
  users=$(nginx_zstd_users "$target")
  if [[ -n $users ]]; then
    tune_miss "zstd: this nginx is built without zstd, but ${users//$'\n'/ } still configure(s) it (nginx -t rejects those directives; remove them there)"
  fi
  return 0
}

# Active files under the tree that load or configure zstd, one per line,
# leaving out the files named after the tree.  Only *.conf files are read:
# the repository's old http.d/zstd_conf template is never included, and
# modules-enabled is not included by the nginx tree.
nginx_zstd_users() {
  local target=${1:-/etc/nginx} f x skip
  shift
  while IFS= read -r f; do
    skip=0
    for x in "$@"; do [[ $f == "$x" ]] && { skip=1; break; }; done
    (( skip )) || printf '%s\n' "$f"
  done < <(grep -RlsE --include='*.conf' --exclude-dir=modules-enabled \
    '^[[:space:]]*(load_module[[:space:]].*ngx_http_zstd|zstd(_[a-z_]+)?[[:space:]])' "$target" 2>/dev/null | sort)
}

# True when an active file under the tree still loads or configures zstd.
nginx_zstd_in_use() {
  [[ -n $(nginx_zstd_users "${1:-/etc/nginx}") ]]
}

# 1.21.58 hosts had the zstd module as a package from the Angie repository.
# The migration purges every angie-module-* package together with Angie, and
# the 1.22 nginx is not a package, so nothing is left to purge here.  Kept
# (always empty) so the install and --optimize callers need no change.
NGINX_ZSTD_PURGE_PENDING=0
NGINX_ZSTD_PURGE_RESULT=""
nginx_purge_zstd_module() {
  NGINX_ZSTD_PURGE_RESULT=""
  NGINX_ZSTD_PURGE_PENDING=0
  return 0
}

# Status 0 when BIN (default: nginx_test_bin) has ngx_brotli compiled in
# statically (`--add-module=...ngx_brotli` in nginx -V), 1 when it has none
# or only a dynamic one (no load_module is ever written, so a dynamic module
# would not be loaded), 2 when there is no binary to ask.  The same match as
# tools/nginx-build.sh verify_binary and SCN's ci-config-test.sh.
nginx_static_brotli() {
  local bin=${1:-} v re='--add-module=[^[:space:]]*ngx_brotli'
  [[ -n $bin ]] || bin=$(nginx_test_bin)
  nginx_bin_usable "$bin" || return 2
  v=$("$bin" -V 2>&1) || return 1
  [[ $v =~ $re ]]
}

# Retire what made a packaged server load Brotli/zstd as dynamic modules:
# the managed modules-enabled/50-brotli.conf moves to /tmp, an unmanaged
# modules-enabled link is moved the same way, and a load_module of a Brotli
# or zstd module in nginx.conf, custom.d (main context) or modules-enabled is
# commented out with NGINX_LOAD_MODULE_OFF.  Sets NGINX_MODULE_LOADS_RETIRED.
nginx_retire_module_loads() {
  local target=${1:-/etc/nginx} f moved tmp
  local re='^[[:space:]]*load_module[[:space:]][^;#]*ngx_http_(brotli|zstd)[a-z_]*_module'
  NGINX_MODULE_LOADS_RETIRED=0
  f="${target}/modules-enabled/50-brotli.conf"
  if [[ -f $f && ! -L $f ]] && grep -q '^# Managed by setup.sh' "$f" 2>/dev/null; then
    moved=$(preserve_to_tmp "$f" 2>/dev/null || true)
    if [[ -n $moved ]]; then
      info "Moved retired Brotli module stanza to ${moved}"
      tune_note "modules-enabled/50-brotli.conf: retired to ${moved} (Brotli is compiled in)"
      NGINX_MODULE_LOADS_RETIRED=1
    fi
  fi
  for f in "${target}/nginx.conf" "${target}"/custom.d/*.conf "${target}"/modules-enabled/*.conf; do
    [[ -e $f || -L $f ]] || continue
    grep -qE "$re" "$f" 2>/dev/null || continue
    if [[ -L $f ]]; then
      # A package's modules-available link: move the link, never its target.
      [[ $f == "${target}/modules-enabled/"* ]] || continue
      moved=$(preserve_to_tmp "$f" 2>/dev/null || true)
      [[ -n $moved ]] || continue
      tune_note "${f#"$target"/}: Brotli/zstd module link retired to ${moved}"
      NGINX_MODULE_LOADS_RETIRED=1
      continue
    fi
    tmp=$(tmp_file) || return 1
    awk -v re="$re" -v off="$NGINX_LOAD_MODULE_OFF" '$0 ~ re { print off $0; next } { print }' "$f" > "$tmp" || continue
    if commit_if_changed "$f" "$tmp"; then
      tune_note "${f#"$target"/}: load_module of a Brotli/zstd module commented out (Brotli is compiled in, zstd is not built)"
      NGINX_MODULE_LOADS_RETIRED=1
    fi
  done
  return 0
}

# Dynamic Brotli level: SETUP_BROTLI_LEVEL when valid, otherwise 1 (1.22.5).
# One owner for the install, --optimize and dry-run values.
nginx_brotli_level() {
  local level=${SETUP_BROTLI_LEVEL:-}
  if ! [[ $level =~ ^([1-9]|1[01])$ ]]; then
    # Every compressible response, static assets included (no siblings).
    # 1.22.5, XenForo behind Cloudflare, pinned clock, two interleaved
    # rounds: level 1 served 4.2-4.7 % more uncached req/s than level 4 on
    # every tier (p99 equal or lower) for about 16 % more bytes to the
    # proxy (11.1 vs 9.5 KB per home page); levels 2 and 3 sat between.
    # Compression competes with PHP for the same cores on every host size.
    level=1
  fi
  printf '%s' "$level"
}

ensure_nginx_compression() {
  local target=${1:-/etc/nginx}
  local conf="${target}/nginx.conf"
  [[ -f $conf ]] || return 0
  NGINX_COMPRESSION_CHANGED=0
  NGINX_COMPRESSION_SKIPPED=0
  NGINX_BROTLI_OK=0
  local changed=0

  # Before the opt-out: a load_module of a .so that does not exist makes the
  # whole tree fail nginx -t, so this is a fix to the tree, not a choice of
  # compression profile.
  nginx_retire_module_loads "$target"
  (( NGINX_MODULE_LOADS_RETIRED )) && changed=1

  if [[ ${SETUP_NGINX_COMPRESSION:-1} == 0 ]]; then
    NGINX_COMPRESSION_SKIPPED=1
    NGINX_COMPRESSION_CHANGED=$changed
    (( changed )) && TUNE_DIRTY=1
    info "nginx dynamic Brotli disabled by SETUP_NGINX_COMPRESSION=0"
    return 0
  fi

  local brotli_level bin brc=0
  brotli_level=$(nginx_brotli_level)
  NGINX_BROTLI_LEVEL=$brotli_level

  # --optimize installs nothing for compression any more: Brotli is part of
  # the build, so its presence is a fact of the binary, not a package state.
  bin=$(nginx_test_bin)
  nginx_static_brotli "$bin" || brc=$?
  case $brc in
    0) NGINX_BROTLI_OK=1 ;;
    2) warn "No nginx binary at ${bin} to check for static Brotli; http.d/brotli.conf left as it is" ;;
    *) warn "${bin} has no static Brotli module (ngx_brotli); gzip only" ;;
  esac

  mkdir -p "${target}/http.d"
  local tmp moved f
  # zstd (1.21.58) is retired: see the header of this section.
  nginx_retire_zstd "$target"
  (( NGINX_ZSTD_RETIRED )) && changed=1

  if (( NGINX_BROTLI_OK )); then
    tmp=$(tmp_file)
    if [[ -f "${target}/http.d/brotli_conf" ]]; then
      {
        printf '# Managed by setup.sh: dynamic Brotli from http.d/brotli_conf.\n'
        cat "${target}/http.d/brotli_conf"
      } > "$tmp"
      sed_in_place -E "s/^brotli_comp_level [0-9]+;/brotli_comp_level ${brotli_level};/" "$tmp"
      # brotli_static is not compiled in (1.22.1): never carried over, also
      # not as a line an activation commented out.
      sed_in_place -E '/^[[:space:]]*(# setup-nginx-build-off: )?brotli_static([[:space:]]|;)/d' "$tmp"
    else
      cat > "$tmp" <<EOT
# Managed by setup.sh: dynamic Brotli (template was missing).
brotli on;
brotli_comp_level ${brotli_level};
brotli_min_length 50;
brotli_types text/plain text/css text/xml application/json application/javascript application/xml image/svg+xml font/ttf font/otf;
EOT
    fi
    if commit_if_changed "${target}/http.d/brotli.conf" "$tmp"; then
      chmod 644 "${target}/http.d/brotli.conf"
      changed=1
    fi
  elif (( brc == 1 )) && [[ -f "${target}/http.d/brotli.conf" ]] \
       && grep -q '^# Managed by setup.sh' "${target}/http.d/brotli.conf" 2>/dev/null; then
    # This binary does not know the brotli directives; the managed stanza
    # would fail the whole tree.  Moved to /tmp (never deleted).
    moved=$(preserve_to_tmp "${target}/http.d/brotli.conf" 2>/dev/null || true)
    [[ -n $moved ]] && info "Moved http.d/brotli.conf to ${moved}: the nginx binary has no Brotli"
    changed=1
  fi

  # Never leave the service unable to start because of the compression
  # stanza.  Only a failure that names brotli moves the managed file away
  # (to /tmp, never deleted); any other failure belongs to the caller's own
  # nginx -t gate and must not silently cost the host its Brotli.
  local testlog
  if (( brc != 2 )); then
    testlog=$(tmp_file)
    if ! nginx_test_tree "$conf" >"$testlog" 2>&1; then
      if grep -qi 'brotli' "$testlog" && [[ -f "${target}/http.d/brotli.conf" ]] \
         && grep -q '^# Managed by setup.sh' "${target}/http.d/brotli.conf" 2>/dev/null; then
        warn "nginx rejected the Brotli configuration; disabling Brotli"
        sed 's/^/  /' "$testlog" >&2 || true
        moved=$(preserve_to_tmp "${target}/http.d/brotli.conf" 2>/dev/null || true)
        [[ -n $moved ]] && info "Moved rejected compression file to ${moved}"
        NGINX_BROTLI_OK=0
        changed=1
        if ! nginx_test_tree "$conf" >/dev/null 2>&1; then
          warn "nginx still rejects the configuration after removing the Brotli file"
        fi
      else
        warn "nginx -t fails for a reason other than compression; Brotli settings kept"
        sed 's/^/  /' "$testlog" >&2 || true
      fi
    fi
  fi

  NGINX_COMPRESSION_CHANGED=$changed
  if (( changed )); then
    TUNE_DIRTY=1
  fi
  return 0
}

# Fetch the canonical nginx tree and run the repository's deployer.  Kept
# separate from the tuning pass so --optimize can synchronize /etc/nginx and
# then apply the hardware-aware profile to the freshly deployed files.
# ---------------------------------------------------------------------------
# nginx config tree
# ---------------------------------------------------------------------------
# This deployer used to live in the server-configs-nginx repository as a
# separate script.  It now lives here so a fresh install and `--optimize`
# share exactly one implementation: fetch -> sync tree -> hardware profile.
# deploy_nginx_tree reloads a running nginx after the sync unless the caller
# tunes the tree first and reloads/restarts it itself.
NGINX_SYNC_RELOAD=1
NGINX_CACHE_DIRS=(/home/nginx_cache /home/nginx_cache_chev /home/xf_proxy_cache
                  /home/proxy_cache /home/proxy_cdn)

# ---------------------------------------------------------------------------
# Operator upstream preservation
# ---------------------------------------------------------------------------
# The canonical tree is synced with rsync, so a custom vhost under conf.d can
# outlive the upstream block it relied on: the repository may rename or drop an
# upstream between releases (xf_websocket -> xf_websocket_so on one host), and
# nginx then refuses to load the whole tree with
#   [emerg] host not found in upstream "soketi_websocket"
# which made --optimize fail and roll the sync back.  Snapshot every upstream
# block before the sync, then re-add only the blocks a deployed vhost still
# references and the new tree no longer defines.  The preserved block lives in
# one managed include so it is easy to inspect and is regenerated every run.
nginx_tree_files() {
  local dir=$1 exclude=${2:-}
  [[ -d $dir ]] || return 0
  local -a prune=()
  [[ -n $exclude ]] && prune=(-not -path "$exclude")
  find "$dir" -type f \( -name '*.conf' -o -name '*_conf' \) \
    "${prune[@]}" -print0 2>/dev/null
}

# Names a deployed vhost passes to a *_pass directive.  Only bare names are
# upstreams; a host:port, unix: path or $variable is not.
nginx_referenced_upstreams() {
  local dir=$1
  nginx_tree_files "$dir" \
    | xargs -0 -r grep -hoE '(proxy_pass|grpc_pass|grpcs_pass|uwsgi_pass|scgi_pass|fastcgi_pass)[[:space:]]+[^;]+' 2>/dev/null \
    | sed -E -e 's|^[a-z_]+[[:space:]]+||' -e 's#^(https?://|grpcs?://)##' \
    | awk '{print $1}' \
    | grep -E '^[A-Za-z0-9_]+$' | sort -u || true
}

# Upstream names the tree defines.  EXCLUDE (the managed include) is skipped
# so its own definitions do not count as canonical on the next run.
nginx_defined_upstreams() {
  local dir=$1 exclude=${2:-}
  nginx_tree_files "$dir" "$exclude" \
    | xargs -0 -r grep -hE '^[[:space:]]*upstream[[:space:]]+[A-Za-z0-9_]+' 2>/dev/null \
    | sed -E 's|^[[:space:]]*upstream[[:space:]]+([A-Za-z0-9_]+).*|\1|' | sort -u || true
}

# Write each "upstream NAME { ... }" block of SRC to DEST/NAME.conf.  The awk
# depth counter keeps multi-line blocks together and stops at the closing
# brace; comments before a block are not part of it.
nginx_snapshot_upstreams() {
  local src=$1 dest=$2 file
  [[ -d $src && -d $dest ]] || return 0
  nginx_tree_files "$src" | while IFS= read -r -d '' file; do
    awk -v out="$dest" '
      /^[[:space:]]*upstream[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{/ {
        name = $2
        sub(/[[:space:]]*\{.*/, "", name)
        depth = 0
        inblock = 1
      }
      inblock {
        line = $0
        opens = gsub(/\{/, "{", line)
        line = $0
        closes = gsub(/\}/, "}", line)
        depth += opens - closes
        print $0 >> (out "/" name ".conf")
        if (depth <= 0) { inblock = 0; close(out "/" name ".conf") }
        next
      }
    ' "$file"
  done
}

# Re-add the blocks a vhost still references and the synced tree lost.
nginx_restore_upstreams() {
  local target=$1 snapshot=$2
  local include="$target/http.d/zz-setup-preserved-upstreams.conf"
  local name tmp moved
  local -a referenced=() defined=() missing=()
  [[ -d $target ]] || return 0
  mapfile -t referenced < <(nginx_referenced_upstreams "$target")
  mapfile -t defined < <(nginx_defined_upstreams "$target" "$include")
  for name in "${referenced[@]}"; do
    [[ -n $name ]] || continue
    [[ " ${defined[*]} " == *" $name "* ]] && continue
    [[ -n $snapshot && -f "$snapshot/$name.conf" ]] || continue
    missing+=("$name")
  done
  if (( ${#missing[@]} == 0 )); then
    if [[ -f $include ]] && grep -q 'Managed by setup.sh: upstream definitions preserved' "$include" 2>/dev/null; then
      moved=$(preserve_to_tmp "$include" 2>/dev/null || true)
      [[ -n $moved ]] && info "Preserved upstream include no longer needed -> ${moved}"
    fi
    return 0
  fi
  tmp=$(tmp_file) || return 1
  {
    printf '# Managed by setup.sh: upstream definitions preserved from the previous tree.\n'
    printf '# A deployed vhost still references a name the canonical repository no\n'
    printf '# longer defines; without this block nginx refuses to load with\n'
    printf '# "host not found in upstream".  Regenerated by install/--optimize.\n'
    for name in "${missing[@]}"; do
      printf '\n# preserved from the previous /etc/nginx tree: %s\n' "$name"
      # A zone name from the old tree would collide with a zone in the new one;
      # the block works without it.
      sed -E '/^[[:space:]]*zone[[:space:]]/d' "$snapshot/$name.conf"
    done
  } > "$tmp"
  if commit_if_changed "$include" "$tmp"; then
    chmod 644 "$include"
    info "Preserved upstream definition(s) still referenced by a vhost: ${missing[*]}"
  fi
  return 0
}

# Basic-auth password files the repository templates tell operators to keep
# inside the tree (htpasswd/chev, htpasswd/xfadmin, basic_auth/wp_auth,
# conf.d/r3f_auth), plus any file an active auth_basic_user_file names.  The
# deploy normaliser resets every file to root:root 0644, so a password file
# the operator had tightened to 0640 came back world-readable on every run.
# Give them 0640 root:<nginx worker group> instead: the workers read the file
# per request, nobody else needs to.  Symlinks and paths that leave the tree
# are skipped so a crafted reference cannot retarget the chmod.
nginx_auth_user_files() {
  local target=$1
  find "$target" -path "$target/ssl" -prune -o \
       -type f \( -name '*.conf' -o -name '*_conf' \) -print0 2>/dev/null \
    | xargs -0 -r awk '
        {
          line = $0
          sub(/#.*/, "", line)
          while (match(line, /auth_basic_user_file[[:space:]]+[^;[:space:]]+/)) {
            v = substr(line, RSTART, RLENGTH)
            sub(/^auth_basic_user_file[[:space:]]+/, "", v)
            gsub(/["\047]/, "", v)
            if (v !~ /\$/) print v
            line = substr(line, RSTART + RLENGTH)
          }
        }' 2>/dev/null || true
}

# Group of the nginx workers (nginx.conf `user` directive, default www-data).
nginx_auth_group() {
  local group
  group=$(awk '/^[[:space:]]*user[[:space:]]/ {
      g = ($3 != "") ? $3 : $2; sub(/;.*/, "", g); print g; exit
    }' "$1/nginx.conf" 2>/dev/null || true)
  [[ $group =~ ^[A-Za-z0-9_.-]+$ ]] || group=www-data
  printf '%s\n' "$group"
}

nginx_secure_auth_files() {
  local target=$1 group file ref
  local -a files=()
  [[ -d $target ]] || return 0
  group=$(nginx_auth_group "$target")
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(find "$target" -path "$target/ssl" -prune -o \
                -path "$target/stream.d" -prune -o \
                -type f \( -path "$target/htpasswd/*" -o -path "$target/basic_auth/*" \
                           -o -name '*_auth' \) -print0 2>/dev/null || true)
  while IFS= read -r ref; do
    [[ -n $ref ]] || continue
    [[ $ref == /* ]] || ref="$target/$ref"
    [[ $ref == "$target"/* && $ref != *..* && -f $ref && ! -L $ref ]] || continue
    files+=("$ref")
  done < <(nginx_auth_user_files "$target")
  # 0640 only after the group change worked: a root:root 0640 file is
  # unreadable for the workers and every protected location would fail.
  for file in "${files[@]}"; do
    if chown "root:${group}" "$file" 2>/dev/null; then
      chmod 640 "$file" 2>/dev/null || true
    fi
  done
  return 0
}

# Sync CONFIG_SOURCE_DIR into /etc/nginx and normalise what a checkout can
# carry (ownership, modes, macOS AppleDouble files, sample keys).  The caller
# has already run fetch_server_configs.
deploy_nginx_tree() {
  local target=/etc/nginx
  local log_dir="${LOG_ROOT}/nginx"
  local src=${CONFIG_SOURCE_DIR:-}
  [[ -n $src && -d $src ]] || { warn "No nginx config source directory available"; return 1; }
  # The nginx tree of server-configs-nginx (CONFIG_REPO_REF=main) ships
  # its own fastcgi.conf / fastcgi_params (SERVER_SOFTWARE "nginx", with the
  # version on admin.php only, R38) and mime.types; no package provides them any more, so a
  # tree without them (the 1.21 Angie tree, tag angie-final) is refused before
  # anything in /etc/nginx changes.
  local req
  for req in nginx.conf mime.types fastcgi.conf fastcgi_params; do
    [[ -f $src/$req ]] || { warn "server configs at ${src} lack ${req} (CONFIG_REPO_REF=${CONFIG_REPO_REF:-?} is not the nginx tree)"; return 1; }
  done

  # Capture the live upstream blocks before rsync overwrites the files that
  # define them (see nginx_restore_upstreams).
  local upstream_snapshot=""
  if [[ -d $target ]]; then
    upstream_snapshot=$(tmp_dir nginx-upstreams.XXXXXX) || upstream_snapshot=""
    [[ -n $upstream_snapshot ]] && nginx_snapshot_upstreams "$target" "$upstream_snapshot"
  fi

  # --no-owner/--no-group + --chmod prevents a checkout owned by uid 1000 from
  # leaving writable files in /etc/nginx. Never copy the sample private key.
  # scripts/ci-*.sh and scripts/uss-ref drive the repository's own CI (they
  # build nginx and run test trees); nothing on a host runs them.
  rsync -a --no-owner --no-group --chmod=D755,F644 \
    --exclude='*.md' --exclude='*.txt' --exclude='.git*' \
    --exclude='.github/' --exclude='test/' --exclude='.editorconfig' \
    --exclude='h5bp/tls/private.key' --exclude='h5bp/tls/certificate.pem' \
    --exclude='/scripts/ci-*.sh' --exclude='/scripts/uss-ref' \
    "$src"/ "$target"/ || return 1
  mkdir -p "$target/snippets" "$target/custom.d"
  # macOS AppleDouble files appear when a local checkout is used via
  # CONFIG_SOURCE_DIR.  Move them out of the live tree; nothing is unlinked.
  local -a stale=()
  mapfile -t stale < <(find "$target" -name '._*' 2>/dev/null || true)
  (( ${#stale[@]} > 0 )) && retire_paths "${stale[@]}"

  # Legacy demo/error pages, sample keys and superseded sample templates that
  # older deployments may still carry, plus old setup.sh-managed overrides
  # that duplicated the cache zones, log_format and limiter variables now
  # provided by the repository tree (PHP-FPM templates live in configs/php).
  # None of these ship in the current repository, so each is retired once per
  # host; they go to /tmp, never to rm, per the file-safety policy.
  retire_paths "$target/test" \
        "$target"/v3.html "$target"/ua.html "$target"/503.html \
        "$target"/ssl/default/certificate.pem "$target"/ssl/default/private.key \
        "$target"/conf.d/templates/sample_basic_php.conf \
        "$target"/conf.d/templates/sample_psi.conf \
        "$target"/conf.d/templates/sample_pingvin_proxy.conf \
        "$target"/conf.d/templates/sample_proxy_pass.conf \
        "$target"/scripts/www_*.conf \
        "$target/scripts/custom_dan.ini" \
        "$target/scripts/php-fpm-limits.conf" \
        "$target/scripts/auto_tune.sh" \
        "$target"/scripts/ci-*.sh \
        "$target/scripts/uss-ref" \
        "$target/scripts/limit_nofile.conf" \
        "$target/scripts/etc_default_nginx" \
        "$target/http.d/98_setup_cache.conf" \
        "$target/http.d/99_setup_overrides.conf" \
        "$target/http.d/limit_req_whitelist.conf" \
        "$target/http.d/fastcgi_cache_conf" \
        "$target/http.d/fastcgi_cache_chev_conf" \
        "$target/http.d/xf_proxy_cache_conf" \
        "$target/http.d/xf_websocket_conf" \
        "$target/http.d/limit_req_conf" \
        "$target/http.d/proxy_cache_conf" \
        "$target/http.d/referer_map.conf" \
        "$target/http.d/ppa_eilander_conf" \
        "$target/http.d/http_trim_filter_conf" \
        "$target/http.d/reverse_proxy_conf" \
        "$target/h5bp/limit_req/_high_conf" \
        "$target/h5bp/limit_req/_medium_conf" \
        "$target/h5bp/tls/private.key" \
        "$target/h5bp/tls/certificate.pem"

  # Re-add any operator-referenced upstream the new tree dropped (rsync
  # overwrites the file that used to define it; a custom vhost survives).
  nginx_restore_upstreams "$target" "$upstream_snapshot"

  # A custom http.d file may carry a directive the canonical tree also sets;
  # nginx rejects duplicates in the http context before the tuner can run.
  tune_nginx_dedupe_http "$target" || true

  # A hand-written vhost may include h5bp/php_xf.conf inside a location (the
  # old single-location snippet allowed that).  The canonical file defines a
  # server-level named location, so the tree fails `nginx -t` before the
  # tuner's migration in nginx_apply_profile would run.  Point such includes
  # at the generic h5bp/php.conf first; the server-level include stays.
  if declare -F nginx_migrate_guest_cache_includes >/dev/null 2>&1; then
    nginx_migrate_guest_cache_includes "$target" || warn "Nested guest-cache include migration reported a problem"
  fi
  # The QUIC catch-all now owns the UDP 443 socket options; an operator
  # vhost that still sets them would fail the test below.
  tune_vhost_quic_listen_options "$target" || true

  # Normalise ownership/modes for everything except operator certificates and
  # stream configs.  scripts/*.sh stay executable for the Cloudflare cron job.
  # Password files are secured first and the normaliser then skips files that
  # are already root:<worker group> 0640.  Securing them after the 0644 pass
  # left each one world-readable for the length of the auth_basic_user_file
  # scan on every install/--optimize.  The skip only keeps a root-owned file
  # that no one but root can write, so it never preserves a checkout's
  # uid-1000 or group-writable leftovers.  It is dropped when the group does
  # not exist: find aborts the whole pass on an unknown -group name.
  nginx_secure_auth_files "$target"
  local auth_group
  local -a keep_secured=()
  auth_group=$(nginx_auth_group "$target")
  if getent group "$auth_group" >/dev/null 2>&1; then
    keep_secured=(-type f -user root -group "$auth_group" -perm 0640 -prune -o)
  fi
  find "$target" -path "$target/ssl" -prune -o \
       -path "$target/stream.d" -prune -o \
       "${keep_secured[@]}" \
       -exec chown root:root {} + 2>/dev/null || true
  find "$target" -path "$target/ssl" -prune -o \
       -path "$target/stream.d" -prune -o \
       -type d -exec chmod 755 {} + 2>/dev/null || true
  find "$target" -path "$target/ssl" -prune -o \
       -path "$target/stream.d" -prune -o \
       "${keep_secured[@]}" \
       -type f -exec chmod 644 {} + 2>/dev/null || true
  chmod 755 "$target"/scripts/*.sh 2>/dev/null || true

  # The catch-all 443 server needs a unique local certificate.  The repository
  # ships no private key; generate one per host instead.
  if [[ ! -s "$target/ssl/default/fullchain.pem" \
        || ! -s "$target/ssl/default/privkey.pem" ]]; then
    local hostname_fqdn
    hostname_fqdn=$(hostname -f 2>/dev/null || hostname)
    install -d -m 700 "$target/ssl/default"
    openssl req -x509 -nodes -newkey rsa:2048 -days 397 \
        -subj "/CN=${hostname_fqdn}" \
        -addext "subjectAltName=DNS:${hostname_fqdn}" \
        -keyout "$target/ssl/default/privkey.pem" \
        -out "$target/ssl/default/fullchain.pem" >/dev/null 2>&1
    chmod 600 "$target/ssl/default/privkey.pem"
    chmod 644 "$target/ssl/default/fullchain.pem"
  fi

  # Central log and cache directories.  All service logs live under
  # /var/www/logs so they can be collected as one tree.
  install -d -m 750 -o www-data -g www-data "$log_dir"
  secure_log_file "$log_dir/error.log" www-data www-data

  local cache_dir
  for cache_dir in "${NGINX_CACHE_DIRS[@]}"; do
    mkdir -p "$cache_dir"
    chown www-data:www-data "$cache_dir" 2>/dev/null || true
    chmod 750 "$cache_dir"
  done

  # Before the first test of the synced tree: otherwise the run that retires
  # the stale file still prints nginx's "defined but not used" warning.
  tune_retire_unused_acme_client "$target"
  tune_retire_superseded_setup_files "$target"

  # nginx -t opens the temp paths under /var/cache/nginx and the log
  # directory; A's tmpfiles.d entry creates them (R70, R84).
  if declare -F nginx_build_tmpfiles_apply >/dev/null 2>&1; then
    nginx_build_tmpfiles_apply || true
  fi

  # A fresh install (install_nginx sets NGINX_DEPLOY_FIT_BIN to the staged
  # candidate) fits the tree to that build before the first test: operator
  # vhosts left in /etc/nginx (e.g. after a distro nginx was cleared) may
  # still carry directives of modules the lean build leaves out (gzip_static,
  # brotli_static since 1.22.1).  They are commented out with the
  # '# setup-nginx-build-off: ' marker and reported, the same as activation
  # does, instead of failing the test and rolling the install back.  A line
  # the fit cannot handle is left to the test below, which reports it.
  # Every other sync (--optimize) fits to the live build the same way, so a
  # droppable directive an operator added since activation does not fail the
  # sync (1.22.1 test: a new vhost with gzip_static on; stopped --optimize).
  # The migration tests its own candidate (NGINX_TEST_BIN) and fits it there.
  if declare -F nginx_build_fit >/dev/null 2>&1; then
    if [[ -n ${NGINX_DEPLOY_FIT_BIN:-} ]]; then
      nginx_build_fit info "$NGINX_DEPLOY_FIT_BIN" "$target/nginx.conf" || true
    elif [[ -z ${NGINX_TEST_BIN:-} && -x ${NGINX_BIN:-} ]]; then
      nginx_build_fit info "" "$target/nginx.conf" || true
    fi
  fi

  # HTTP/3 on by default in existing vhosts too (self-testing: it only
  # changes a tree that passes nginx -t before and after).
  tune_vhost_http3_default "$target" || true

  # Validate before anything reloads.  A stopped service is valid (the tree is
  # applied at the next start); reload only when the unit is active.  The
  # migration tests with its candidate binary (NGINX_TEST_BIN).
  if ! nginx_test_tree "$target/nginx.conf"; then
    warn "nginx configuration test failed; live service left untouched"
    local quic_hit
    while IFS= read -r quic_hit; do
      [[ -n $quic_hit ]] || continue
      warn "nginx: ${quic_hit#"$target"/} sets socket options on a QUIC 443 listen; conf.d/1.https.default.conf owns reuseport/rcvbuf/sndbuf for UDP 443 (\"duplicate listen options\"): remove them from that line"
    done < <(nginx_quic_listen_conflicts "$target")
    return 1
  fi
  # The install and --optimize paths tune the synced tree before they reload
  # or restart it themselves (NGINX_SYNC_RELOAD=0); reloading here as well
  # briefly ran the repository defaults (65535 connections, 16g cache zones)
  # on every --optimize and doubled the reloads.
  if (( NGINX_SYNC_RELOAD )) && systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl daemon-reload || true
    if systemctl reload nginx.service 2>/dev/null; then
      info "nginx configuration reloaded"
    else
      warn "nginx configuration is valid but the reload failed"
    fi
  fi
  # nginx's master opens log files as root.  Normalise pre-existing logs for
  # the UMask=0027 drop-in; new files are already 0640.
  find "$log_dir" -type f -name '*.log' -exec chmod 640 {} + 2>/dev/null || true
  return 0
}

# Files named with a double underscore are a botched `.conf` rename from an
# old layout.  nginx.conf includes `http.d/*.conf`, so they are never loaded
# and only make the tuner warn about a stale cache zone (e.g.
# `proxy_cache__conf`).  Move them to /tmp; never delete.
retire_nginx_double_underscore() {
  local target=${1:-/etc/nginx} file moved
  for file in "$target"/http.d/*__conf; do
    [[ -f $file ]] || continue
    moved=$(preserve_to_tmp "$file" 2>/dev/null || true)
    if [[ -n $moved ]]; then
      info "Retired legacy nginx file ${file} -> ${moved} (not deleted)"
    else
      warn "Could not move legacy nginx file ${file}; leaving it in place"
    fi
  done
  return 0
}

# The nginx tree (CONFIG_REPO_REF, SCN main) into /etc/nginx.
# The 1.21 tree also shipped scripts/limit_nofile.conf and
# scripts/etc_default_nginx for a unit drop-in and /etc/default/<server>.
# The nginx.service written by lib/nginx-build.sh sets LimitNOFILE=524288 and
# UMask=0027 itself and reads no /etc/default file, so neither is required
# or installed any more (deploy_nginx_tree retires stale copies).
sync_nginx_repo_configs() {
  fetch_server_configs || return 1
  deploy_nginx_tree || return 1
  retire_nginx_double_underscore /etc/nginx
  return 0
}

# The hardware-aware nginx profile applied to a freshly synced /etc/nginx:
# guest caches, the tuner and dynamic compression, in
# the one order both the installer and --optimize use (the repository
# templates are restored first so the tuner's cache values win).  Returns 1
# when the tuner fails; the compression outcome is left in
# NGINX_COMPRESSION_SUMMARY for the caller's report.
NGINX_COMPRESSION_SUMMARY=""
nginx_apply_profile() {
  local target=${1:-/etc/nginx}
  optimize_wordpress_cache "$target" || warn "WordPress cache setup was skipped"
  ensure_xf_guest_cache "$target" || warn "XenForo cache setup was skipped"
  nginx_migrate_guest_cache_includes "$target" || warn "Guest cache include migration was skipped"
  tune_nginx_configs "$target" || return 1
  # Dynamic Brotli compression.  The module is optional, so a failure here
  # must not stop the run; gzip remains active.
  ensure_nginx_compression "$target" || warn "nginx compression setup was skipped"
  (( NGINX_COMPRESSION_CHANGED )) && TUNE_DIRTY=1
  if (( NGINX_COMPRESSION_SKIPPED )); then
    NGINX_COMPRESSION_SUMMARY="Compression: unchanged (SETUP_NGINX_COMPRESSION=0)"
  else
    local -a enc=()
    (( NGINX_BROTLI_OK )) && enc+=("Brotli level ${NGINX_BROTLI_LEVEL}")
    enc+=("gzip")
    NGINX_COMPRESSION_SUMMARY="Compression: $(printf '%s, ' "${enc[@]}" | sed 's/, $//') (first the client accepts)"
  fi
  return 0
}

# md5 of one file, "absent" when it does not exist: the before/after probe
# every tuner uses to decide whether a service needs a restart.
file_md5() {
  [[ -f $1 ]] || { printf 'absent'; return 0; }
  md5sum "$1" | awk '{print $1}'
}

# One digest for a configuration tree, so --optimize can tell whether the
# sync + profile actually changed anything before reloading a service.
config_tree_digest() {
  local dir=$1
  [[ -d $dir ]] || { printf 'absent'; return 0; }
  (cd "$dir" && find . -type f -print0 2>/dev/null | sort -z | xargs -0 md5sum 2>/dev/null) | md5sum | awk '{print $1}'
}

deploy_nginx_configs() {
  step "nginx configuration (server-configs-nginx)"
  # install_nginx validates and restarts the service after this function;
  # the sync itself must not reload the untuned tree first.
  NGINX_SYNC_RELOAD=0
  if ! sync_nginx_repo_configs; then
    NGINX_SYNC_RELOAD=1
    warn "nginx config deployment failed"
    return 1
  fi
  NGINX_SYNC_RELOAD=1

  # Hardware-aware nginx tuning is owned by setup.sh so the same code runs
  # during install and during `--optimize`.
  tune_reset_changes
  if ! nginx_apply_profile /etc/nginx; then
    warn "nginx tuning failed"
    return 1
  fi
  info "$NGINX_COMPRESSION_SUMMARY"
  local change
  for change in "${TUNE_CHANGES[@]}"; do info "tune: ${change}"; done
  for change in "${TUNE_MISSES[@]}"; do warn "tune not applied: ${change}"; done
}

# Ensure an embedded, ASCII-armoured key is present (dearmoured) and
# byte-identical to the payload.  A truncated file from an interrupted write,
# or an outdated key, otherwise makes every later apt operation fail until an
# operator removes it manually.  (The plain refresh_blob_key went with the
# Sury keyring in 1.22.)
refresh_blob_key_dearmor() {
  local target=$1 blob=$2 tmp
  tmp=$(tmp_file) || return 1
  "$blob" 2>/dev/null | gpg --dearmor --yes -o "$tmp" 2>/dev/null \
    || { warn "Could not decode/dearmor ${blob}"; return 1; }
  [[ -s $tmp ]] || { warn "Embedded ${blob} decoded to an empty key"; return 1; }
  if [[ -s $target ]] && cmp -s "$tmp" "$target"; then
    return 0
  fi
  install -m 644 "$tmp" "$target" || return 1
  info "Refreshed embedded key: ${target}"
}
