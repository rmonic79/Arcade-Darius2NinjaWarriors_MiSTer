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

// triple_screen_test — Compositor video finale.
// Mixa tile L0/L1 (3 panel orizzontali), sprite e FG layer con priority e
// opacità. Gestisce ce_pix, layer enable dall'OSD e output RGB verso il
// wrapper MiSTer (sys/).

module triple_screen_test
#(
	parameter ENABLE_DEBUG = 1  // 1=overlay visible, 0=no overlay (zero logic)
)
(
	input         clk,
	input         reset,
	input   [3:0] layer_en,   // {FG, SPR, L1, L0} — 1=visible, 0=hidden
	input  [23:0] tile_rgb,
	input   [1:0] tile_prio,
	input         tile_opaque,
	input  [23:0] sprite_pix_rgb,
	input   [1:0] sprite_prio,
	input         sprite_opaque,
	input  [23:0] fg_rgb,
	input         fg_opaque,

	// Debug overlay inputs (active only when ENABLE_DEBUG=1)
	input  [23:0] dbg_pc,
	input  [23:0] dbg_bus_addr,
	input   [3:0] dbg_txn_state,
	input         dbg_bus_busy,
	input         dbg_dtack_n,
	input         dbg_ext_dtack_n,
	input  [15:0] dbg_rom_word,
	input         dbg_rom_word_valid,
	input         dbg_sdram_req1,
	input         dbg_sdram_ack1,
	input         dbg_main_pending,
	input         dbg_download_active,
	input         dbg_sdram_ready,
	input   [1:0] dbg_cache_state,
	input         dbg_reset,
	// Video debug
	input  [14:0] dbg_scn0_sc,
	input         dbg_scn0_sc_seen,
	input         dbg_tilerom_req_seen,
	input  [15:0] dbg_scn0_wr_cnt,
	input  [15:0] dbg_peek_val,
	input         dbg_peek_match,
	input  [31:0] dbg_d6,
	input  [31:0] dbg_d7,
	input  [31:0] dbg_d0,
	input  [31:0] dbg_a0,
	input  [31:0] dbg_a1,
	input  [15:0] dbg_ram_wr_cnt,
	input  [15:0] dbg_ram_rd_val,
	input  [23:0] dbg_sub_pc,
	input         dbg_enable,       // runtime toggle overlay (OSD status bit)

	output        ce_pix,
	output        HBlank,
	output        HSync,
	output        VBlank,
	output        VSync,
	output  [9:0] render_x,
	output  [8:0] render_y,
	output  [7:0] R,
	output  [7:0] G,
	output  [7:0] B
);

localparam [10:0] H_ACTIVE = 11'd864;
localparam [10:0] H_FP     = 11'd100;
localparam [10:0] H_SYNC   = 11'd150;
localparam [10:0] H_BP     = 11'd413;
localparam [10:0] H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 1527

localparam V_ACTIVE = 9'd224;
localparam V_FP     = 9'd8;
localparam V_SYNC   = 9'd4;
localparam V_BP     = 9'd26;
localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 262

localparam PANEL_W  = 10'd288;

// Pixel clock: 96MHz / 4 = 24MHz -> 24M / 1527 / 262 ~ 60Hz
reg        pxl_en;
reg  [1:0] pxl_div;

reg [10:0] hc = 0;
reg  [8:0] vc = 0;

