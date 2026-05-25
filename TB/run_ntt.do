quit -sim
if {[file exists work]} {
    vdel -all -lib work
}
vlib work
vmap work work

set COMP_FLAGS [list -sv +lint=all +cover=bcesft]

vlog {*}$COMP_FLAGS Twiddle_ROM.v
vlog {*}$COMP_FLAGS NTT_RAM.v
vlog {*}$COMP_FLAGS U_Butterfly_Unit.v
vlog {*}$COMP_FLAGS NTT_Control_Unit.v
vlog {*}$COMP_FLAGS NTT_Accelerator_Top.v
vlog {*}$COMP_FLAGS SPI_Slave.v
vlog {*}$COMP_FLAGS NTT_Top_Wrapper.v
vlog {*}$COMP_FLAGS NTT_System_tb.sv

vsim -coverage -voptargs="+acc" work.NTT_System_tb

add wave -radix unsigned -r /*
add wave -position insertpoint sim:/NTT_System_tb/dut/core_inst/memory_inst/ram

run -all
wave zoom full

puts "\n=================================================="
puts "                COVERAGE SUMMARY                  "
puts "=================================================="

coverage report -summary

puts "\n=================================================="
puts "            COVERAGE BY INSTANCE (MODULES)        "
puts "=================================================="

coverage report -byinstance

coverage save ntt_coverage.ucdb
coverage report -file coverage_report.txt -byinstance -detail

puts "=================================================="
puts "\[INFO\] Verification and Coverage Extraction Finished."