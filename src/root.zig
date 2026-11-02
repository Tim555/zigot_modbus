//! Transport-independent Modbus codecs, a reusable blocking TCP transport,
//! and a synchronous Modbus TCP client. Serial I/O remains caller-supplied.
pub const rtu = @import("rtu.zig");
pub const modbus_codec = @import("modbus_codec.zig");
/// Compatibility alias; prefer modbus_codec for MBAP and PDU codecs.
pub const tcp = modbus_codec;
pub const modbus_tcp = @import("modbus_tcp.zig");
pub const tcp_transport = @import("tcp_transport.zig");
pub const TcpClient = tcp_transport.TcpClient;
pub const SyncTcpModbusClient = modbus_tcp.SyncTcpModbusClient;
pub const TcpModbusClient = modbus_tcp.TcpModbusClient;
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
    _ = modbus_codec;
    _ = modbus_tcp;
    _ = tcp_transport;
}
