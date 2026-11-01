# =============================================================================
#  final_cam_ir_io.sdc -- hand written constraints (kept separate from the
#  interface generated final_cam_ir.sdc, which is rewritten on every run)
#
#  These are the 3 exclusive clock groups hand added in the original
#  ti60f225_oob.sdc (the jtag_inst1_TCK one is dropped: this project no longer
#  uses JTAG USER1 / the Efinix debug core).
#  NOTE: keep this file pure ASCII -- the SDC parser chokes on non-ASCII.
# =============================================================================

set_clock_groups -exclusive -group {core_clk} -group {tx_cal_clk} -group {i_mipi_tx_pclk} -group {vid_clk_dvi2} -group {CLK_5M} -group {i_mipi_rx_pclk} -group {sdram_clk} -group {rx_cal_clk}
set_clock_groups -exclusive -group {i_mipi_tx_pclk} -group {i_mipi_rx_pclk}
