#!/bin/bash
# One line per OS from verify_os.sh results; exit 1 if anything failed.
# usage: summary.sh results.tsv   (also writes results.tsv -> summary.txt next to it)
set -uo pipefail
R=$1
cat "$(dirname "$0")/checks.txt"
echo
awk -F'\t' '{ if (!($1 in seen)) { seen[$1]=1; ord[++n]=$1 }
              if ($2=="os") os[$1]=$4; if ($2=="perCPU") pc[$1]=$4
              if ($3=="PASS") p[$1]++; if ($3=="FAIL") f[$1]=f[$1] " " $2 }
    END { for (i=1;i<=n;i++) { k=ord[i]
            printf "%-10s %-4s PASS=%-3d FAIL:%s\n           %s | %s\n", k, (f[k]=="" ? "OK" : "FAIL"), p[k], (f[k]=="" ? " none" : f[k]), os[k], pc[k] } }' \
    "$R" | tee "$(dirname "$R")/summary.txt"
fails=$(awk -F'\t' '$3=="FAIL"' "$R" | wc -l)
echo "FAIL total: $fails"
[ "$fails" -eq 0 ]
