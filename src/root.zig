//! Transport-independent Modbus building blocks. Networking and serial I/O
//! will be supplied by callers; this package does not open devices or sockets.
pub const rtu = @import("rtu.zig");
pub const tcp = @import("tcp.zig");
pub const max_pdu_length = 253;

pub const FunctionCode = enum(u8) {
    read_coils = 0x01,
    read_discrete_inputs = 0x02,
    read_holding_registers = 0x03,
    read_input_registers = 0x04,
    write_single_coil = 0x05,
    write_single_register = 0x06,
    write_multiple_coils = 0x0f,
    write_multiple_registers = 0x10,
    _,
};

test {
    _ = rtu;
    _ = tcp;
}
