/*  This file is part of Darius2NinjaWarriors_MiSTer.

    Darius2NinjaWarriors_MiSTer is free software: you can redistribute it
    and/or modify it under the terms of the GNU General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    Darius2NinjaWarriors_MiSTer is distributed in the hope that it will be
    useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Darius2NinjaWarriors_MiSTer.
    If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026
*/

// pause_overlay.sv — overlay pausa: dim + logo + header "PATREON" +
// patron list scrollante (sx) + links statici (dx).
//
// Layout 864×224:
//   - Header "PATREON" giallo top-sx (X≈16, Y≈8)
//   - Patron scroll bottom→top, sx del logo (X=16..344, Y=40..184)
//   - Logo 48×48 ×3 = 144×144 al centro (X=360..504, Y=40..184)
//   - Links statici a destra (X=520..848, Y=40..184)

module pause_overlay (
	input  wire        clk,
	input  wire        pause,
	input  wire        clean,    // OSD: bypass overlay (no dim, no logo, no addon)

	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,

	input  wire [7:0]  rgb_r_in,
	input  wire [7:0]  rgb_g_in,
	input  wire [7:0]  rgb_b_in,

	output wire [7:0]  rgb_r_out,
	output wire [7:0]  rgb_g_out,
	output wire [7:0]  rgb_b_out
);

// Effective overlay: pause attiva ma clean disattivato.
wire overlay_on = pause & ~clean;

// VBlank pulse: rilevato all'ingresso vblank (render_y attraversa 224).
// triple_screen_test ha V_ACTIVE=224, V_TOTAL=262 → render_y va 0..261.
// Pulse di 1 ciclo quando render_y passa da 223 a 224.
reg [8:0] render_y_d;
always @(posedge clk) render_y_d <= render_y;
wire vblank_pulse = (render_y == 9'd224) && (render_y_d == 9'd223);

// =====================================================================
// Logo placement: 48x48 sorgente, scalato x3 → 144x144 sullo schermo.
// Schermo 864x224, top-left logo a ((864-144)/2, (224-144)/2) = (360, 40).
// =====================================================================
localparam [9:0] LOGO_X    = 10'd360;
localparam [8:0] LOGO_Y    = 9'd40;
localparam [9:0] LOGO_XEND = LOGO_X + 10'd144;
localparam [8:0] LOGO_YEND = LOGO_Y + 9'd144;

// Read-ahead: per il pixel corrente serve l'address sul ck precedente.
wire [9:0] x_ahead = render_x + 10'd1;
wire [9:0] dx_screen = x_ahead - LOGO_X;          // 0..143
wire [9:0] dy_screen = {1'b0, render_y} - {1'b0, LOGO_Y};

wire in_logo_ahead = overlay_on &&
	(x_ahead   >= LOGO_X) && (x_ahead   < LOGO_XEND) &&
	(render_y  >= LOGO_Y) && (render_y  < LOGO_YEND);

