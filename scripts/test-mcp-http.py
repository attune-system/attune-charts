#!/usr/bin/env python3
"""Chart render contracts; --integration also runs the chart-pinned MCP image.

Requires Helm/PyYAML; integration requires Docker with published loopback ports.
Only a loopback synthetic API is used. No platform credentials or live API.
"""
import concurrent.futures
import http.client
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

import yaml

ROOT = Path(__file__).resolve().parent.parent
INTEGRATION = '--integration' in sys.argv
if INTEGRATION:
    sys.argv.remove('--integration')


def render(values=None, chart=None):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / 'values.yaml'
        path.write_text(yaml.safe_dump(values or {}))
        return subprocess.run(['helm', 'template', 'mcp-test', str(chart or ROOT / 'charts/attune'),
                               '--set', 'security.existingSecret=runtime', '-f', str(path)],
                              capture_output=True, text=True)


def container(result):
    if result.returncode:
        raise AssertionError(result.stderr)
    deployment = next(d for d in yaml.safe_load_all(result.stdout)
                      if d and d['kind'] == 'Deployment' and d['metadata']['name'] == 'mcp-test-attune-mcp')
    spec = deployment['spec']['template']['spec']
    assert spec['volumes'] == [{'name': 'ca-bundle', 'emptyDir': {'sizeLimit': '2Mi'}}]
    assert spec['containers'][0]['volumeMounts'] == [{'name': 'ca-bundle', 'mountPath': '/etc/ssl/certs', 'readOnly': True}]
    return spec['containers'][0]


def environment(c):
    return {e['name']: e['value'] for e in c['env']}


class Rendering(unittest.TestCase):
    def test_disabled_by_default(self):
        self.assertNotIn('name: "mcp-test-attune-mcp"', render().stdout)

    def test_defaults_and_package_have_no_credentials(self):
        version = yaml.safe_load((ROOT / 'charts/attune/Chart.yaml').read_text())['version']
        for chart in (ROOT / 'charts/attune', ROOT / f'packages/attune-{version}.tgz'):
            c = container(render({'mcp': {'enabled': True}}, chart))
            self.assertFalse(c.get('envFrom'))
            self.assertEqual(environment(c), {
                'ATTUNE_API_URL': 'http://mcp-test-attune-api:8080',
                'ATTUNE_MCP_TRANSPORT': 'http', 'ATTUNE_MCP_LISTEN_ADDR': '0.0.0.0:8090',
                'ATTUNE_MCP_HTTP_HOSTS': 'mcp-test-attune-mcp:8090'})
            for probe in ('readinessProbe', 'livenessProbe'):
                self.assertEqual(c[probe]['httpGet'], {'path': '/health', 'port': 'http'})

    def test_explicit_hosts_origins_and_port(self):
        env = environment(container(render({'mcp': {'enabled': True, 'service': {'port': 9090},
            'http': {'hosts': ['mcp.example.com', 'mcp.example.com:443'],
                     'origins': ['https://console.example.com']}}})))
        self.assertEqual(env['ATTUNE_MCP_HTTP_HOSTS'], 'mcp.example.com,mcp.example.com:443')
        self.assertEqual(env['ATTUNE_MCP_HTTP_ORIGINS'], 'https://console.example.com')
        self.assertEqual(env['ATTUNE_MCP_LISTEN_ADDR'], '0.0.0.0:9090')
        env = environment(container(render({'mcp': {'enabled': True, 'service': {'port': 9090}}})))
        self.assertEqual(env['ATTUNE_MCP_HTTP_HOSTS'], 'mcp-test-attune-mcp:9090')

    def test_custom_image_overrides_preserve_ca_contract(self):
        result = render({'mcp': {'enabled': True}, 'images': {
            'mcp': {'repository': 'custom/mcp', 'digest': '', 'tag': 'test'},
            'api': {'repository': 'custom/api', 'digest': '', 'tag': 'test'}}})
        self.assertEqual(container(result)['image'], 'ghcr.io/attune-system/custom/mcp:test')
        deployment = next(d for d in yaml.safe_load_all(result.stdout)
                          if d and d['kind'] == 'Deployment' and d['metadata']['name'] == 'mcp-test-attune-mcp')
        spec = deployment['spec']['template']['spec']
        init = spec['initContainers'][0]
        self.assertEqual(init['image'], 'ghcr.io/attune-system/custom/api:test')
        self.assertEqual(init['securityContext'], spec['containers'][0]['securityContext'])
        self.assertEqual(spec['securityContext']['fsGroup'], 1000)
        self.assertIn('test -s /etc/ssl/certs/ca-certificates.crt', init['args'][0])

    def test_reject_obsolete_auth_even_when_disabled(self):
        for auth in ({}, {'useBootstrapTestUser': True}, {'useBootstrapTestUser': False,
                     'existingSecret': 'shared-login'}):
            result = render({'mcp': {'auth': auth}})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('mcp.auth has been removed', result.stderr)

    def test_reject_ambiguous_allowlists(self):
        for field in ('hosts', 'origins'):
            for value in ('example.com', [1], [''], ['*'], ['a,b'], ['a b']):
                result = render({'mcp': {'http': {field: value}}})
                self.assertNotEqual(result.returncode, 0, (field, value))
                self.assertTrue('mcp.http.' + field in result.stderr or '/mcp/http/' + field in result.stderr, result.stderr)


