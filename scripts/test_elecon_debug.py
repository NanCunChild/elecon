"""Synthetic file-protocol integration tests; no ADB devices or school data."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = Path(__file__).with_name('elecon-debug.py')
spec = importlib.util.spec_from_file_location('elecon_debug', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DebugCliTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='elecon-cli-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ['inbox', 'results', 'logs']:
            (self.root / name).mkdir()
        (self.root / 'status.json').write_text(json.dumps({'profileId': 'default', 'locked': False}))
        self.received = []
        self.stop = threading.Event()
        self.worker = threading.Thread(target=self.consume, daemon=True)
        self.worker.start()
        self.addCleanup(self.finish)

    def finish(self):
        self.stop.set()
        self.worker.join(timeout=2)

    def consume(self):
        while not self.stop.wait(0.01):
            for file in (self.root / 'inbox').glob('*.json'):
                command = json.loads(file.read_text())
                self.received.append(command)
                target = self.root / 'results' / file.name
                file.unlink()
                temporary = target.with_suffix('.tmp')
                temporary.write_text(json.dumps({'result': 'ok'}))
                temporary.replace(target)

    def cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), '--local', str(self.root), *args],
                              capture_output=True, timeout=5)

    def package(self, path, source='export const capabilities = {};'):
        path.write_text(json.dumps({'format': 'elecon-script/1', 'manifest': {'id': 'synthetic'},
                                   'source': source}, ensure_ascii=False), encoding='utf-8')

    def until(self, count):
        deadline = time.monotonic() + 4
        while len(self.received) < count and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertGreaterEqual(len(self.received), count)

    def test_put_pins_profile_and_hashes_exact_unicode_source(self):
        package = self.root / 'example.elecon.json'
        self.package(package, '中文\r\nsource')
        package.write_bytes(package.read_bytes().replace(b', ', b',\r\n '))
        result = self.cli('put', str(package))
        self.assertEqual(result.returncode, 0, result.stderr)
        command = self.received[0]
        self.assertEqual(command['profileId'], 'default')
        self.assertEqual(command['package'], package.read_bytes().decode('utf-8'))
        self.assertEqual(command['sha256'], hashlib.sha256(command['package'].encode()).hexdigest())
        self.assertEqual(list((self.root / 'results').iterdir()), [])
        rejected = self.cli('--profile', 'another', 'remove', 'synthetic')
        self.assertEqual(rejected.returncode, 1)
        self.assertEqual(len(self.received), 1)

    def test_watch_detects_add_modify_delete_and_never_removes_other_ids(self):
        directory = self.root / 'packages'
        directory.mkdir()
        process = subprocess.Popen([sys.executable, str(SCRIPT), '--local', str(self.root),
                                    'sync', str(directory), '--watch'], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        try:
            package = directory / 'example.elecon.json'
            self.package(package)
            self.until(1)
            package.write_text('{incomplete')
            time.sleep(1.3)
            self.assertIsNone(process.poll())
            self.assertEqual(len(self.received), 1)
            self.package(package, 'changed source')
            self.until(2)
            package.unlink()
            self.until(3)
            self.assertEqual([c['operation'] for c in self.received], ['upsert', 'upsert', 'remove'])
            self.assertEqual(self.received[2]['packageId'], 'synthetic')
            self.assertNotEqual(self.received[0]['sha256'], self.received[1]['sha256'])
        finally:
            process.terminate()
            process.wait(timeout=3)

    def test_logs_export_all_retained_records_without_line_truncation(self):
        expected = b''
        for index in [3, 2, 1, 0]:
            content = (json.dumps({'message': '中' * 12000, 'index': index}, ensure_ascii=False) + '\n').encode()
            suffix = f'.{index}' if index else ''
            (self.root / 'logs' / f'dev-log.jsonl{suffix}').write_bytes(content)
            expected += content
        output = self.root / 'export.jsonl'
        result = self.cli('logs', '--output', str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), expected)


if __name__ == '__main__':
    unittest.main()
