#!/usr/bin/env python3
"""Independent-session owner/successor deletion races. Local disposable DB only."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('padel_races', ROOT / 'scripts/db/run-concurrency-tests.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def group(owner, peers):
    payload = {'kind': 'group', 'client_id': str(uuid.uuid4()), 'title': 'Группа проверки',
               'player_ids': peers}
    return json.loads(r.sql(r.act(owner, 'select public.create_conversation(' + r.body(payload) + ')')))['id']


def delete(player):
    return ("begin; set local statement_timeout='15s'; select tests.act_as_service(); "
            'select public.svc_anonymize_account(' + r.literal(player) + '); commit;')


def assert_owner(chat, expected):
    assert r.sql('select owner_id from public.conversations where id=' + r.literal(chat)) == expected
    assert r.sql('select count(*) from public.conversation_members where conversation_id=' + r.literal(chat) + " and role='owner'") == '1'
    assert json.loads(r.sql(r.act(expected, 'select public.conversation(' + r.literal(chat) + ')')))['owner_id'] == expected


def main():
    subprocess.run(r.PSQL + ['-f', str(ROOT / 'supabase/tests/00_setup.sql')], check=True, stdout=subprocess.DEVNULL)
    players = []
    chats = []
    try:
        for suffix in ('a', 'b', 'c', 'd', 'e', 'f', 'g'):
            players.append(r.sql('select tests.player(' + r.literal(r.PREFIX + '_gd_' + suffix) + ')'))
        a, b, c, d, e, f, g = players
        for owner, peers in ((a, (b, c)), (d, (e, f)), (e, (d, g))):
            for peer in peers:
                r.sql(r.act(owner, 'select public.friendship_action(' + r.literal(peer) + ",'request')"))
                r.sql(r.act(peer, 'select public.friendship_action(' + r.literal(owner) + ",'accept')"))
        chat = group(a, [b, c]); chats.append(chat)
        r.sql('update public.conversation_members set joined_at=case when player_id=' + r.literal(b) +
              " then '2026-01-01'::timestamptz else '2026-01-02'::timestamptz end where conversation_id=" + r.literal(chat))
        results = r.race([delete(a), delete(b)])
        assert all(code == 0 for code, _, _ in results), results
        assert_owner(chat, c)
        r.sql(r.act(c, 'select public.send_message(' + r.literal(chat) + ", 'Группа продолжает работу'," + r.literal(uuid.uuid4()) + ')'))
        print('ok   simultaneous owner/successor deletion transfers to a surviving member')

        first = group(d, [e, f]); chats.append(first)
        second = group(e, [d, g]); chats.append(second)
        results = r.race([delete(d), delete(e)])
        assert all(code == 0 for code, _, _ in results), results
        assert_owner(first, f)
        assert_owner(second, g)
        print('ok   cross-owned groups survive concurrent owner deletions without deadlock or orphan')

        results = r.race([delete(c), delete(c)])
        assert all(code == 0 for code, _, _ in results), results
        assert r.sql('select archived_at is not null from public.conversations where id=' + r.literal(chat)) == 't'
        assert r.sql('select count(*) from public.conversation_members where conversation_id=' + r.literal(chat)) == '0'
        print('ok   concurrent repeated final-owner cleanup archives exactly once and revokes membership')
    finally:
        # Erase only the exact fixture UUIDs; no global resets or broad prefixes.
        # Canonical cleanup runs first so the race exercises production behavior.
        for player in players:
            r.sql(delete(player))
        if players:
            ids = ','.join(r.literal(player) for player in players)
            statements = []
            if chats:
                statements.append('delete from public.conversations where id in (' + ','.join(r.literal(chat) for chat in chats) + ')')
            for table, column in (('social_notifications', 'player_id'), ('social_notifications', 'actor_id'),
                                  ('content_reports', 'reporter_id'), ('social_reactions', 'player_id'),
                                  ('social_comments', 'author_id'), ('social_posts', 'author_id'),
                                  ('social_settings', 'player_id'), ('rating_events', 'player_id'),
                                  ('player_dna_history', 'player_id'), ('player_dna', 'player_id'),
                                  ('dna_self_assessments', 'player_id'), ('player_ratings', 'player_id')):
                statements.append('delete from public.' + table + ' where ' + column + ' in (' + ids + ')')
            for table, first_col, second_col in (('friendships', 'player_low', 'player_high'),
                                               ('player_blocks', 'blocker_id', 'blocked_id'),
                                               ('player_follows', 'follower_id', 'followed_id')):
                statements.append('delete from public.' + table + ' where ' + first_col + ' in (' + ids + ') or ' + second_col + ' in (' + ids + ')')
            statements.append('delete from public.profiles where id in (' + ids + ')')
            statements.append('delete from auth.users where id in (' + ids + ')')
            r.sql('begin; ' + ';'.join(statements) + '; commit;')
        r.sql('drop schema if exists tests cascade')


if __name__ == '__main__':
    if os.environ.get('PADELID_DISPOSABLE_DB') != '1' or not os.environ.get('PGDATABASE') or os.environ.get('PGHOST') not in ('/tmp', '/var/tmp/pgdev', '127.0.0.1', 'localhost'):
        raise SystemExit('Set PADELID_DISPOSABLE_DB=1, PGDATABASE and a local PGHOST to a disposable migrated database.')
    main()
