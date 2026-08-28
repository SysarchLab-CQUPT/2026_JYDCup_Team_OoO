set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
open_checkpoint [file join $project_root reports impl pre_route jyd_soc_top_opt.dcp]

foreach {label pattern} {
  PRF_LANE0 {^u_soc/u_core/u_prf/(bank[01]_r[01]_q.*|ex0_rs[12]_q.*)}
  PRF_LANE1 {^u_soc/u_core/u_prf/(bank[01]_r[23]_q.*|ex1_rs[12]_q.*)}
  EX0_REGS  {^u_soc/u_core/ex0_(q|rs1_q|rs2_q)_reg.*}
  EX1_REGS  {^u_soc/u_core/ex1_(q|rs1_q|rs2_q)_reg.*}
  SQ_HIER   {^u_soc/u_core/u_sq$}
  DCACHE_LOOKUP_REGS {^u_soc/u_dcache/(lookup_(valid_q|data_ready_q|addr_q|seq_q|uop_id_q|hit0_q|hit1_q|repl_way_q|store_forward.*)_reg.*)}
} {
  set cells [get_cells -quiet -hierarchical -regexp $pattern]
  puts "CLUSTER_CANDIDATE_${label}_COUNT=[llength $cells]"
  set shown 0
  foreach cell $cells {
    puts "CLUSTER_CANDIDATE_${label}=$cell"
    incr shown
    if {$shown >= 20} { break }
  }
}

close_design
