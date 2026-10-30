from pymodbus.datastore import (
    ModbusSparseDataBlock,
    ModbusSlaveContext,
    ModbusServerContext,
)
from pymodbus.server import StartTcpServer


def main():
    store = ModbusSlaveContext(
        hr=ModbusSparseDataBlock({10: 12, 11: 13}),
        ir=ModbusSparseDataBlock({8: 14, 9: 15}),
        co=ModbusSparseDataBlock(),
        di=ModbusSparseDataBlock(),
        zero_mode=True,  # Client address 10 maps directly to register 10.
    )
    context = ModbusServerContext(slaves={1: store}, single=False)

    print("Modbus TCP listening on localhost:5020; register 10 = 12")
    StartTcpServer(context=context, address=("127.0.0.1", 5020))


if __name__ == "__main__":
    main()    
