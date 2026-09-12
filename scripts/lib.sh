# Shared setup for the scripts in this folder. Source it, don't run it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DATABASE_URL="${DATABASE_URL:-postgresql://bidhub:bidhub@localhost:5433/bidhub}"

# Git Bash on Windows rarely has the PostgreSQL client on PATH; pick the newest install.
if ! command -v psql >/dev/null 2>&1; then
    for d in "/c/Program Files/PostgreSQL"/*/bin; do
        [ -x "$d/psql.exe" ] && PATH="$d:$PATH"
    done
    export PATH
fi

if ! command -v psql >/dev/null 2>&1; then
    echo "FAIL  psql not found — install the PostgreSQL client or add it to PATH" >&2
    exit 1
fi

# -X: ignore ~/.psqlrc so output is predictable.
psql_q() { psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }

wait_for_db() {
    local tries=${1:-30}
    until pg_isready -d "$DATABASE_URL" >/dev/null 2>&1; do
        tries=$((tries - 1))
        [ "$tries" -le 0 ] && { echo "FAIL  database not reachable at $DATABASE_URL" >&2; return 1; }
        sleep 1
    done
}
