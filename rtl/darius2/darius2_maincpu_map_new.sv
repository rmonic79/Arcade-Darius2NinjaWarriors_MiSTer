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
    Version: 0.1
    Date: 2026

*/

// darius2_maincpu_map — Memory map del Main 68000 per Darius II.
//
// MAME: darius2_master_map (ninjaw.cpp)
//
// $000000-$0BFFFF  ROM (768 KB)         → SDRAM
// $0C0000-$0CFFFF  Main RAM (64 KB)     → BRAM
// $200000-$200003  TC0040IOC (I/O)      → registri
// $210000-$210001  CPUA ctrl write      → registro (sub reset bit 0)
// $220001          TC0140SYT port write  → sound comm (stub)
// $220003          TC0140SYT comm R/W    → sound comm (stub)
// $240000-$24FFFF  Shared RAM (64 KB)   → BRAM dual-port
// $260000-$263FFF  Sprite RAM (16 KB)   → BRAM dual-port
// $280000-$293FFF  TC0100SCN[0] RAM     → write-through to all 3
// $2A0000-$2A000F  TC0100SCN[0] ctrl
// $2C0000-$2D3FFF  TC0100SCN[1] RAM
// $2E0000-$2E000F  TC0100SCN[1] ctrl
// $300000-$313FFF  TC0100SCN[2] RAM
// $320000-$32000F  TC0100SCN[2] ctrl
// $340000-$340007  TC0110PCR[0] palette
// $350000-$350007  TC0110PCR[1] palette
// $360000-$360007  TC0110PCR[2] palette

module darius2_maincpu_map_new
(
	input  wire        clk,
	input  wire        reset,

	// CPU bus
	input  wire [23:0] bus_addr,
	input  wire        bus_asn,
	input  wire        bus_rnw,
	input  wire [1:0]  bus_dsn,
	input  wire [15:0] bus_wdata,
	output wire [15:0] bus_rdata,
	output reg         bus_cs,
	output reg         bus_busy,

	// Byte enable (active high, derived from DSn active low)
	output wire [1:0]  bus_be,

	// ROM (SDRAM via rom_cache)
	output reg  [23:0] rom_addr,
	output reg         rom_req,
	input  wire [15:0] rom_rdata,
	input  wire        rom_ready,

	// Main RAM (64 KB)
	output reg         ram_rd,
	output reg         ram_wr,
	output reg  [1:0]  ram_be_o,    // latched byte enable (bus_be changes when DSn de-asserts)
	output reg  [14:0] ram_addr_o,
	output reg  [15:0] ram_wdata,
	input  wire [15:0] ram_rdata,

	// Shared RAM (64 KB, dual-port — Port A = main)
	output reg         shared_rd,
	output reg         shared_wr,
	output reg  [1:0]  shared_be_o,  // latched byte enable
	output reg  [14:0] shared_addr,
	output reg  [15:0] shared_wdata,
	input  wire [15:0] shared_rdata,
	input  wire        shared_ready,

	// Sprite RAM (16 KB, dual-port — Port A = main)
	output reg         sprite_rd,
	output reg         sprite_wr,
	output reg  [1:0]  sprite_be_o,  // latched byte enable
	output reg  [12:0] sprite_addr,
	output reg  [15:0] sprite_wdata,
	input  wire [15:0] sprite_rdata,
	input  wire        sprite_ready,

	// TC0040IOC (shared in top — signals only)
	output wire        ioc_cs,
	output wire        ioc_rnw,
	output wire        ioc_addr1,
	output wire  [7:0] ioc_wdata,
	input  wire  [7:0] ioc_rdata,  // combinational from tc0040ioc module

	// CPUA ctrl
	output reg         cpua_ctrl_wr,
	output reg   [7:0] cpua_ctrl_data,
	input  wire  [7:0] cpua_ctrl_q,

	// TC0140SYT sound comm (active low, directly to TC0140SYT in top)
	output reg         syt_cs_n,
	output reg         syt_wr_n,
	output reg         syt_rd_n,
	output reg         syt_a1,
	input  wire  [3:0] syt_main_dout,  // dato di ritorno dal TC0140SYT vero (audio_top)

	// TC0100SCN / TC0110PCR — directly decoded in top, not here.
	// The memory map only needs to NOT assert bus_cs/bus_busy for those ranges.
	// The decode for SCN/PCR chip selects is in darius2_dual68k_top.sv.

	// VBlank status (active high during vblank)
	input  wire        vblank,
	// External DTACK from SCN/palette chips (0 = chip responded)
	input  wire        ext_dtack_n,
	// Debug
	output wire [3:0]  dbg_txn_state
);

assign bus_be = ~bus_dsn;

