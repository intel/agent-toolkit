# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Run a script with the given hostnames resolved to the gateway address.

Usage: run_via_gateway.py <gateway-ip> <host,host,...> <script> [args...]
For validation from a host without DNS for the platform domain; nothing else
is redirected, and no system file is changed.
"""
import runpy
import socket
import sys

gateway, hosts = sys.argv[1], set(sys.argv[2].split(","))
_getaddrinfo = socket.getaddrinfo
socket.getaddrinfo = lambda host, *a, **k: _getaddrinfo(gateway if host in hosts else host, *a, **k)
sys.argv = sys.argv[3:]
runpy.run_path(sys.argv[0], run_name="__main__")
