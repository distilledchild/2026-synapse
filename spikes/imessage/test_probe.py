from contextlib import closing, redirect_stdout, redirect_stderr
import hashlib
import io
from pathlib import Path
import sqlite3
import tempfile
import unittest

from probe import APPLE_EPOCH_MS, main, open_readonly, read_batch, seed_demo, sent_at, summary


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / '메시지 ?# test.db'
        with closing(sqlite3.connect(self.path)) as db:
            seed_demo(db)

    def test_read_only_and_source_unchanged(self):
        before = hashlib.sha256(self.path.read_bytes()).digest()
        with closing(open_readonly(self.path)) as db:
            self.assertEqual(read_batch(db)['sourceMessageCount'], 4)
            with self.assertRaises(sqlite3.OperationalError):
                db.execute('DELETE FROM message')
        self.assertEqual(before, hashlib.sha256(self.path.read_bytes()).digest())

    def test_missing_path_does_not_create_db(self):
        path = self.path.parent / 'absent.db'
        with self.assertRaises(sqlite3.OperationalError):
            open_readonly(path)
        self.assertFalse(path.exists())

    def test_body_states_and_timestamp(self):
        with closing(open_readonly(self.path)) as db:
            messages = read_batch(db)['messages']
        self.assertEqual([m['bodyStatus'] for m in messages],
                         ['plain_text', 'plain_text', 'unsupported_attributed_body', 'attachment_only'])
        self.assertEqual(messages[0]['sentAt'], APPLE_EPOCH_MS + 800000000000)
        self.assertEqual(messages[1]['direction'], 'outgoing')
        self.assertIsNone(messages[2]['text'])

    def test_join_does_not_lose_messages_on_page_boundary(self):
        with closing(sqlite3.connect(self.path)) as db:
            db.executescript("INSERT INTO chat VALUES ('second'); INSERT INTO chat_message_join VALUES (2,1),(1,1);")
            db.commit()
        with closing(open_readonly(self.path)) as db:
            first = read_batch(db, limit=1)
            self.assertEqual(len(first['messages']), 2)
            self.assertEqual(first['nextCursor'], 1)
            second = read_batch(db, after=first['nextCursor'], limit=1)
            self.assertEqual(second['messages'][0]['key']['originalMessageId'], 'demo-2')

    def test_cursor_empty_and_account_scope(self):
        with closing(open_readonly(self.path)) as db:
            self.assertEqual(read_batch(db, after=99)['nextCursor'], 99)
            a = read_batch(db, account_id='A')['messages'][0]['key']
            b = read_batch(db, account_id='B')['messages'][0]['key']
        self.assertNotEqual(a, b)

    def test_live_wal_new_rows_visible(self):
        with closing(sqlite3.connect(self.path)) as writer:
            writer.execute('PRAGMA journal_mode=WAL')
            with closing(open_readonly(self.path)) as reader:
                cursor = read_batch(reader)['nextCursor']
                writer.execute("INSERT INTO message(guid,text,date,is_from_me) VALUES ('new','WAL',1,0)")
                writer.commit()
                batch = read_batch(reader, after=cursor)
                self.assertEqual(batch['sourceMessageCount'], 1)
                self.assertEqual(batch['messages'][0]['key']['conversationId'], 'unassigned')

    def test_unsupported_schema(self):
        with closing(sqlite3.connect(':memory:')) as db:
            with self.assertRaisesRegex(ValueError, 'Unsupported schema'):
                read_batch(db)

    def test_legacy_optional_columns(self):
        with closing(sqlite3.connect(':memory:')) as db:
            db.row_factory = sqlite3.Row
            db.executescript('CREATE TABLE message(guid,text,date,is_from_me); CREATE TABLE chat(guid); CREATE TABLE chat_message_join(chat_id,message_id); INSERT INTO message VALUES (NULL,NULL,1,0);')
            m = read_batch(db, date_unit='seconds')['messages'][0]
            self.assertEqual(m['sentAt'], APPLE_EPOCH_MS + 1000)
            self.assertEqual(m['key']['originalMessageId'], 'local-message-row:1')

    def test_summary_omits_content_and_identifiers(self):
        with closing(open_readonly(self.path)) as db:
            result = str(summary(read_batch(db)))
        self.assertNotIn('demo-chat', result)
        self.assertNotIn('안녕하세요', result)
        self.assertNotIn('demo-1', result)

    def test_cli_demo_and_errors(self):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(main(['--demo']), 0)
        self.assertNotIn('안녕하세요', out.getvalue())
        with redirect_stderr(err):
            self.assertEqual(main(['--db', str(self.path.parent / 'missing.db')]), 2)
        self.assertIn('Database unavailable', err.getvalue())

    def test_invalid_limits_and_time_units(self):
        with closing(open_readonly(self.path)) as db:
            for limit in (0, 1001):
                with self.assertRaises(ValueError):
                    read_batch(db, limit=limit)
        self.assertEqual(sent_at(0, 'seconds'), APPLE_EPOCH_MS)
        self.assertIsNone(sent_at(None, 'nanoseconds'))


if __name__ == '__main__':
    unittest.main()
