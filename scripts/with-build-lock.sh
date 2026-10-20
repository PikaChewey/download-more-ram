#!/bin/zsh
# Machine-wide heavy-job lock (one Swift build/test/bench at a time on this 16 GB Mac).
# lockf holds a kernel lock that is released automatically when the holder dies,
# so there is no stale-lock logic. Nested calls (BRYAN_BUILD_LOCK_HELD=1) just run.
#
#   scripts/with-build-lock.sh swift build -j 4
if [[ -n ${BRYAN_BUILD_LOCK_HELD:-} ]]; then
  exec "$@"
fi
export BRYAN_BUILD_LOCK_HELD=1
exec /usr/bin/lockf -k -t 3600 /tmp/bryan-heavy-swift.lock "$@"