always @(posedge clk) begin
	if(reset) begin
		hc <= 0;
		vc <= 0;
		pxl_en <= 0;
		pxl_div <= 0;
	end else begin
		pxl_div <= pxl_div + 2'd1;
		pxl_en <= (pxl_div == 2'd3);
		if(pxl_en) begin
			if(hc == H_TOTAL - 1'd1) begin
				hc <= 0;
				if(vc == V_TOTAL - 1'd1) vc <= 0;
				else                     vc <= vc + 1'd1;
			end else begin
				hc <= hc + 1'd1;
			end
		end
	end
end

wire active = (hc < H_ACTIVE) && (vc < V_ACTIVE);
assign HBlank = ~((hc < H_ACTIVE));
assign VBlank = ~((vc < V_ACTIVE));
assign HSync  = ~((hc >= (H_ACTIVE + H_FP)) && (hc < (H_ACTIVE + H_FP + H_SYNC)));
assign VSync  = ~((vc >= (V_ACTIVE + V_FP)) && (vc < (V_ACTIVE + V_FP + V_SYNC)));
assign ce_pix = pxl_en;

wire [9:0] screen_x = hc[9:0];
wire [8:0] screen_y = vc;
// During hblank: render_x=900 (prevents hc[9:0] wrap re-triggering tile prefetch).
// render_y keeps actual line so FG renderer can start during hblank.
// During vblank: screen_y >= V_ACTIVE naturally, so render_y < V_ACTIVE fails.
assign render_x = active ? screen_x : 10'd900;
// Shift globale +1: il chip renderizza 1..224 invece di 0..223.
// Così lo schermo mostra contenuto alzato di 1 pixel globalmente.
// Wrap V_TOTAL: 261 → 0
assign render_y = (screen_y == 9'd261) ? 9'd0 : screen_y + 9'd1;

reg [7:0] r;
reg [7:0] g;
reg [7:0] b;

always @(*) begin
	r = 8'd0;
	g = 8'd0;
	b = 8'd0;

	if(active) begin
		// Tile layers (L0+L1 combined in line buffer)
		if(tile_opaque && layer_en[0]) begin
			r = tile_rgb[23:16];
			g = tile_rgb[15:8];
			b = tile_rgb[7:0];
		end

		// Sprite overlay (MAME ninjaw.cpp priority: "1 = low")
		//   prio=0 (primask GFX_PMASK_4): sprite sopra tutto tranne FG
		//   prio=1 (primask GFX_PMASK_4|GFX_PMASK_2): sprite sotto L1 (tile_prio=10)
		// Draw se: no tile opaco, OR prio=0, OR tile NON è L1.
		if(sprite_opaque && layer_en[2] &&
		   (~tile_opaque || !sprite_prio[0] || tile_prio != 2'b10)) begin
			r = sprite_pix_rgb[23:16];
			g = sprite_pix_rgb[15:8];
			b = sprite_pix_rgb[7:0];
		end

		// FG layer (text/HUD) — on top of everything
		if (fg_opaque && layer_en[3]) begin
			r = fg_rgb[23:16];
			g = fg_rgb[15:8];
			b = fg_rgb[7:0];
		end
	end
end

// --- Debug overlay (conditional) ---
generate if (ENABLE_DEBUG) begin : gen_dbg_overlay
	wire dbg_pixel_on_raw, dbg_bg_on_raw;
	reg  dbg_pixel_on, dbg_bg_on;
	reg  [7:0] r_reg, g_reg, b_reg;

	debug_overlay_d2 u_dbg_ovl (
		.render_x(hc[9:0]),
		.render_y(vc),
		.clk(clk),
		.reset(reset),
		.dbg_pc(dbg_pc),
		.dbg_bus_addr(dbg_bus_addr),
		.dbg_txn_state(dbg_txn_state),
		.dbg_bus_busy(dbg_bus_busy),
		.dbg_dtack_n(dbg_dtack_n),
		.dbg_ext_dtack_n(dbg_ext_dtack_n),
		.dbg_rom_word(dbg_rom_word),
		.dbg_rom_word_valid(dbg_rom_word_valid),
		.dbg_sdram_req1(dbg_sdram_req1),
		.dbg_sdram_ack1(dbg_sdram_ack1),
		.dbg_main_pending(dbg_main_pending),
		.dbg_download_active(dbg_download_active),
		.dbg_sdram_ready(dbg_sdram_ready),
		.dbg_cache_state(dbg_cache_state),
		.dbg_reset(dbg_reset),
		.dbg_scn0_sc(dbg_scn0_sc),
		.dbg_scn0_sc_seen(dbg_scn0_sc_seen),
		.dbg_tilerom_req_seen(dbg_tilerom_req_seen),
		.dbg_scn0_wr_cnt(dbg_scn0_wr_cnt),
		.dbg_peek_val(dbg_peek_val),
		.dbg_peek_match(dbg_peek_match),
		.dbg_d6(dbg_d6),
		.dbg_d7(dbg_d7),
		.dbg_d0(dbg_d0),
		.dbg_a0(dbg_a0),
		.dbg_a1(dbg_a1),
		.dbg_ram_wr_cnt(dbg_ram_wr_cnt),
		.dbg_ram_rd_val(dbg_ram_rd_val),
		.dbg_sub_pc(dbg_sub_pc),
		.pixel_on(dbg_pixel_on_raw),
		.bg_on(dbg_bg_on_raw)
	);

	// Register overlay output + r/g/b to break long combinational path to scanlines.
	// 1 pixel clock delay is invisible; fixes timing failure on core clock.
	always @(posedge clk) begin
		dbg_pixel_on <= dbg_pixel_on_raw;
		dbg_bg_on    <= dbg_bg_on_raw;
		r_reg        <= r;
		g_reg        <= g;
		b_reg        <= b;
	end

	// Runtime toggle: dbg_enable=0 bypassa overlay mostrando solo gioco
	assign R = dbg_enable ? (dbg_pixel_on ? 8'hFF : dbg_bg_on ? 8'h00 : r_reg) : r_reg;
	assign G = dbg_enable ? (dbg_pixel_on ? 8'hFF : dbg_bg_on ? 8'h00 : g_reg) : g_reg;
	assign B = dbg_enable ? (dbg_pixel_on ? 8'hFF : dbg_bg_on ? 8'h20 : b_reg) : b_reg;
end else begin : gen_no_dbg
	assign R = r;
	assign G = g;
	assign B = b;
end endgenerate

endmodule
