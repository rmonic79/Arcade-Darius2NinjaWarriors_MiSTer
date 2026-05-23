/*  This file is part of Darius_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonc79)
*/

// darius2_audio_top — sottosistema audio Darius II / Ninja Warriors.
// Tutto su DDRAM HPS via modulo darius2_ddram (Sorgelig pattern, NeoGeo-style).
//
// MRA Darius II / Ninja Warriors layout ioctl:
//   0x120000-0x13FFFF: Z80 ROM (128 KB) → DDRAM byte addr 0x000000 (offset Z80 ROM)
//   0x440000-0x5BFFFF: ADPCM-A (1.5 MB) → DDRAM byte addr 0x100000
//   0x5C0000-0x63FFFF: ADPCM-B (512 KB) → DDRAM byte addr 0x300000

module darius2_audio_top (
	input  wire        clk,         // 96 MHz (sys clk)
	input  wire        ddram_clk,   // DDRAM clock (da sysmem)
	input  wire        reset,
	input  wire        pause,

	// ioctl per write DDRAM (Z80 ROM + ADPCM A + B)
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,
	input  wire [15:0] ioctl_index,
	output wire        ioctl_wait,

	// Comunicazione main 68000 ↔ TC0140SYT
	input  wire  [3:0] main_din,
	output wire  [3:0] main_dout,
	input  wire        main_a1,
	input  wire        main_cs_n,
	input  wire        main_wr_n,
	input  wire        main_rd_n,

	// DDRAM HPS pin (passa a darius2_ddram)
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,

	// Sprite ROM read port (DDRAM port 4, 32-bit). Esposto al top per
	// alimentare lo sprite_rom_cache senza istanziarlo qui dentro.
	input  wire [27:0] spr_rdaddr,
	output wire [31:0] spr_dout,
	input  wire        spr_rd_req,
	output wire        spr_rd_ack,

	// Sprite ROM download path (separato da audio): il top si occupa di
	// gestire ioctl per sprite ROM e ce lo passa qui. Quando spr_we_req !=
	// spr_we_ack viene applicato. ddr_waddr/data interni audio_top tengono
	// la priorità solo se nessun audio download attivo.
	input  wire [27:0] spr_we_addr,
	input  wire [15:0] spr_we_data,
	input  wire        spr_we_req,
	output wire        spr_we_ack,

	// Audio output
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,

	// Audio mixer OSD volumes (3-bit each).
	// Mappa sel → fattore in 1/8: 0=8 (100%), 1=1 (12%), 2=2 (25%), 3=4 (50%),
	//                              4=6 (75%), 5=12 (150%), 6=16 (200%), 7=0 (mute)
	input  wire [2:0] osd_fm_vol,
	input  wire [2:0] osd_adpcma_vol,
	input  wire [2:0] osd_adpcmb_vol,
	input  wire [2:0] osd_psg_vol,

	// Debug counters (per LED visibility)
	output wire        dbg_z80_active,    // toggle se Z80 emette M1 (boot OK)
	output wire        dbg_ym_active,     // toggle se Z80 scrive YM (suoni)
	output wire        dbg_syt_main_act,  // toggle se main 68k tocca SYT
	output wire        dbg_syt_z80_act,   // toggle se Z80 tocca SYT (slave port)
	output wire        dbg_audio_nonzero  // 1 se jt10_left|jt10_right != 0 di recente
);

// Offset DDRAM byte (interno al modulo darius2_ddram → addr 28-bit, prefisso 0011 lo aggiunge ddram)
localparam [27:0] DDR_Z80_ROM_OFF  = 28'h0000000;  // 128 KB
localparam [27:0] DDR_ADPCMA_OFF   = 28'h0100000;  // 1.5 MB
localparam [27:0] DDR_ADPCMB_OFF   = 28'h0300000;  //  512 KB
localparam [27:0] DDR_SPRITE_OFF   = 28'h0400000;  //  2 MB sprite ROM (esposto al top)

