# GX-BIDT + XC7A200T-FBG484-2
# Core-board USB-UART / CH340E
# CH340E RXD <- FPGA B13_L5_N -> package pin AA14
set_property PACKAGE_PIN AA14 [get_ports UART_TXD]
set_property IOSTANDARD LVCMOS33 [get_ports UART_TXD]
