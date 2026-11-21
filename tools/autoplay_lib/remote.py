"""Authenticated Sanity and Supabase adapters. Credentials never enter receipts."""
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, quote, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler


class RemoteError(RuntimeError):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward an authorization header to another origin.


def credentials(env_file=None, secrets_plist=None):
    values = {}
    if secrets_plist:
        with Path(secrets_plist).open('rb') as stream:
            values.update({k: v for k, v in plistlib.load(stream).items() if isinstance(v, str)})
    if env_file:
        for line in Path(env_file).read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('export '):
                line = line[7:]
            key, separator, value = line.partition('=')
            if not separator or not re.fullmatch(r'[A-Z][A-Z0-9_]*', key.strip()):
                raise ValueError('Invalid credential environment file assignment')
            parsed = shlex.split(value, comments=True, posix=True)
            if len(parsed) > 1:
                raise ValueError('Quote credential values containing spaces')
            values[key.strip()] = parsed[0] if parsed else ''
    values.update(os.environ)
    return values


def https_origin(url):
    parts = urlsplit(url)
    if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment or parts.path not in ('', '/'):
        raise ValueError('Remote endpoint must be an HTTPS origin')
    return url.rstrip('/')


def http(method, url, headers, data=None, missing_ok=False):
    request = Request(url, data=data, headers=headers, method=method)
    try:
        with build_opener(NoRedirect()).open(request, timeout=45) as response:
            return response.read()
    except HTTPError as error:
        if missing_ok and error.code == 404:
            return None
        raise RemoteError(f'Remote {method} failed: HTTP {error.code}') from None
    except URLError:
        raise RemoteError(f'Remote {method} failed: connection error') from None


class Sanity:
    def __init__(self, config, values, transport=http):
        project, dataset = config['project_id'], config['dataset']
        version = config.get('api_version', 'v2025-11-10')
        if not re.fullmatch(r'[a-z0-9]+', project) or not re.fullmatch(r'[A-Za-z0-9_-]+', dataset) or not re.fullmatch(r'v\d{4}-\d{2}-\d{2}', version):
            raise ValueError('Invalid Sanity endpoint configuration')
        self.base = f'https://{project}.api.sanity.io/{version}/data'
        self.dataset, self.transport = dataset, transport
        self.read_token = values.get('SANITY_READ_TOKEN') or values.get('SANITY_WRITE_TOKEN')
        self.write_token = values.get('SANITY_WRITE_TOKEN')
        if not self.read_token:
            raise ValueError('Configure SANITY_READ_TOKEN or SANITY_WRITE_TOKEN')

    def query(self, query, params):
        values = {'query': query, 'perspective': 'raw'}
        values.update({'$' + k: json.dumps(v) for k, v in params.items()})
        data = self.transport('GET', f'{self.base}/query/{self.dataset}?' + urlencode(values),
                              {'Authorization': 'Bearer ' + self.read_token, 'Cache-Control': 'no-cache'})
        return json.loads(data)['result']

    def read(self, score_id):
        rows = self.query('*[_id in $ids]', {'ids': [score_id, 'drafts.' + score_id]})
        if any(row['_id'] == 'drafts.' + score_id for row in rows):
            raise ValueError('Unpublished Sanity draft exists; preserve it and use the review workflow')
        matches = [row for row in rows if row['_id'] == score_id]
        if len(matches) != 1:
            raise ValueError('Expected one canonical published Sanity score')
        return matches[0]

    def patch(self, score_id, revision, set_values, changelog_entry):
        if not self.write_token:
            raise ValueError('SANITY_WRITE_TOKEN is required for publication')
        patch = {'id': score_id, 'ifRevisionID': revision, 'set': set_values,
                 'setIfMissing': {'changelog': []},
                 'insert': {'after': 'changelog[-1]', 'items': [changelog_entry]}}
        self.transport('POST', f'{self.base}/mutate/{self.dataset}?returnDocuments=true',
                       {'Authorization': 'Bearer ' + self.write_token, 'Content-Type': 'application/json'},
                       json.dumps({'mutations': [{'patch': patch}]}).encode())


def storage_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or str(path) != value or any(part in ('.', '..') for part in path.parts) or '\\' in value:
        raise ValueError('Unsafe Storage object path')
    return '/'.join(quote(part, safe='') for part in path.parts)


class Storage:
    def __init__(self, config, values, transport=http):
        self.origin = https_origin(config['storage_url'])
        self.bucket = config['bucket']
        if not re.fullmatch(r'[a-z0-9][a-z0-9._-]*', self.bucket):
            raise ValueError('Invalid Storage bucket')
        # Environment pins the credential's intended host independently of the manifest.
        if https_origin(values.get('SUPABASE_URL', '')) != self.origin:
            raise ValueError('SUPABASE_URL must match the manifest storage_url')
        key = values.get('SUPABASE_KEY') or values.get('SUPABASE_ANON_KEY') or values.get('SUPABASE_SERVICE_ROLE_KEY')
        token = values.get('SUPABASE_ACCESS_TOKEN') or values.get('SUPABASE_SERVICE_ROLE_KEY')
        if not key or not token:
            raise ValueError('Configure Supabase API key and authenticated access token')
        self.headers = {'apikey': key, 'Authorization': 'Bearer ' + token, 'Cache-Control': 'no-cache'}
        self.transport = transport

    def read(self, path):
        url = self.origin + '/storage/v1/object/authenticated/' + self.bucket + '/' + storage_path(path)
        return self.transport('GET', url, self.headers, missing_ok=True)

    def write(self, path, data, replace=True):
        url = self.origin + '/storage/v1/object/' + self.bucket + '/' + storage_path(path)
        headers = dict(self.headers, **{'Content-Type': 'application/json', 'x-upsert': str(replace).lower()})
        self.transport('POST', url, headers, data)

    def delete(self, path):
        self.transport('DELETE', self.origin + '/storage/v1/object/' + self.bucket,
                       dict(self.headers, **{'Content-Type': 'application/json'}),
                       json.dumps({'prefixes': [path]}).encode())