// Divisione per 3 esatta con costante: (v * 0xAAAB) >> 17 esatto per v<=65535.
// v max = 143, v*0xAAAB max = 143*43691 = 6'247'813 = 0x5F58A5 (23 bit).
// Per minimizzare uso (v*0x55+0x55)>>8 valido per v<=170 (verificato).
//   v=0   → (0+0x55)>>8     = 0  ✓
//   v=3   → (0xFF+0x55)>>8  = 1  ✓
//   v=6   → (0x1FE+0x55)>>8 = 2  ✓
//   v=143 → (0x2F7B+0x55)>>8= 0x2F = 47 ✓
function [5:0] div3;
	input [7:0] v;  // 0..143
	begin
		div3 = (({8'd0, v} * 16'h0055) + 16'h0055) >> 8;
	end
endfunction

wire [5:0] dx = div3(dx_screen[7:0]);
wire [5:0] dy = div3(dy_screen[7:0]);
// addr = dy*48 + dx = (dy<<5) + (dy<<4) + dx, max=47*48+47=2303
wire [11:0] logo_addr = {1'b0, dy, 5'd0} + {2'b0, dy, 4'd0} + {6'd0, dx};

// =====================================================================
// Logo BRAM 2304x2 init da logo/logo.mem
// =====================================================================
reg [1:0] logo_rom [0:2303] /* synthesis ramstyle = "M10K" */;
initial $readmemb("logo/logo.mem", logo_rom);
reg [1:0] logo_pix;
reg       in_logo_now;
always @(posedge clk) begin
	logo_pix    <= logo_rom[logo_addr];
	in_logo_now <= in_logo_ahead;
end

// Palette logo: pal0=nero (trasparente), pal1=magenta, pal2=cyan, pal3=bianco
reg [7:0] lr, lg, lb;
always @(*) case (logo_pix)
	2'd0: {lr, lg, lb} = 24'h000000;
	2'd1: {lr, lg, lb} = 24'hFF00FF;
	2'd2: {lr, lg, lb} = 24'h00E6E4;
	2'd3: {lr, lg, lb} = 24'hFFFFFF;
endcase

wire logo_opaque = 1'b1;  // Logo tutto opaco (nero=palette[0] visibile come bordo)

// =====================================================================
// Header "SUPPORTERS" — centrato nel monitor sx (sopra patron scroll).
// 10 char × 8 = 80 px → ORIGIN_X = 0 + (288-80)/2 = 104
// =====================================================================
wire       header_on;
wire [1:0] header_tier;
pause_text #(
	.W_CHARS      (10),
	.H_CHARS      (1),
	.MSG_ROWS     (1),
	.ORIGIN_X     (10'd104),
	.ORIGIN_Y     (9'd24),
	.SCROLL_EN    (0),
	.FONT_FILE    ("logo/font_darius.hex"),
	.MSG_FILE     ("logo/header.mem")
) u_header (
	.clk          (clk),
	.active       (overlay_on),
	.vblank_pulse (vblank_pulse),
	.render_x     (render_x),
	.render_y     (render_y),
	.pixel_on     (header_on),
	.pixel_tier   (header_tier)
);

// =====================================================================
// Patron scroll — centrati nel monitor sx (X=0..288, 288 px).
// 30 char × 8 = 240 px → ORIGIN_X = 0 + (288-240)/2 = 24
// Y=40..184 (18 righe), MSG_ROWS=32 (scroll loop)
// =====================================================================
wire       patron_on;
wire [1:0] patron_tier;
pause_text #(
	.W_CHARS       (30),
	.H_CHARS       (18),
	.MSG_ROWS      (70),
	.ORIGIN_X      (10'd24),
	.ORIGIN_Y      (9'd48),
	.SCROLL_EN     (1),
	.SCROLL_PERIOD (3),
	.FONT_FILE     ("logo/font_darius.hex"),
	.MSG_FILE      ("logo/patrons.mem")
) u_patron (
	.clk          (clk),
	.active       (overlay_on),
	.vblank_pulse (vblank_pulse),
	.render_x     (render_x),
	.render_y     (render_y),
	.pixel_on     (patron_on),
	.pixel_tier   (patron_tier)
);

// =====================================================================
// Links statici — centrati nel monitor dx (X=576..864, 288 px).
// 32 char × 8 = 256 px → ORIGIN_X = 576 + (288-256)/2 = 592
// 17 righe × 8 = 136 px, da Y=16
// =====================================================================
wire       links_on;
wire [1:0] links_tier;  // unused, links sempre cyan (uniformi)
pause_text #(
	.W_CHARS      (32),
	.H_CHARS      (17),
	.MSG_ROWS     (17),
	.ORIGIN_X     (10'd592),
	.ORIGIN_Y     (9'd24),
	.SCROLL_EN    (0),
	.FONT_FILE    ("logo/font_darius.hex"),
	.MSG_FILE     ("logo/links.mem")
) u_links (
	.clk          (clk),
	.active       (overlay_on),
	.vblank_pulse (vblank_pulse),
	.render_x     (render_x),
	.render_y     (render_y),
	.pixel_on     (links_on),
	.pixel_tier   (links_tier)
);

// Palette tier per i patron (4 livelli):
//   tier 0 = bianco  (default, nessun tier)
//   tier 1 = bronzo  ($3 — base supporters)
//   tier 2 = argento ($7 — silver supporters)
//   tier 3 = oro     (futuro gold supporters)
function [23:0] tier_color;
	input [1:0] tier;
	begin
		case (tier)
			2'd0: tier_color = 24'hFFFFFF;  // bianco (etichette tier + honorable + URL link)
			2'd1: tier_color = 24'h00E6E4;  // azzurrino/cyan (bronze + label link)
			2'd2: tier_color = 24'hFF00FF;  // magenta (silver, tier medio)
			2'd3: tier_color = 24'hFFD700;  // oro (gold, tier alto)
		endcase
	end
endfunction

// Colori testi:
//   header   = giallo/oro (FFD700) — stile Taito
//   patron   = colore tier (palette sopra)
//   links    = colore tier (label azzurrino, URL bianco)
wire [23:0] header_rgb = 24'hFFD700;
wire [23:0] patron_rgb = tier_color(patron_tier);
wire [23:0] links_rgb  = tier_color(links_tier);

// Priorità mux: logo > header > patron > links > dim > raw
wire text_on = header_on | patron_on | links_on;
wire [23:0] text_rgb = header_on ? header_rgb :
                       links_on  ? links_rgb  :
                                   patron_rgb;

// =====================================================================
// Output mux combinatoriale puro (no shift sul path video!)
// =====================================================================
wire [7:0] dim_r = {1'b0, rgb_r_in[7:1]};
wire [7:0] dim_g = {1'b0, rgb_g_in[7:1]};
wire [7:0] dim_b = {1'b0, rgb_b_in[7:1]};

assign rgb_r_out = !overlay_on             ? rgb_r_in :
                   in_logo_now & logo_opaque ? lr        :
                   text_on                  ? text_rgb[23:16] :
                                              dim_r;
assign rgb_g_out = !overlay_on             ? rgb_g_in :
                   in_logo_now & logo_opaque ? lg        :
                   text_on                  ? text_rgb[15:8]  :
                                              dim_g;
assign rgb_b_out = !overlay_on             ? rgb_b_in :
                   in_logo_now & logo_opaque ? lb        :
                   text_on                  ? text_rgb[7:0]   :
                                              dim_b;

endmodule
