#!/bin/bash
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Defaults ─────────────────────────────────────────────────────────────────

PARALLEL_JOBS=0  # 0 = auto-detect CPU cores
DATA_ONLY=false
CLEAN_TARGET=true
DUMP_FILE=""
KEEP_DUMP=false

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
  echo -e "${BOLD}Usage:${NC} ./migrate-db.sh [OPTIONS] <source_url> <target_url>"
  echo ""
  echo "Migrates a PostgreSQL database from source to target using pg_dump/pg_restore."
  echo "Automatically parallelizes the restore for maximum speed."
  echo ""
  echo -e "${BOLD}Arguments:${NC}"
  echo "  source_url         PostgreSQL connection URL for source database"
  echo "  target_url         PostgreSQL connection URL for target database"
  echo ""
  echo -e "${BOLD}Options:${NC}"
  echo "  -j, --jobs N       Number of parallel restore jobs (default: number of CPU cores)"
  echo "  -d, --data-only    Migrate data only (skip schema, assumes target has matching schema)"
  echo "  --no-clean         Don't drop existing objects on target before restore"
  echo "  --keep-dump        Keep the dump file after migration (saved in current directory)"
  echo "  -h, --help         Show this help message"
  echo ""
  echo -e "${BOLD}Examples:${NC}"
  echo "  ./migrate-db.sh postgresql://user:pass@source:5432/mydb postgresql://user:pass@target:5432/mydb"
  echo "  ./migrate-db.sh --data-only -j 8 \$SOURCE_URL \$TARGET_URL"
  echo "  ./migrate-db.sh --keep-dump postgresql://localhost/dev postgresql://prod-host/prod"
  exit 1
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────

parse_args() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case $1 in
      -j|--jobs)
        PARALLEL_JOBS="$2"
        shift 2
        ;;
      -d|--data-only)
        DATA_ONLY=true
        shift
        ;;
      --no-clean)
        CLEAN_TARGET=false
        shift
        ;;
      --keep-dump)
        KEEP_DUMP=true
        shift
        ;;
      -h|--help)
        usage
        ;;
      -*)
        echo -e "${RED}Error: Unknown option $1${NC}"
        usage
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#positional[@]} -lt 2 ]]; then
    echo -e "${RED}Error: Both source and target URLs are required.${NC}"
    echo ""
    usage
  fi

  SOURCE_URL="${positional[0]}"
  TARGET_URL="${positional[1]}"
}

# ─── Platform Detection & Dependencies ───────────────────────────────────────

detect_platform() {
  case "$(uname -s)" in
    Darwin*) echo "macos" ;;
    Linux*)  echo "linux" ;;
    *)       echo "unknown" ;;
  esac
}

get_cpu_cores() {
  case "$(detect_platform)" in
    macos) sysctl -n hw.ncpu 2>/dev/null || echo 4 ;;
    linux) nproc 2>/dev/null || echo 4 ;;
    *)     echo 4 ;;
  esac
}

check_and_install_dependencies() {
  local platform
  platform=$(detect_platform)
  echo -e "${BLUE}Platform:${NC} ${platform} ($(uname -m))"

  local missing=()
  command -v pg_dump &>/dev/null || missing+=("pg_dump")
  command -v pg_restore &>/dev/null || missing+=("pg_restore")
  command -v psql &>/dev/null || missing+=("psql")

  if [[ ${#missing[@]} -eq 0 ]]; then
    local pg_version
    pg_version=$(pg_dump --version | head -1)
    echo -e "${GREEN}Dependencies satisfied:${NC} ${pg_version}"
    return 0
  fi

  echo -e "${YELLOW}Missing tools: ${missing[*]}${NC}"
  echo -e "${BLUE}Installing PostgreSQL client tools...${NC}"

  case "$platform" in
    macos)
      if ! command -v brew &>/dev/null; then
        echo -e "${RED}Error: Homebrew not found. Install from https://brew.sh${NC}"
        echo -e "  Then run: brew install libpq && brew link --force libpq"
        exit 1
      fi
      brew install libpq 2>/dev/null || true
      brew link --force libpq 2>/dev/null || true
      ;;
    linux)
      if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client
      elif command -v dnf &>/dev/null; then
        sudo dnf install -y postgresql
      elif command -v yum &>/dev/null; then
        sudo yum install -y postgresql
      elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm postgresql-libs
      elif command -v apk &>/dev/null; then
        apk add --no-cache postgresql-client
      else
        echo -e "${RED}Error: No supported package manager found.${NC}"
        echo -e "  Install postgresql-client manually for your distribution."
        exit 1
      fi
      ;;
    *)
      echo -e "${RED}Error: Unsupported platform '$(uname -s)'.${NC}"
      echo -e "  Install pg_dump, pg_restore, and psql manually."
      exit 1
      ;;
  esac

  # Verify
  for tool in pg_dump pg_restore psql; do
    if ! command -v "$tool" &>/dev/null; then
      echo -e "${RED}Error: '$tool' still not found after installation attempt.${NC}"
      exit 1
    fi
  done

  echo -e "${GREEN}Installation successful:${NC} $(pg_dump --version | head -1)"
}

