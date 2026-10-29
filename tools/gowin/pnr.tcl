# 布局布线脚本：在工程根目录执行
#   gw_sh.exe tools/gowin/pnr.tcl
set prj [file normalize "fpga_project.gprj"]
open_project $prj
set_option -place_option 2
set_option -route_option 2
run pnr
puts "=== PNR OK ==="
