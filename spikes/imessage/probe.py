"""Read-only iMessage schema/range spike; not a production connector."""
import argparse
from collections import Counter
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import sys
import time

APPLE_EPOCH_MS = 978307200000
REQUIRED = {
    'message': {'guid', 'text', 'date', 'is_from_me'},
    'chat': {'guid'},
    'chat_message_join': {'chat_id', 'message_id'},
}


def open_readonly(path):
    # URI quoting handles spaces, #, ? and non-ASCII paths; no immutable=1 on live WAL DBs.
    uri = Path(path).expanduser().resolve().as_uri() + '?mode=ro'
    db = sqlite3.connect(uri, uri=True, timeout=2)
    db.execute('PRAGMA query_only = ON')
    db.row_factory = sqlite3.Row
    return db


def inspect_schema(db):
    columns = {}
    for table, required in REQUIRED.items():
        columns[table] = {r[1] for r in db.execute('PRAGMA table_info("%s")' % table)}
        missing = required - columns[table]
        if missing:
            raise ValueError('Unsupported schema: %s missing %s' % (table, ', '.join(sorted(missing))))
    return columns


def sent_at(value, unit):
    if value is None:
        return None
    # Integer conversion avoids nanosecond precision loss in floating point.
    return APPLE_EPOCH_MS + (int(value) // 1000000 if unit == 'nanoseconds' else int(value) * 1000)


def read_batch(db, after=0, limit=100, account_id='imessage-local', date_unit='nanoseconds'):
    if after < 0 or not 1 <= limit <= 1000 or not account_id.strip():
        raise ValueError('Invalid cursor, limit or account ID')
    columns = inspect_schema(db)
    body = 'm.attributedBody' if 'attributedBody' in columns['message'] else 'NULL'
    attachment = 'm.cache_has_attachments' if 'cache_has_attachments' in columns['message'] else 'NULL'
    # Page by source message first: joining a message to multiple chats must not split a page.
    sql = '''WITH page AS (
      SELECT ROWID AS source_rowid, * FROM message WHERE ROWID > ? ORDER BY ROWID LIMIT ?
    ) SELECT m.source_rowid, m.guid, m.text, m.date, m.is_from_me,
      %s AS attributed_body, %s AS has_attachments,
      c.ROWID AS chat_rowid, c.guid AS chat_guid
    FROM page m LEFT JOIN chat_message_join j ON j.message_id = m.source_rowid
    LEFT JOIN chat c ON c.ROWID = j.chat_id
    ORDER BY m.source_rowid, c.ROWID''' % (body, attachment)
    rows = db.execute(sql, (after, limit)).fetchall()
    messages, seen = [], set()
    for r in rows:
        conversation_id = r['chat_guid'] or ('local-chat-row:%s' % r['chat_rowid'] if r['chat_rowid'] else 'unassigned')
        original_id = r['guid'] or 'local-message-row:%s' % r['source_rowid']
        key = (account_id, conversation_id, original_id)
        if key in seen:
            continue
        seen.add(key)
        if r['text'] is not None:
            status = 'plain_text'
        elif r['attributed_body']:
            status = 'unsupported_attributed_body'
        elif r['has_attachments']:
            status = 'attachment_only'
        else:
            status = 'empty_or_unsupported'
        messages.append({
            'schemaVersion': 1, 'platform': 'imessage',
            'key': dict(zip(('accountId', 'conversationId', 'originalMessageId'), key)),
            'sourceRowId': r['source_rowid'], 'text': r['text'], 'bodyStatus': status,
            'sentAt': sent_at(r['date'], date_unit),
            'direction': 'outgoing' if r['is_from_me'] else 'incoming',
        })
    return {
        'messages': messages,
        'sourceMessageCount': len({r['source_rowid'] for r in rows}),
        'nextCursor': max((r['source_rowid'] for r in rows), default=after),
    }


def summary(batch):
    return {
        'sourceMessageCount': batch['sourceMessageCount'],
        'conversationMessageCount': len(batch['messages']),
        'bodyStatusCounts': dict(Counter(m['bodyStatus'] for m in batch['messages'])),
        'nextCursor': batch['nextCursor'],
    }


def seed_demo(db):
    """Only for the isolated in-memory demo or synthetic test databases."""
    db.executescript('''
    CREATE TABLE message(guid TEXT, text TEXT, date INTEGER, is_from_me INTEGER,
                         attributedBody BLOB, cache_has_attachments INTEGER DEFAULT 0);
    CREATE TABLE chat(guid TEXT);
    CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
    INSERT INTO chat VALUES ('demo-chat');
    INSERT INTO message VALUES ('demo-1', '안녕하세요. 합성 메시지입니다.', 800000000000000000, 0, NULL, 0);
    INSERT INTO message VALUES ('demo-2', '통합 인박스 개발 테스트', 800000001000000000, 1, NULL, 0);
    INSERT INTO message VALUES ('demo-3', NULL, 800000002000000000, 0, X'0102', 0);
    INSERT INTO message VALUES ('demo-4', NULL, 800000003000000000, 0, NULL, 1);
    INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3),(1,4);
    ''')
    db.commit()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--demo', action='store_true', help='Use synthetic in-memory data only')
    source.add_argument('--db', help='Explicit path to a permitted Messages database')
    parser.add_argument('--after', type=int, default=0, help='Source ROWID cursor; same database only')
    parser.add_argument('--limit', type=int, default=100)
    parser.add_argument('--account-id', default='imessage-local')
    parser.add_argument('--date-unit', choices=['nanoseconds', 'seconds'], default='nanoseconds')
    parser.add_argument('--show-content', action='store_true', help='Print message text and identifiers to this terminal')
    parser.add_argument('--watch', action='store_true', help='Poll for new rows; no edit/delete tracking')
    parser.add_argument('--interval', type=float, default=2)
    args = parser.parse_args(argv)
    if args.after < 0 or not 1 <= args.limit <= 1000 or not 0.5 <= args.interval <= 60 or not args.account_id.strip():
        parser.error('Require after >= 0, limit 1..1000, interval 0.5..60 and nonempty account ID')
    try:
        with closing(sqlite3.connect(':memory:') if args.demo else open_readonly(args.db)) as db:
            if args.demo:
                db.row_factory = sqlite3.Row
                seed_demo(db)
                db.execute('PRAGMA query_only = ON')
            cursor = args.after
            while True:
                batch = read_batch(db, cursor, args.limit, args.account_id, args.date_unit)
                print(json.dumps(batch if args.show_content else summary(batch), ensure_ascii=False), flush=True)
                # Advance only after successfully delivering the batch to stdout.
                cursor = batch['nextCursor']
                if not args.watch:
                    return 0
                time.sleep(args.interval)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    except (sqlite3.Error, OSError):
        print('Database unavailable: check the path, macOS Full Disk Access, file permissions, or DB lock/corruption. No permission change was attempted.', file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 0


if __name__ == '__main__':
    sys.exit(main())
