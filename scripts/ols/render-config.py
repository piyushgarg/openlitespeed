#!/usr/bin/env python3
"""Render a private static site; only called for a new configuration."""
import grp
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import tempfile

COMPRESSION = {
    'enableGzipCompress': '1',
    'enableBrCompress': '4',
    'gzipAutoUpdateStatic': '1',
    'gzipStaticCompressLevel': '6',
    'brStaticCompressLevel': '6',
    'gzipMinFileSize': '300',
    'gzipMaxFileSize': '10485760',
    'gzipCacheDir': '@ROOT@/tmp/compression',
    'compressibleTypes': 'default',
}


def configure_compression(root):
    """Update only compression options in an existing managed installation."""
    paths = [root / 'conf/httpd_config.conf', root / 'conf/vhosts/site/vhconf.conf']
    originals = {path: path.read_bytes() for path in paths}
    server = originals[paths[0]].decode()
    blocks = list(re.finditer(r'(?ms)^tuning[ \t]*\{[ \t]*\n(.*?)^\}', server))
    if len(blocks) != 1:
        raise ValueError('Expected exactly one tuning block in the managed configuration')
    block = blocks[0]
    body = block[1]
    for key, value in COMPRESSION.items():
        value = value.replace('@ROOT@', str(root))
        body, count = re.subn(r'(?m)^[ \t]*' + key + r'[ \t]+[^\n]*$',
                             lambda match: f'  {key} {value}', body)
        if count > 1:
            raise ValueError(f'Duplicate compression setting: {key}')
        if count == 0:
            body += f'  {key} {value}\n'
    server = server[:block.start(1)] + body + server[block.end(1):]
    site = originals[paths[1]].decode()
    for key in ('enableGzip', 'enableBr'):
        site, count = re.subn(r'(?m)^' + key + r'[ \t]+[^\n]*$', key + ' 1', site)
        if count > 1:
            raise ValueError(f'Duplicate vhost compression setting: {key}')
        if count == 0:
            site = key + ' 1\n' + site

    def replace(path, content):
        fd, name = tempfile.mkstemp(prefix='.compression-', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as output:
                os.fchmod(output.fileno(), stat.S_IMODE(path.stat().st_mode))
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    try:
        for path, content in zip(paths, (server.encode(), site.encode())):
            replace(path, content)
        env = dict(os.environ, LSWS_HOME=str(root), OLS_PID_FILE=str(root / 'run/lshttpd.pid'))
        subprocess.run([str(root / 'bin/openlitespeed'), '-t'], env=env, check=True)
    except BaseException:
        for path, content in originals.items():
            replace(path, content)
        raise
    print('Static compression enabled: Brotli preferred, gzip fallback (level 6).')


if len(sys.argv) == 3 and sys.argv[1] == '--compression':
    configure_compression(Path(sys.argv[2]).resolve())
    sys.exit(0)

root, document_root, bind, port, cert, key = sys.argv[1:]
values = {
    "ROOT": root, "DOCROOT": document_root, "BIND": bind, "PORT": port,
    "CERT": cert, "KEY": key, "USER": pwd.getpwuid(os.getuid()).pw_name,
    "GROUP": grp.getgrgid(os.getgid()).gr_name,
}
if ':' in values['BIND'] and not values['BIND'].startswith('['):
    values['BIND'] = '[' + values['BIND'] + ']'
for value in values.values():
    if any(char in value for char in '\r\n"$#{}'):
        raise SystemExit('Configuration values cannot contain newlines, quotes, $, # or braces.')

server = '''serverName PrivateStaticSite
user @USER@
group @GROUP@
httpdWorkers 1
priority 0
enableChroot 0
disableWebAdmin 1
autoRestart 1
autoFix503 1
mime conf/mime.properties
indexFiles index.html
showVersionNumber 0
swappingDir @ROOT@/tmp/swap
statDir @ROOT@/run/status

errorlog @ROOT@/logs/error.log {
  logLevel INFO
  rollingSize 10M
  enableStderrLog 1
}
accesslog @ROOT@/logs/access.log {
  rollingSize 10M
  keepDays 7
}
tuning {
  maxConnections 1024
  maxSSLConnections 1024
  connTimeout 60
  keepAliveTimeout 5
  maxKeepAliveReq 100
  useSendfile 1
@COMPRESSION@
}
security {
  fileAccessControl {
    followSymbolLink 1
    checkSymbolLink 0
    requiredPermissionMask 000
    restrictedPermissionMask 000
  }
}
virtualhost site {
  vhRoot @DOCROOT@/
  configFile conf/vhosts/site/vhconf.conf
  allowSymbolLink 1
  enableScript 0
  restrained 1
}
listener HTTPS {
  address @BIND@:@PORT@
  secure 1
  keyFile @KEY@
  certFile @CERT@
  certChain 1
  sslProtocol 24
  map site *
}
'''
site = '''docRoot @DOCROOT@/
enableGzip 1
enableBr 1
index {
  useServer 0
  indexFiles index.html
  autoIndex 0
}
realm SiteUsers {
  userDB {
    location @ROOT@/conf/auth/htpasswd
    maxCacheSize 200
    cacheTimeout 1
  }
}
context / {
  location @DOCROOT@/
  allowBrowse 1
  realm SiteUsers
  authName PrivateWebsite
  required valid-user
}
context /_autoindex/ {
  allowBrowse 0
}
context exp:^/(.*/)?\\. {
  allowBrowse 0
}
'''
server = server.replace('@COMPRESSION@', '\n'.join(f'  {key} {value}' for key, value in COMPRESSION.items()))
for name, template in [('conf/httpd_config.conf', server), ('conf/vhosts/site/vhconf.conf', site)]:
    for token, value in values.items():
        template = template.replace('@' + token + '@', value)
    with (Path(root) / name).open('x') as output:
        output.write(template)