// --- I/O devices rdata (latched inside FSM for simple devices) ---
reg [15:0] io_rdata;  // TC0040IOC, watchdog, cpua_ctrl, SYT
reg  [3:0] syt_mode;  // TC0140SYT master mode latched on write to $220001
reg        syt_active;  // 1 mentre la transazione corrente e' verso il SYT (CS stretch)

// --- Address decode ---
// IMPORTANT: bus_active requires DSn asserted (matches Darius 1). Without this check,
// sel_ram can trigger before CPU asserts UDSn/LDSn → byte enable latched as 00 → write lost.
wire bus_active = ~bus_asn && (bus_dsn != 2'b11);

// ROM mirror: bit 20 not decoded by HW → $100000-$1BFFFF mirrors $000000-$0BFFFF
// The game uses jsr $135E6 in IRQ handler (= mirror of $035E6)
wire [23:0] rom_addr_masked = {bus_addr[23:21], 1'b0, bus_addr[19:0]};  // clear bit 20
wire sel_rom     = bus_active && (rom_addr_masked <= 24'h0BFFFF);
wire sel_ram     = bus_active && (bus_addr >= 24'h0C0000) && (bus_addr <= 24'h0DFFFF);  // 64KB + mirror (exception vectors at $0D0xxx)
wire sel_ioc     = bus_active && (bus_addr >= 24'h200000) && (bus_addr <= 24'h200003);
wire sel_ctrl    = bus_active && (bus_addr >= 24'h210000) && (bus_addr <= 24'h210001);
wire sel_syt     = bus_active && (bus_addr >= 24'h220000) && (bus_addr <= 24'h220003);
wire sel_shared  = bus_active && (bus_addr >= 24'h240000) && (bus_addr <= 24'h24FFFF);
wire sel_sprite  = bus_active && (bus_addr >= 24'h260000) && (bus_addr <= 24'h263FFF);

// SCN and palette ranges — decoded in top, NOT here
wire sel_scn_or_pal = bus_active && (bus_addr >= 24'h280000) && (bus_addr <= 24'h360007);

// --- Combinational bus_rdata mux (Darius 1 style) ---
// bus_rdata must be valid in the SAME cycle as DTACK. A registered mux would
// delay data by 1 cycle and the CPU would latch stale values (memtest fails).
// SCN / palette reads come from the top-level composite mux (chip outputs).
assign bus_rdata = sel_rom     ? rom_rdata    :
                   sel_ram     ? ram_rdata    :
                   sel_shared  ? shared_rdata :
                   sel_sprite  ? sprite_rdata :
                   sel_ioc     ? {8'h00, ioc_rdata} :
                   sel_ctrl    ? io_rdata     :
                   sel_syt     ? io_rdata     :
                   16'hFFFF;

// --- TC0040IOC shared via top module. This map provides cs/rnw/addr1/wdata. ---
// ioc_cs is pulsed during sel_ioc TXN_NONE so the top module latches writes.
reg        r_ioc_cs;
reg  [7:0] r_ioc_wdata;
assign ioc_cs    = r_ioc_cs;
assign ioc_rnw   = bus_rnw;
assign ioc_addr1 = bus_addr[1];
assign ioc_wdata = r_ioc_wdata;

// --- FSM for bus transactions ---
localparam TXN_NONE       = 4'd0;
localparam TXN_ROM        = 4'd1;
localparam TXN_RAM_RD     = 4'd2;
localparam TXN_RAM_WR     = 4'd3;
localparam TXN_SHARED_RD  = 4'd4;
localparam TXN_SHARED_WR  = 4'd5;
localparam TXN_SPRITE_RD  = 4'd6;
localparam TXN_SPRITE_WR  = 4'd7;
localparam TXN_DONE       = 4'd8;
localparam TXN_EXT_WAIT   = 4'd9;  // hold bus_busy=1, DTACK from ext_dtack_n only
localparam TXN_RAM_RD_WAIT = 4'd10; // extra cycle for BRAM output register to settle

reg [3:0] txn_state;
assign dbg_txn_state = txn_state;

always @(posedge clk) begin
	if (reset) begin
		txn_state     <= TXN_NONE;
		bus_cs        <= 1'b0;
		bus_busy      <= 1'b0;
		io_rdata      <= 16'hFFFF;
		rom_req       <= 1'b0;
		rom_addr      <= 24'd0;
		ram_rd        <= 1'b0;
		ram_wr        <= 1'b0;
		shared_rd     <= 1'b0;
		shared_wr     <= 1'b0;
		sprite_rd     <= 1'b0;
		sprite_wr     <= 1'b0;
		cpua_ctrl_wr  <= 1'b0;
		cpua_ctrl_data <= 8'd0;
		syt_mode      <= 4'd0;
		syt_cs_n      <= 1'b1;
		syt_wr_n      <= 1'b1;
		syt_rd_n      <= 1'b1;
		syt_a1        <= 1'b0;
		syt_active    <= 1'b0;
		r_ioc_cs      <= 1'b0;
		r_ioc_wdata   <= 8'd0;
	end else begin
		// Defaults — pulse signals return to 0 each cycle.
		// syt_cs/wr/rd_n NON vengono resettati ogni ciclo: la durata e' gestita
		// da syt_active (alta per tutta la transazione 68000 verso il SYT).
		rom_req      <= 1'b0;
		ram_rd       <= 1'b0;
		ram_wr       <= 1'b0;
		shared_rd    <= 1'b0;
		shared_wr    <= 1'b0;
		sprite_rd    <= 1'b0;
		sprite_wr    <= 1'b0;
		cpua_ctrl_wr <= 1'b0;
		r_ioc_cs     <= 1'b0;

		case (txn_state)
		TXN_NONE: begin
			bus_cs   <= 1'b0;
			bus_busy <= 1'b0;

			if (bus_active) begin
				// --- ROM fetch ---
				if (sel_rom) begin
					rom_addr  <= rom_addr_masked;  // clear bit 20 for mirror
					rom_req   <= 1'b1;  // single pulse (rom_cache detects rising edge)
					bus_cs    <= 1'b1;
					bus_busy  <= 1'b1;
					txn_state <= TXN_ROM;

				// --- Main RAM ---
				end else if (sel_ram) begin
					ram_addr_o <= bus_addr[15:1];
					ram_wdata  <= bus_wdata;
					ram_be_o   <= ~bus_dsn;  // latch byte enable NOW (DSn may de-assert before write reaches BRAM)
					if (bus_rnw) begin
						ram_rd    <= 1'b1;
						txn_state <= TXN_RAM_RD_WAIT;  // 1-cycle delay: BRAM needs N+2 to present data
					end else begin
						ram_wr    <= 1'b1;
						txn_state <= TXN_RAM_WR;
					end
					bus_cs   <= 1'b1;
					bus_busy <= 1'b1;

				// --- TC0040IOC (shared) ---
				// Pulse ioc_cs so the shared module latches write / provides read.
				// bus_rdata takes ioc_rdata combinationally via the mux above (sel_ioc).
				end else if (sel_ioc) begin
					bus_cs      <= 1'b1;
					bus_busy    <= 1'b0;
					r_ioc_cs    <= 1'b1;
					r_ioc_wdata <= bus_wdata[7:0];
					txn_state   <= TXN_DONE;

				// --- CPUA ctrl ---
				// MAME cpua_ctrl_w: if only high byte is written (UDS only),
				// shift high→low so bit 0 of the low byte is correctly set.
				// if ((data & 0xff00) && ((data & 0xff) == 0)) data = data >> 8;
				end else if (sel_ctrl) begin
					bus_cs   <= 1'b1;
					bus_busy <= 1'b0;
					if (~bus_rnw) begin
						cpua_ctrl_wr   <= 1'b1;
						// MAME-style high-byte-only normalization
						if ((bus_wdata[15:8] != 8'h00) && (bus_wdata[7:0] == 8'h00))
							cpua_ctrl_data <= bus_wdata[15:8];
						else
							cpua_ctrl_data <= bus_wdata[7:0];
					end else begin
						io_rdata  <= {8'h00, cpua_ctrl_q};
					end
					txn_state <= TXN_DONE;

				// --- TC0140SYT sound comm (real, no stub) ---
				// MAME: $220001=master_port_w, $220003=master_comm_r/w
				// Pilotiamo cs/wr/rd/a1 al TC0140SYT vero in audio_top.
				// Lettura: dato dal SYT (syt_main_dout, nibble basso).
				// CS/WR/RD vengono tenuti asseriti per tutta la transazione 68000
				// (TXN_DONE finche' bus_active) cosi' il SYT li campiona col ce_12m.
				end else if (sel_syt) begin
					bus_cs     <= 1'b1;
					bus_busy   <= 1'b0;
					syt_cs_n   <= 1'b0;
					syt_a1     <= bus_addr[1];
					syt_wr_n   <= bus_rnw;
					syt_rd_n   <= ~bus_rnw;
					syt_active <= 1'b1;
					io_rdata   <= {12'h000, syt_main_dout};
					txn_state  <= TXN_DONE;

				// --- Shared RAM ---
				end else if (sel_shared) begin
					shared_addr  <= bus_addr[15:1];
					shared_wdata <= bus_wdata;
					shared_be_o  <= ~bus_dsn;  // latch byte enable
					if (bus_rnw) begin
						shared_rd <= 1'b1;
						txn_state <= TXN_SHARED_RD;
					end else begin
						shared_wr <= 1'b1;
						txn_state <= TXN_SHARED_WR;
					end
					bus_cs   <= 1'b1;
					bus_busy <= 1'b1;

				// --- Sprite RAM ---
				end else if (sel_sprite) begin
					sprite_addr  <= bus_addr[13:1];
					sprite_wdata <= bus_wdata;
					sprite_be_o  <= ~bus_dsn;  // latch byte enable
					if (bus_rnw) begin
						sprite_rd <= 1'b1;
						txn_state <= TXN_SPRITE_RD;
					end else begin
						sprite_wr <= 1'b1;
						txn_state <= TXN_SPRITE_WR;
					end
					bus_cs   <= 1'b1;
					bus_busy <= 1'b1;

				// --- TC0100SCN / TC0110PCR ranges ---
				// bus_cs=1, bus_busy=1: jtframe holds DTACKn high.
				// DTACK comes from ext_dtack_n (chip DACKn) via AND in cpu_node.
				// This ensures the CPU waits for the TC0100SCN CPU_ACCESS slot.
				end else if (sel_scn_or_pal) begin
					bus_cs   <= 1'b1;
					bus_busy <= 1'b1;
					txn_state <= TXN_EXT_WAIT;

				// --- Unknown address ---
				end else begin
					bus_cs    <= 1'b1;
					bus_busy  <= 1'b0;
					txn_state <= TXN_DONE;
				end
			end
		end

		// --- ROM fetch wait ---
		TXN_ROM: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~rom_ready;
			if (rom_ready) begin
				txn_state <= TXN_DONE;
			end
		end

		// --- Main RAM read: BRAM output register needs 1 extra cycle to settle ---
		// Sequence: cycle N: ram_rd<=1 → cycle N+1: BRAM registers addr, reads array
		//           cycle N+2: rdata_hi/lo present on ram_rdata → sample here
		TXN_RAM_RD_WAIT: begin
			bus_cs    <= 1'b1;
			bus_busy  <= 1'b1;      // hold CPU waiting
			txn_state <= TXN_RAM_RD;
		end
		TXN_RAM_RD: begin
			// bus_rdata is combinational from ram_rdata via mux above (Darius 1 style)
			bus_cs    <= 1'b1;
			bus_busy  <= 1'b0;
			txn_state <= TXN_DONE;
		end

		// --- Main RAM write (immediate) ---
		TXN_RAM_WR: begin
			bus_cs    <= 1'b1;
			bus_busy  <= 1'b0;
			txn_state <= TXN_DONE;
		end

		// --- Shared RAM read ---
		TXN_SHARED_RD: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~shared_ready;
			if (shared_ready) begin
				// bus_rdata is combinational from shared_rdata via mux above
				txn_state <= TXN_DONE;
			end
		end

		// --- Shared RAM write ---
		TXN_SHARED_WR: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~shared_ready;
			if (shared_ready) begin
				txn_state <= TXN_DONE;
			end else begin
				shared_wr <= 1'b1;
			end
		end

		// --- Sprite RAM read ---
		TXN_SPRITE_RD: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~sprite_ready;
			if (sprite_ready) begin
				// bus_rdata is combinational from sprite_rdata via mux above
				txn_state <= TXN_DONE;
			end
		end

		// --- Sprite RAM write ---
		TXN_SPRITE_WR: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~sprite_ready;
			if (sprite_ready) begin
				txn_state <= TXN_DONE;
			end else begin
				sprite_wr <= 1'b1;
			end
		end

		// --- External device wait (SCN/palette) ---
		// bus_cs=1; bus_busy follows ext_dtack_n: high while chip busy, low when chip responds.
		// This lets jtframe_68kdtack_cen pass DTACKn=0 to CPU (DTACKn <= DTACKn && bus_cs && bus_busy).
		// When chip responds (ext_dtack_n=0), bus_busy=0 → jtframe drops DTACKn → CPU completes.
		TXN_EXT_WAIT: begin
			bus_cs   <= 1'b1;
			bus_busy <= ext_dtack_n;
			if (~bus_active)
				txn_state <= TXN_NONE;
		end

		// --- Transaction done, wait for bus release ---
		TXN_DONE: begin
			bus_cs   <= 1'b1;
			bus_busy <= 1'b0;
			if (~bus_active) begin
				txn_state  <= TXN_NONE;
				syt_cs_n   <= 1'b1;
				syt_wr_n   <= 1'b1;
				syt_rd_n   <= 1'b1;
				syt_active <= 1'b0;
			end
		end

		default: txn_state <= TXN_NONE;
		endcase
	end
end

endmodule
