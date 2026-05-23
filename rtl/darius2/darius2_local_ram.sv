/*  This file is part of Darius_MiSTer.

    Darius_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Darius_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Darius_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

// darius_local_ram — BRAM single-port con byte enable.
// Split HI/LO per inference pulita M10K con byte enable.
// Usata per main RAM, sprite RAM locale e altre RAM single-client.

module darius_local_ram
#(
	parameter integer ADDR_WIDTH = 11
)
(
	input  wire                  clk,
	input  wire                  rd,
	input  wire                  wr,
	input  wire [1:0]            be,    // byte enable: be[1]=write HI, be[0]=write LO
	input  wire [ADDR_WIDTH-1:0] addr,
	input  wire [15:0]           wdata,
	output wire [15:0]           rdata
);

// Split into two 8-bit RAMs for proper M10K byte-enable inference.
// "no_rw_check" tells Quartus read-during-write to same addr is don't-care,
// which enables proper M10K placement instead of fallback to LUTRAM when
// M10K blocks are tight. Without this, Quartus may emit LUT-based altsyncram
// with decode_8la/mux_ofb which has different write/read timing and causes
// memtest failures on real hardware.
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] ram_hi [0:(1 << ADDR_WIDTH)-1];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] ram_lo [0:(1 << ADDR_WIDTH)-1];
reg [7:0] rdata_hi, rdata_lo;

// synthesis translate_off
initial begin : init_ram
	integer i;
	for (i = 0; i < (1 << ADDR_WIDTH); i = i + 1) begin
		ram_hi[i] = 8'h00;
		ram_lo[i] = 8'h00;
	end
end
// synthesis translate_on

// M10K single-port inference: write gated by wr+be, read UNCONDITIONAL.
// Unconditional read avoids any chance of stale rdata when rd pulse is narrow.
// The memory map FSM samples bus_rdata 2 cycles after asserting rd, which
// matches the 1-cycle BRAM registered output (addr@N → rdata@N+1).
always @(posedge clk) begin
	if (wr && be[1]) ram_hi[addr] <= wdata[15:8];
	if (wr && be[0]) ram_lo[addr] <= wdata[7:0];
	rdata_hi <= ram_hi[addr];
	rdata_lo <= ram_lo[addr];
end

assign rdata = {rdata_hi, rdata_lo};

endmodule
