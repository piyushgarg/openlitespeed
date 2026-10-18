#!/usr/bin/env python3
"""Exercise the real installer, TLS listener, authentication and server control."""
import base64
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

REPO = Path(__file__).resolve().parents[2]


class SetupOLSTest(unittest.TestCase):
    def command(self, *args, password=None, success=True, environment=None):
        env = dict(getattr(self, 'environment', os.environ))
        env.update(environment or {})
        result = subprocess.run(
            [str(arg) for arg in args], input=password, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=40,
            env=env,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def check_runtime_listener(self, prefix, context, password):
        control = prefix / 'runserver.sh'
        config = prefix / 'conf/httpd_config.conf'
        original = config.read_bytes()
        accounts = (prefix / 'conf/auth/htpasswd').read_bytes()
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))

        def port_number():
            with socket.socket(socket.AF_INET6) as listener:
                listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                listener.bind(('::', 0))
                return listener.getsockname()[1]

        def fetch(port, host):
            token = base64.b64encode(('alice:' + password).encode()).decode()
            request = urllib.request.Request(f'https://{host}:{port}/',
                                             headers={'Authorization': 'Basic ' + token})
            with opener.open(request, timeout=2) as response:
                return response.status, response.read()

        self.command(control, 'test', environment={'IP': 'not-an-address'}, success=False)
        self.assertEqual(config.read_bytes(), original)
        self.command(control, 'start')
        try:
            pid_before = (prefix / 'run/lshttpd.pid').read_text()
            self.command(control, 'restart', environment={'PORT': '70000'}, success=False)
            self.assertEqual((prefix / 'run/lshttpd.pid').read_text(), pid_before)
            self.assertEqual(config.read_bytes(), original)
            port = port_number()
            self.command(control, 'start', environment={'PORT': str(port)}, success=False)
            self.assertEqual(config.read_bytes(), original)
            self.command(control, 'restart', environment={'IP': '[::]', 'PORT': str(port)})
            expected = re.sub(rb'(?m)^([ \t]*address[ \t]+)\S+',
                              lambda match: match[1] + f'[::]:{port}'.encode(), original)
            self.assertEqual(config.read_bytes(), expected)
            self.assertEqual(fetch(port, '127.0.0.1'), (200, b'private site content'))
            self.assertEqual(fetch(port, '[::1]'), (200, b'private site content'))
            self.command(control, 'start', environment={'IP': '::', 'PORT': str(port)})
        finally:
            self.command(control, 'stop', environment={'PORT': 'invalid-is-ignored-for-stop'})

        # A failed OLS configuration check must undo the listener edit.
        valid = config.read_bytes()
        broken = re.sub(rb'(?m)^([ \t]*configFile[ \t]+).*$',
                        rb'\g<1>conf/vhosts/site/nonexistent-test.conf', valid)
        config.write_bytes(broken)
        self.command(control, 'test', environment={'IP': '127.0.0.1'}, success=False)
        self.assertEqual(config.read_bytes(), broken)
        config.write_bytes(valid)

        # Override only PORT, retain IPv6 dual stack, and verify exec/signal handling.
        port = port_number()
        env = dict(self.environment, PORT=str(port))
        with (prefix / 'logs/foreground-test.log').open('w') as log:
            process = subprocess.Popen([str(control), 'foreground'], env=env,
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 10
                while True:
                    if process.poll() is not None:
                        self.fail('Foreground server exited before serving requests:\n'
                                  + (prefix / 'logs/foreground-test.log').read_text())
                    try:
                        self.assertEqual(fetch(port, '[::1]'), (200, b'private site content'))
                        break
                    except (OSError, urllib.error.URLError):
                        if time.monotonic() >= deadline:
                            self.fail('Foreground server did not become ready')
                        time.sleep(0.05)
                self.assertEqual(int((prefix / 'run/lshttpd.pid').read_text()), process.pid)
                self.assertEqual(fetch(port, '127.0.0.1'), (200, b'private site content'))
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=10), 0)
            finally:
                if process.poll() is None:
                    self.command(control, 'stop')
                    process.wait(timeout=10)
        self.assertIn(f'address [::]:{port}'.encode(), config.read_bytes())
        self.assertEqual((prefix / 'conf/auth/htpasswd').read_bytes(), accounts)

    def test_https_site(self):
        with tempfile.TemporaryDirectory(prefix='ols-integration-') as directory:
            work = Path(directory)
            # Catch privileged account-management attempts even when OLS
            # ignores their exit status and continues to serve requests.
            guard = work / 'guard'
            guard.mkdir()
            marker = work / 'account-change-attempted'
            usermod = guard / 'usermod'
            usermod.write_text('#!/bin/sh\n: > "$OLS_TEST_ACCOUNT_CHANGE_MARKER"\nexit 91\n')
            usermod.chmod(0o755)
            self.environment = dict(os.environ,
                                    PATH=str(guard) + os.pathsep + os.environ['PATH'],
                                    OLS_TEST_ACCOUNT_CHANGE_MARKER=str(marker))
            self.environment.pop('IP', None)
            self.environment.pop('PORT', None)
            certificates = work / 'ssl'
            certificates.mkdir()
            self.command(
                'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                '-keyout', certificates / 'privkey.pem', '-out', certificates / 'fullchain.pem',
                '-days', '1', '-subj', '/CN=localhost',
                '-addext', 'subjectAltName=IP:127.0.0.1,IP:::1,DNS:localhost',
            )
            context = ssl.create_default_context(cafile=str(certificates / 'fullchain.pem'))
            for variant in ('static', 'dynamic'):
                with self.subTest(variant=variant):
                    # Spaces exercise shell quoting and the OLS configuration parser.
                    prefix = work / f'{variant} installation'
                    site = work / f'{variant} website'
                    site.mkdir()
                    (site / 'index.html').write_text('private site content')
                    (site / '.hidden').write_text('must not be served')
                    (site / 'nested').mkdir()
                    (site / 'nested' / 'page.html').write_text('nested private content')
                    (site / 'nested' / '.hidden').write_text('must not be served')
                    with socket.socket(socket.AF_INET6) as listener:
                        listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                        listener.bind(('::', 0))
                        port = listener.getsockname()[1]
                    setup = [REPO / 'setupols.sh', '--prefix', prefix, '--docroot', site,
                             '--cert-dir', certificates, '--variant', variant, '--port', port]
                    if variant == 'dynamic':
                        # Explicit flags win over conflicting environment variables.
                        self.command(*setup, '--bind', '::',
                                     environment={'IP': '127.0.0.1', 'PORT': '0'})
                    else:
                        self.command(*setup)
                    control = prefix / 'runserver.sh'
                    users = prefix / 'siteuser.sh'
                    self.command(control, 'start', success=False)
                    self.command(users, 'add', 'alice', '--password-stdin', password='Initial-Test-password\n')
                    self.assertEqual((prefix / 'conf/auth/htpasswd').stat().st_mode & 0o777, 0o600)

                    opener = urllib.request.build_opener(
                        urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))

                    def request(path='/', user=None, password=None, host='127.0.0.1'):
                        headers = {}
                        if user:
                            encoded = base64.b64encode(f'{user}:{password}'.encode()).decode()
                            headers['Authorization'] = 'Basic ' + encoded
                        req = urllib.request.Request(f'https://{host}:{port}{path}', headers=headers)
                        try:
                            response = opener.open(req, timeout=5)
                        except urllib.error.HTTPError as error:
                            response = error
                        with response:
                            return response.status, response.read(), response.headers

                    try:
                        self.command(control, 'start')
                        self.command(control, 'status')
                        unauth = request()
                        self.assertEqual(unauth[0], 401)
                        self.assertIn('Basic', unauth[2].get('WWW-Authenticate', ''))
                        self.assertEqual(request(user='alice', password='wrong')[0], 401)
                        self.assertEqual(request(user='alice', password='Initial-Test-password')[:2],
                                         (200, b'private site content'))
                        self.assertEqual(request(host='[::1]')[0], 401)
                        self.assertEqual(request(user='alice', password='Initial-Test-password', host='[::1]')[:2],
                                         (200, b'private site content'))
                        self.assertEqual(request('/nested/page.html')[0], 401)
                        self.assertEqual(request('/nested/page.html', 'alice', 'Initial-Test-password')[:2],
                                         (200, b'nested private content'))
                        self.assertIn(request('/_autoindex/default.php')[0], (403, 404))
                        for hidden in ('/.hidden', '/nested/.hidden'):
                            self.assertEqual(request(hidden, 'alice', 'Initial-Test-password')[0], 403)
                        # Refuse an upgrade of a running instance before touching it.
                        self.command(*setup, '--clean', success=False)
                        new_password = 'Changed-Test $ with spaces!'
                        self.command(users, 'add', 'alice', '--password-stdin', password=new_password + '\n')
                        self.command(users, 'add', 'bob', '--password-stdin', password='Second-Test-password\n')
                        self.command(control, 'reload')
                        self.assertEqual(request(user='alice', password='Initial-Test-password')[0], 401)
                        self.assertEqual(request(user='alice', password=new_password)[0], 200)
                        self.assertEqual(request(user='bob', password='Second-Test-password')[0], 200)
                        self.command(users, 'delete', 'bob')
                        self.command(control, 'restart')
                        self.assertEqual(request(user='bob', password='Second-Test-password')[0], 401)
                        self.assertEqual(request(user='alice', password=new_password)[0], 200)
                    except Exception:
                        log = prefix / 'logs/error.log'
                        if log.exists():
                            print(log.read_text()[-14000:], file=sys.stderr)
                        raise
                    finally:
                        self.command(control, 'stop')
                    self.command(control, 'status', success=False)
                    config = prefix / 'conf/httpd_config.conf'
                    config.write_text(config.read_text() + '\n# preserve this configuration\n')
                    config_before = config.read_bytes()
                    passwords_before = (prefix / 'conf/auth/htpasswd').read_bytes()
                    self.command(*setup)
                    self.assertEqual(config.read_bytes(), config_before)
                    self.assertEqual((prefix / 'conf/auth/htpasswd').read_bytes(), passwords_before)
                    self.check_runtime_listener(prefix, context, new_password)
                    # Installer environment overrides on an existing install change
                    # only explicitly specified listener fields, not the site/accounts.
                    current = config.read_bytes()
                    self.command(*setup, environment={'IP': '::1'})
                    expected = re.sub(rb'(?m)^([ \t]*address[ \t]+)\S+',
                                      lambda match: match[1] + f'[::1]:{port}'.encode(), current)
                    self.assertEqual(config.read_bytes(), expected)
                    self.assertEqual((prefix / 'conf/auth/htpasswd').read_bytes(), passwords_before)
                    self.command(*setup, '--clean')
                    backups = list(work.glob(prefix.name + '.backup-*'))
                    self.assertEqual(len(backups), 1)
                    self.assertEqual((backups[0] / 'conf/auth/htpasswd').read_bytes(), passwords_before)
                    self.assertEqual((site / 'index.html').read_text(), 'private site content')
                    self.assertEqual((prefix / 'conf/auth/htpasswd').read_bytes(), b'')
                    self.assertFalse(marker.exists(), 'OLS attempted to modify a system account')


if __name__ == '__main__':
    unittest.main(verbosity=2)
