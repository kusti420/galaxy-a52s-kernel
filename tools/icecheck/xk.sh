# on-phone (root): xk.sh write <set> | verify <set>: cross-kernel /data files (DE: /data/local/tmp/xk, CE: /data/media/0/xk)
op=$1; S=$2
for base in /data/local/tmp/xk /data/media/0/xk; do
  d=$base/$S
  if [ $op = write ]; then
    mkdir -p $d/small; i=0
    for sz in 1 3 4 7 16 64 255 256 1024 4096 8192; do head -c $((sz*1024+i*13)) /dev/urandom > $d/f$i.bin; i=$((i+1)); done
    j=0; while [ $j -lt 200 ]; do echo "small file $j $S $(head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n')" > $d/small/n_$j.txt; j=$((j+1)); done
    sync; (cd $d && find . -type f | sort | xargs md5sum) > $d.md5
  fi
  if [ $op = verify ]; then
    [ -f $d.md5 ] || { echo "$d: NO MANIFEST"; continue; }
    n=$(wc -l < $d.md5); bad=$(cd $d && md5sum -c $d.md5 2>/dev/null | grep -vc ': OK$')
    echo "$d: $n files, $bad bad"
  fi
done
[ $op = write ] && cat /data/local/tmp/xk/$S.md5 /data/media/0/xk/$S.md5 | md5sum | sed "s/-/manifest $S/"