@unittest.skipUnless(INTEGRATION, 'use --integration for pinned-image checks')
class ImageIntegration(unittest.TestCase):
    def test_startup_and_per_request_boundary(self):
        seen = []
        class API(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                token = self.headers.get('Authorization')
                seen.append((self.path, token))
                allowed = token in ('Bearer caller-a', 'Bearer caller-b')
                self.send_response(200 if allowed else 401)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                data = {'caller': token} if self.path == '/auth/me' else [{'caller': token}]
                self.wfile.write(json.dumps(({'data': data} if self.path == '/auth/me' else {'items': data}) if allowed else
                                            {'error': 'invalid token'}).encode())

        api = ThreadingHTTPServer(('0.0.0.0', 0), API)
        thread = threading.Thread(target=api.serve_forever, daemon=True)
        thread.start()
        c = container(render({'mcp': {'enabled': True}}))
        image = c['image']
        subprocess.run(['docker', 'pull', image], check=True, capture_output=True)
        info = subprocess.check_output(['docker', 'run', '--rm', '--entrypoint', c['command'][0],
                                        image, '--info', '--local'], text=True)
        provenance = json.loads((ROOT / 'docs/published-images-0.11.1.json').read_text())
        self.assertEqual(json.loads(info)['git_sha'], provenance['source_revision'])
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        # Execute the rendered CA init command with its exact image and user.
        deployment = next(d for d in yaml.safe_load_all(render({'mcp': {'enabled': True}}).stdout)
                          if d and d['kind'] == 'Deployment' and d['metadata']['name'] == 'mcp-test-attune-mcp')
        init = deployment['spec']['template']['spec']['initContainers'][0]
        bundle = tempfile.TemporaryDirectory(prefix='attune-mcp-ca-')
        Path(bundle.name).chmod(0o777)
        copy = ['docker', 'run', '--rm', '--user', '1000:1000', '--cap-drop', 'ALL',
                '--security-opt', 'no-new-privileges', '-v', bundle.name + ':/ca-bundle',
                '--entrypoint', init['command'][0], init['image'], *init['command'][1:], *init['args']]
        subprocess.run(copy, check=True, capture_output=True)
        self.assertGreater((Path(bundle.name) / 'ca-certificates.crt').stat().st_size, 1000)
        # A custom API image without the public bundle must stop the init.
        missing = copy.copy()
        missing[missing.index(init['image'])] = 'busybox:1.36'
        self.assertNotEqual(subprocess.run(missing, capture_output=True).returncode, 0)
        env = environment(c)
        # Only routing changes for the owned loopback fixture; auth/Host/Origin
        # values are taken directly from the rendered chart, never hand-invented.
        env['ATTUNE_API_URL'] = f'http://host.docker.internal:{api.server_port}'
        env['ATTUNE_MCP_LISTEN_ADDR'] = f'0.0.0.0:{port}'
        name = 'attune-chart-mcp-' + uuid.uuid4().hex

        def start(settings, mount_bundle=True):
            args = ['docker', 'run', '-d', '--name', name, '-p', f'127.0.0.1:{port}:{port}', '--user', '1000:1000',
                    '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                    '--entrypoint', c['command'][0]]
            if mount_bundle:
                args.extend(['-v', bundle.name + ':/etc/ssl/certs:ro'])
            if 'desktop' not in subprocess.check_output(['docker', 'info', '--format', '{{.OperatingSystem}}'], text=True).lower():
                args.extend(['--add-host', 'host.docker.internal:host-gateway'])
            for key, value in settings.items():
                args.extend(['-e', f'{key}={value}'])
            subprocess.run(args + [image], check=True, capture_output=True)

        def remove():
            subprocess.run(['docker', 'rm', '-f', name], check=True, capture_output=True)

        def request(host=None, token=None, origin=None, health=False, tool=False):
            conn = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
            headers = {'Host': host or env['ATTUNE_MCP_HTTP_HOSTS'], 'Content-Type': 'application/json'}
            if token is not None:
                headers['Authorization'] = token
            if origin is not None:
                headers['Origin'] = origin
            try:
                conn.request('GET' if health else 'POST', '/health' if health else '/mcp',
                             None if health else json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call' if tool else 'tools/list',
                                 **({'params': {'name': 'events_list', 'arguments': {}}} if tool else {})}), headers)
                response = conn.getresponse()
                return response.status, response.read()
            finally:
                conn.close()

        def ready():
            for _ in range(100):
                try:
                    if request(host=f'127.0.0.1:{port}', health=True)[0] == 200:
                        return
                except OSError:
                    pass
                time.sleep(.1)
            self.fail(subprocess.check_output(['docker', 'logs', name], stderr=subprocess.STDOUT, text=True))

        try:
            start(env, mount_bundle=False)
            self.assertNotEqual(subprocess.check_output(['docker', 'wait', name], text=True, timeout=30).strip(), '0')
            self.assertIn('No CA certificates were loaded', subprocess.check_output(
                ['docker', 'logs', name], stderr=subprocess.STDOUT, text=True))
            remove()
            start(env)
            ready()
            # Kubelet sends Pod IP:port, not Service Host: health is independent.
            self.assertEqual(request(host=f'127.0.0.1:{port}', health=True)[0], 200)
            self.assertEqual(request()[0], 401)
            for token in ('Basic caller-a', 'Bearer', 'Bearer bad token', 'Bearer invalid'):
                self.assertEqual(request(token=token)[0], 401)
            self.assertEqual(request(token='Bearer caller-a', origin='https://console.example.com')[0], 403)
            self.assertEqual(request(host='evil.example', token='Bearer caller-a')[0], 403)
            self.assertEqual(request(token='Bearer caller-a')[0], 200)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(lambda token: request(token='Bearer ' + token)[0],
                                        ['caller-a', 'caller-b'] * 8))
            self.assertEqual(results, [200] * 16)
            self.assertEqual(request()[0], 401)  # Never inherit the last caller.
            self.assertEqual({token for _, token in seen},
                             {'Bearer invalid', 'Bearer caller-a', 'Bearer caller-b'})
            for caller in ('caller-a', 'caller-b', 'caller-a'):
                status, body = request(token='Bearer ' + caller, tool=True)
                self.assertEqual(status, 200)
                self.assertIn(caller, body.decode())
                self.assertNotIn('caller-b' if caller == 'caller-a' else 'caller-a', body.decode())
            self.assertTrue(all(path == '/auth/me' or path.startswith('/events?') for path, _ in seen))
            remove()
            custom = environment(container(render({'mcp': {'enabled': True, 'http': {
                'hosts': ['mcp.example.com'], 'origins': ['https://console.example.com']}}})))
            custom.update({k: env[k] for k in ('ATTUNE_API_URL', 'ATTUNE_MCP_LISTEN_ADDR')})
            start(custom)
            ready()
            self.assertEqual(request(host='mcp.example.com', origin='https://console.example.com', token='Bearer caller-b')[0], 200)
            self.assertEqual(request(host='mcp.example.com', token='Bearer caller-b')[0], 200)
            self.assertEqual(request(host='mcp.example.com', origin='https://evil.example', token='Bearer caller-b')[0], 403)
            self.assertEqual(request(token='Bearer caller-b')[0], 403)
            remove()
            # Exercise TLS verification, first rejecting an untrusted fixture CA,
            # then trusting only its public certificate in the same bundle path.
            cert = Path(bundle.name) / 'fixture.pem'
            key = Path(bundle.name) / 'fixture.key'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', str(key), '-out', str(cert), '-days', '1',
                            '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:host.docker.internal'],
                           check=True, capture_output=True)
            tls_api = ThreadingHTTPServer(('0.0.0.0', 0), API)
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(cert, key)
            tls_api.socket = tls.wrap_socket(tls_api.socket, server_side=True)
            tls_thread = threading.Thread(target=tls_api.serve_forever, daemon=True)
            tls_thread.start()
            try:
                tls_env = dict(env, ATTUNE_API_URL=f'https://host.docker.internal:{tls_api.server_port}')
                start(tls_env)
                ready()
                self.assertEqual(request(token='Bearer caller-a')[0], 401)
                remove()
                ca_file = Path(bundle.name) / 'ca-certificates.crt'
                ca_file.chmod(0o644)
                ca_file.write_bytes(ca_file.read_bytes() + cert.read_bytes())
                ca_file.chmod(0o444)
                start(tls_env)
                ready()
                self.assertEqual(request(token='Bearer caller-a')[0], 200)
                remove()
            finally:
                tls_api.shutdown()
                tls_api.server_close()
                tls_thread.join()
            for forbidden in ({'ATTUNE_LOGIN': 'shared', 'ATTUNE_PASSWORD': 'shared'},
                              {'ATTUNE_AUTH_TOKEN': 'shared'}, {'ATTUNE_PROFILE': 'shared'}):
                start(dict(env, **forbidden))
                code = subprocess.check_output(['docker', 'wait', name], text=True, timeout=30).strip()
                self.assertNotEqual(code, '0')
                self.assertIn('remove startup credentials/profile', subprocess.check_output(['docker', 'logs', name], stderr=subprocess.STDOUT, text=True))
                remove()
        finally:
            subprocess.run(['docker', 'rm', '-f', name], capture_output=True)
            api.shutdown()
            api.server_close()
            thread.join()
            bundle.cleanup()


if __name__ == '__main__':
    unittest.main()
