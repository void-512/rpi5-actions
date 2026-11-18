#!/usr/bin/env bash
set -euo pipefail

task_id="${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
ram_root="$HOME/.cache/codex-tmp/$task_id"
docker_root="$HOME/.cache/codex-docker/$task_id"
docker=(env -u DOCKER_CONTEXT docker --config "$docker_root/client" --host "unix://$docker_root/docker.sock")

case "$1" in
  build)
    docker --version
    dockerd --version
    mkdir -p "$ram_root" "$docker_root"
    sudo mount -t tmpfs -o "size=4G,mode=0700,uid=$(id -u),gid=$(id -g)" tmpfs "$ram_root"
    mkdir -p "$ram_root/docker" "$ram_root/tmp" "$ram_root/work"/{artifacts,tmp}
    sudo mount --bind "$ram_root/docker" "$docker_root"
    for path in "$ram_root" "$docker_root"; do
      if [[ "$(findmnt -n -o FSTYPE -T "$path")" != tmpfs ]]; then
        printf '::error::Expected tmpfs at %s\n' "$path" >&2
        exit 1
      fi
    done
    export TMPDIR="$ram_root/tmp" TMP="$ram_root/tmp" TEMP="$ram_root/tmp"
    install -m 0644 "$BUILD_SCRIPT" "$ram_root/work/build.sh"

    mkdir -p "$docker_root"/{data,exec,client}
    printf '%s\n' '{"features":{"containerd-snapshotter":false},"log-driver":"none"}' \
      > "$docker_root/daemon.json"
    # The private data and exec roots also contain Docker's managed containerd.
    # shellcheck disable=SC2024
    sudo env TMPDIR="$TMPDIR" TMP="$TMP" TEMP="$TEMP" \
      dockerd --config-file "$docker_root/daemon.json" \
      --data-root "$docker_root/data" --exec-root "$docker_root/exec" \
      --pidfile "$docker_root/dockerd.pid" --host "unix://$docker_root/docker.sock" \
      --group "$(id -gn)" --storage-driver overlay2 \
      --bridge none --iptables=false --ip6tables=false \
      --ip-forward=false --ip-masq=false --userland-proxy=false \
      > "$docker_root/dockerd.log" 2>&1 &
    for ((attempt=0; attempt<60; attempt++)); do
      if "${docker[@]}" info > /dev/null 2>&1; then break; fi
      sleep 1
    done
    if ! actual_root="$("${docker[@]}" info --format '{{.DockerRootDir}}')" || [[ "$actual_root" != "$docker_root/data" ]]; then
      cat "$docker_root/dockerd.log" >&2
      exit 1
    fi

    read -r -a env_names <<< "$BUILD_ENV_VARS"
    build_env=()
    for name in "${env_names[@]}"; do
      build_env+=(--env "$name")
    done

    # Build scripts reclaim completed phases. The mount caps active work at 4 GiB.
    (
      while sleep 5; do
        used="$(df --output=pcent "$ram_root" | tail -n1 | tr -dc '0-9')"
        if (( used > 80 )); then
          printf '::warning::RAM build storage is %s%% used (4 GiB capacity).\n' "$used" >&2
          break
        fi
      done
    ) &
    monitor_pid=$!
    trap 'kill "$monitor_pid" 2>/dev/null || true' EXIT

    # Expand the build environment inside the container.
    # shellcheck disable=SC2016
    if ! "${docker[@]}" run --rm --network host --log-driver none \
      --env DEBIAN_FRONTEND=noninteractive --env LANG=C.UTF-8 --env LC_ALL=C.UTF-8 \
      --env BUILD_ROOT=/work --env TMPDIR=/work/tmp --env TMP=/work/tmp --env TEMP=/work/tmp \
      "${build_env[@]}" --volume "$ram_root/work:/work" \
      debian:trixie-slim bash -c '
        set -euo pipefail
        test "$(stat -f -c %T "$BUILD_ROOT")" = tmpfs
        test "$(dpkg --print-architecture)" = arm64
        exec bash /work/build.sh
      '; then
      df -h "$ram_root" >&2
      exit 1
    fi

    shopt -s nullglob
    archives=("$ram_root/work/artifacts/"*.tar.*)
    if (( ${#archives[@]} != 1 )) || [[ ! -s "${archives[0]}" ]]; then
      printf '%s\n' '::error::Expected one release archive from the Debian build.' >&2
      exit 1
    fi
    archive="$OUTPUT_DIR/${archives[0]##*/}"
    mkdir -p "$OUTPUT_DIR"
    install -m 0644 "${archives[0]}" "$archive"
    printf 'archive=%s\n' "$archive" >> "$GITHUB_OUTPUT"
    ;;

  cleanup)
    if mountpoint -q "$docker_root"; then
      if sudo test -f "$docker_root/dockerd.pid"; then
        daemon_pid="$(sudo cat "$docker_root/dockerd.pid")"
        sudo kill -TERM "$daemon_pid"
        for ((attempt=0; attempt<30; attempt++)); do
          if ! sudo kill -0 "$daemon_pid" 2>/dev/null; then break; fi
          sleep 1
        done
        if sudo kill -0 "$daemon_pid" 2>/dev/null; then
          printf '%s\n' '::error::The isolated Docker daemon did not stop.' >&2
          exit 1
        fi
      fi
      sudo umount --recursive "$docker_root"
    fi
    if mountpoint -q "$ram_root"; then sudo umount --recursive "$ram_root"; fi
    for path in "$docker_root" "$ram_root"; do
      if [[ -d "$path" ]]; then rmdir -- "$path"; fi
    done
    ;;

  *)
    printf '::error::Unknown Debian build command: %s\n' "$1" >&2
    exit 1
    ;;
esac