# ─── Progress Helpers ─────────────────────────────────────────────────────────

spinner() {
  local pid=$1
  local message=$2
  local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    local char="${spin_chars:$i:1}"
    printf "\r  ${CYAN}%s${NC} %s" "$char" "$message"
    i=$(( (i + 1) % ${#spin_chars} ))
    sleep 0.1
  done
  printf "\r"
}

format_size() {
  local bytes=$1
  if [[ $bytes -ge 1073741824 ]]; then
    echo "$(echo "scale=1; $bytes / 1073741824" | bc)GB"
  elif [[ $bytes -ge 1048576 ]]; then
    echo "$(echo "scale=1; $bytes / 1048576" | bc)MB"
  elif [[ $bytes -ge 1024 ]]; then
    echo "$(echo "scale=1; $bytes / 1024" | bc)KB"
  else
    echo "${bytes}B"
  fi
}

format_duration() {
  local seconds=$1
  if [[ $seconds -ge 3600 ]]; then
    printf "%dh %dm %ds" $((seconds/3600)) $((seconds%3600/60)) $((seconds%60))
  elif [[ $seconds -ge 60 ]]; then
    printf "%dm %ds" $((seconds/60)) $((seconds%60))
  else
    printf "%ds" "$seconds"
  fi
}

# ─── Database Info ────────────────────────────────────────────────────────────

print_db_info() {
  local url=$1
  local label=$2

  # Extract db name from URL (last path component)
  local db_name
  db_name=$(echo "$url" | sed -E 's|.*/([^?]+).*|\1|')

  # Get table count and total size
  local info
  info=$(psql "$url" -t -A -c "
    SELECT
      (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'),
      pg_size_pretty(pg_database_size(current_database()))
  ;" 2>/dev/null || echo "?|?")

  local table_count size
  IFS='|' read -r table_count size <<< "$info"

  echo -e "  ${label}: ${BOLD}${db_name}${NC} (${table_count} tables, ${size})"
}

print_table_summary() {
  local url=$1
  echo ""
  echo -e "${DIM}  Table                          Rows${NC}"
  echo -e "${DIM}  ─────────────────────────────  ──────────${NC}"

  psql "$url" -t -A -c "
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public'
    ORDER BY tablename;
  " 2>/dev/null | while read -r table; do
    local count
    count=$(psql "$url" -t -A -c "SELECT COUNT(*) FROM \"${table}\";" 2>/dev/null || echo "?")
    printf "  %-32s %s\n" "$table" "$count"
  done

  local total
  total=$(psql "$url" -t -A -c "
    SELECT SUM(n_tup_ins - n_tup_del)
    FROM pg_stat_all_tables
    WHERE schemaname = 'public';
  " 2>/dev/null || echo "?")
  echo -e "${DIM}  ─────────────────────────────  ──────────${NC}"
  echo -e "  ${BOLD}Total                            ${total}${NC}"
}

# ─── Core Migration ──────────────────────────────────────────────────────────

run_migration() {
  local jobs=$PARALLEL_JOBS
  if [[ $jobs -eq 0 ]]; then
    jobs=$(get_cpu_cores)
  fi

  echo -e "\n${BOLD}Configuration:${NC}"
  echo -e "  Parallel jobs: ${BOLD}${jobs}${NC}"
  echo -e "  Mode:          ${BOLD}$(if $DATA_ONLY; then echo "data-only"; else echo "full (schema + data)"; fi)${NC}"
  echo -e "  Clean target:  ${BOLD}$(if $CLEAN_TARGET; then echo "yes"; else echo "no"; fi)${NC}"

  # ── Step 1: Dump source database ──

  DUMP_FILE=$(mktemp -t "pgmigrate_XXXXXX.dump")
  if ! $KEEP_DUMP; then
    trap "rm -f '$DUMP_FILE'" EXIT
  fi

  echo -e "\n${BOLD}[1/3] Dumping source database...${NC}"

  local dump_start
  dump_start=$(date +%s)

  # Build pg_dump command
  local dump_cmd=("pg_dump" "$SOURCE_URL" "-Fc" "--no-owner" "--no-privileges")

  if $DATA_ONLY; then
    dump_cmd+=("--data-only" "--disable-triggers")
  fi

  # Run dump with progress spinner
  "${dump_cmd[@]}" > "$DUMP_FILE" 2>/dev/null &
  local dump_pid=$!

  # Show file size growth as progress
  while kill -0 "$dump_pid" 2>/dev/null; do
    if [[ -f "$DUMP_FILE" ]]; then
      local current_size
      current_size=$(wc -c < "$DUMP_FILE" 2>/dev/null || echo 0)
      printf "\r  ${CYAN}⠿${NC} Dumping... %s written" "$(format_size "$current_size")"
    fi
    sleep 0.5
  done

  if ! wait "$dump_pid"; then
    echo -e "\n  ${RED}Error: pg_dump failed.${NC}"
    exit 1
  fi

  local dump_size
  dump_size=$(wc -c < "$DUMP_FILE")
  local dump_end
  dump_end=$(date +%s)
  local dump_duration=$((dump_end - dump_start))

  printf "\r  ${GREEN}●${NC} Dump complete: %s in %s                    \n" \
    "$(format_size "$dump_size")" "$(format_duration $dump_duration)"

  # ── Step 2: Prepare target ──

  echo -e "\n${BOLD}[2/3] Preparing target database...${NC}"

  if $DATA_ONLY && $CLEAN_TARGET; then
    # For data-only mode, truncate all tables
    echo -e "  Truncating target tables..."
    psql "$TARGET_URL" -q -c "
      DO \$\$
      DECLARE r RECORD;
      BEGIN
        SET session_replication_role = 'replica';
        FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
          EXECUTE 'TRUNCATE TABLE ' || quote_ident(r.tablename) || ' CASCADE';
        END LOOP;
        SET session_replication_role = 'origin';
      END \$\$;
    " 2>/dev/null
    echo -e "  ${GREEN}●${NC} Target tables truncated"
  else
    echo -e "  ${GREEN}●${NC} Target ready (pg_restore will handle cleanup)"
  fi

  # ── Step 3: Restore to target ──

  echo -e "\n${BOLD}[3/3] Restoring to target database (${jobs} parallel jobs)...${NC}"

  local restore_start
  restore_start=$(date +%s)

  # Build pg_restore command
  local restore_cmd=("pg_restore" "-d" "$TARGET_URL" "--no-owner" "--no-privileges" "-j" "$jobs")

  if $DATA_ONLY; then
    restore_cmd+=("--data-only" "--disable-triggers")
  fi

  if $CLEAN_TARGET && ! $DATA_ONLY; then
    restore_cmd+=("--clean" "--if-exists")
  fi

  restore_cmd+=("--verbose" "$DUMP_FILE")

  # Run restore, capture verbose output for progress
  local restore_log
  restore_log=$(mktemp -t "pgrestore_log_XXXXXX")
  trap "rm -f '$DUMP_FILE' '$restore_log'" EXIT

  "${restore_cmd[@]}" 2>"$restore_log" &
  local restore_pid=$!

  # Monitor restore progress from verbose log
  local last_count=0
  while kill -0 "$restore_pid" 2>/dev/null; do
    local current_count
    current_count=$(wc -l < "$restore_log" 2>/dev/null || echo 0)
    if [[ $current_count -ne $last_count ]]; then
      local last_line
      last_line=$(tail -1 "$restore_log" 2>/dev/null || echo "")
      # Truncate long lines for display
      if [[ ${#last_line} -gt 70 ]]; then
        last_line="${last_line:0:67}..."
      fi
      printf "\r  ${CYAN}⠿${NC} %-74s" "$last_line"
      last_count=$current_count
    fi
    sleep 0.3
  done

  local restore_exit=0
  wait "$restore_pid" || restore_exit=$?

  printf "\r%-80s\r" " "  # Clear the progress line

  local restore_end
  restore_end=$(date +%s)
  local restore_duration=$((restore_end - restore_start))

  if [[ $restore_exit -ne 0 ]]; then
    # pg_restore returns non-zero for warnings too, check if there are actual errors
    local error_count
    error_count=$(grep -c "ERROR" "$restore_log" 2>/dev/null || echo 0)
    if [[ $error_count -gt 0 ]]; then
      echo -e "  ${YELLOW}Warning: pg_restore completed with ${error_count} error(s).${NC}"
      echo -e "  ${DIM}Check details: $(if $KEEP_DUMP; then echo "$restore_log"; else echo "re-run with --keep-dump"; fi)${NC}"
    else
      echo -e "  ${GREEN}●${NC} Restore complete (with non-fatal warnings) in $(format_duration $restore_duration)"
    fi
  else
    echo -e "  ${GREEN}●${NC} Restore complete in $(format_duration $restore_duration)"
  fi

  # ── Step 4: Reset sequences ──

  echo -e "\n${BOLD}[4/4] Resetting sequences...${NC}"

  local seq_count=0
  local sequences
  sequences=$(psql "$TARGET_URL" -t -A -c "
    SELECT
      t.relname || '|' || a.attname || '|' || pg_get_serial_sequence(t.relname::text, a.attname::text)
    FROM pg_class t
    JOIN pg_attribute a ON a.attrelid = t.oid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND pg_get_serial_sequence(t.relname::text, a.attname::text) IS NOT NULL;
  " 2>/dev/null || echo "")

  if [[ -n "$sequences" ]]; then
    while IFS='|' read -r table_name column_name sequence_name; do
      [[ -z "$sequence_name" ]] && continue
      local max_val
      max_val=$(psql "$TARGET_URL" -t -A -c \
        "SELECT COALESCE(MAX(\"${column_name}\"), 0) + 1 FROM \"${table_name}\";" 2>/dev/null || echo "1")
      psql "$TARGET_URL" -q -c "ALTER SEQUENCE ${sequence_name} RESTART WITH ${max_val};" 2>/dev/null
      echo -e "  ${GREEN}↻${NC} ${sequence_name} → ${max_val}"
      seq_count=$((seq_count + 1))
    done <<< "$sequences"
  fi

  echo -e "  ${GREEN}●${NC} ${seq_count} sequence(s) reset"

  # ── Summary ──

  local total_duration=$((restore_end - dump_start))

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Migration complete!${NC}"
  echo -e "  Dump size:    ${BOLD}$(format_size "$dump_size")${NC}"
  echo -e "  Total time:   ${BOLD}$(format_duration $total_duration)${NC}"
  if $KEEP_DUMP; then
    echo -e "  Dump file:    ${BOLD}${DUMP_FILE}${NC}"
  fi
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"

  # Show final table state
  echo -e "\n${BOLD}Target database after migration:${NC}"
  print_table_summary "$TARGET_URL"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}              PostgreSQL Database Migration                    ${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"

  # Check dependencies
  echo -e "\n${BOLD}Checking dependencies...${NC}"
  check_and_install_dependencies

  # Verify connections
  echo -e "\n${BOLD}Verifying connections...${NC}"

  if ! psql "$SOURCE_URL" -c "SELECT 1;" &>/dev/null; then
    echo -e "  ${RED}✗ Cannot connect to source database.${NC}"
    exit 1
  fi
  print_db_info "$SOURCE_URL" "${GREEN}Source${NC} "

  if ! psql "$TARGET_URL" -c "SELECT 1;" &>/dev/null; then
    echo -e "  ${RED}✗ Cannot connect to target database.${NC}"
    exit 1
  fi
  print_db_info "$TARGET_URL" "${YELLOW}Target${NC}"

  # Show source table summary
  echo -e "\n${BOLD}Source database tables:${NC}"
  print_table_summary "$SOURCE_URL"

  # Confirmation
  echo ""
  echo -e "${YELLOW}This will overwrite data in the target database.${NC}"
  read -rp "Continue? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Aborted.${NC}"
    exit 0
  fi

  # Run migration
  run_migration
}

main "$@"
