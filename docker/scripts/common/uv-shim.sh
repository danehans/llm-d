#!/bin/sh
set -eu

python_bin() {
  if command -v python >/dev/null 2>&1; then
    command -v python
    return
  fi
  command -v python3
}

venv_cmd() {
  target=""
  py="python3"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --python)
        py="python$2"
        shift 2
        ;;
      *)
        if [ -z "$target" ]; then
          target="$1"
        fi
        shift
        ;;
    esac
  done

  if [ -z "$target" ]; then
    echo "uv-shim: missing venv target" >&2
    exit 1
  fi

  "$py" -m venv "$target"
}

pip_cmd() {
  subcmd="$1"
  shift

  py="$(python_bin)"

  case "$subcmd" in
    install)
      constraint_args=""
      if [ -n "${UV_CONSTRAINT:-}" ]; then
        constraint_args="--constraint ${UV_CONSTRAINT}"
      fi
      # shellcheck disable=SC2086
      exec "$py" -m pip install $constraint_args "$@"
      ;;
    uninstall)
      exec "$py" -m pip uninstall "$@"
      ;;
    *)
      echo "uv-shim: unsupported pip subcommand: $subcmd" >&2
      exit 1
      ;;
  esac
}

build_cmd() {
  py="$(python_bin)"
  outdir=""
  args=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out-dir)
        outdir="$2"
        shift 2
        ;;
      --no-build-isolation)
        args="$args --no-isolation"
        shift
        ;;
      *)
        args="$args $1"
        shift
        ;;
    esac
  done

  if [ -n "$outdir" ]; then
    args="$args --outdir $outdir"
  fi

  # shellcheck disable=SC2086
  exec "$py" -m build $args
}

main() {
  if [ "$#" -eq 0 ]; then
    echo "uv-shim: missing command" >&2
    exit 1
  fi

  cmd="$1"
  shift

  case "$cmd" in
    venv)
      venv_cmd "$@"
      ;;
    pip)
      if [ "$#" -eq 0 ]; then
        echo "uv-shim: missing pip subcommand" >&2
        exit 1
      fi
      pip_cmd "$@"
      ;;
    build)
      build_cmd "$@"
      ;;
    *)
      echo "uv-shim: unsupported command: $cmd" >&2
      exit 1
      ;;
  esac
}

main "$@"
