// Darius (Taito 1987) — MiSTer core
// Dual FX68K + Genesis SDRAM controller (3 ports)
// Based on MiSTer Template by Sorgelig

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,
	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,
	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Unused ports /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM HPS pilotato direttamente dal game (modulo darius2_ddram dentro audio_top)
assign DDRAM_CLK = clk_sys;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
// Pause: toggle on rising edge of joy[12] (standard MiSTer pause bit)
reg pause_toggle;
reg joy_pause_prev;
always @(posedge clk_sys) begin
	if (reset) begin
		pause_toggle <= 1'b0;
		joy_pause_prev <= 1'b0;
	end else begin
		joy_pause_prev <= joy0[12] | joy1[12];
		if ((joy0[12] | joy1[12]) && !joy_pause_prev)
			pause_toggle <= ~pause_toggle;
	end
end
wire pause = pause_toggle;  // solo pad (OSD pause rimosso)
assign HDMI_FREEZE = 1'b0;  // overlay pause è renderizzato in real-time, no freeze scaler
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;  // signed audio
wire signed [15:0] game_audio_l, game_audio_r;
assign AUDIO_L = game_audio_l;
assign AUDIO_R = game_audio_r;
assign AUDIO_MIX = 0;

// LED debug audio.
//   LED_USER  = Z80 boota
//   LED_DISK  = sticky: HIGH appena Z80 ha toccato SYT slave (0xE200/E201).
//               LED ON dopo boot → Z80 ha armato NMI ✅
//               LED OFF fisso  → Z80 mai parla col SYT → firmware corrotto/loop garbage
// led_disk[1]=enable, led_disk[0]=~sticky.
assign LED_DISK  = {1'b1, ~dbg_syt_z80_act};
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

// OSD layer offsets: 6-bit signed 2's complement, default 0 on reset
wire signed [9:0] osd_l0_xoff  = {{4{status[43]}}, status[43:38]};
wire signed [9:0] osd_l0_yoff  = {{4{status[49]}}, status[49:44]};
wire signed [9:0] osd_l1_xoff  = {{4{status[55]}}, status[55:50]};
wire signed [9:0] osd_l1_yoff  = {{4{status[61]}}, status[61:56]};
wire signed [9:0] osd_spr_xoff = {{4{status[67]}}, status[67:62]};
wire signed [9:0] osd_spr_yoff = {{4{status[73]}}, status[73:68]};
wire signed [9:0] osd_fg_xoff  = {{4{status[79]}}, status[79:74]};
wire signed [9:0] osd_fg_yoff  = {{4{status[85]}}, status[85:80]};

`include "build_id.v"
localparam CONF_STR = {
	"Darius2;;",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[6:5],Scale,Narrower HV-Integer,V-Integer,HV-Integer;",
	"-;",
	"O[19],Clean Pause,Off,On;",
	"-;",
	"O[30],Layer BG0,On,Off;",
	"O[31],Layer BG1,On,Off;",
	"O[32],Sprite,On,Off;",
	"O[33],Layer FG0,On,Off;",
	"-;",
	// Layer Offsets — disabilitati (offset OK hardcoded). Riabilitare se servono di nuovo.
	// "P2,Layer Offsets;",
	// "P2O[43:38],BG0 X offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P2O[49:44],BG0 Y offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P2O[55:50],BG1 X offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P2O[61:56],BG1 Y offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P2O[67:62],Sprite X offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P2O[73:68],Sprite Y offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P2O[79:74],FG X offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P2O[85:80],FG Y offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "-;",
	"P3,Audio Mixer;",
	"P3O[88:86],FM volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
	"P3O[91:89],ADPCM-A volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
	"P3O[94:92],ADPCM-B volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
	"P3O[95],PSG volume,Polite,MAME;",
	"-;",
	"DIP;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	"J1,Fire,Bomb,Start 1P,Start 2P,Coin;",
	"jn,A,B,Start,Select,R;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [15:0] joy0, joy1;
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;   // 16-bit: WIDE=1
wire        ioctl_wait_sdram;
wire        ioctl_wait_audio;
wire        ioctl_wait = ioctl_wait_sdram | ioctl_wait_audio;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.ps2_key(ps2_key),
	.joystick_0(joy0),
	.joystick_1(joy1),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

// --- Joystick to Darius 2 / Ninja Warriors input mapping ---
// MAME ninjaw.cpp IN0 (= p1_input, TC0040IOC port $02):
//   bit 0: UNKNOWN ACTIVE_HIGH  ("Stops working if this is high") — MUST be 0
//   bit 1: UNKNOWN ACTIVE_LOW   — idle=1
//   bit 2: COIN1    ACTIVE_HIGH — idle=0
//   bit 3: COIN2    ACTIVE_HIGH — idle=0
//   bit 4: FREEZE   ACTIVE_HIGH — idle=0 (keyboard F1 in MAME)
//   bits 5..7: UNKNOWN ACTIVE_LOW — idle=1
// Idle = $E2 (0b1110_0010).
// MiSTer joy[11] = Coin, joy[10] = Start. Map COIN to bit 2 of IN0.
wire [7:0] p1_input = {3'b111, 1'b0, 1'b0, joy0[11], 1'b1, 1'b0};
//                     [7:5]=1  [4]=freeze 0 [3]=coin2 0 [2]=coin1 [1]=1 [0]=0

// MAME ninjaw.cpp IN2 (= system_input, TC0040IOC port $07):
//   bit 0: SERVICE1 ACTIVE_LOW  — idle=1
//   bit 1: TILT     ACTIVE_LOW  — idle=1
//   bit 2: START1   ACTIVE_LOW  — idle=1 (pressed=0)
//   bit 3: START2   ACTIVE_LOW  — idle=1
//   bit 4: P1 BTN1  ACTIVE_LOW
//   bit 5: P1 BTN2  ACTIVE_LOW
//   bit 6: P2 BTN1  ACTIVE_LOW
//   bit 7: P2 BTN2  ACTIVE_LOW
// p2_input = IN1 (TAITO_JOY_DUAL_UDRL — directional both players, active LOW).
// Layout MAME: [3:0] P1 U D R L, [7:4] P2 U D R L (Right prima di Left).
// MiSTer joy: [0]=R [1]=L [2]=D [3]=U.
wire [7:0] p2_input = {~joy1[1], ~joy1[0], ~joy1[2], ~joy1[3],
                        ~joy0[1], ~joy0[0], ~joy0[2], ~joy0[3]};


// MAME ninjaw IN2 (= system_input, TC0040IOC port $07):
//   bit 0: SERVICE1 ACTIVE_LOW  — idle=1
//   bit 1: TILT     ACTIVE_LOW  — idle=1
//   bit 2: START1   ACTIVE_LOW  — idle=1 (pressed=0)
//   bit 3: START2   ACTIVE_LOW  — idle=1
//   bit 4: P1 BTN1  ACTIVE_LOW  — idle=1 (pressed=0)
//   bit 5: P1 BTN2  ACTIVE_LOW
//   bit 6: P2 BTN1  ACTIVE_LOW
//   bit 7: P2 BTN2  ACTIVE_LOW
// Idle = $FF.
wire [7:0] system_input = {~joy1[5], ~joy1[4], ~joy0[5], ~joy0[4],
                           ~joy1[10], ~joy0[10], 1'b1, 1'b1};

// DIP switches — loaded from MRA via ioctl (index 254)
// Active-LOW: default "FF,FF" = all OFF = all 1s
reg [15:0] dip_sw = 16'hFFFF;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[26:1])
		dip_sw <= ioctl_dout;

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

// Game reset: includes download (game held in reset while ROM loads)
// + hold counter: tiene reset alto per ~2^17 cicli (~1.4ms a 96MHz) dopo che
// la causa cade, per dare tempo a SDRAM/clear FSM/PLL di stabilizzarsi.
wire reset_cause = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;
reg [16:0] reset_hold_cnt = 17'h1FFFF;  // parte carico al power-on
always @(posedge clk_sys) begin
	if (reset_cause) reset_hold_cnt <= 17'h1FFFF;  // ricarica finche' c'e' causa
	else if (reset_hold_cnt != 17'd0) reset_hold_cnt <= reset_hold_cnt - 17'd1;
end
wire reset = (reset_hold_cnt != 17'd0);
// Bridge reset: ONLY pll_locked — bridge must run during download, before RESET drops
wire bridge_reset = ~pll_locked;
// Video reset: ONLY pll_locked — CRT needs sync always, even during RESET and download
wire video_reset = ~pll_locked;

///////////////////////   SDRAM   ///////////////////////////////

// Genesis 4-port SDRAM controller (Sorgelig + port 3 for audio)
// Port 0: Tile ROM + download
// Port 1: Main CPU ROM
// Port 2: Sub CPU ROM
// Port 3: Audio Z80 ROM

wire [24:1] sd_addr0, sd_addr1, sd_addr2, sd_addr3;
wire [15:0] sd_din0, sd_din1, sd_din2, sd_din3;
wire        sd_wrl0, sd_wrh0, sd_wrl1, sd_wrh1, sd_wrl2, sd_wrh2, sd_wrl3, sd_wrh3;
wire        sd_req0, sd_req1, sd_req2, sd_req3;
wire        sd_ack0, sd_ack1, sd_ack2, sd_ack3;
wire [15:0] sd_dout0, sd_dout1, sd_dout2, sd_dout3;
wire        sdram_ready;

sdram sdram_ctrl
(
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_CKE(SDRAM_CKE),

	.init(~pll_locked),
	.clk(clk_sys),
	.prio_mode(status[35:34]),
	.ready(sdram_ready),

	.addr0(sd_addr0), .wrl0(sd_wrl0), .wrh0(sd_wrh0),
	.din0(sd_din0), .dout0(sd_dout0), .req0(sd_req0), .ack0(sd_ack0),

	.addr1(sd_addr1), .wrl1(sd_wrl1), .wrh1(sd_wrh1),
	.din1(sd_din1), .dout1(sd_dout1), .req1(sd_req1), .ack1(sd_ack1),

	.addr2(sd_addr2), .wrl2(sd_wrl2), .wrh2(sd_wrh2),
	.din2(sd_din2), .dout2(sd_dout2), .req2(sd_req2), .ack2(sd_ack2),

	.addr3(sd_addr3), .wrl3(sd_wrl3), .wrh3(sd_wrh3),
	.din3(sd_din3), .dout3(sd_dout3), .req3(sd_req3), .ack3(sd_ack3)
);

///////////////////////   BRIDGE   ///////////////////////////////

// Bridge between darius game logic (level protocol) and Genesis SDRAM (toggle protocol)
wire [23:0] game_tile_addr, game_main_addr, game_sub_addr;
wire        game_tile_req, game_main_req, game_sub_req;
wire        game_tile_is_sprite;
wire        game_tile_is_text;
wire [31:0] game_tile_data;
// SDRAM port 3 sprite scollegata: tie-off del bridge port 3
wire [23:0] game_spr_addr  = 24'd0;
wire        game_spr_req   = 1'b0;
wire [31:0] game_spr_data;        // unused (uscita bridge)
wire        game_spr_valid;       // unused (uscita bridge)

wire        game_tile_valid;
wire [15:0] game_main_data, game_sub_data;
// Audio Z80 ROM removed from SDRAM — will use BRAM when audio implemented
wire        game_main_ready, game_sub_ready;

// ROM instruction cache — between game and SDRAM bridge
wire [23:0] bridge_main_addr, bridge_sub_addr;
wire        bridge_main_req, bridge_sub_req;
wire [15:0] bridge_main_data, bridge_sub_data;
wire        bridge_main_ready, bridge_sub_ready;
wire [1:0]  dbg_cache_state;

rom_cache #(.CACHE_BITS(8)) u_main_cache (
	.clk(clk_sys), .reset(reset),
	.cpu_addr(game_main_addr), .cpu_req(game_main_req),
	.cpu_data(game_main_data), .cpu_ready(game_main_ready),
	.sdram_addr(bridge_main_addr), .sdram_req(bridge_main_req),
	.sdram_data(bridge_main_data), .sdram_ready(bridge_main_ready),
	.dbg_state(dbg_cache_state)
);

rom_cache #(.CACHE_BITS(8)) u_sub_cache (
	.clk(clk_sys), .reset(reset),
	.cpu_addr(game_sub_addr), .cpu_req(game_sub_req),
	.cpu_data(game_sub_data), .cpu_ready(game_sub_ready),
	.sdram_addr(bridge_sub_addr), .sdram_req(bridge_sub_req),
	.sdram_data(bridge_sub_data), .sdram_ready(bridge_sub_ready),
	.dbg_state()
);

sdram_bridge bridge
(
	.clk(clk_sys),
	.reset(bridge_reset),
	.sdram_ready(sdram_ready),

	// HPS download
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait_sdram),

	// Game: Tile ROM (32-bit)
	.tile_byte_addr(game_tile_addr),
	.tile_req(game_tile_req),
	.tile_is_sprite(game_tile_is_sprite),
	.tile_is_text(game_tile_is_text),
	.tile_data(game_tile_data),
	.tile_valid(game_tile_valid),

	// Sprite ROM dedicato (port 3)
	.spr_byte_addr(game_spr_addr),
	.spr_req(game_spr_req),
	.spr_data(game_spr_data),
	.spr_valid(game_spr_valid),


	// Game: Main CPU ROM (16-bit)
	.main_byte_addr(bridge_main_addr),
	.main_req(bridge_main_req),
	.main_data(bridge_main_data),
	.main_ready(bridge_main_ready),

	// Game: Sub CPU ROM (16-bit)
	.sub_byte_addr(bridge_sub_addr),
	.sub_req(bridge_sub_req),
	.sub_data(bridge_sub_data),
	.sub_ready(bridge_sub_ready),

	// SDRAM ports
	.sdram_addr0(sd_addr0), .sdram_din0(sd_din0),
	.sdram_wrl0(sd_wrl0), .sdram_wrh0(sd_wrh0),
	.sdram_req0(sd_req0), .sdram_ack0(sd_ack0), .sdram_dout0(sd_dout0),

	.sdram_addr1(sd_addr1), .sdram_din1(sd_din1),
	.sdram_wrl1(sd_wrl1), .sdram_wrh1(sd_wrh1),
	.sdram_req1(sd_req1), .sdram_ack1(sd_ack1), .sdram_dout1(sd_dout1),

	.sdram_addr2(sd_addr2), .sdram_din2(sd_din2),
	.sdram_wrl2(sd_wrl2), .sdram_wrh2(sd_wrh2),
	.sdram_req2(sd_req2), .sdram_ack2(sd_ack2), .sdram_dout2(sd_dout2),

	.sdram_addr3(sd_addr3), .sdram_din3(sd_din3),
	.sdram_wrl3(sd_wrl3), .sdram_wrh3(sd_wrh3),
	.sdram_req3(sd_req3), .sdram_ack3(sd_ack3), .sdram_dout3(sd_dout3),
	.dbg_main_pending(dbg_main_pending),
	.dbg_download_active(dbg_download_active),
	.dbg_peek_val(dbg_peek_val),
	.dbg_peek_match(dbg_peek_match)
);
wire [15:0] dbg_peek_val;
wire        dbg_peek_match;

///////////////////////   GAME   ///////////////////////////////

wire ce_pix;  // 24 MHz pixel clock enable (generated by compositor, used by game)
wire [9:0]  render_x;
wire [8:0]  render_y;
wire [23:0] tile_rgb;
wire [1:0]  tile_prio;
wire        tile_opaque;
wire [23:0] game_sprite_rgb;
wire [1:0]  game_sprite_prio;
wire        game_sprite_opaque;
wire [23:0] game_fg_rgb;
wire        game_fg_opaque;
wire [15:0] map_xscroll_l0, map_xscroll_l1;
wire [15:0] map_yscroll_l0, map_yscroll_l1;

darius2_dual68k_top game
(
	.clk(clk_sys),
	.reset(reset),
	.pause(pause),
	// Hardcoded 12 MHz (Darius 2 original MAME rate). OSD overclock rimosso.
	// clk_sel code (top case): 0=12MHz
	.clk_sel(3'd0),
	.sub_clk_sel(3'd0),
	.z80_clk_sel(status[37:36]), // OSD: Z80 audio speed
	.p1_input(p1_input),
	.p2_input(p2_input),
	.system_input(system_input),
	.dsw_input(dip_sw),

	// SDRAM ROM (via bridge)
	.main_rom_rdata(game_main_data),
	.main_rom_ready(game_main_ready),
	.sub_rom_rdata(game_sub_data),
	.sub_rom_ready(game_sub_ready),
	.tilerom_data(game_tile_data),
	.tilerom_valid(game_tile_valid),

	// OSD layer disables: 1=hide layer
	.dbg_dis_bg0(status[30]),
	.dbg_dis_bg1(status[31]),
	// scn_rate_sel rimosso (Donlon-legacy): SCN ora usa ce_13m fisso
	.dbg_dis_fg0(status[33]),

	.main_rom_addr(game_main_addr),
	.main_rom_req(game_main_req),
	.sub_rom_addr(game_sub_addr),
	.sub_rom_req(game_sub_req),
	.tilerom_addr(game_tile_addr),
	.tilerom_req(game_tile_req),
	.tilerom_is_sprite(game_tile_is_sprite),
	.tilerom_is_text(game_tile_is_text),
	// (sprite ROM ora su DDR3 port 4 internamente al game, no port qui)

	// Audio ROM download (ioctl → BRAM)
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),

	// Video
	.render_x(render_x),
	.render_y(render_y),
	.hblank_in(HBlank),
	.tile_rgb(tile_rgb),
	.tile_prio(tile_prio),
	.tile_opaque(tile_opaque),
	.sprite_rgb(game_sprite_rgb),
	.sprite_prio(game_sprite_prio),
	.sprite_opaque(game_sprite_opaque),
	.fg_rgb(game_fg_rgb),
	.fg_opaque(game_fg_opaque),

	// Scroll/debug
	.xscroll_l0(map_xscroll_l0),
	.xscroll_l1(map_xscroll_l1),
	.yscroll_l0(map_yscroll_l0),
	.yscroll_l1(map_yscroll_l1),
	.ctrl_l0(),
	.ctrl_l1(),
	// OSD layer offsets
	.l0_xoff(osd_l0_xoff), .l0_yoff(osd_l0_yoff),
	.l1_xoff(osd_l1_xoff), .l1_yoff(osd_l1_yoff),
	.spr_xoff(osd_spr_xoff), .spr_yoff(osd_spr_yoff),
	.fg_xoff(osd_fg_xoff), .fg_yoff(osd_fg_yoff),
	// OSD layer enable (O[30]=BG0, O[31]=BG1, O[33]=FG0). Status bit "Off" = 1 → invertito.
	.osd_tile_layer_en({~status[33], ~status[31], ~status[30]}),
	// Text ROM download → FG BRAM
	.fg_dl_wr(ioctl_download && ioctl_wr && ioctl_index == 16'd0 &&
	           ioctl_addr >= 27'h1C0000 && ioctl_addr < 27'h1C8000),
	.fg_dl_addr(ioctl_addr[14:1]),
	.fg_dl_data(ioctl_dout),
	// Compositor pixel clock (24 MHz)
	.ce_pix(ce_pix),
	// Audio
	.audio_l(game_audio_l),
	.audio_r(game_audio_r),
	// Audio mixer OSD volumes (3-bit each, vedi CONF_STR P3 audio mixer)
	.osd_fm_vol    (status[88:86]),
	.osd_adpcma_vol(status[91:89]),
	.osd_adpcmb_vol(status[94:92]),
	.osd_psg_vol   ({2'd0, status[95]}),  // 1-bit OSD: 0=Polite (default), 1=MAME (100%)
	// DDRAM HPS pin (gestiti internamente da darius2_ddram dentro audio_top)
	.DDRAM_CLK(clk_sys),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),
	.ioctl_wait_audio(ioctl_wait_audio),
	// Debug overlay
	.dbg_main_pc(dbg_main_pc),
	.dbg_bus_addr(dbg_bus_addr),
	.dbg_txn_state(dbg_txn_state),
	.dbg_bus_busy(dbg_bus_busy),
	.dbg_dtack_n(dbg_dtack_n),
	.dbg_ext_dtack_n(dbg_ext_dtack_n),
	.dbg_scn0_sc(dbg_scn0_sc),
	.dbg_scn0_sc_seen(dbg_scn0_sc_seen),
	.dbg_tilerom_req_seen(dbg_tilerom_req_seen),
	.dbg_scn0_wr_cnt(dbg_scn0_wr_cnt),
	.dbg_z80_active(dbg_z80_active),
	.dbg_ym_active(dbg_ym_active),
	.dbg_syt_main_act(dbg_syt_main_act),
	.dbg_syt_z80_act(dbg_syt_z80_act),
	.dbg_audio_nonzero(dbg_audio_nonzero),
	.dbg_d6(dbg_d6),
	.dbg_d7(dbg_d7),
	.dbg_d0(dbg_d0),
	.dbg_a0(dbg_a0),
	.dbg_a1(dbg_a1),
	.dbg_ram_wr_cnt(dbg_ram_wr_cnt),
	.dbg_ram_rd_val(dbg_ram_rd_val),
	.dbg_sub_pc(dbg_sub_pc)
);

// --- Debug signals from game + bridge ---
wire [23:0] dbg_main_pc;
wire [23:0] dbg_bus_addr;
wire [3:0]  dbg_txn_state;
wire        dbg_bus_busy;
wire        dbg_dtack_n;
wire        dbg_ext_dtack_n;
wire [14:0] dbg_scn0_sc;
wire        dbg_scn0_sc_seen;
wire        dbg_tilerom_req_seen;
wire [15:0] dbg_scn0_wr_cnt;
wire dbg_z80_active, dbg_ym_active, dbg_syt_main_act, dbg_syt_z80_act, dbg_audio_nonzero;
wire [31:0] dbg_d6, dbg_d7, dbg_d0, dbg_a0, dbg_a1;
wire [15:0] dbg_ram_wr_cnt, dbg_ram_rd_val;
wire [23:0] dbg_sub_pc;
wire        dbg_main_pending;
wire        dbg_download_active;
// dbg_cache_state già dichiarato nel blocco rom_cache
// ROM word: latch first word read by main cache from SDRAM
wire        dbg_rom_word_valid = bridge_main_ready;
wire [15:0] dbg_rom_word       = bridge_main_data;

///////////////////////   VIDEO   ///////////////////////////////

// Triple screen video timing via dedicated module (864x224 Darius layout)
wire HBlank, VBlank, HSync, VSync;
wire [7:0] video_r, video_g, video_b;

triple_screen_test #(.ENABLE_DEBUG(0)) u_video (
	.clk(clk_sys),
	.reset(video_reset),
	// Sprite passa via OB → palette bypass (sprite_ob gate dentro top).
	// Path esterno sprite_rgb DISATTIVATO (pal_data=0 darebbe sprite neri).
	.layer_en({1'b1, 1'b0, 1'b1, 1'b1}),  // {FG, SPR=off path esterno, L1, L0}
	.tile_rgb(tile_rgb),
	.tile_prio(tile_prio),
	.tile_opaque(tile_opaque),
	.sprite_pix_rgb(game_sprite_rgb),
	.sprite_prio(game_sprite_prio),
	.sprite_opaque(game_sprite_opaque),
	.fg_rgb(game_fg_rgb),
	.fg_opaque(game_fg_opaque),
	// Debug overlay — DISATTIVATO (ENABLE_DEBUG=0). Tied 0 per liberare timing.
	// Per riattivare: cambia ENABLE_DEBUG a 1 e de-commenta i collegamenti sotto.
	.dbg_pc(24'd0),
	.dbg_bus_addr(24'd0),
	.dbg_txn_state(4'd0),
	.dbg_bus_busy(1'b0),
	.dbg_dtack_n(1'b1),
	.dbg_ext_dtack_n(1'b1),
	.dbg_rom_word(16'd0),
	.dbg_rom_word_valid(1'b0),
	.dbg_sdram_req1(1'b0),
	.dbg_sdram_ack1(1'b0),
	.dbg_main_pending(1'b0),
	.dbg_download_active(1'b0),
	.dbg_sdram_ready(1'b0),
	.dbg_cache_state(2'd0),
	.dbg_reset(1'b0),
	.dbg_scn0_sc(15'd0),
	.dbg_scn0_sc_seen(1'b0),
	.dbg_tilerom_req_seen(1'b0),
	.dbg_scn0_wr_cnt(16'd0),
	.dbg_peek_val(16'd0),
	.dbg_peek_match(1'b0),
	.dbg_d6(32'd0),
	.dbg_d7(32'd0),
	.dbg_d0(32'd0),
	.dbg_a0(32'd0),
	.dbg_a1(32'd0),
	.dbg_ram_wr_cnt(16'd0),
	.dbg_ram_rd_val(16'd0),
	.dbg_sub_pc(24'd0),
	.dbg_enable(1'b0),
	// Originali (per riattivare copia questi al posto dei tied 0):
	// .dbg_pc(dbg_main_pc),
	// .dbg_bus_addr(dbg_bus_addr),
	// .dbg_txn_state(dbg_txn_state),
	// .dbg_bus_busy(dbg_bus_busy),
	// .dbg_dtack_n(dbg_dtack_n),
	// .dbg_ext_dtack_n(dbg_ext_dtack_n),
	// .dbg_rom_word(dbg_rom_word),
	// .dbg_rom_word_valid(dbg_rom_word_valid),
	// .dbg_sdram_req1(sd_req1),
	// .dbg_sdram_ack1(sd_ack1),
	// .dbg_main_pending(dbg_main_pending),
	// .dbg_download_active(dbg_download_active),
	// .dbg_sdram_ready(sdram_ready),
	// .dbg_cache_state(dbg_cache_state),
	// .dbg_reset(reset),
	// .dbg_scn0_sc(dbg_scn0_sc),
	// .dbg_scn0_sc_seen(dbg_scn0_sc_seen),
	// .dbg_tilerom_req_seen(dbg_tilerom_req_seen),
	// .dbg_scn0_wr_cnt(dbg_scn0_wr_cnt),
	// .dbg_peek_val(dbg_peek_val),
	// .dbg_peek_match(dbg_peek_match),
	// .dbg_d6(dbg_d6),
	// .dbg_d7(dbg_d7),
	// .dbg_d0(dbg_d0),
	// .dbg_a0(dbg_a0),
	// .dbg_a1(dbg_a1),
	// .dbg_ram_wr_cnt(dbg_ram_wr_cnt),
	// .dbg_ram_rd_val(dbg_ram_rd_val),
	// .dbg_sub_pc(dbg_sub_pc),
	// .dbg_enable(~status[18]),
	//
	.ce_pix(ce_pix),
	.HBlank(HBlank),
	.HSync(HSync),
	.VBlank(VBlank),
	.VSync(VSync),
	.render_x(render_x),
	.render_y(render_y),
	.R(video_r),
	.G(video_g),
	.B(video_b)
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_HS    = HSync;
assign VGA_VS    = VSync;

// MAME warning overlay: "DON'T BREAK YOUR WOOFER!" per ~3s su edge status[95]
reg vsync_d;
always @(posedge clk_sys) vsync_d <= VSync;
wire vblank_tick = VSync & ~vsync_d;  // 1 colpo per frame

wire mame_warn_on;
mame_warning_overlay u_mame_warn (
	.clk             (clk_sys),
	.reset           (video_reset),
	.tick            (vblank_tick),
	.mame_psg_active (status[95]),
	.render_x        (render_x),
	.render_y        (render_y),
	.text_on         (mame_warn_on)
);

wire [7:0] mame_r = mame_warn_on ? 8'hFF : video_r;
wire [7:0] mame_g = mame_warn_on ? 8'hFF : video_g;
wire [7:0] mame_b = mame_warn_on ? 8'h00 : video_b;

// Pause overlay: dim video + logo 48x48 al centro + scroll patron + links durante pausa.
// OSD "Clean Pause" (status[19]): ON=video raw senza addon, OFF=overlay attivo.
pause_overlay u_pause_ovl (
	.clk       (clk_sys),
	.pause     (pause),
	.clean     (status[19]),
	.render_x  (render_x),
	.render_y  (render_y),
	.rgb_r_in  (mame_r),
	.rgb_g_in  (mame_g),
	.rgb_b_in  (mame_b),
	.rgb_r_out (VGA_R),
	.rgb_g_out (VGA_G),
	.rgb_b_out (VGA_B)
);

// Aspect ratio: Original = 4:1 (3x 4:3 monitors), Full Screen = 0:0
wire [11:0] arx = (!ar) ? 12'd4 : (ar - 1'd1);
wire [11:0] ary = (!ar) ? 12'd1 : 12'd0;

// Integer scaling (Scale menu: Narrower HV-Integer / V-Integer / HV-Integer).
// Tolto "Normal" come prima voce — default ora Narrower HV-Integer.
video_freak video_freak
(
	.CLK_VIDEO(clk_sys),
	.CE_PIXEL(ce_pix),
	.VGA_VS(VSync),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(~(HBlank | VBlank)),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE({1'b0, status[6:5]})
);

// LED_USER lampeggia se Z80 audio fa M1 fetch (boot OK).
// Se resta spento → Z80 non boota (ROM non in DDRAM o WAIT_n eterno).
assign LED_USER = dbg_z80_active;

// ============================================================
// JTAG Debug Probes (readable via quartus_stp / System Console)
// ============================================================
// JTAG boot trace removed to save M10K for 64KB work RAM

endmodule