// =====================================================================
// Clock enables (96 MHz / N) — pattern Darius1 con T80pa CEN_p/CEN_n
// + ce_12m separato per TC0140SYT
// =====================================================================
reg [6:0] ce_z80_cnt;
reg [3:0] ym_div;
reg [2:0] ce12_div;
wire ce_z80_p_raw = (ce_z80_cnt == 7'd23);  // 96/24 = 4 MHz
wire ce_z80_n_raw = (ce_z80_cnt == 7'd11);  // 96/24 = 4 MHz, mezza fase
wire ce_z80_p = ce_z80_p_raw & ~pause;
wire ce_z80_n = ce_z80_n_raw & ~pause;
wire ce_ym    = (ym_div == 4'd0) & ~pause;     // 96/12 = 8 MHz (jt10)
wire ce_12m   = (ce12_div == 3'd0) & ~pause;   // 96/8 = 12 MHz (TC0140SYT)

always @(posedge clk) begin
	if (reset) begin
		ce_z80_cnt <= 0;
		ym_div     <= 0;
		ce12_div   <= 0;
	end else begin
		ce_z80_cnt <= ce_z80_p_raw ? 7'd0 : ce_z80_cnt + 7'd1;
		ym_div     <= (ym_div   == 4'd11) ? 4'd0 : ym_div   + 4'd1;
		ce12_div   <= (ce12_div == 3'd7)  ? 3'd0 : ce12_div + 3'd1;
	end
end

// =====================================================================
// Z80 (T80s)
// =====================================================================
wire [15:0] z80_addr;
wire  [7:0] z80_dout;
reg   [7:0] z80_din;
wire z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
wire z80_int_n;
wire z80_wait_n_rom;

wire z80_rfsh_n;
wire syt_nmi_n;
T80pa u_z80 (
	.RESET_n (~reset),
	.CLK     (clk),
	.CEN_p   (ce_z80_p),
	.CEN_n   (ce_z80_n),
	.WAIT_n  (z80_wait_n_rom),
	.INT_n   (z80_int_n),
	.NMI_n   (syt_nmi_n),
	.BUSRQ_n (1'b1),
	.M1_n    (z80_m1_n),
	.MREQ_n  (z80_mreq_n),
	.IORQ_n  (z80_iorq_n),
	.RD_n    (z80_rd_n),
	.WR_n    (z80_wr_n),
	.RFSH_n  (z80_rfsh_n),
	.HALT_n  (),
	.BUSAK_n (),
	.A       (z80_addr),
	.DI      (z80_din),
	.DO      (z80_dout)
);

// =====================================================================
// Sound RAM 8 KB (0xC000-0xDFFF MAME)
// =====================================================================
wire sram_sel = (z80_addr[15:13] == 3'b110);
wire sram_we  = sram_sel & ~z80_mreq_n & ~z80_wr_n & z80_rfsh_n;
reg [7:0] sound_ram [0:8191];
reg [7:0] sram_q;
always @(posedge clk) begin
	if (sram_we) sound_ram[z80_addr[12:0]] <= z80_dout;
	sram_q <= sound_ram[z80_addr[12:0]];
end

// =====================================================================
// ROM bank register (0xF200, 3 bit, 8 banchi)
// =====================================================================
reg [2:0] rom_bank;
// MAME ninjaw_state::sound_bankswitch_w mappa 0xF200 (memory write, non I/O).
// Quindi bank_we usa mreq_n + wr_n + filtro rfsh_n (no false trigger su refresh).
wire bank_we = (z80_addr == 16'hF200) & ~z80_mreq_n & ~z80_wr_n & z80_rfsh_n;
always @(posedge clk) begin
	if (reset) rom_bank <= 3'd0;
	else if (bank_we) rom_bank <= z80_dout[2:0];
end

// =====================================================================
// Z80 ROM addr (0x0000-0x7FFF banked)
// =====================================================================
//   0x0000-0x3FFF → fisso (banco 0)
//   0x4000-0x7FFF → banked, addr_rom[16:14] = rom_bank
wire [16:0] rom_logical_addr =
	(z80_addr[15:14] == 2'b00) ? {3'd0, z80_addr[13:0]} :
	(z80_addr[15:14] == 2'b01) ? {rom_bank, z80_addr[13:0]} :
	17'd0;
wire rom_sel = (z80_addr[15] == 1'b0);

// Z80 ROM toggle req/ack (clock crossing tramite synch interno a darius2_ddram)
reg z80_rd_req;
wire z80_rd_ack;
wire [7:0] z80_rom_dout;
reg [16:0] z80_rom_addr_lat;

// Edge detect rising su z80_rom_rd_pulse: 1 toggle per accesso Z80 ROM.
// Il pulse dura ~24 cicli a 96 MHz (Z80 a 4 MHz), quindi prev cattura
// stabilmente il valore precedente e il rising edge e' netto.
reg z80_rom_rd_prev;
wire z80_rom_rd_pulse = rom_sel & ~z80_mreq_n & ~z80_rd_n & z80_rfsh_n;
always @(posedge clk) begin
	if (reset) begin
		z80_rd_req       <= 1'b0;
		z80_rom_rd_prev  <= 1'b0;
		z80_rom_addr_lat <= 17'd0;
	end else begin
		z80_rom_rd_prev <= z80_rom_rd_pulse;
		if (z80_rom_rd_pulse && !z80_rom_rd_prev) begin
			z80_rom_addr_lat <= rom_logical_addr;
			z80_rd_req       <= ~z80_rd_req;
		end
	end
end

// Pattern NeoGeo: wait_n = (req == ack), incondizionato.
// Quando Z80 idle req=ack → wait_n=1. Quando emette rd: edge → req toggla →
// stesso ciclo req!=ack → wait_n=0 → Z80 stalla. Ack arriva da DDRAM → wait_n=1.
assign z80_wait_n_rom = (z80_rd_req == z80_rd_ack);

// =====================================================================
// YM2610 (jt10)
// =====================================================================
wire ym_sel = (z80_addr[15:8] == 8'hE0);
wire [7:0] ym_dout_w;
wire       ym_irq_n;
wire [19:0] adpcma_addr_jt;
wire [3:0]  adpcma_bank_jt;
wire        adpcma_roe_n_jt;
wire [7:0]  adpcma_data_w;
wire [23:0] adpcmb_addr_jt;
wire        adpcmb_roe_n_jt;
wire [7:0]  adpcmb_data_w;

wire signed [15:0] jt10_left, jt10_right;
wire        [9:0]  jt10_psg;
wire signed [15:0] jt10_adpcmA_l, jt10_adpcmA_r;
wire signed [15:0] jt10_adpcmB_l, jt10_adpcmB_r;
wire signed [15:0] jt10_fm_l, jt10_fm_r;  // FM + ADPCM (no PSG) — pre-mix saturazione

// Bus jt10 diretto (no latch — jt12_mmr ha gia' la sua sincronizzazione interna).

jt10 u_jt10 (
	.rst(reset),
	.clk(clk),
	.cen(ce_ym),
	.din(z80_dout),
	.addr(z80_addr[1:0]),
	.cs_n(~ym_sel | z80_mreq_n | ~z80_rfsh_n),
	.wr_n(z80_wr_n),
	.dout(ym_dout_w),
	.irq_n(ym_irq_n),
	.adpcma_addr(adpcma_addr_jt),
	.adpcma_bank(adpcma_bank_jt),
	.adpcma_roe_n(adpcma_roe_n_jt),
	.adpcma_data(adpcma_data_w),
	.adpcmb_addr(adpcmb_addr_jt),
	.adpcmb_roe_n(adpcmb_roe_n_jt),
	.adpcmb_data(adpcmb_data_w),
	.psg_A(), .psg_B(), .psg_C(),
	.fm_snd(),
	.psg_snd(jt10_psg),
	.snd_left(jt10_left),
	.snd_right(jt10_right),
	.snd_sample(),
	.ch_enable(6'b111111),
	// Tap separati per TC0060DCA (pan/gain externo Taito ninjaw)
	.adpcmA_l_o(jt10_adpcmA_l),
	.adpcmA_r_o(jt10_adpcmA_r),
	.adpcmB_l_o(jt10_adpcmB_l),
	.adpcmB_r_o(jt10_adpcmB_r),
	// FM+ADPCM senza PSG: per saturare la somma FM+PSG correttamente esternamente.
	.fm_snd_left_o(jt10_fm_l),
	.fm_snd_right_o(jt10_fm_r)
);

// =====================================================================
// TC0060DCA Volume Control (chip Taito presente sul board ninjaw, mancante in
// jotego). 4 register 8-bit gain (lineare 0-255 = 0-100%) scritti dallo Z80 a
// $E400-$E403. Routing MAME ninjaw.cpp:633-652:
//   pan_data[0] = FM L gain     ($E401 dopo XOR^1)
//   pan_data[1] = FM R gain     ($E400 dopo XOR^1)
//   pan_data[2] = ADPCM L gain  ($E403 dopo XOR^1)
//   pan_data[3] = ADPCM R gain  ($E402 dopo XOR^1)
// (offset ^= 1 prima del decode, vedi MAME pancontrol_w)
// =====================================================================
reg [7:0] pan_data [0:3];
integer pi;
initial for (pi = 0; pi < 4; pi = pi + 1) pan_data[pi] = 8'hFF;  // default full gain
wire pan_sel = (z80_addr[15:2] == 14'h3900);  // 0xE400-0xE403 → addr[15:2]=0xE400>>2=0x3900
wire pan_we  = pan_sel & ~z80_mreq_n & ~z80_wr_n & z80_rfsh_n;
wire [1:0] pan_offset = z80_addr[1:0] ^ 2'b01;  // MAME: offset ^= 1

always @(posedge clk) begin
	if (reset) begin
		pan_data[0] <= 8'hFF;
		pan_data[1] <= 8'hFF;
		pan_data[2] <= 8'hFF;
		pan_data[3] <= 8'hFF;
	end else if (pan_we) begin
		pan_data[pan_offset] <= z80_dout;
	end
end

// Mixer TC0060DCA:
//   audio_l = (FM_only_l * pan_data[0] + ADPCM_l * pan_data[2]) / 256 + PSG_l
//   audio_r = (FM_only_r * pan_data[1] + ADPCM_r * pan_data[3]) / 256 + PSG_r
//
// FM_only = jt10.snd - ADPCM-A - ADPCM-B - PSG (estraggo FM puro da snd_left
// che ha tutto mixato). PSG resta non panneggiato (in MAME va al subwoofer
// mono, qui lo sommo a entrambi i canali).
//
// jt10_adpcm{A,B}_{l,r} sono signed 16-bit, jt10_left/right anche.
// jt10_psg e' 10-bit unsigned: in jt12_top:483 viene sommato a fm_snd come
// {1'b0, psg, 5'd0} = unsigned 16-bit (max 0x7FE0).
// Per estrarre fm_only sottraggo lo stesso valore unsigned interpretato come signed.
wire signed [15:0] psg_added = $signed({1'b0, jt10_psg, 5'd0});

// =====================================================================
// LUT volume OSD: 3-bit sel → fattore 5-bit in unita' di 1/8.
//   0 → 8/8 = 100% (default)
//   1 → 1/8 = 12.5%
//   2 → 2/8 = 25%
//   3 → 4/8 = 50%
//   4 → 6/8 = 75%
//   5 → 12/8 = 150%
//   6 → 16/8 = 200%
//   7 → 0    = mute
// =====================================================================
function [4:0] vol_lut;
	input [2:0] sel;
	case (sel)
		3'd0: vol_lut = 5'd8;
		3'd1: vol_lut = 5'd1;
		3'd2: vol_lut = 5'd2;
		3'd3: vol_lut = 5'd4;
		3'd4: vol_lut = 5'd6;
		3'd5: vol_lut = 5'd12;
		3'd6: vol_lut = 5'd16;
		3'd7: vol_lut = 5'd0;
		default: vol_lut = 5'd8;
	endcase
endfunction

wire [4:0] vol_fm     = vol_lut(osd_fm_vol);
wire [4:0] vol_adpcma = vol_lut(osd_adpcma_vol);
wire [4:0] vol_adpcmb = vol_lut(osd_adpcmb_vol);
// PSG: solo 2 valori OSD (Polite=12% default, MAME=100%). osd_psg_vol[0] e' il bit OSD.
wire [4:0] vol_psg    = osd_psg_vol[0] ? 5'd8 : 5'd1;  // 0=Polite (1/8), 1=MAME (8/8)

// =====================================================================
// MIXER NUOVO — interpretazione MAME-fedele basata su audit ymfm + ninjaw.cpp
// =====================================================================
//
// YM2610 ha 3 output:
//   output 0 = SSG/PSG mono
//   output 1 = FM+ADPCM L (pan interno YM gia' applicato)
//   output 2 = FM+ADPCM R
//
// MAME ninjaw routing (ninjaw.cpp:992-1003):
//   add_route(0, "subwoofer", 0.75)  → PSG mono * 0.75
//   add_route(1, "2610.1.l", 1.0)    → FM_L → flt[0] (m_2610_l[0])
//   add_route(1, "2610.1.r", 1.0)    → FM_L → flt[1] (m_2610_r[0])  ← stesso input!
//   add_route(2, "2610.2.l", 1.0)    → FM_R → flt[2] (m_2610_l[1])
//   add_route(2, "2610.2.r", 1.0)    → FM_R → flt[3] (m_2610_r[1])
//
// pancontrol_w (ninjaw.cpp:633-652) decode con offset XOR^1:
//   $E400 → flt[1] (FM_L verso speaker R) = pan_data[1] mio
//   $E401 → flt[0] (FM_L verso speaker L) = pan_data[0] mio
//   $E402 → flt[3] (FM_R verso speaker R) = pan_data[3] mio
//   $E403 → flt[2] (FM_R verso speaker L) = pan_data[2] mio
//
// TC0060DCA = 2 chip × 2 vie = cross-fader stereo per cabinet multi-monitor:
//   audio_l = FM_L * pan_data[0] + FM_R * pan_data[2]
//   audio_r = FM_L * pan_data[1] + FM_R * pan_data[3]
//
// PSG va al subwoofer mono (in MAME) — qui sommato a entrambi audio_l/r.
//
// Bypass di snd_left/right del jt12_top (= fm + psg<<5 con WRAP signed 16-bit)
// per evitare cracking PSG su esplosioni: uso jt10_fm_l/r (no PSG) e sommo PSG
// esternamente con saturazione corretta.
// =====================================================================

// Estendi jt10_fm_l/r a 18-bit signed (per moltiplicazione successiva)
wire signed [17:0] fm_l_in = $signed({{2{jt10_fm_l[15]}}, jt10_fm_l});
wire signed [17:0] fm_r_in = $signed({{2{jt10_fm_r[15]}}, jt10_fm_r});

// Cross-fader TC0060DCA: 4 moltiplicazioni signed_18 * unsigned_8 = signed_26
wire signed [25:0] fm_l_to_l = fm_l_in * $signed({1'b0, pan_data[0]});
wire signed [25:0] fm_l_to_r = fm_l_in * $signed({1'b0, pan_data[1]});
wire signed [25:0] fm_r_to_l = fm_r_in * $signed({1'b0, pan_data[2]});
wire signed [25:0] fm_r_to_r = fm_r_in * $signed({1'b0, pan_data[3]});

// >>8 per dividere per 256 (approx /255). Estraggo signed_18.
wire signed [17:0] fm_l_to_l_g = fm_l_to_l[25:8];
wire signed [17:0] fm_l_to_r_g = fm_l_to_r[25:8];
wire signed [17:0] fm_r_to_l_g = fm_r_to_l[25:8];
wire signed [17:0] fm_r_to_r_g = fm_r_to_r[25:8];

// =====================================================================
// OSD VOLUME (slider FM/PSG; ADPCM-A/B non separabili senza modifiche jt12).
// Mantengo slider FM e PSG. ADPCM A/B = sentito assieme dentro fm_l/r,
// non separabili dal mixer cross-fader. vol_adpcma/b ignorati in questo round.
// =====================================================================
// FM × vol_fm (signed_18 * unsigned_5 = signed_24)
wire signed [23:0] fm_l_l_vol = fm_l_to_l_g * $signed({1'b0, vol_fm});
wire signed [23:0] fm_l_r_vol = fm_l_to_r_g * $signed({1'b0, vol_fm});
wire signed [23:0] fm_r_l_vol = fm_r_to_l_g * $signed({1'b0, vol_fm});
wire signed [23:0] fm_r_r_vol = fm_r_to_r_g * $signed({1'b0, vol_fm});
// PSG × vol_psg (signed_16 * unsigned_5 = signed_21)
wire signed [20:0] psg_vol_v  = psg_added * $signed({1'b0, vol_psg});

// Saturate to signed 16-bit
function signed [15:0] sat16;
	input signed [21:0] v;
	if (v > $signed(22'sd32767))       sat16 = 16'sd32767;
	else if (v < $signed(-22'sd32768)) sat16 = -16'sd32768;
	else                                sat16 = v[15:0];
endfunction

// Somma finale: 2 vie FM (post pan + vol) + PSG mono (post vol).
// Tutto ridotto >> 3 per /8 (compensa max vol = ×2). signed_22.
wire signed [21:0] sum_l = $signed({{2{fm_l_l_vol[23]}}, fm_l_l_vol[23:3]})
                         + $signed({{2{fm_r_l_vol[23]}}, fm_r_l_vol[23:3]})
                         + $signed({{4{psg_vol_v[20]}},  psg_vol_v[20:3]});
wire signed [21:0] sum_r = $signed({{2{fm_l_r_vol[23]}}, fm_l_r_vol[23:3]})
                         + $signed({{2{fm_r_r_vol[23]}}, fm_r_r_vol[23:3]})
                         + $signed({{4{psg_vol_v[20]}},  psg_vol_v[20:3]});

assign audio_l = sat16(sum_l);
assign audio_r = sat16(sum_r);

// vol_adpcma e vol_adpcmb riservati per future estensioni (TC0060DCA non separa A/B).

// =====================================================================
// ADPCM A: trigger req su cambio addr (prefetch ahead di oe).
// Pattern NeoGeo: addr cambia → req toggla → dato pronto per quando oe=1.
// =====================================================================
reg  adpcma_rd_req;
wire adpcma_rd_ack;
wire [7:0] adpcma_dout_ddr;
reg [27:0] adpcma_addr_lat;
reg [23:0] adpcma_full_prev;
wire [23:0] adpcma_full = {adpcma_bank_jt, adpcma_addr_jt};
always @(posedge clk) begin
	if (reset) begin
		adpcma_rd_req    <= 1'b0;
		adpcma_addr_lat  <= 28'd0;
		adpcma_full_prev <= 24'd0;
	end else begin
		adpcma_full_prev <= adpcma_full;
		if (adpcma_full != adpcma_full_prev) begin
			adpcma_addr_lat <= DDR_ADPCMA_OFF + {4'd0, adpcma_full};
			adpcma_rd_req   <= ~adpcma_rd_req;
		end
	end
end
assign adpcma_data_w = adpcma_dout_ddr;

// =====================================================================
// ADPCM B: stesso pattern
// =====================================================================
reg  adpcmb_rd_req;
wire adpcmb_rd_ack;
wire [7:0] adpcmb_dout_ddr;
reg [27:0] adpcmb_addr_lat;
reg [23:0] adpcmb_full_prev;
always @(posedge clk) begin
	if (reset) begin
		adpcmb_rd_req    <= 1'b0;
		adpcmb_addr_lat  <= 28'd0;
		adpcmb_full_prev <= 24'd0;
	end else begin
		adpcmb_full_prev <= adpcmb_addr_jt;
		if (adpcmb_addr_jt != adpcmb_full_prev) begin
			adpcmb_addr_lat <= DDR_ADPCMB_OFF + {4'd0, adpcmb_addr_jt};
			adpcmb_rd_req   <= ~adpcmb_rd_req;
		end
	end
end
assign adpcmb_data_w = adpcmb_dout_ddr;

// =====================================================================
// TC0140SYT (sound comm)
// =====================================================================
wire syt_sel = (z80_addr[15:8] == 8'hE2) & ~z80_mreq_n;
wire [3:0] syt_z80_dout;

// TC0140SYT vuole anche ADPCM bus master (sdr_*), ma noi gestiamo ADPCM via
// ddram diretto. Lasciamo sdr_* tied a vuoto (TC0140SYT versione "passthrough").
wire [26:0] sdr_address_unused;
wire [15:0] sdr_data_unused = 16'd0;
wire        sdr_req_unused;
wire        sdr_ack_unused = 1'b0;

TC0140SYT u_syt (
	.clk(clk),
	.ce_12m(ce_12m),
	.ce_4m(ce_z80_p),
	.RESn(~reset),
	.MDin(main_din),
	.MDout(main_dout),
	.MA1(main_a1),
	.MCSn(main_cs_n),
	.MWRn(main_wr_n),
	.MRDn(main_rd_n),
	.MREQn(z80_mreq_n),
	.RFSHn(z80_rfsh_n),
	.RDn(z80_rd_n),
	.WRn(z80_wr_n),
	.A(z80_addr),
	.Din(z80_dout[3:0]),
	.Dout(syt_z80_dout),
	.ROUTn(), .NMIn(syt_nmi_n), .ROMCS0n(), .ROMCS1n(), .RAMCSn(),
	.ROMA14(), .ROMA15(),
	.OPXn(),
	.YAOEn(adpcma_roe_n_jt),
	.YBOEn(adpcmb_roe_n_jt),
	.YAA({adpcma_bank_jt, adpcma_addr_jt}),
	.YBA(adpcmb_addr_jt),
	.YAD(),    // non usato (ADPCM A va via ddram diretto)
	.YBD(),    // non usato
	.CSAn(), .CSBn(),
	.IOA(), .IOC(),
	.sdr_address(sdr_address_unused),
	.sdr_data(sdr_data_unused),
	.sdr_req(sdr_req_unused),
	.sdr_ack(sdr_ack_unused)
);

// =====================================================================
// ioctl write DDRAM (Z80 ROM + ADPCM A + B)
// =====================================================================
wire is_rom_dl  = ioctl_download && (ioctl_index == 16'd0);
wire is_z80_dl  = is_rom_dl && (ioctl_addr >= 27'h120000) && (ioctl_addr < 27'h140000);
wire is_adpa_dl = is_rom_dl && (ioctl_addr >= 27'h440000) && (ioctl_addr < 27'h5C0000);
wire is_adpb_dl = is_rom_dl && (ioctl_addr >= 27'h5C0000) && (ioctl_addr < 27'h640000);
wire is_audio_dl = is_z80_dl | is_adpa_dl | is_adpb_dl;

wire [27:0] ddr_audio_waddr =
	is_z80_dl  ? (DDR_Z80_ROM_OFF + {1'b0, ioctl_addr - 27'h120000}) :
	is_adpa_dl ? (DDR_ADPCMA_OFF  + {1'b0, ioctl_addr - 27'h440000}) :
	is_adpb_dl ? (DDR_ADPCMB_OFF  + {1'b0, ioctl_addr - 27'h5C0000}) :
	28'd0;

// Audio side: rising edge ioctl_wr trasformato in toggle audio_we_req.
reg  audio_we_req = 1'b0;
reg  audio_we_ack_r = 1'b0;
reg  ioctl_wr_prev = 1'b0;
always @(posedge clk) begin
	ioctl_wr_prev <= ioctl_wr;
	if (ioctl_wr && !ioctl_wr_prev && is_audio_dl) audio_we_req <= ~audio_we_req;
end

// Sprite side: ack registrato per matching toggle protocol con il top.
reg  spr_we_ack_r = 1'b0;

// Mux write DDRAM: due client (audio + sprite). Una sola write a tempo.
// FSM: IDLE → grant client che ha pending → wait we_ack → ack client.
reg  we_req = 1'b0;
reg  we_pick_spr = 1'b0;
reg  [27:0] ddr_waddr;
reg  [15:0] ddr_wdata;
wire we_ack;
reg  we_active = 1'b0;

wire audio_pending = (audio_we_req != audio_we_ack_r);
wire spr_pending   = (spr_we_req   != spr_we_ack_r);

always @(posedge clk) begin
	if (!we_active) begin
		// IDLE: lancia se qualcuno ha pending
		if (audio_pending) begin
			ddr_waddr   <= ddr_audio_waddr;
			ddr_wdata   <= ioctl_dout;
			we_pick_spr <= 1'b0;
			we_req      <= ~we_req;
			we_active   <= 1'b1;
		end else if (spr_pending) begin
			ddr_waddr   <= spr_we_addr;
			ddr_wdata   <= spr_we_data;
			we_pick_spr <= 1'b1;
			we_req      <= ~we_req;
			we_active   <= 1'b1;
		end
	end else begin
		// Wait completion (we_ack si allinea a we_req)
		if (we_req == we_ack) begin
			if (we_pick_spr) spr_we_ack_r   <= ~spr_we_ack_r;
			else             audio_we_ack_r <= ~audio_we_ack_r;
			we_active <= 1'b0;
		end
	end
end

assign spr_we_ack = spr_we_ack_r;
// ioctl_wait alza durante audio download finche' write non completa
assign ioctl_wait = audio_pending;

// =====================================================================
// darius2_ddram (NeoGeo Sorgelig pattern)
//   Port write: ioctl
//   Port rd1:   Z80 ROM
//   Port rd2:   ADPCM A
//   Port rd3:   ADPCM B
//   Port cp:    non usato
// =====================================================================
darius2_ddram u_ddram (
	.DDRAM_CLK       (ddram_clk),
	.DDRAM_BUSY      (DDRAM_BUSY),
	.DDRAM_BURSTCNT  (DDRAM_BURSTCNT),
	.DDRAM_ADDR      (DDRAM_ADDR),
	.DDRAM_DOUT      (DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD        (DDRAM_RD),
	.DDRAM_DIN       (DDRAM_DIN),
	.DDRAM_BE        (DDRAM_BE),
	.DDRAM_WE        (DDRAM_WE),

	// Write port (ioctl audio + sprite muxati sopra)
	.wraddr  (ddr_waddr),
	.din     (ddr_wdata),
	.we_byte (1'b0),     // word write
	.we_req  (we_req),
	.we_ack  (we_ack),

	// Read port 1: Z80 ROM
	.rdaddr  ({11'd0, z80_rom_addr_lat}),
	.dout    (z80_rom_dout),
	.rd_req  (z80_rd_req),
	.rd_ack  (z80_rd_ack),

	// Read port 2: ADPCM A
	.rdaddr2 (adpcma_addr_lat),
	.dout2   (adpcma_dout_ddr),
	.rd_req2 (adpcma_rd_req),
	.rd_ack2 (adpcma_rd_ack),

	// Read port 3: ADPCM B
	.rdaddr3 (adpcmb_addr_lat),
	.dout3   (adpcmb_dout_ddr),
	.rd_req3 (adpcmb_rd_req),
	.rd_ack3 (adpcmb_rd_ack),

	// Read port 4: sprite ROM (32-bit fetch dal top)
	.rdaddr4 (spr_rdaddr),
	.dout4   (spr_dout),
	.rd_req4 (spr_rd_req),
	.rd_ack4 (spr_rd_ack),

	// Copy port (non usato)
	.cpaddr  (28'd0),
	.cpdout  (),
	.cpwr    (),
	.cpreq   (1'b0),
	.cpbusy  ()
);

// =====================================================================
// Z80 din mux
// =====================================================================
always @(*) begin
	z80_din = 8'hFF;
	if (rom_sel & ~z80_mreq_n & ~z80_rd_n) z80_din = z80_rom_dout;
	else if (sram_sel & ~z80_mreq_n & ~z80_rd_n) z80_din = sram_q;
	else if (ym_sel & ~z80_mreq_n & ~z80_rd_n) z80_din = ym_dout_w;
	else if (syt_sel & ~z80_rd_n) z80_din = {4'd0, syt_z80_dout};
end

assign z80_int_n = ym_irq_n;

// =====================================================================
// Debug counters: bit alto lampeggia se evento attivo (~3Hz)
// =====================================================================
reg [25:0] z80_active_cnt;
reg [25:0] ym_active_cnt;
reg [25:0] syt_main_cnt;
reg [25:0] syt_z80_cnt;
reg main_cs_n_d;
always @(posedge clk) begin
	main_cs_n_d <= main_cs_n;
	if (reset) begin
		z80_active_cnt <= 0;
		ym_active_cnt  <= 0;
		syt_main_cnt   <= 0;
		syt_z80_cnt    <= 0;
	end else begin
		if (~z80_m1_n & ~z80_mreq_n) z80_active_cnt <= z80_active_cnt + 1'd1;
		if (ym_sel & ~z80_mreq_n & ~z80_wr_n & z80_rfsh_n) ym_active_cnt <= ym_active_cnt + 1'd1;
		// Edge falling main_cs_n = main 68k apre transazione SYT
		if (main_cs_n_d & ~main_cs_n) syt_main_cnt <= syt_main_cnt + 1'd1;
		// Z80 access slave SYT (0xE200/0xE201)
		if ((z80_addr[15:8] == 8'hE2) & ~z80_mreq_n & (~z80_wr_n | ~z80_rd_n) & z80_rfsh_n)
			syt_z80_cnt <= syt_z80_cnt + 1'd1;
	end
end
assign dbg_z80_active   = z80_active_cnt[24];
assign dbg_ym_active    = ym_active_cnt[14];
assign dbg_syt_main_act = syt_main_cnt[10];
// dbg_syt_z80_act: latch sticky — alto se Z80 ha MAI scritto SYT slave dopo reset.
// Il firmware ninjaw abilita NMI con 1-2 write a 0xE200/0xE201 al boot, poi
// nessun altro tocca il SYT slave finche' non arriva NMI. Un counter su bit
// alto non lo vede. Latch sticky risolve.
reg syt_z80_seen;
always @(posedge clk) begin
	if (reset) syt_z80_seen <= 1'b0;
	else if ((z80_addr[15:8] == 8'hE2) & ~z80_mreq_n & (~z80_wr_n | ~z80_rd_n) & z80_rfsh_n)
		syt_z80_seen <= 1'b1;
end
assign dbg_syt_z80_act  = syt_z80_seen;

// Audio nonzero: tieni alto se jt10 ha emesso qualcosa di diverso da 0 negli
// ultimi ~1.4ms (a 96MHz, 17-bit decay counter ≈ 1.36ms).
reg [16:0] audio_nz_decay;
always @(posedge clk) begin
	if (reset) audio_nz_decay <= 0;
	else if (jt10_left != 16'sd0 || jt10_right != 16'sd0)
		audio_nz_decay <= 17'h1FFFF;
	else if (audio_nz_decay != 0)
		audio_nz_decay <= audio_nz_decay - 1'b1;
end
assign dbg_audio_nonzero = (audio_nz_decay != 0);

endmodule
