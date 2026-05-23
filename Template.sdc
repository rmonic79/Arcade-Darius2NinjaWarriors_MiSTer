derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ============================================================
# Audio subsystem runs at ce_z80_p (96MHz/24 = 4MHz)
# T80 (Z80 audio) registri tutti CE-gated → 24 cicli liberi tra ogni edge attivo.
# Multicycle 4 (conservativo: T80 propaga in pochi cicli logici) → slack chiude.
# Target: tutti i registri sotto T80 dentro darius2_audio_top.
# ============================================================
set_multicycle_path -setup -from [get_registers {*darius2_audio_top*T80*}] -to [get_registers {*darius2_audio_top*T80*}] 4
set_multicycle_path -hold  -from [get_registers {*darius2_audio_top*T80*}] -to [get_registers {*darius2_audio_top*T80*}] 3
# Stessa cosa per gli altri moduli audio CE-gated (jt03, jt12, jt10, syt, mixer)
set_multicycle_path -setup -from [get_registers {*darius2_audio_top*jt*}] -to [get_registers {*darius2_audio_top*jt*}] 4
set_multicycle_path -hold  -from [get_registers {*darius2_audio_top*jt*}] -to [get_registers {*darius2_audio_top*jt*}] 3
