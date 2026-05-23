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

// darius2_subcpu_map — Memory map del Sub 68000 per Darius II.
//
// MAME: darius2_slave_map (ninjaw.cpp)
//
// $000000-$05FFFF  ROM (384 KB)         → SDRAM
// $080000-$08FFFF  Sub RAM (64 KB)      → BRAM
// $200000-$200003  TC0040IOC (I/O)      → registri (same as main)
// $240000-$24FFFF  Shared RAM (64 KB)   → BRAM dual-port
// $260000-$263FFF  Sprite RAM (16 KB)   → BRAM dual-port
// $280000-$293FFF  TC0100SCN[0] RAM     → write-through to all 3

module darius2_subcpu_map_new
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

	output wire [1:0]  bus_be,

	// ROM (SDRAM via rom_cache)
	output reg  [23:0] rom_addr,
	output reg         rom_req,
	input  wire [15:0] rom_rdata,
	input  wire        rom_ready,

	// Sub RAM (64 KB)
	output reg         ram_rd,
	output reg         ram_wr,
	output reg  [1:0]  ram_be_o,    // latched byte enable
	output reg  [14:0] ram_addr_o,
	output reg  [15:0] ram_wdata,
	input  wire [15:0] ram_rdata,

	// Shared RAM (64 KB, dual-port — Port B = sub)
	output reg         shared_rd,
	output reg         shared_wr,
	output reg  [1:0]  shared_be_o,  // latched byte enable
	output reg  [14:0] shared_addr,
	output reg  [15:0] shared_wdata,
	input  wire [15:0] shared_rdata,
	input  wire        shared_ready,

	// Sprite RAM (16 KB, dual-port — Port B = sub)
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
	input  wire  [7:0] ioc_rdata,

	// TC0100SCN[0] access — decoded in top, not here
	// Sub only accesses $280000-$293FFF with write-through

	input  wire        vblank,
	// External DTACK from SCN/palette chips (0 = chip responded)
	input  wire        ext_dtack_n
);

assign bus_be = ~bus_dsn;

