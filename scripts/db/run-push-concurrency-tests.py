#!/usr/bin/env python3
"""Independent-session APNs queue races; refuses nonlocal/non-disposable targets."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import uuid

spec = importlib.util.spec_from_file_location('padel_push_races', Path(__file__).with_name('run-concurrency-tests.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
SECRET = uuid.uuid4().hex + uuid.uuid4().hex


def rpc(player, name, *args):
    return r.act(player, 'select public.' + name + '(' + ','.join(args) + ')')


def worker(name, *args):
    return 'begin;select tests.act_as_anon();select public.' + name + '(' + ','.join([r.literal(SECRET), *args]) + ');commit;'


def claim():
    return json.loads(r.sql(worker('claim_push_deliveries', '1')))['items'][0]


def notify(sender, chat):
    r.sql(rpc(sender, 'send_message', r.literal(chat), "'Настоящее событие проверки'", r.literal(uuid.uuid4())))


def main():
    if r.sql('select enabled from private.push_config where singleton') != 'f':
        raise SystemExit('Use a fresh disposable database with push disabled; do not alter an existing worker configuration.')
    subprocess.run(r.PSQL + ['-f', str(r.ROOT / 'supabase/tests/00_setup.sql')], check=True, stdout=subprocess.DEVNULL)
    players = []
    try:
        for tag in ('pa', 'pb'):
            players.append(r.sql('select tests.player(' + r.literal(r.PREFIX + '_' + tag) + ')'))
        a, b = players
        r.sql(rpc(a, 'friendship_action', r.literal(b), "'request'"))
        r.sql(rpc(b, 'friendship_action', r.literal(a), "'accept'"))
        chat = json.loads(r.sql(rpc(a, 'create_conversation', r.body({'client_id': str(uuid.uuid4()), 'kind': 'direct', 'player_id': b}))))['id']
        r.sql('update private.push_config set enabled=true,worker_secret_hash=extensions.digest(' + r.literal(SECRET) + ",'sha256') where singleton")
        for token in ('aabb', 'ccdd'):
            r.sql(rpc(b, 'register_push_device', r.literal(uuid.uuid4()), r.literal(token), 'true'))
        notify(a, chat)
        results = r.race([worker('claim_push_deliveries', '1'), worker('claim_push_deliveries', '1')])
        assert all(code == 0 for code, _, _ in results), results
        jobs = [json.loads(body)['items'][0] for _, body, _ in results]
        assert jobs[0]['id'] != jobs[1]['id'], jobs
        assert len(json.loads(r.sql(worker('claim_push_deliveries', '10')))['items']) == 0
        print('ok   independent workers claim disjoint rows with SKIP LOCKED')

        old = jobs[0]
        r.sql('update private.push_deliveries set lease_until=clock_timestamp()-interval \'1 second\' where id=' + r.literal(old['id']))
        new = claim()
        assert new['id'] == old['id'] and new['lease_id'] != old['lease_id']
        late = json.loads(r.sql(worker('finish_push_delivery', r.literal(old['id']), r.literal(old['lease_id']), "'accepted'")))
        assert not late['updated']
        r.sql(worker('finish_push_delivery', r.literal(new['id']), r.literal(new['lease_id']), "'accepted'"))
        r.sql(worker('finish_push_delivery', r.literal(jobs[1]['id']), r.literal(jobs[1]['lease_id']), "'accepted'"))
        print('ok   expired lease is fenced against a late old acknowledgment')

        notify(a, chat)
        job = claim()
        installation = r.sql('select d.installation_id from private.push_devices d join private.push_deliveries q on q.device_id=d.id where q.id=' + r.literal(job['id']))
        results = r.race([
            rpc(b, 'register_push_device', r.literal(installation), "'1122'", 'true'),
            worker('finish_push_delivery', r.literal(job['id']), r.literal(job['lease_id']), "'dead_token'", "'BadDeviceToken'")])
        assert all(code == 0 for code, _, _ in results), results
        assert r.sql('select enabled and device_token=\'1122\' from private.push_devices where player_id=' + r.literal(b) + ' and installation_id=' + r.literal(installation)) == 't'
        print('ok   registration racing dead-token finish cannot invalidate a new generation')

        notify(a, chat)
        job = claim()
        installation = r.sql('select d.installation_id from private.push_devices d join private.push_deliveries q on q.device_id=d.id where q.id=' + r.literal(job['id']))
        results = r.race([
            rpc(b, 'register_push_device', r.literal(installation), "'3344'", 'true'),
            rpc(b, 'revoke_push_device', r.literal(installation)),
            worker('finish_push_delivery', r.literal(job['id']), r.literal(job['lease_id']), "'dead_token'", "'BadDeviceToken'")])
        assert all(code == 0 for code, _, _ in results), results
        assert r.sql('select coalesce(bool_and(enabled and device_token=\'3344\'),true) from private.push_devices where player_id=' + r.literal(b) + ' and installation_id=' + r.literal(installation)) == 't'
        print('ok   revoke/register/finish use consistent device-before-delivery lock ordering')

        results = r.race([rpc(player, 'register_push_device', r.literal(uuid.uuid4()), "'eeff'", 'true') for player in (a, b)])
        assert all(code == 0 for code, _, _ in results), results
        assert r.sql("select count(*) from private.push_devices where device_token='eeff'") == '1'
        print('ok   simultaneous token registration keeps one canonical APNs destination')

        shared = str(uuid.uuid4())
        results = r.race([rpc(player, 'register_push_device', r.literal(shared), r.literal(token), 'true') for player, token in ((a, '8899'), (b, '9900'))])
        assert all(code == 0 for code, _, _ in results), results
        assert r.sql('select count(*) from private.push_devices where installation_id=' + r.literal(shared)) == '2'
        r.sql(rpc(b, 'revoke_push_device', r.literal(shared)))
        assert r.sql('select device_token from private.push_devices where player_id=' + r.literal(a) + ' and installation_id=' + r.literal(shared)) == '8899'
        print('ok   another account knowing installation UUID cannot overwrite or revoke a different token')
    finally:
        if players:
            ids = ','.join(r.literal(x) for x in players)
            statements = ['delete from private.push_devices where player_id in (' + ids + ')',
                          'delete from public.social_notifications where player_id in (' + ids + ') or actor_id in (' + ids + ')',
                          'delete from public.conversations where owner_id in (' + ids + ')',
                          'delete from public.friendships where player_low in (' + ids + ') or player_high in (' + ids + ')']
            for table, field in [('social_settings', 'player_id'), ('rating_events', 'player_id'), ('player_dna_history', 'player_id'),
                                 ('player_dna', 'player_id'), ('dna_self_assessments', 'player_id'), ('player_ratings', 'player_id'), ('profiles', 'id')]:
                statements.append('delete from public.' + table + ' where ' + field + ' in (' + ids + ')')
            statements.append('delete from auth.users where id in (' + ids + ')')
            r.sql('begin;' + ';'.join(statements) + ';commit;')
        r.sql('update private.push_config set enabled=false,worker_secret_hash=null where singleton')
        r.sql('drop schema if exists tests cascade')


if __name__ == '__main__':
    database = os.environ.get('PGDATABASE', '')
    disposable_stack = (database == 'postgres' and os.environ.get('PGPORT') == '54322'
                        and os.environ.get('PADELID_DISPOSABLE_DB') == '1')
    if (not (database.startswith('padel_push_') or disposable_stack)
            or os.environ.get('PGHOST') not in ('/tmp', '/var/tmp/pgdev', 'localhost', '127.0.0.1')):
        raise SystemExit('Set local PGHOST and a disposable PGDATABASE=padel_push_...; never target production.')
    main()
