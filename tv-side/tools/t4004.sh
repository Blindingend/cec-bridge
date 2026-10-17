#!/system/bin/sh
OUT=/storage/emulated/0/t4004.out
echo "start adbd=$(getprop init.svc.adbd)" > "$OUT"
/system/bin/service call TvService 4004 i32 1 >> "$OUT" 2>&1
sleep 1
echo "after adbd=$(getprop init.svc.adbd)" >> "$OUT"
