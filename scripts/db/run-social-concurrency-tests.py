#!/usr/bin/env python3
"""Real independent-session social races on a disposable migrated database.

Uses the existing PostgreSQL fixture/race helpers. Never target production.
PGHOST/PGPORT/PGUSER/PGDATABASE must identify a local disposable test database.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import uuid

BASE = Path(__file__).with_name('run-concurrency-tests.py')
spec = importlib.util.spec_from_file_location('padel_races', BASE)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def rpc(player, name, *args):
    return r.act(player, 'select public.' + name + '(' + ','.join(args) + ')')


def chat(owner, peer):
    return json.loads(r.sql(rpc(owner, 'create_conversation', r.body({
        'client_id': str(uuid.uuid4()), 'kind': 'direct', 'player_id': peer}))))['id']


def main():
    subprocess.run(r.PSQL + ['-f', str(r.ROOT / 'supabase/tests/00_setup.sql')],
                   check=True, stdout=subprocess.DEVNULL)
    players = []
    try:
        for tag in ('a', 'b', 'c', 'd'):
            players.append(r.sql('select tests.player(' + r.literal(r.PREFIX + '_social_' + tag) + ')'))
        a, b, c, d = players
        for peer in (b, c, d):
            r.sql(rpc(a, 'friendship_action', r.literal(peer), "'request'"))
            r.sql(rpc(peer, 'friendship_action', r.literal(a), "'accept'"))
        dm = chat(a, b)
        key = str(uuid.uuid4())
        send = rpc(a, 'send_message', r.literal(dm), "'Повторное сообщение'", r.literal(key))
        results = r.race([send, send])
        assert all(code == 0 for code, _, _ in results), results
        assert len({json.loads(v)['id'] for _, v, _ in results}) == 1, results
        assert r.sql('select count(*) from public.conversation_messages where conversation_id=' + r.literal(dm)) == '1'
        assert r.sql("select count(*) from public.social_notifications where player_id=" + r.literal(b) +
                     " and kind='message' and resource_id=" + r.literal(dm)) == '1'
        print('ok   concurrent send retries create one message and one notification')

        key = str(uuid.uuid4())
        results = r.race([rpc(a, 'send_message', r.literal(dm), r.literal(text), r.literal(key))
                          for text in ('Первый текст', 'Иной текст')])
        assert sum(code == 0 for code, _, _ in results) == 1, results
        assert sum('version_conflict' in error for _, _, error in results) == 1, results
        print('ok   concurrent same-key payload collision fails without replacing content')

        results = r.race([rpc(a, 'send_message', r.literal(dm), "'Во время блокировки'", r.literal(uuid.uuid4())),
                          rpc(b, 'block_player', r.literal(a))])
        assert results[1][0] == 0, results
        assert results[0][0] == 0 or 'conversation_not_found' in results[0][2] or 'social_blocked' in results[0][2], results
        try:
            r.sql(rpc(a, 'conversation', r.literal(dm)))
            raise AssertionError('blocked chat remained accessible')
        except RuntimeError as exc:
            assert 'conversation_not_found' in str(exc)
        assert r.sql("select count(*) from public.social_notifications where (player_id=" + r.literal(a) +
                     ' and actor_id=' + r.literal(b) + ') or (player_id=' + r.literal(b) +
                     ' and actor_id=' + r.literal(a) + ')') == '0'
        print('ok   blocking serializes with send and leaves no readable chat or actor notifications')

        group = json.loads(r.sql(rpc(a, 'create_conversation', r.body({
            'client_id': str(uuid.uuid4()), 'kind': 'group', 'title': 'Группа проверки',
            'visibility': 'public', 'player_ids': [c]}))))['id']
        results = r.race([rpc(c, 'conversation_member_action', r.literal(group), 'null', "'join'"),
                          rpc(a, 'conversation_member_action', r.literal(group), r.literal(c), "'remove'")])
        assert all(code == 0 for code, _, _ in results), results
        assert r.sql('select count(*) from public.conversation_members where conversation_id=' + r.literal(group) +
                     ' and player_id=' + r.literal(c)) in ('0', '1')
        r.sql(rpc(a, 'conversation_member_action', r.literal(group), r.literal(c), "'add'"))
        results = r.race([rpc(c, 'send_message', r.literal(group), "'Перед исключением'", r.literal(uuid.uuid4())),
                          rpc(a, 'conversation_member_action', r.literal(group), r.literal(c), "'remove'")])
        assert results[1][0] == 0, results
        assert results[0][0] == 0 or 'conversation_not_found' in results[0][2], results
        assert r.sql('select count(*) from public.conversation_members where conversation_id=' + r.literal(group) +
                     ' and player_id=' + r.literal(c)) == '0'
        print('ok   group join/removal and send/removal keep canonical membership and revoke access')

        dm_delete = chat(a, d)
        results = r.race([rpc(d, 'send_message', r.literal(dm_delete), "'Удаляемые личные данные'", r.literal(uuid.uuid4())),
                          'begin; select tests.act_as_service(); select public.svc_anonymize_account(' + r.literal(d) + '); commit;'])
        assert results[1][0] == 0, results
        assert results[0][0] == 0 or 'player_not_found' in results[0][2] or 'session_expired' in results[0][2], results
        assert r.sql('select count(*) from public.conversation_messages where sender_id=' + r.literal(d) +
                     " and (deleted_at is null or body<>'Сообщение удалено')") == '0'
        assert r.sql('select count(*) from public.conversation_members where player_id=' + r.literal(d)) == '0'
        assert r.sql('select count(*) from public.social_notifications where player_id=' + r.literal(d) +
                     ' or actor_id=' + r.literal(d)) == '0'
        print('ok   account deletion racing send erases content and cannot restore memberships')
    finally:
        if players:
            ids = ','.join(r.literal(x) for x in players)
            statements = [
                'delete from public.social_notifications where player_id in (' + ids + ') or actor_id in (' + ids + ')',
                'delete from public.content_reports where reporter_id in (' + ids + ')',
                'delete from public.social_reactions where player_id in (' + ids + ')',
                'delete from public.social_comments where author_id in (' + ids + ')',
                'delete from public.social_posts where author_id in (' + ids + ')',
                'delete from public.conversations where owner_id in (' + ids + ')',
                'delete from public.player_blocks where blocker_id in (' + ids + ') or blocked_id in (' + ids + ')',
                'delete from public.player_follows where follower_id in (' + ids + ') or followed_id in (' + ids + ')',
                'delete from public.social_settings where player_id in (' + ids + ')',
                'delete from public.friendships where player_low in (' + ids + ') or player_high in (' + ids + ')',
                'delete from public.rating_events where player_id in (' + ids + ')',
                'delete from public.player_dna_history where player_id in (' + ids + ')',
                'delete from public.player_dna where player_id in (' + ids + ')',
                'delete from public.dna_self_assessments where player_id in (' + ids + ')',
                'delete from public.player_ratings where player_id in (' + ids + ')',
                'delete from public.profiles where id in (' + ids + ')',
                'delete from auth.users where id in (' + ids + ')',
            ]
            r.sql('begin; ' + ';'.join(statements) + '; commit;')
        r.sql('drop schema if exists tests cascade')


if __name__ == '__main__':
    if not os.environ.get('PGDATABASE') or os.environ.get('PGHOST') not in ('/tmp', '/var/tmp/pgdev', '127.0.0.1', 'localhost'):
        raise SystemExit('Set PGDATABASE and a local PGHOST to a disposable migrated database.')
    main()
