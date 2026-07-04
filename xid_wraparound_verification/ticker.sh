#!/bin/bash
# Emulate a live DB: complete a real transaction periodically so latestCompletedXid
# (and thus the xmin horizon) tracks nextXid. Without this, an idle system pins the
# horizon at the pre-consume value and vacuum cannot lower relfrozenxid.
export PATH=$PGBIN:$PATH
while true; do
  psql -d postgres -Atc "SELECT txid_current();" >/dev/null 2>&1
  sleep 0.5
done
