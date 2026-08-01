#!/bin/sh
set -e

APP_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MINIFORGE="/Users/Joe/Miniforge3"

if [ ! -x "$MINIFORGE/bin/python" ]; then
  echo "Missing Miniforge Python at $MINIFORGE/bin/python" >&2
  exit 1
fi

cd "$APP_ROOT"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export STREAMLIT_BROWSER_GATHER_USAGE_STATS=false
exec "$MINIFORGE/bin/python" -m streamlit run streamlit_app.py --server.port=8501 --server.address=127.0.0.1
