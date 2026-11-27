#!/usr/bin/env bash
# Run on the image's native architecture: emulation cannot validate JIT protection.
set -euo pipefail

image=${1:?Usage: jit-memory-check.sh IMAGE}

docker run --rm --entrypoint sh "$image" -ec '
  if [ "${ERL_FLAGS:-}" != "+JMsingle false" ]; then
    echo "Runtime image must explicitly disable single-mapped JIT memory" >&2
    exit 1
  fi
  set -- /app/releases/*/start_clean.boot
  exec /app/erts-*/bin/erl \
    -boot "${1%.boot}" -boot_var RELEASE_LIB /app/lib -noshell -eval '\''
      {ok, Maps} = file:read_file("/proc/self/maps"),
      case re:run(Maps, "(?m)^[0-9a-f]+-[0-9a-f]+ .wx") of
        nomatch ->
          io:format("Runtime JIT protection verified: no writable/executable mappings~n"),
          halt(0);
        _ ->
          io:format(standard_error, "Runtime has writable/executable memory mappings~n", []),
          halt(1)
      end.
    '\''
'
