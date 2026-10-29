# 综合脚本：在工程根目录执行
#   gw_sh.exe tools/gowin/syn.tcl
set prj [file normalize "fpga_project.gprj"]
open_project $prj
set_option -ram_style block_ram
run syn
puts "=== SYN DONE ==="
