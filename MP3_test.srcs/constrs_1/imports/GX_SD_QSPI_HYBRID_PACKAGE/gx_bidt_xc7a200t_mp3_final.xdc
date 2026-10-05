# ============================================================================
# GX-BIDT + XC7A200T-FBG484-2
# SD + user-QSPI raw-PCM player with LCD lyrics / Vivado 2025.2
# ============================================================================

# 100 MHz system clock
set_property PACKAGE_PIN W19 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]

# ----------------------------------------------------------------------------
# ES8388 Audio Codec
# Baseboard nets -> core-board FPGA pins
# MCLK        F_B15_L3_P   -> J14
# BCLK/SCLK   F_B15_L3_N   -> H14
# LRCK        F_B15_L18_N  -> M20
# DSDIN       F_B16_L1_P   -> F13
# ASDOUT      F_B16_L1_N   -> F14
# CCLK/I2C    F_B16_L7_P   -> B15
# CDATA/I2C   F_B16_L7_N   -> B16
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN J14 [get_ports AUDIO_MCLK]
set_property PACKAGE_PIN H14 [get_ports AUDIO_BCLK]
set_property PACKAGE_PIN M20 [get_ports AUDIO_LRCK]
set_property PACKAGE_PIN F13 [get_ports AUDIO_DAC_DIN]
set_property PACKAGE_PIN F14 [get_ports AUDIO_ADC_DOUT]
set_property PACKAGE_PIN B15 [get_ports AUDIO_CCLK]
set_property PACKAGE_PIN B16 [get_ports AUDIO_CDATA]

set_property IOSTANDARD LVCMOS33 [get_ports {AUDIO_MCLK AUDIO_BCLK AUDIO_LRCK AUDIO_DAC_DIN AUDIO_ADC_DOUT AUDIO_CCLK AUDIO_CDATA}]
set_property PULLUP true [get_ports AUDIO_CDATA]

# ----------------------------------------------------------------------------
# Independent user SPI Flash U26 on baseboard
# This is intentionally used for media bring-up instead of overwriting the
# XC7A configuration QSPI flash.
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN W16 [get_ports FLASH_CS_N]
set_property PACKAGE_PIN W15 [get_ports FLASH_SCLK]
set_property PACKAGE_PIN T15 [get_ports FLASH_MOSI]
set_property PACKAGE_PIN T14 [get_ports FLASH_MISO]
set_property IOSTANDARD LVCMOS33 [get_ports {FLASH_CS_N FLASH_SCLK FLASH_MOSI FLASH_MISO}]

# ----------------------------------------------------------------------------
# Core-board TF/SD card, SPI mode
# DATA3/CS  B13_L4_N -> AB15
# CMD/MOSI  B13_L6_N -> Y14
# CLK       B13_L6_P -> W14
# DATA0/MISO B13_L1_P -> Y16
# CD        B13_L1_N -> AA16
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN AB15 [get_ports SD_CS_N]
set_property PACKAGE_PIN Y14  [get_ports SD_MOSI]
set_property PACKAGE_PIN W14  [get_ports SD_SCLK]
set_property PACKAGE_PIN Y16  [get_ports SD_MISO]
set_property PACKAGE_PIN AA16 [get_ports SD_CD_N]
set_property IOSTANDARD LVCMOS33 [get_ports {SD_CS_N SD_SCLK SD_MOSI SD_MISO SD_CD_N}]

# ----------------------------------------------------------------------------
# Core-board pushbuttons (active low)
# KEY0 -> previous SD track, KEY1 -> next SD track
# KEY2 -> toggle SD / independent user-QSPI playback
# KEY3 -> copy SONG.RAW first 10 seconds from SD to user QSPI
# Bank 34 is powered from 1.5 V; the board already has 4.7 kOhm pull-ups.
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN Y6  [get_ports KEY0_N]
set_property PACKAGE_PIN AA6 [get_ports KEY1_N]
set_property PACKAGE_PIN V7  [get_ports KEY2_N]
set_property PACKAGE_PIN W7  [get_ports KEY3_N]
set_property IOSTANDARD LVCMOS15 [get_ports {KEY0_N KEY1_N KEY2_N KEY3_N}]

# ----------------------------------------------------------------------------
# LCD1602 -- FPGA common side of the baseboard C-group bus switches.
# To use LCD1602, the C-group mux must select B4 (S1C=1, S0C=1, nOEC=0).
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN E14 [get_ports {LCD_D[0]}]
set_property PACKAGE_PIN K19 [get_ports {LCD_D[1]}]
set_property PACKAGE_PIN K21 [get_ports {LCD_D[2]}]
set_property PACKAGE_PIN L21 [get_ports {LCD_D[3]}]
set_property PACKAGE_PIN F16 [get_ports {LCD_D[4]}]
set_property PACKAGE_PIN M22 [get_ports {LCD_D[5]}]
set_property PACKAGE_PIN M18 [get_ports {LCD_D[6]}]
set_property PACKAGE_PIN L18 [get_ports {LCD_D[7]}]
set_property PACKAGE_PIN N18 [get_ports LCD_RS]
set_property PACKAGE_PIN N19 [get_ports LCD_RW]
set_property PACKAGE_PIN N20 [get_ports LCD_E]
set_property IOSTANDARD LVCMOS33 [get_ports {LCD_D[*] LCD_RS LCD_RW LCD_E}]

# Diagnostics
set_property PACKAGE_PIN J16 [get_ports LED0]
set_property PACKAGE_PIN E22 [get_ports LED1]
set_property IOSTANDARD LVCMOS33 [get_ports {LED0 LED1}]

set_property PACKAGE_PIN C18 [get_ports FLASH_HOLD_N]
set_property IOSTANDARD LVCMOS33 [get_ports FLASH_HOLD_N]


# Core-board USB_UART / CH340E
# CH340E TXD -> B13_L13_N -> FPGA V14 (UART_RXD)
# CH340E RXD <- B13_L5_N  <- FPGA AA14 (UART_TXD)
set_property PACKAGE_PIN V14  [get_ports UART_RXD]
set_property PACKAGE_PIN AA14 [get_ports UART_TXD]
set_property IOSTANDARD LVCMOS33 [get_ports {UART_RXD UART_TXD}]
