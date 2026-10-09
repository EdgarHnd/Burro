# Isolated cross-platform parser/probe fixtures; no SSH connections or provider accounts are used.
import calendar
from contextlib import closing
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

PROBE = Path(__file__).resolve().parents[1] / 'Sources/BurroCore/Resources/remote_probe.py'
spec = importlib.util.spec_from_file_location('probe', PROBE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProbeTests(unittest.TestCase):
    def test_shared_status_fixtures(self):
        fixtures = json.loads((PROBE.parents[3] / 'policy/status-fixtures.json').read_text())
        for case in fixtures['codex']:
            with self.subTest(case=case):
                self.assertEqual(probe.codex_state(case['tail'], case['held'], 10000 - case['age'], 10000), case['state'])
                self.assertEqual(probe.codex_completed(case['tail']), case['completed'])
        for case in fixtures['claude']:
            self.assertEqual(probe.claude_state(case['status'], case['live']), case['state'])

    def test_history_limit_prioritizes_recent_chats_across_providers(self):
        with tempfile.TemporaryDirectory(prefix='burro-today-limit-') as directory:
            home = Path(directory); codex = home / '.codex'; codex.mkdir()
            now = time.time()
            rollout = codex / 'done.jsonl'
            rollout.write_text(json.dumps({'type': 'event_msg', 'payload': {'type': 'task_complete'}}))
            with closing(sqlite3.connect(codex / 'state_7.sqlite')) as db, db:
                db.execute('CREATE TABLE threads (id TEXT,cwd TEXT,title TEXT,updated_at REAL,rollout_path TEXT,archived INTEGER)')
                db.executemany('INSERT INTO threads VALUES (?,?,?,?,?,0)', [
                    ('old-1', '/repo', 'Old result', now - 3 * 86400, str(rollout)),
                    ('old-2', '/repo', 'Older result', now - 4 * 86400, str(rollout))])
            registry = home / '.claude/sessions'; registry.mkdir(parents=True)
            (registry / 'recent.json').write_text(json.dumps(dict(
                sessionId='recent', cwd='/repo', pid=123, status='idle', updatedAt=(now - 3600) * 1000)))
            with patch.object(probe, 'claude_identity', return_value=False), patch.object(probe, 'LIMIT', 2):
                result = probe.collect(home)
            self.assertEqual([s['id'] for s in result['sessions']], ['claude:recent', 'codex:old-1'])
            self.assertIn('Remote sessions exceed the inspection limit.', result['warnings'])

    def test_recent_closed_chats_are_retained_for_viewer_local_today(self):
        with tempfile.TemporaryDirectory(prefix='burro-today-') as directory:
            home = Path(directory); codex = home / '.codex'; codex.mkdir()
            now = time.time()
            rollout = codex / 'aborted.jsonl'
            rollout.write_text(json.dumps({'type': 'event_msg', 'payload': {'type': 'task_aborted'}}))
            os.utime(rollout, (now - 3600, now - 3600))
            with closing(sqlite3.connect(codex / 'state_7.sqlite')) as db, db:
                db.execute('CREATE TABLE threads (id TEXT,cwd TEXT,title TEXT,updated_at REAL,rollout_path TEXT,archived INTEGER)')
                db.executemany('INSERT INTO threads VALUES (?,?,?,?,?,0)', [
                    ('recent', '/repo', 'Recent closed chat', now - 3600, str(rollout)),
                    ('old', '/repo', 'Old closed chat', now - 3 * 86400, str(rollout))])
            registry = home / '.claude/sessions'; registry.mkdir(parents=True)
            for sid, age in [('recent', 3600), ('old', 3 * 86400)]:
                (registry / (sid + '.json')).write_text(json.dumps(dict(
                    sessionId=sid, cwd='/repo', pid=123, status='idle', name='Closed Claude',
                    updatedAt=(now - age) * 1000)))
            with patch.object(probe, 'claude_identity', return_value=False):
                sessions = probe.collect(home)['sessions']
            self.assertEqual({s['id'] for s in sessions}, {'codex:recent', 'claude:recent'})
            self.assertTrue(all(s['state'] == 'Inactive' for s in sessions))
            self.assertTrue(all(not s['turnCompleted'] for s in sessions))

    def worker_event(self, sid, agent='worker-a', age=0, stop='tool_use', started=None):
        from datetime import datetime, timezone
        stamp = time.time() - age if started is None else started
        return json.dumps(dict(type='assistant', isSidechain=True, sessionId=sid, agentId=agent,
                               timestamp=datetime.fromtimestamp(stamp, timezone.utc).isoformat(),
                               message=dict(stop_reason=stop, content='PRIVATE BODY')))

    def test_worker_lifecycle_requires_explicit_identity_and_current_incarnation(self):
        sid = '11111111-2222-4333-8444-555555555555'
        now = time.time()
        parse = lambda text, modified=now: probe.claude_worker_tail_state(text, sid, 'worker-a', now - 60, now, modified)
        running = self.worker_event(sid)
        self.assertEqual(parse(running), 'Working')
        self.assertIsNone(parse(running + '\n' + self.worker_event(sid, stop='end_turn')))
        self.assertIsNone(parse(running.replace(sid, 'another-session')))
        self.assertIsNone(parse(running.replace('worker-a', 'different-agent')))
        self.assertIsNone(parse(running.replace('true', 'false')))
        self.assertIsNone(parse(self.worker_event(sid, age=120)))
        self.assertEqual(parse(running, now - 130), 'Unknown')
        self.assertEqual(parse(self.worker_event(sid, started=now + 3600)), 'Unknown')
        self.assertEqual(parse('truncated lifecycle envelope'), 'Unknown')

    def test_worker_discovery_handles_more_than_256_projects(self):
        sid = '11111111-2222-4333-8444-555555555555'
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            root = home / '.claude/projects'
            root.mkdir(parents=True)
            for i in range(270):
                (root / str(i)).mkdir()
            now = time.time()
            self.assertEqual(probe.claude_worker_states(home, sid, now - 60, now, time.monotonic() + 5), [])
            folder = root / '269' / sid / 'subagents'
            folder.mkdir(parents=True)
            (folder / 'agent-worker-a.jsonl').write_text(self.worker_event(sid))
            self.assertEqual(probe.claude_worker_states(home, sid, now - 60, now, time.monotonic() + 5), ['Working'])

    def test_stale_unfinished_worker_remains_unknown_until_terminal_event(self):
        sid = '11111111-2222-4333-8444-555555555555'
        now = time.time()
        old = self.worker_event(sid, age=300)
        self.assertEqual(probe.claude_worker_tail_state(old, sid, 'worker-a', now - 600, now, now - 300), 'Unknown')
        done = old + '\n' + self.worker_event(sid, age=200, stop='end_turn')
        self.assertIsNone(probe.claude_worker_tail_state(done, sid, 'worker-a', now - 600, now, now - 200))

    def test_task_descriptors_require_writable_owned_session_output(self):
        sid = '11111111-2222-4333-8444-555555555555'
        path = f'/private/tmp/claude-{os.getuid()}/project/{sid}/tasks/task-a.output'
        lines = f'p11\nf1\naw\nn{path}\nf2\naw\nn{path}\n'
        self.assertEqual(probe.claude_task_descriptors(lines, sid, {11}), {'task-a'})
        self.assertEqual(probe.claude_task_descriptors(lines, sid, {22}), set())
        self.assertEqual(probe.claude_task_descriptors(lines.replace('aw', 'ar'), sid, {11}), set())
        self.assertEqual(probe.claude_task_descriptors(lines, 'other-session', {11}), set())
        self.assertIsNone(probe.claude_task_id(path.replace('tasks', 'scratchpad'), sid))
        self.assertIsNone(probe.claude_task_id(path.replace('/private/tmp/', '/untrusted/'), sid))
        self.assertIsNone(probe.claude_task_id(path.replace('task-a.output', 'task-a.output (deleted)'), sid))
        self.assertIsNone(probe.claude_task_id('/dev/pipe', sid))
        self.assertEqual(probe.claude_descendants(10, {10: 1, 11: 10, 12: 11, 13: 99}), {11, 12})

    def test_handback_ends_worker_and_new_activity_can_resume_it(self):
        sid = '11111111-2222-4333-8444-555555555555'
        now = time.time()
        event = json.loads(self.worker_event(sid, age=300))
        event.update(type='user', toolEndsTurn=True, message={'role': 'user', 'content': [{'type': 'tool_result'}]})
        done = json.dumps(event)
        parse = lambda text: probe.claude_worker_tail_state(text, sid, 'worker-a', now - 600, now, now)
        self.assertIsNone(parse(done))
        self.assertIsNone(probe.claude_worker_tail_state(done, sid, 'worker-a', now - 600, now, now - 300))
        self.assertEqual(parse(done + '\n' + self.worker_event(sid)), 'Working')
        self.assertEqual(parse(done + '\n' + self.worker_event(sid, age=121)), 'Unknown')
        for value in [False, 1, 'true', None]:
            self.assertEqual(parse(json.dumps(dict(event, toolEndsTurn=value))), 'Unknown')
        no_result = dict(event, message={'content': [{'type': 'text', 'text': 'toolEndsTurn: true'}]})
        self.assertEqual(parse(json.dumps(no_result)), 'Unknown')
        self.assertIsNone(parse(done.replace(sid, 'another-session')))
        self.assertIsNone(parse(done.replace('worker-a', 'another-worker')))
        self.assertIsNone(probe.claude_worker_tail_state(done, sid, 'worker-a', now - 60, now, now))

    def test_background_descriptor_probe_deduplicates_tasks_and_ignores_helpers(self):
        sid = '11111111-2222-4333-8444-555555555555'
        path = f'/tmp/claude-{os.getuid()}/project/{sid}/tasks/task-a.output'
        result = subprocess.CompletedProcess([], 0, f'p11\nf1\naw\nn{path}\np12\nf1\naw\nn/dev/pipe\n', '')
        with patch.object(probe.sys, 'platform', 'darwin'), patch.object(probe.subprocess, 'run', return_value=result) as run:
            self.assertEqual(probe.claude_background_tasks(10, sid, {10: 1, 11: 10, 12: 10, 99: 88}), {'task-a'})
            self.assertIn('11,12', run.call_args.args[0])
            self.assertNotIn('99', run.call_args.args[0])

    def test_linux_background_probe_checks_writable_descriptors_without_reading_output(self):
        sid = '11111111-2222-4333-8444-555555555555'
        output = f'/tmp/claude-{os.getuid()}/project/{sid}/tasks/task-a.output'
        with patch.object(probe.sys, 'platform', 'linux'), patch.object(Path, 'read_text', return_value='flags: 0100001\n'), patch.object(probe.os, 'readlink', return_value=output):
            self.assertEqual(probe.claude_background_tasks(10, sid, {10: 1, 11: 10}), {'task-a'})
        with patch.object(probe.sys, 'platform', 'linux'), patch.object(Path, 'read_text', return_value='flags: 0100000\n'), patch.object(probe.os, 'readlink') as links:
            self.assertEqual(probe.claude_background_tasks(10, sid, {10: 1, 11: 10}), set())
            links.assert_not_called()
        with patch.object(probe.sys, 'platform', 'linux'), patch.object(Path, 'read_text', side_effect=PermissionError()):
            with self.assertRaises(OSError):
                probe.claude_background_tasks(10, sid, {10: 1, 11: 10})

    def delegated_fixture(self, home):
        sid = '11111111-2222-4333-8444-555555555555'
        registry = home / '.claude/sessions'; registry.mkdir(parents=True)
        metadata = home / 'Library/Application Support/Claude/claude-code-sessions/account/org'
        metadata.mkdir(parents=True)
        (metadata / 'local_fixture.json').write_text(json.dumps(dict(sessionId='local_fixture', completedTurns=1, isArchived=False)))
        record = dict(sessionId=sid, cwd='/repo', pid=123, status='idle', hostSessionId='local_fixture',
                      startedAt=(time.time() - 600) * 1000, updatedAt=time.time() * 1000)
        (registry / 'fixture.json').write_text(json.dumps(record))
        return sid, registry / 'fixture.json', record

    def test_collect_idle_parent_stays_working_for_background_task_then_completes(self):
        with tempfile.TemporaryDirectory(prefix='burro-delegated-') as directory:
            home = Path(directory); sid, path, record = self.delegated_fixture(home)
            with patch.object(probe, 'claude_identity', return_value=True), patch.object(probe, 'claude_process_tree', return_value={123: 1, 124: 123}), patch.object(probe, 'claude_background_tasks', return_value={'task-a': {124}}) as tasks:
                result = probe.collect(home)
                self.assertEqual(len(result['sessions']), 1)
                self.assertEqual(result['sessions'][0]['state'], 'Working')
                self.assertFalse(result['sessions'][0]['turnCompleted'])
                self.assertIn('1 active delegated task', result['sessions'][0]['evidence'])
                tasks.return_value = set()
                result = probe.collect(home)
                self.assertEqual(result['sessions'][0]['state'], 'Open · idle')
                self.assertTrue(result['sessions'][0]['turnCompleted'])

    def test_remote_scheduled_task_uses_owned_branch_and_executable_names(self):
        rows = {10: 1, 11: 10, 12: 11, 13: 10}
        names = subprocess.CompletedProcess([], 0, '11 /bin/zsh\n12 sleep\n', '')
        with patch.object(probe.subprocess, 'run', return_value=names):
            self.assertTrue(probe.claude_scheduled_tasks({'task': {11, 12}}, rows))
            names.stdout = '11 /bin/zsh\n12 /usr/bin/python3\n'
            self.assertFalse(probe.claude_scheduled_tasks({'task': {11, 12}}, rows))
            names.stdout = '11 /usr/bin/node\n12 sleep\n'
            self.assertFalse(probe.claude_scheduled_tasks({'task': {11, 12}}, rows))
            names.stdout = '11 /bin/zsh\n12 sleep\n13 /usr/bin/python3\n'
            self.assertFalse(probe.claude_scheduled_tasks({'task': {11, 12}, 'other': {13}}, rows))

    def test_collect_scheduled_stays_visible_without_done_and_returns_to_running(self):
        with tempfile.TemporaryDirectory(prefix='burro-scheduled-') as directory:
            home = Path(directory); sid, path, record = self.delegated_fixture(home)
            with patch.object(probe, 'claude_identity', return_value=True), patch.object(probe, 'claude_process_tree', return_value={123: 1, 124: 123}), patch.object(probe, 'claude_background_tasks', return_value={'task-a': {124}}), patch.object(probe, 'claude_scheduled_tasks', return_value=True) as scheduled:
                result = probe.collect(home)['sessions'][0]
                self.assertEqual(result['state'], 'Scheduled')
                self.assertFalse(result['turnCompleted'])
                self.assertIn('live sleep delay', result['evidence'])
                scheduled.return_value = False
                self.assertEqual(probe.collect(home)['sessions'][0]['state'], 'Working')

    def test_collect_waiting_parent_is_not_hidden_by_background_work(self):
        with tempfile.TemporaryDirectory(prefix='burro-delegated-') as directory:
            home = Path(directory); sid, path, record = self.delegated_fixture(home)
            record['status'] = 'waiting_for_permission'; path.write_text(json.dumps(record))
            with patch.object(probe, 'claude_identity', return_value=True), patch.object(probe, 'claude_background_tasks') as tasks:
                result = probe.collect(home)
                self.assertEqual(result['sessions'][0]['state'], 'Needs input')
                self.assertFalse(result['sessions'][0]['turnCompleted'])
                tasks.assert_not_called()

    def test_collect_real_worker_file_promotes_parent_but_completed_and_foreign_workers_do_not(self):
        with tempfile.TemporaryDirectory(prefix='burro-delegated-') as directory:
            home = Path(directory); sid, path, record = self.delegated_fixture(home)
            workers = home / '.claude/projects/project' / sid / 'subagents'; workers.mkdir(parents=True)
            worker = workers / 'agent-worker-a.jsonl'
            worker.write_text(self.worker_event(sid))
            with patch.object(probe, 'claude_identity', return_value=True), patch.object(probe, 'claude_process_tree', return_value={123: 1}), patch.object(probe, 'claude_background_tasks', return_value=set()):
                result = probe.collect(home)
                self.assertEqual(result['sessions'][0]['state'], 'Working')
                self.assertNotIn('PRIVATE BODY', json.dumps(result))
                worker.write_text(self.worker_event(sid, stop='end_turn'))
                self.assertEqual(probe.collect(home)['sessions'][0]['state'], 'Open · idle')
                worker.write_text(self.worker_event('other-session'))
                self.assertEqual(probe.collect(home)['sessions'][0]['state'], 'Open · idle')
                worker.write_text(self.worker_event(sid, age=1200))
                self.assertEqual(probe.collect(home)['sessions'][0]['state'], 'Open · idle')

    def test_collect_dead_or_reused_parent_never_inherits_worker_activity(self):
        with tempfile.TemporaryDirectory(prefix='burro-delegated-') as directory:
            home = Path(directory); sid, path, record = self.delegated_fixture(home)
            with patch.object(probe, 'claude_identity', return_value=False), patch.object(probe, 'claude_delegated_state') as delegated:
                result = probe.collect(home)
                self.assertEqual(result['sessions'][0]['state'], 'Inactive')
                self.assertTrue(result['sessions'][0]['turnCompleted'])
                delegated.assert_not_called()
            with patch.object(probe, 'claude_identity', side_effect=[True, None]), patch.object(probe, 'claude_process_tree', return_value={123: 1}), patch.object(probe, 'claude_delegated_state', return_value=('Working', 1)):
                result = probe.collect(home)
                self.assertEqual(result['sessions'][0]['state'], 'Unknown')
                self.assertFalse(result['sessions'][0]['turnCompleted'])

    def test_incomplete_visibility_never_acknowledges_idle_parent_as_done(self):
        with tempfile.TemporaryDirectory(prefix='burro-delegated-') as directory:
            home = Path(directory); sid, path, record = self.delegated_fixture(home)
            with patch.object(probe, 'claude_identity', return_value=True), patch.object(probe, 'claude_process_tree', side_effect=OSError()):
                result = probe.collect(home)
                self.assertEqual(result['sessions'][0]['state'], 'Unknown')
                self.assertFalse(result['sessions'][0]['turnCompleted'])
                self.assertTrue(result['warnings'])

    def test_parent_identity_is_explicit_and_validated(self):
        sid = '11111111-2222-4333-8444-555555555555'
        source = json.dumps({'subagent': {'thread_spawn': {'parent_thread_id': sid}}})
        self.assertEqual(probe.codex_parent_id(source), 'codex:' + sid)
        for invalid in [None, 'vscode', '{}', '{"subagent":{"other":"guardian"}}', source.replace(sid, '../bad')]:
            self.assertIsNone(probe.codex_parent_id(invalid))

    def test_event_states_need_live_evidence(self):
        start = json.dumps({'type': 'event_msg', 'payload': {'type': 'task_started'}})
        stop = json.dumps({'type': 'event_msg', 'payload': {'type': 'task_complete'}})
        self.assertEqual(probe.codex_state(start, 1, 100, 101), 'Working')
        self.assertEqual(probe.codex_state(start, 0, 100, 101), 'Recent activity')
        self.assertEqual(probe.codex_state(start, 0, 100, 1000), 'Inactive')
        self.assertEqual(probe.codex_state(start + '\n' + stop, 1, 100, 101), 'Open · idle')
        self.assertEqual(probe.codex_state(start + '\n' + stop, 0, 100, 101), 'Inactive')
        self.assertEqual(probe.codex_state(start, -1, 100, 101), 'Unknown')

    def test_claude_dead_or_uncertain_identity_never_looks_working(self):
        self.assertEqual(probe.claude_state('working', False), 'Inactive')
        self.assertEqual(probe.claude_state('working', None), 'Unknown')
        self.assertEqual(probe.claude_state('waiting_for_permission', True), 'Needs input')
        self.assertEqual(probe.claude_state('future_status', True), 'Unknown')

    def test_mac_and_linux_ps_identity_fixtures(self):
        start = 1800000000
        local = time.strftime('%a %b %d %H:%M:%S %Y', time.localtime(start))
        utc = time.strftime('%a %b %d %H:%M:%S %Y', time.gmtime(start))
        for executable in ['/usr/local/bin/claude', '/home/user/.local/share/claude/versions/2.1.0']:
            response = subprocess.CompletedProcess([], 0, f'{os.getuid()} {local} {executable}\n', '')
            with patch.object(probe.subprocess, 'run', return_value=response):
                self.assertTrue(probe.claude_identity(1234, utc))
                self.assertIsNone(probe.claude_identity(1234, time.strftime('%a %b %d %H:%M:%S %Y', time.gmtime(start - 60))))
        response = subprocess.CompletedProcess([], 0, f'{os.getuid()} {local} /usr/bin/python3\n', '')
        with patch.object(probe.subprocess, 'run', return_value=response):
            self.assertFalse(probe.claude_identity(1234, utc))

    def test_unreadable_identity_is_unknown(self):
        with patch.object(probe.subprocess, 'run', side_effect=subprocess.TimeoutExpired('ps', 1)):
            self.assertIsNone(probe.claude_identity(1234, 'fixture'))
        self.assertIsNone(probe.claude_identity(-1, 'fixture'))

    def test_read_only_probe_fixture_and_no_transcript_body_in_output(self):
        with tempfile.TemporaryDirectory(prefix='burro-probe-') as directory:
            home = Path(directory)
            codex = home / '.codex'; codex.mkdir()
            locks = codex / 'thread-writer-locks'; locks.mkdir()
            rollout = codex / 'fixture.jsonl'
            rollout.write_text(json.dumps({'type': 'event_msg', 'payload': {'type': 'task_started'}}) + '\n' +
                               json.dumps({'type': 'response_item', 'payload': {'content': 'PRIVATE PROMPT BODY'}}) + '\n')
            database = codex / 'state_7.sqlite'
            with closing(sqlite3.connect(database)) as db, db:
                db.execute('CREATE TABLE threads (id TEXT,cwd TEXT,title TEXT,updated_at REAL,rollout_path TEXT,archived INTEGER)')
                db.execute('INSERT INTO threads VALUES (?,?,?,?,?,0)', ('fixture', '/remote/space path', 'Codex fixture', time.time(), str(rollout)))
            before = database.read_bytes()
            with open(locks / 'fixture.lock', 'wb') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                result = subprocess.run([sys.executable, '-B', str(PROBE), '--home', directory], capture_output=True, text=True, check=True)
            self.assertNotIn('PRIVATE PROMPT BODY', result.stdout)
            snapshot = json.loads(result.stdout)
            self.assertEqual(snapshot['sessions'][0]['state'], 'Working')
            self.assertEqual(snapshot['sessions'][0]['cwd'], '/remote/space path')
            self.assertEqual(before, database.read_bytes())
            self.assertEqual(snapshot['warnings'], [])

    def test_closed_completed_history_is_exported_without_viewer_ids(self):
        with tempfile.TemporaryDirectory(prefix='burro-probe-') as directory:
            home = Path(directory); codex = home / '.codex'; codex.mkdir()
            rollout = codex / 'done.jsonl'
            rollout.write_text(json.dumps({'type': 'event_msg', 'payload': {'type': 'task_complete'}}))
            with closing(sqlite3.connect(codex / 'state_7.sqlite')) as db, db:
                db.execute('CREATE TABLE threads (id TEXT,cwd TEXT,title TEXT,updated_at REAL,rollout_path TEXT,archived INTEGER)')
                db.executemany('INSERT INTO threads VALUES (?,?,?,?,?,0)', [(f'fixture-{i}', '/repo', 'Done', i, str(rollout)) for i in range(3)])
            result = probe.collect(home)
            self.assertEqual(len(result['sessions']), 3)
            self.assertEqual(len({s['id'] for s in result['sessions']}), 3)
            self.assertEqual(result['sessions'][0]['state'], 'Inactive')
            self.assertTrue(result['sessions'][0]['turnCompleted'])
            self.assertNotIn('hasUnreadResult', result['sessions'][0])
            rollout.write_text(json.dumps({'type': 'event_msg', 'payload': {'type': 'task_aborted'}}))
            self.assertFalse(probe.codex_completed(rollout.read_text()))
            self.assertEqual(probe.collect(home)['sessions'], [])
            with closing(sqlite3.connect(codex / 'state_7.sqlite')) as db, db:
                db.execute('DELETE FROM threads')
            self.assertEqual(probe.collect(home)['sessions'], [])

    def test_claude_completion_requires_finished_turn_and_idle(self):
        with tempfile.TemporaryDirectory(prefix='burro-probe-') as directory:
            home = Path(directory)
            registry = home / '.claude/sessions'; registry.mkdir(parents=True)
            metadata = home / 'Library/Application Support/Claude/claude-code-sessions/account/org'
            metadata.mkdir(parents=True)
            (metadata / 'local_fixture.json').write_text(json.dumps(dict(sessionId='local_fixture', completedTurns=1, isArchived=False)))
            record = dict(sessionId='cli-fixture', cwd='/repo', pid=123, status='idle', hostSessionId='local_fixture')
            (registry / 'fixture.json').write_text(json.dumps(record))
            with patch.object(probe, 'claude_identity', return_value=True), patch.object(probe, 'claude_process_tree', return_value={123: 1}):
                self.assertTrue(probe.collect(home)['sessions'][0]['turnCompleted'])
                record['status'] = 'busy'
                (registry / 'fixture.json').write_text(json.dumps(record))
                self.assertFalse(probe.collect(home)['sessions'][0]['turnCompleted'])

    def test_checkpoint_fallback_refuses_live_journals(self):
        with tempfile.TemporaryDirectory(prefix='burro-probe-') as directory:
            database = Path(directory) / 'state.sqlite'
            with closing(sqlite3.connect(database)) as db, db:
                db.execute('CREATE TABLE threads (id TEXT,cwd TEXT,title TEXT,updated_at REAL,rollout_path TEXT,archived INTEGER)')
            original = sqlite3.connect
            calls = []
            def blocked_sidecars(location, **kwargs):
                calls.append(location)
                if 'immutable=1' not in location:
                    raise sqlite3.OperationalError('unable to open database file')
                return original(location, **kwargs)
            with patch.object(probe.sqlite3, 'connect', side_effect=blocked_sidecars):
                self.assertEqual(probe.codex_rows(database), [])
                self.assertIn('immutable=1', calls[-1])
                Path(str(database) + '-wal').write_bytes(b'live')
                calls.clear()
                with self.assertRaises(sqlite3.OperationalError):
                    probe.codex_rows(database)
                self.assertEqual(len(calls), 1)

    def test_internal_children_never_export_closed_done_history(self):
        child = json.dumps({'subagent': {'thread_spawn': {'parent_thread_id': 'parent', 'depth': 1}}})
        self.assertTrue(probe.codex_is_subagent(child))
        self.assertTrue(probe.codex_is_subagent('{"subagent":{"other":"guardian"}}'))
        self.assertFalse(probe.codex_is_subagent('vscode'))
        with tempfile.TemporaryDirectory(prefix='burro-identity-') as directory:
            home = Path(directory); codex = home / '.codex'; codex.mkdir()
            rollout = codex / 'done.jsonl'
            rollout.write_text(json.dumps({'type': 'event_msg', 'payload': {'type': 'task_complete'}}))
            with closing(sqlite3.connect(codex / 'state_5.sqlite')) as db, db:
                db.execute('CREATE TABLE threads (id TEXT,cwd TEXT,title TEXT,name TEXT,source TEXT,updated_at REAL,rollout_path TEXT,archived INTEGER)')
                db.executemany('INSERT INTO threads VALUES (?,?,?,?,?,?,?,0)', [
                    ('chat', '/repo', 'Original prompt', 'Displayed chat name', 'vscode', 1, str(rollout)),
                    ('untitled', '/repo', '', '', 'vscode', 1, str(rollout)),
                    ('blank-worker', '/repo', '', '', child, 1, str(rollout)),
                    ('named-worker', '/repo', 'Task instruction', 'Worker name', child, 1, str(rollout))])
            result = probe.collect(home)
            self.assertEqual({s['id'] for s in result['sessions']}, {'codex:chat', 'codex:untitled'})
            self.assertEqual({s['title'] for s in result['sessions']}, {'Displayed chat name', 'Untitled chat'})
            self.assertTrue(all(not s['isSubagent'] for s in result['sessions']))
            rollout.write_text(json.dumps({'type': 'event_msg', 'payload': {'type': 'task_started'}}))
            with patch.object(probe, 'held_lock', return_value=1):
                live = probe.collect(home)['sessions']
            self.assertEqual(len(live), 4)
            self.assertEqual(sum(s['isSubagent'] for s in live), 2)
            self.assertTrue(all(s['state'] == 'Working' for s in live))

    def test_provider_schema_failures_report_limited_visibility(self):
        with tempfile.TemporaryDirectory(prefix='burro-probe-') as directory:
            home = Path(directory)
            (home / '.codex').mkdir()
            (home / '.claude').mkdir()
            result = probe.collect(home)
            self.assertEqual(result['sessions'], [])
            self.assertEqual(len(result['warnings']), 2)

    def test_claude_navigation_ids_survive_remote_probe_without_session_content(self):
        with tempfile.TemporaryDirectory(prefix='burro-probe-') as directory:
            home = Path(directory)
            registry = home / '.claude/sessions'
            registry.mkdir(parents=True)
            record = dict(sessionId='cli-session', cwd='/remote/workspace', pid=123, procStart='fixture',
                          status='busy', hostSessionId='local_desktop', bridgeSessionId='session_remote',
                          unrelated='PRIVATE CONTENT')
            (registry / 'fixture.json').write_text(json.dumps(record))
            with patch.object(probe, 'claude_identity', return_value=True):
                result = probe.collect(home)
            self.assertEqual(result['sessions'][0]['claudeDesktopSessionID'], 'local_desktop')
            self.assertEqual(result['sessions'][0]['claudeBridgeSessionID'], 'session_remote')
            self.assertNotIn('PRIVATE CONTENT', json.dumps(result))
            record['hostSessionId'] = {'unexpected': 'object'}
            record['bridgeSessionId'] = 'x' * 129
            (registry / 'fixture.json').write_text(json.dumps(record))
            with patch.object(probe, 'claude_identity', return_value=True):
                result = probe.collect(home)
            self.assertNotIn('claudeDesktopSessionID', result['sessions'][0])
            self.assertNotIn('claudeBridgeSessionID', result['sessions'][0])


if __name__ == '__main__':
    unittest.main()
