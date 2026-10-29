# 完整构建脚本：在工程根目录执行
#   gw_sh.exe tools/gowin/build.tcl
set prj [file normalize "fpga_project.gprj"]
open_project $prj
set_option -ram_style block_ram
run syn
puts "=== SYN DONE ==="
set_option -place_option 2
set_option -route_option 2
run pnr
puts "=== PNR OK ==="
