#!/usr/bin/env python3
"""Apply IP/PORT overrides to the managed HTTPS listener, with validation."""
import ipaddress
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import sys
import tempfile


def main():
    root = Path(sys.argv[1]).resolve()
    operation = sys.argv[2] if len(sys.argv) == 3 else ''
    check_only = operation == '--check'
    config = root / 'conf/httpd_config.conf'
    original = config.read_bytes()
    text = original.decode()
    listeners = list(re.finditer(r'(?ms)^listener[ \t]+HTTPS[ \t]*\{[ \t]*\n(.*?)^\}', text))
    if len(listeners) != 1:
        raise ValueError('Expected exactly one managed listener named HTTPS')
    listener = listeners[0]
    addresses = list(re.finditer(r'(?m)^([ \t]*address[ \t]+)(\S+)([ \t]*(?:#.*)?)$', listener[1]))
    if len(addresses) != 1:
        raise ValueError('Expected exactly one address in listener HTTPS')
    address = addresses[0]
    saved_ip, saved_port = address[2].rsplit(':', 1)
    if operation == '--ready':
        host = saved_ip.strip('[]')
        host = {'::': '::1', '0.0.0.0': '127.0.0.1'}.get(host, host)
        try:
            with socket.create_connection((host, int(saved_port)), timeout=0.2):
                return 0
        except OSError:
            return 1
    bind = os.environ.get('IP', saved_ip)
    if bind.startswith('[') and bind.endswith(']'):
        bind = bind[1:-1]
    ip = ipaddress.ip_address(bind)
    port_text = os.environ.get('PORT', saved_port)
    if not re.fullmatch(r'[0-9]{1,5}', port_text) or not 1 <= int(port_text) <= 65535:
        raise ValueError('PORT must be an integer between 1 and 65535')
    endpoint = f'[{ip}]:{int(port_text)}' if ip.version == 6 else f'{ip}:{int(port_text)}'
    if address[2] == endpoint:
        return 0
    if check_only:
        print('IP/PORT differ from the running configuration; use restart to apply them.', file=sys.stderr)
        return 3
    start = listener.start(1) + address.start(2)
    end = listener.start(1) + address.end(2)
    updated = (text[:start] + endpoint + text[end:]).encode()
    mode = stat.S_IMODE(config.stat().st_mode)

    def replace(content):
        fd, name = tempfile.mkstemp(prefix='.listener-', dir=config.parent)
        try:
            with os.fdopen(fd, 'wb') as output:
                os.fchmod(output.fileno(), mode)
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            os.replace(name, config)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    replace(updated)
    env = dict(os.environ, LSWS_HOME=str(root), OLS_PID_FILE=str(root / 'run/lshttpd.pid'))
    try:
        subprocess.run([str(root / 'bin/openlitespeed'), '-t'], env=env, check=True)
    except BaseException:
        replace(original)
        print('Listener validation failed; restored the previous configuration.', file=sys.stderr)
        raise
    print(f'HTTPS listener saved: {endpoint}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
