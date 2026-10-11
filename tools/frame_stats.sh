#!/bin/bash
# frame_stats.sh: how often the game loop overran its 30,000-cycle frame, and
# the least idle time seen, from a FRAME_STATS build run headless in vecx.
#
#   make -B GCC_FLAGS="-DDOME_NO_TAIL -DFRAME_STATS" KEEP_WORK=1
#   tools/frame_stats.sh FRAMES [vxhost options, e.g. --hold left@700-3000]
#
# The counters (src/e-srg.c) test the VIA T2 flag before each Wait_Recal (set =
# the frame already ended) and read T2's high byte (idle time / 256). "least
# idle ~0" means some loop came within 256 cycles of overrunning.
cd "$(dirname "$0")/.." || exit 1
f=$1; shift
map=$(ls build/.gcc6809-work/*e.map | head -1)
addr(){ grep -E " _$1 " $map | awk '{print $1}'; }
tests/vxhost ${VECX_CORE:-$HOME/.var/app/org.libretro.RetroArch/config/retroarch/cores/vecx_libretro.so} build/e-srg-*e.bin --frames $f --ram "$@" 2>/dev/null \
 | python3 -c "
import sys
ram={}
for l in sys.stdin:
    if l[:2] in ('C8','C9','CA','CB'):
        a,*b=l.split(); base=int(a[:-1],16)
        for i,x in enumerate(b): ram[base+i]=int(x,16)
ov,lp,mi=int('$(addr frame_overruns)',16),int('$(addr frame_loops)',16),int('$(addr frame_minidle)',16)
w=lambda a: ram[a]*256+ram[a+1]
print(f'overruns {w(ov)} of {w(lp)} loops, least idle ~{ram[mi]*256} cycles', end='')
rs='$(addr radar_sum)'
if rs:
    rs,rn,rm=int(rs,16),int('$(addr radar_n)',16),int('$(addr radar_max)',16)
    print(f'; radar ~{w(rs)*256//max(1,w(rn))} cycles avg, max ~{ram[rm]*256} ({w(rn)} frames)', end='')
cs='$(addr crack_sum)'
if cs:
    cs,cn=int(cs,16),int('$(addr crack_n)',16)
    print(f'; cracks ~{w(cs)*256//max(1,w(cn))} cycles avg', end='')
ts='$(addr text_sum)'
if ts:
    ts,tn=int(ts,16),int('$(addr text_n)',16)
    print(f'; text ~{w(ts)*256//max(1,w(tn))} cycles avg', end='')
ls_='$(addr logic_steps)'
if ls_:
    print(f'; logic steps {w(int(ls_,16))}', end='')
print()"
