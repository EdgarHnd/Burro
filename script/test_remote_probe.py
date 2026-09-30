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
    def test_delivery_git_evidence(self):
        with tempfile.TemporaryDirectory() as path:
            def git(*args):
                subprocess.run(['git', '-C', path, *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            git('init', '-b', 'main')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            git('config', 'remote.origin.url', path)
            git('config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
            git('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'initial')
            check = lambda: probe.delivery_status(path, time.monotonic() + 5)
            self.assertEqual(check(), 'Needs push')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            git('branch', '--set-upstream-to=origin/main')
            self.assertEqual(check(), 'Done')
            git('checkout', '-b', 'feature')
            git('update-ref', 'refs/remotes/origin/feature', 'HEAD')
            git('branch', '--set-upstream-to=origin/feature')
            self.assertEqual(check(), 'Merged')
            Path(path, 'draft').write_text('change')
            self.assertEqual(check(), 'Uncommitted changes')
            git('add', 'draft')
            git('-c', 'commit.gpgsign=false', 'commit', '-m', 'feature')
            self.assertEqual(check(), 'Needs push')
            git('update-ref', 'refs/remotes/origin/feature', 'HEAD')
            self.assertEqual(check(), 'Needs to merge')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            self.assertEqual(check(), 'Merged')
            git('checkout', '-b', 'staging', 'HEAD~1')
            git('update-ref', 'refs/remotes/origin/staging', 'feature')
            git('branch', '--set-upstream-to=origin/staging')
            self.assertEqual(check(), 'Needs pull')
            Path(path, 'draft-two').write_text('uncommitted')
            details = probe.delivery_details(path, time.monotonic() + 5)
            self.assertEqual(details['deliveryStatus'], 'Uncommitted changes')
            self.assertEqual(details['checkoutBranch'], 'staging')
            self.assertEqual(details['workspaceDiff']['added'], 1)
            self.assertEqual(details['workspaceDiff']['removed'], 0)
            self.assertFalse(details['checkoutIsLinked'])
            linked = path + '-linked'
            try:
                git('worktree', 'add', '--detach', linked, 'HEAD')
                self.assertTrue(probe.delivery_details(linked, time.monotonic() + 5)['checkoutIsLinked'])
            finally:
                git('worktree', 'remove', '--force', linked)
            self.assertEqual(Path(details['repositoryPath']).resolve(), Path(path).resolve())
            self.assertEqual(details['upstreamBehind'], 1)
            self.assertEqual(Path(details['checkoutPath']).resolve(), Path(path).resolve())
            self.assertIsNone(probe.delivery_status(path, time.monotonic() - 1))
        self.assertIsNone(probe.delivery_status(path, time.monotonic() + 5))

    def test_reported_commit_is_verified_without_claiming_chat_ownership(self):
        with tempfile.TemporaryDirectory() as path:
            def git(*args):
                return subprocess.check_output(['git', '-C', path, *args], stderr=subprocess.DEVNULL, text=True).strip()
            git('init', '-b', 'main')
            git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'initial')
            sha = git('rev-parse', 'HEAD')
            rows = [dict(type='session_meta', payload=dict(cwd=path)),
                    dict(type='response_item', payload=dict(type='message', role='assistant', phase='final', content=[dict(text='Committed in ' + sha[:9])]))]
            self.assertEqual(probe.reported_commit(rows), dict(sha=sha, onRemote=False))
            git('update-ref', 'refs/remotes/origin/main', sha)
            self.assertEqual(probe.reported_commit(rows), dict(sha=sha, onRemote=True))
            rows[-1]['payload']['content'][0]['text'] = 'Committed deadbeef12345678'
            self.assertIsNone(probe.reported_commit(rows))
            rows[-1]['payload']['content'][0]['text'] = 'Committed ' + sha[:9] + ' compared to abc12345'
            self.assertIsNone(probe.reported_commit(rows))
            rows[-1]['payload']['content'][0]['text'] = 'Committed ' + sha[:9]
            rows.append(dict(type='event_msg', payload=dict(type='task_started')))
            self.assertIsNone(probe.reported_commit(rows))

    def test_chat_edit_counts_ignore_conversation_and_failed_edits(self):
        with tempfile.NamedTemporaryFile(mode='w+', suffix='.jsonl') as log:
            def check(rows):
                log.seek(0); log.truncate()
                for row in rows:
                    log.write(json.dumps(row) + '\n')
                log.flush()
                return probe.chat_edit_stats(log.name)
            self.assertFalse(check([dict(type='response_item', payload=dict(type='message', content='edit code please'))])['hasEdits'])
            patch = dict(type='event_msg', payload=dict(type='patch_apply_end', call_id='a', success=True,
                changes={'file.py': dict(type='update', unified_diff='@@\n-old\n+new\n+extra')}))
            result = check([patch, patch])
            self.assertEqual((result['added'], result['removed']), (2, 1))
            patch['payload']['success'] = False
            self.assertFalse(check([patch])['hasEdits'])
            claude = dict(uuid='a', toolUseResult=dict(structuredPatch=[dict(lines=[' context', '-before', '+after'])]))
            result = check([claude, claude])
            self.assertEqual((result['added'], result['removed']), (1, 1))
            shell = dict(payload=dict(type='item_completed', item=dict(type='CommandExecution', status='completed', exit_code=0,
                command=['python3', '-c', 'p.write_text("new")'])))
            result = check([shell])
            self.assertTrue(result['hasEdits']); self.assertFalse(result['exact'])
            shell['payload']['item']['exit_code'] = 1
            self.assertFalse(check([shell])['hasEdits'])

    def test_incomplete_edit_scan_never_confirms_no_edits(self):
        with tempfile.NamedTemporaryFile(mode='w+', suffix='.jsonl') as log:
            log.write(json.dumps(dict(type='assistant', message=dict(content='conversation'))) + '\n')
            log.flush()
            result = probe.chat_edit_stats(log.name, time.monotonic() - 1)
            self.assertFalse(result['hasEdits'])
            self.assertFalse(result['exact'])
            # An old edit can fall outside the bounded tail of a large active transcript.
            log.seek(0); log.truncate()
            log.write(json.dumps(dict(toolUseResult=dict(structuredPatch=[dict(lines=['+code'])]))) + '\n')
            log.write(' ' * (16 * 1024 * 1024) + '\n')
            log.write('{}\n'); log.flush()
            result = probe.chat_edit_stats(log.name)
            self.assertFalse(result['hasEdits'])
            self.assertFalse(result['exact'])

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
        self.assertIsNone(parse(self.worker_event(sid, started=now + 3600)))
        self.assertEqual(parse('truncated lifecycle envelope'), 'Unknown')

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
