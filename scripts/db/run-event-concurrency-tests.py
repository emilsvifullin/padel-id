#!/usr/bin/env python3
"""Event races on a disposable local DB, through independent sessions."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import uuid

spec = importlib.util.spec_from_file_location('padel_races', Path(__file__).with_name('run-concurrency-tests.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def rpc(player, name, *args):
    return r.act(player, 'select public.' + name + '(' + ','.join(args) + ')')


def event(owner, capacity=4):
    return json.loads(r.sql(rpc(owner, 'create_event', r.body({
        'client_id': str(uuid.uuid4()), 'kind': 'tournament', 'format': 'americano',
        'title': 'Проверка одновременных действий', 'description': 'Правила тестового события',
        'starts_at': r.sql("select (now()+interval '2 days')::text"),
        'duration_minutes': 90, 'city_id': 1, 'location': 'Корт проверки',
        'capacity': capacity, 'min_level': 0, 'max_level': 7,
        'round_count': 3, 'points_per_game': 32,
    }))))['id']


def main():
    subprocess.run(r.PSQL + ['-f', str(r.ROOT / 'supabase/tests/00_setup.sql')], check=True, stdout=subprocess.DEVNULL)
    players = []
    try:
        for i in range(6):
            players.append(r.sql('select tests.player(' + r.literal(r.PREFIX + '_event_' + chr(97+i)) + ')'))
        owner, a, b, c, d, outsider = players
        e = event(owner)
        for player in (owner, a, b):
            r.sql(rpc(player, 'event_register', r.literal(e)))
        results = r.race([rpc(player, 'event_register', r.literal(e)) for player in (c, d)])
        assert sum(code == 0 for code, _, _ in results) == 1, results
        assert sum('event_full' in error for _, _, error in results) == 1, results
        assert r.sql('select count(*) from public.event_registrations where event_id=' + r.literal(e)) == '4'
        print('ok   concurrent enrollment cannot overfill the last tournament place')

        r.sql('update public.sports_events set starts_at=now()-interval \'10 minutes\' where id=' + r.literal(e))
        results = r.race([rpc(owner, 'event_generate_round', r.literal(e), '0')] * 2)
        assert sum(code == 0 for code, _, _ in results) == 1, results
        assert sum('event_version_conflict' in error for _, _, error in results) == 1, results
        assert r.sql('select count(*) from public.event_games where event_id=' + r.literal(e)) == '1'
        g = r.sql('select id from public.event_games where event_id=' + r.literal(e))
        print('ok   concurrent round generation creates one complete round')

        results = r.race([rpc(owner, 'event_game_score', r.literal(e), r.literal(g), r.body({
            'version': 1, 'points1': points, 'points2': 32-points,
        })) for points in (20, 21)])
        assert sum(code == 0 for code, _, _ in results) == 1, results
        assert sum('event_version_conflict' in error for _, _, error in results) == 1, results
        assert r.sql('select version from public.event_games where id=' + r.literal(g)) == '2'
        print('ok   conflicting scores cannot silently replace the winner')

        roster = json.loads(r.sql('select jsonb_build_array(player1,player2,player3,player4) from public.event_games where id=' + r.literal(g)))
        results = r.race([rpc(player, 'event_game_confirm', r.literal(e), r.literal(g), '2') for player in roster])
        assert all(code == 0 for code, _, _ in results), results
        assert r.sql('select count(*) from public.event_game_confirmations where game_id=' + r.literal(g) + ' and version=2') == '4'
        assert r.sql('select confirmed_at is not null from public.event_games where id=' + r.literal(g)) == 't'
        assert r.sql('select count(*) from public.matches where created_by in (' + ','.join(r.literal(p) for p in players) + ')') == '0'
        print('ok   four concurrent confirmations confirm once without creating rated matches')

        e2 = event(owner)
        results = r.race([rpc(a, 'event_register', r.literal(e2)), rpc(owner, 'event_manage', r.literal(e2), "'cancel'")])
        assert results[1][0] == 0, results
        assert results[0][0] == 0 or 'event_closed' in results[0][2], results
        assert r.sql('select status from public.sports_events where id=' + r.literal(e2)) == 'cancelled'
        print('ok   cancellation racing enrollment leaves the event closed')

        e3 = event(owner)
        r.sql(rpc(a, 'event_register', r.literal(e3)))
        changes = [{
            'version': 1, 'title': title, 'description': 'Участники сохраняются',
            'starts_at': r.sql("select (now()+interval '3 days')::text"),
            'duration_minutes': 90, 'city_id': 1, 'club_id': None,
            'location': 'Корт проверки', 'specialization': None, 'price_rub': None,
        } for title in ('Первый перенос', 'Второй перенос')]
        results = r.race([rpc(owner, 'event_update', r.literal(e3), r.body(body)) for body in changes])
        assert sum(code == 0 for code, _, _ in results) == 1, results
        assert sum('event_version_conflict' in error for _, _, error in results) == 1, results
        assert r.sql('select metadata_version from public.sports_events where id=' + r.literal(e3)) == '2'
        assert r.sql('select count(*) from public.event_registrations where event_id=' + r.literal(e3)) == '1'
        assert r.sql('select count(*) from public.social_notifications where player_id=' + r.literal(a)
                     + ' and resource_id=' + r.literal(e3) + " and title='Обновлены условия события'") == '1'
        print('ok   divergent concurrent schedule edits preserve one version, roster and notification')
    finally:
        if players:
            ids = ','.join(r.literal(p) for p in players)
            # Only this uniquely named fixture community is removed.
            tables = [('social_notifications', 'player_id in ('+ids+') or actor_id in ('+ids+')'),
                      ('sports_events', 'organizer_id in ('+ids+')'),
                      ('social_settings', 'player_id in ('+ids+')'),
                      ('rating_events', 'player_id in ('+ids+')'),
                      ('player_dna_history', 'player_id in ('+ids+')'),
                      ('player_dna', 'player_id in ('+ids+')'),
                      ('dna_self_assessments', 'player_id in ('+ids+')'),
                      ('player_ratings', 'player_id in ('+ids+')'),
                      ('profiles', 'id in ('+ids+')')]
            statements = ['delete from public.'+table+' where '+where for table, where in tables]
            statements.append('delete from auth.users where id in ('+ids+')')
            r.sql('begin;'+';'.join(statements)+';commit;')
        r.sql('drop schema if exists tests cascade')


if __name__ == '__main__':
    if (os.environ.get('PGHOST') not in ('/tmp', '/var/tmp/pgdev', '127.0.0.1', 'localhost')
            or not os.environ.get('PGDATABASE') or os.environ.get('PADELID_DISPOSABLE_DB') != '1'):
        raise SystemExit('Set local PGHOST, PGDATABASE and PADELID_DISPOSABLE_DB=1 for a disposable migrated DB.')
    main()
