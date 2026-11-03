//! Transport-independent Modbus codecs, a reusable blocking TCP transport,
//! a synchronous Modbus TCP client, and a concurrent TCP server. Serial I/O
//! remains caller-supplied.
pub const rtu = @import("rtu.zig");
pub const modbus_codec = @import("modbus_codec.zig");
const modbus_tcp = @import("modbus_tcp.zig");
const tcp_transport = @import("tcp_transport.zig");
const tcp_server = @import("tcp_server.zig");
pub const TcpServer = tcp_server.TcpServer;
pub const TcpClient = tcp_transport.TcpClient;
pub const SyncTcpModbusClient = modbus_tcp.SyncTcpModbusClient;
/// Caller-owned tables for one server unit.
pub const Device = tcp_server.Device;
pub const TcpServerOptions = tcp_server.Options;
pub const ReadResult = modbus_tcp.ReadResult;
pub const WriteResult = modbus_tcp.WriteResult;
pub const max_register_count = modbus_tcp.max_register_count;
pub const max_bit_count = modbus_tcp.max_bit_count;
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
    _ = tcp_server;
}
