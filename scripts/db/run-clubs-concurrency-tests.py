#!/usr/bin/env python3
"""Club edits through independent PostgreSQL sessions on a disposable local DB."""
import importlib.util
import os
from pathlib import Path
import subprocess
import uuid

spec = importlib.util.spec_from_file_location('padel_club_races', Path(__file__).with_name('run-concurrency-tests.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def rpc(player, name, *args):
    return r.act(player, 'select public.' + name + '(' + ','.join(args) + ')')


def main():
    subprocess.run(r.PSQL + ['-f', str(r.ROOT / 'supabase/tests/00_setup.sql')], check=True, stdout=subprocess.DEVNULL)
    admin = club = None
    try:
        admin = r.sql('select tests.player(' + r.literal(r.PREFIX + '_ca') + ')')
        r.sql('insert into private.admins(user_id) values(' + r.literal(admin) + ')')
        club = r.sql('select (public.create_club(1,' + r.literal('Клуб ' + r.PREFIX) + ")->>'id') from tests.act_as(" + r.literal(admin) + ')')
        results = r.race([rpc(admin, 'admin_club_update', club, r.body({
            'version': 1, 'description': description, 'reason': 'Подтверждено оператором клуба'}))
            for description in ('Первое описание', 'Другое описание')])
        assert sum(code == 0 for code, _, _ in results) == 1, results
        assert sum('version_conflict' in err for _, _, err in results) == 1, results
        assert r.sql('select metadata_version from public.clubs where id=' + club) == '2'
        assert r.sql('select count(*) from private.club_metadata_audit where club_id=' + club) == '1'
        print('ok   concurrent club metadata versions cannot overwrite one another')

        court = str(uuid.uuid4())
        payload = {'version': 0, 'name': 'Корт 1', 'indoor': True, 'surface': 'Трава',
                   'description': 'Подтверждено клубом', 'is_active': True, 'reason': 'Проверено оператором клуба'}
        put = rpc(admin, 'admin_court_put', club, r.literal(court), r.body(payload))
        results = r.race([put, put])
        assert all(code == 0 for code, _, _ in results), results
        assert r.sql('select count(*) from public.club_courts where id=' + r.literal(court)) == '1'
        assert r.sql('select count(*) from private.club_metadata_audit where court_id=' + r.literal(court)) == '1'
        print('ok   concurrent identical court creation returns one canonical court')

        results = r.race([rpc(admin, 'admin_court_put', club, r.literal(court), r.body({
            **payload, 'version': 1, 'description': description}))
            for description in ('Первое изменение', 'Другое изменение')])
        assert sum(code == 0 for code, _, _ in results) == 1, results
        assert sum('version_conflict' in err for _, _, err in results) == 1, results
        assert r.sql('select version from public.club_courts where id=' + r.literal(court)) == '2'
        assert r.sql('select count(*) from private.club_metadata_audit where court_id=' + r.literal(court)) == '2'
        print('ok   concurrent court edits preserve optimistic version and audit')
    finally:
        if club:
            r.sql('begin;delete from private.club_metadata_audit where club_id=' + club +
                  ';delete from public.club_courts where club_id=' + club + ';delete from public.clubs where id=' + club + ';commit;')
        if admin:
            statements = ['delete from private.admins where user_id=' + r.literal(admin)]
            for table, field in [('social_notifications', 'player_id'), ('social_settings', 'player_id'),
                                 ('rating_events', 'player_id'), ('player_dna_history', 'player_id'),
                                 ('player_dna', 'player_id'), ('dna_self_assessments', 'player_id'),
                                 ('player_ratings', 'player_id'), ('profiles', 'id')]:
                statements.append('delete from public.' + table + ' where ' + field + '=' + r.literal(admin))
            statements.append('delete from auth.users where id=' + r.literal(admin))
            r.sql('begin;' + ';'.join(statements) + ';commit;')
        r.sql('drop schema if exists tests cascade')


if __name__ == '__main__':
    database = os.environ.get('PGDATABASE', '')
    disposable_stack = (database == 'postgres' and os.environ.get('PGPORT') == '54322'
                        and os.environ.get('PADELID_DISPOSABLE_DB') == '1')
    if (not (database.startswith('padel_clubs_') or disposable_stack)
            or os.environ.get('PGHOST') not in ('/tmp', '/var/tmp/pgdev', 'localhost', '127.0.0.1')):
        raise SystemExit('Set a local PGHOST and disposable PGDATABASE=padel_clubs_...; never target production.')
    main()
