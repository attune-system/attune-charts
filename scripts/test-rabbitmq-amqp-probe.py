#!/usr/bin/env python3

import os
import socket
import struct
import subprocess
import sys
import threading


FRAME_END = b"\xce"
TEST_USERNAME = "attune-probe"
TEST_PASSWORD = "probe-password"


def read_exact(connection, size):
    data = b""
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise ConnectionError("probe closed the connection")
        data += chunk
    return data


def read_frame(connection):
    frame_type, channel, size = struct.unpack(">BHI", read_exact(connection, 7))
    payload = read_exact(connection, size)
    if read_exact(connection, 1) != FRAME_END:
        raise AssertionError("invalid frame terminator")
    if frame_type != 1 or channel != 0:
        raise AssertionError("expected an AMQP method frame on channel zero")
    return payload


def method_frame(payload):
    return b"\x01" + struct.pack(">HI", 0, len(payload)) + payload + FRAME_END


def short_string(value):
    return bytes([len(value)]) + value


def send_start(connection):
    connection.sendall(method_frame(struct.pack(">HH", 10, 10)))


def validate_start_ok(payload):
    if struct.unpack(">HH", payload[:4]) != (10, 11):
        raise AssertionError("expected connection.start-ok")
    table_size = struct.unpack(">I", payload[4:8])[0]
    offset = 8 + table_size
    mechanism_size = payload[offset]
    offset += 1
    mechanism = payload[offset : offset + mechanism_size]
    offset += mechanism_size
    response_size = struct.unpack(">I", payload[offset : offset + 4])[0]
    offset += 4
    response = payload[offset : offset + response_size]
    if mechanism != b"PLAIN":
        raise AssertionError("probe did not select SASL PLAIN")
    expected = b"\x00" + TEST_USERNAME.encode() + b"\x00" + TEST_PASSWORD.encode()
    if response != expected:
        raise AssertionError("probe sent the wrong credentials")


def reject_first_attempt(listener):
    connection, _ = listener.accept()
    with connection:
        if read_exact(connection, 8) != b"AMQP\x00\x00\x09\x01":
            raise AssertionError("probe did not send the AMQP 0-9-1 header")
        send_start(connection)
        validate_start_ok(read_frame(connection))
        connection_close = (
            struct.pack(">HHH", 10, 50, 403)
            + short_string(b"ACCESS_REFUSED")
            + struct.pack(">HH", 10, 11)
        )
        connection.sendall(method_frame(connection_close))


def accept_second_attempt(listener):
    connection, _ = listener.accept()
    with connection:
        if read_exact(connection, 8) != b"AMQP\x00\x00\x09\x01":
            raise AssertionError("probe did not retry with the AMQP 0-9-1 header")
        send_start(connection)
        validate_start_ok(read_frame(connection))

        tune = struct.pack(">HHHIH", 10, 30, 0, 131072, 0)
        connection.sendall(method_frame(tune))
        tune_ok = read_frame(connection)
        if struct.unpack(">HH", tune_ok[:4]) != (10, 31):
            raise AssertionError("expected connection.tune-ok")

        connection_open = read_frame(connection)
        if struct.unpack(">HH", connection_open[:4]) != (10, 40):
            raise AssertionError("expected connection.open")
        vhost_size = connection_open[4]
        if connection_open[5 : 5 + vhost_size] != b"/":
            raise AssertionError("probe did not open the bundled RabbitMQ vhost")
        connection.sendall(method_frame(struct.pack(">HH", 10, 41)))

        connection_close = read_frame(connection)
        if struct.unpack(">HH", connection_close[:4]) != (10, 50):
            raise AssertionError("expected connection.close")
        connection.sendall(method_frame(struct.pack(">HH", 10, 51)))


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} RENDERED_PROBE_SCRIPT")

    errors = []
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(2)
        listener.settimeout(10)
        port = listener.getsockname()[1]

        def serve():
            try:
                reject_first_attempt(listener)
                accept_second_attempt(listener)
            except Exception as error:
                errors.append(error)

        server = threading.Thread(target=serve)
        server.start()
        environment = os.environ.copy()
        environment.update(
            {
                "RABBITMQ_HOST": "127.0.0.1",
                "RABBITMQ_PORT": str(port),
                "RABBITMQ_USER": TEST_USERNAME,
                "RABBITMQ_PASSWORD": TEST_PASSWORD,
            }
        )
        result = subprocess.run(
            [sys.executable, sys.argv[1]],
            env=environment,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        server.join(timeout=10)

    if server.is_alive():
        raise AssertionError("fake RabbitMQ server did not finish")
    if errors:
        raise errors[0]
    if result.returncode != 0:
        raise AssertionError(
            f"rendered probe exited {result.returncode}: {result.stdout}{result.stderr}"
        )


if __name__ == "__main__":
    main()
