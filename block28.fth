( counted loops )
variable leaves                 0 rpick: i   2 rpick: j
: subw-sr, 83 c, 5 rm-r, c, ;   : unloop, 2 cells di subw-sr, ;
:code unloop unloop, next,      :code 2rdrop unloop, next,
: leave postpone (branch) leaves link, ; immediate
: >leave leaves @ begin dup while dup @ swap >br repeat drop ;
: begin-loop leaves @ 0 leaves ! ;
: end-loop <br >leave   leaves !  postpone unloop ;
: do begin-loop postpone 2>r br< ; immediate
: ?do begin-loop postpone{ 2dup 2>r <> (0branch) } leaves link,
  br< ; immediate
: (+loop) rover + 2rpick over 1+ rover 1+ swap
  within swap r> ( flag new retaddr ) rdrop 2>r ;
: +loop postpone{ (+loop) (0branch) } end-loop ; immediate
: loop 1 lit, postpone +loop ; immediate
                                                             -->