// bus_active requires DSn asserted — prevents sel_ram triggering before CPU asserts DSn.
wire bus_active = ~bus_asn && (bus_dsn != 2'b11);

wire sel_rom     = bus_active && (bus_addr <= 24'h05FFFF);
wire sel_ram     = bus_active && (bus_addr >= 24'h080000) && (bus_addr <= 24'h08FFFF);
wire sel_ioc     = bus_active && (bus_addr >= 24'h200000) && (bus_addr <= 24'h200003);
wire sel_shared  = bus_active && (bus_addr >= 24'h240000) && (bus_addr <= 24'h24FFFF);
wire sel_sprite  = bus_active && (bus_addr >= 24'h260000) && (bus_addr <= 24'h263FFF);
wire sel_scn0    = bus_active && (bus_addr >= 24'h280000) && (bus_addr <= 24'h293FFF);
// Ninja Warriors slave map: palette $340000-$360007 (3 TC0110PCR chips).
// MAME ninjaw_slave_map (ninjaw.cpp:699-701): sub scrive palette dei 3 schermi.
// Main e sub condividono l'accesso palette via bus mux esterno (ext_dtack_n).
wire sel_pal     = bus_active && (bus_addr >= 24'h340000) && (bus_addr <= 24'h360007);

// --- Combinational bus_rdata mux (Darius 1 style) ---
// Per sel_pal/sel_scn0 fallback 16'hFFFF → il top fornisce dato via
// composite mux con output chip palette/SCN (stessa struttura main).
assign bus_rdata = sel_rom     ? rom_rdata    :
                   sel_ram     ? ram_rdata    :
                   sel_shared  ? shared_rdata :
                   sel_sprite  ? sprite_rdata :
                   sel_ioc     ? {8'h00, ioc_rdata} :
                   16'hFFFF;

// --- TC0040IOC shared ---
reg        r_ioc_cs;
reg  [7:0] r_ioc_wdata;
assign ioc_cs    = r_ioc_cs;
assign ioc_rnw   = bus_rnw;
assign ioc_addr1 = bus_addr[1];
assign ioc_wdata = r_ioc_wdata;

// FSM
localparam TXN_NONE       = 4'd0;
localparam TXN_ROM        = 4'd1;
localparam TXN_RAM_RD     = 4'd2;
localparam TXN_RAM_WR     = 4'd3;
localparam TXN_SHARED_RD  = 4'd4;
localparam TXN_SHARED_WR  = 4'd5;
localparam TXN_SPRITE_RD  = 4'd6;
localparam TXN_SPRITE_WR  = 4'd7;
localparam TXN_DONE       = 4'd8;
localparam TXN_EXT_WAIT   = 4'd9;
localparam TXN_RAM_RD_WAIT = 4'd10; // extra cycle for BRAM output register to settle

reg [3:0] txn_state;

always @(posedge clk) begin
	if (reset) begin
		txn_state <= TXN_NONE;
		bus_cs    <= 1'b0;
		bus_busy  <= 1'b0;
		rom_req   <= 1'b0;
		rom_addr  <= 24'd0;
		ram_rd    <= 1'b0;
		ram_wr    <= 1'b0;
		shared_rd <= 1'b0;
		shared_wr <= 1'b0;
		sprite_rd <= 1'b0;
		sprite_wr <= 1'b0;
		r_ioc_cs    <= 1'b0;
		r_ioc_wdata <= 8'd0;
	end else begin
		rom_req   <= 1'b0;
		ram_rd    <= 1'b0;
		ram_wr    <= 1'b0;
		shared_rd <= 1'b0;
		shared_wr <= 1'b0;
		sprite_rd <= 1'b0;
		sprite_wr <= 1'b0;
		r_ioc_cs  <= 1'b0;

		case (txn_state)
		TXN_NONE: begin
			bus_cs   <= 1'b0;
			bus_busy <= 1'b0;

			if (bus_active) begin
				if (sel_rom) begin
					rom_addr  <= bus_addr;
					rom_req   <= 1'b1;  // single pulse
					bus_cs    <= 1'b1;
					bus_busy  <= 1'b1;
					txn_state <= TXN_ROM;

				end else if (sel_ram) begin
					ram_addr_o <= bus_addr[15:1];
					ram_wdata  <= bus_wdata;
					ram_be_o   <= ~bus_dsn;  // latch NOW (DSn may de-assert before write reaches BRAM)
					if (bus_rnw) begin
						ram_rd    <= 1'b1;
						txn_state <= TXN_RAM_RD_WAIT;  // 1-cycle delay: BRAM needs N+2 to present data
					end else begin
						ram_wr    <= 1'b1;
						txn_state <= TXN_RAM_WR;
					end
					bus_cs   <= 1'b1;
					bus_busy <= 1'b1;

				end else if (sel_ioc) begin
					bus_cs      <= 1'b1;
					bus_busy    <= 1'b0;
					r_ioc_cs    <= 1'b1;
					r_ioc_wdata <= bus_wdata[7:0];
					txn_state   <= TXN_DONE;

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

				// SCN[0] range: hold CPU until chip responds via ext_dtack_n
				end else if (sel_scn0 || sel_pal) begin
					bus_cs   <= 1'b1;
					bus_busy <= 1'b1;
					txn_state <= TXN_EXT_WAIT;

				end else begin
					bus_cs    <= 1'b1;
					bus_busy  <= 1'b0;
					txn_state <= TXN_DONE;
				end
			end
		end

		TXN_ROM: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~rom_ready;
			if (rom_ready) begin
				txn_state <= TXN_DONE;
			end
		end

		TXN_RAM_RD_WAIT: begin
			bus_cs    <= 1'b1;
			bus_busy  <= 1'b1;
			txn_state <= TXN_RAM_RD;
		end

		TXN_RAM_RD: begin
			// bus_rdata is combinational from ram_rdata via mux above
			bus_cs    <= 1'b1;
			bus_busy  <= 1'b0;
			txn_state <= TXN_DONE;
		end

		TXN_RAM_WR: begin
			bus_cs    <= 1'b1;
			bus_busy  <= 1'b0;
			txn_state <= TXN_DONE;
		end

		TXN_SHARED_RD: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~shared_ready;
			if (shared_ready) begin
				// bus_rdata is combinational from shared_rdata via mux above
				txn_state <= TXN_DONE;
			end
		end

		TXN_SHARED_WR: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~shared_ready;
			if (shared_ready) begin
				txn_state <= TXN_DONE;
			end else begin
				shared_wr <= 1'b1;
			end
		end

		TXN_SPRITE_RD: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~sprite_ready;
			if (sprite_ready) begin
				// bus_rdata is combinational from sprite_rdata via mux above
				txn_state <= TXN_DONE;
			end
		end

		TXN_SPRITE_WR: begin
			bus_cs   <= 1'b1;
			bus_busy <= ~sprite_ready;
			if (sprite_ready) begin
				txn_state <= TXN_DONE;
			end else begin
				sprite_wr <= 1'b1;
			end
		end

		TXN_EXT_WAIT: begin
			bus_cs   <= 1'b1;
			bus_busy <= ext_dtack_n;
			if (~bus_active)
				txn_state <= TXN_NONE;
		end

		TXN_DONE: begin
			bus_cs   <= 1'b1;
			bus_busy <= 1'b0;
			if (~bus_active)
				txn_state <= TXN_NONE;
		end

		default: txn_state <= TXN_NONE;
		endcase
	end
end

endmodule
