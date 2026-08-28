# Optional legacy A/B placement experiment.  The normal implementation flow
# does not source this file unless JYD_USE_USER_CLUSTER=1 because the preserved
# routed baseline showed severe local directional congestion with broad
# hierarchy clustering enabled.
#
# Run after opt_design, when hierarchy exists, and before place_design.  One
# monolithic backend cluster left unrelated memory and issue logic competing
# for one centroid. USER_CLUSTER is honored only on hierarchical cells in this
# Vivado release, so group the two mutually-waking issue queues together and
# keep the memory pipeline in its own cluster. Top-level EX/PRF registers stay
# connection-driven.
set jyd_issue_hier_cells [get_cells -quiet -hierarchical -regexp \
  {^u_soc/u_core/(u_iq0|u_iq1)$}]
set jyd_memory_hier_cells [get_cells -quiet -hierarchical -regexp \
  {^u_soc/u_core/(u_lq|u_sq)$|^u_soc/(u_dmem_request_fifo|u_dcache)$}]
if {[llength $jyd_issue_hier_cells] != 2} {
  error "Expected IQ0/IQ1 hierarchy cells, found [llength $jyd_issue_hier_cells]: $jyd_issue_hier_cells"
}
if {[llength $jyd_memory_hier_cells] != 4} {
  error "Expected LQ/SQ/FIFO/D-cache hierarchy cells, found [llength $jyd_memory_hier_cells]: $jyd_memory_hier_cells"
}

set_property USER_CLUSTER jyd_issue_pair $jyd_issue_hier_cells
set_property USER_CLUSTER jyd_memory_pipe $jyd_memory_hier_cells

puts "BACKEND_ISSUE_CLUSTER_HIER_COUNT=[llength $jyd_issue_hier_cells]"
puts "BACKEND_MEMORY_CLUSTER_HIER_COUNT=[llength $jyd_memory_hier_cells]"

# The routed branch-recovery family crossed EX0 ALU -> predictor -> fetch PC
# over 18 levels and 5.8 ns of routing.  Keep those frontend hierarchy blocks
# local.  Top-level redirect registers cannot use USER_CLUSTER and therefore
# remain connection-driven rather than carrying an ignored property.
set jyd_frontend_hier_cells [get_cells -quiet -hierarchical -regexp \
  {^u_soc/u_core/(u_branch_predictor|u_fetch_bundle_queue)$|^u_soc/u_icache$}]
if {[llength $jyd_frontend_hier_cells] != 3} {
  error "Expected predictor/fetch-queue/I-cache hierarchy cells, found [llength $jyd_frontend_hier_cells]: $jyd_frontend_hier_cells"
}
set_property USER_CLUSTER jyd_frontend_redirect $jyd_frontend_hier_cells
puts "FRONTEND_REDIRECT_CLUSTER_HIER_COUNT=[llength $jyd_frontend_hier_cells]"

unset jyd_issue_hier_cells
unset jyd_memory_hier_cells
unset jyd_frontend_hier_cells
