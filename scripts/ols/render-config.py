#!/usr/bin/env python3
"""Render a private static site; only called for a new configuration."""
import grp
import os
from pathlib import Path
import pwd
import sys

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
  enableGzipCompress 1
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
for name, template in [('conf/httpd_config.conf', server), ('conf/vhosts/site/vhconf.conf', site)]:
    for token, value in values.items():
        template = template.replace('@' + token + '@', value)
    with (Path(root) / name).open('x') as output:
        output.write(template)
