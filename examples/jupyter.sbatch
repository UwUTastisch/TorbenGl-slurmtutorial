#!/bin/bash
#SBATCH --job-name=jupyter
#SBATCH --partition=compute-node # CPU partition; jupyter.sh switches this for GPU
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=04:00:00          # max on our partitions is 1-00:00:00
#SBATCH --output=logs/%x-%j.out

# Run Jupyter Lab on a compute node and push its port back to the login node.
#
# Submit with the wrapper (recommended):  ./examples/jupyter.sh
# Or directly:                            sbatch examples/jupyter.sbatch
#
# Ports are negotiated automatically, so two people can run this at the same
# time without stepping on each other's reverse tunnel.

set -euo pipefail

LOGIN_HOST="${JUPYTER_LOGIN_HOST:-sl-li}"      # where the reverse tunnel lands
NOTEBOOK_DIR="${JUPYTER_DIR:-$SLURM_SUBMIT_DIR}"  # the repo you submitted from
CONNFILE="$SLURM_SUBMIT_DIR/logs/${SLURM_JOB_NAME}.conn"

cd "$SLURM_SUBMIT_DIR"
mkdir -p logs

echo "Running on host: $(hostname)"
echo "Job $SLURM_JOB_ID on partition $SLURM_JOB_PARTITION"
nvidia-smi -L 2>/dev/null || true

# --- Environment ------------------------------------------------------------
# Activate the prebuilt venv (run `uv sync` on the login node first — it installs
# jupyterlab). We avoid `uv run` here: compute nodes may be offline.
if [ ! -f .venv/bin/activate ]; then
  echo "ERROR: no .venv found. Run 'uv sync' on the login node first." >&2
  exit 1
fi
source .venv/bin/activate

# --- Pick a free port on THIS compute node ----------------------------------
LOCAL_PORT=$(python -c '
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0))
print(s.getsockname()[1]); s.close()
')

# --- Open the reverse tunnel to the login node ------------------------------
# The login node is shared, so its end of the tunnel is the part that collides.
# ExitOnForwardFailure makes a failed bind a hard error instead of a silent
# no-op, and we simply retry with another port until one sticks.
LOGIN_PORT=""
TUNNEL_PID=""
for _ in $(seq 1 15); do
  CANDIDATE=$(( 9000 + RANDOM % 1000 ))
  ssh -N \
      -o ExitOnForwardFailure=yes \
      -o BatchMode=yes \
      -o ServerAliveInterval=60 \
      -R "${CANDIDATE}:127.0.0.1:${LOCAL_PORT}" "$LOGIN_HOST" &
  pid=$!
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    LOGIN_PORT=$CANDIDATE
    TUNNEL_PID=$pid
    break
  fi
  wait "$pid" 2>/dev/null || true
done

if [ -z "$LOGIN_PORT" ]; then
  echo "ERROR: could not open a reverse tunnel to $LOGIN_HOST." >&2
  echo "Check that 'ssh $LOGIN_HOST' works from a compute node without a" >&2
  echo "password (ssh-copy-id inside the cluster, or ask the admin)." >&2
  exit 1
fi

echo "Reverse tunnel: ${LOGIN_HOST}:${LOGIN_PORT} -> $(hostname):${LOCAL_PORT}"

# --- Token ------------------------------------------------------------------
# Generated up front so the wrapper never has to scrape it back out of the log.
TOKEN=$(openssl rand -hex 24 2>/dev/null || python -c 'import secrets; print(secrets.token_hex(24))')

# --- Publish connection details on the shared filesystem --------------------
umask 077
cat > "$CONNFILE" <<EOF
JOBID=${SLURM_JOB_ID}
NODE=$(hostname -s)
LOGIN_HOST=${LOGIN_HOST}
LOGIN_PORT=${LOGIN_PORT}
TOKEN=${TOKEN}
DIR=${NOTEBOOK_DIR}
EOF

cleanup() {
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  rm -f "$CONNFILE"
}
trap cleanup EXIT TERM INT

echo
echo "From your laptop, run:"
echo "    ssh -N -L 8888:localhost:${LOGIN_PORT} slurm"
echo "Then open:"
echo "    http://localhost:8888/lab?token=${TOKEN}"
echo

# --- Launch -----------------------------------------------------------------
# Bound to 127.0.0.1: only the tunnel can reach it, never other nodes.
jupyter lab \
  --no-browser \
  --ip=127.0.0.1 \
  --port="$LOCAL_PORT" \
  --port-retries=0 \
  --ServerApp.root_dir="$NOTEBOOK_DIR" \
  --IdentityProvider.token="$TOKEN"

