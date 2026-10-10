#!/usr/bin/env python3
"""Exercise races through separate real PostgreSQL connections.

Use a disposable migrated DB via PGHOST/PGPORT/PGUSER/PGDATABASE. This suite
creates a uniquely named fixture community and cleans up after itself. It does
not require Python database packages; psql is the only runtime dependency.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
PREFIX = "cc_" + uuid.uuid4().hex[:8].translate(str.maketrans("0123456789", "ghijklmnop"))
PSQL = ["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"]


def sql(statement):
    result = subprocess.run(PSQL + ["-c", statement], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def body(value):
    return literal(json.dumps(value)) + "::jsonb"


def act(player, operation):
    return "begin; select tests.act_as(" + literal(player) + "); " + operation + "; commit;"


def race(jobs):
    barrier = threading.Barrier(len(jobs))

    def run(job):
        barrier.wait()
        # Hold the successfully acquired relationship/game lock across COMMIT
        # long enough for the other independent connection to contend for it.
        result = subprocess.run(PSQL + ["-c", job.replace("; commit;", "; select pg_sleep(0.25); commit;")],
                                text=True, capture_output=True)
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        return result.returncode, lines[-1] if lines else "", result.stderr

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        return list(pool.map(run, jobs))


def assert_one_seat(results, match):
    assert sum(code == 0 for code, _, _ in results) == 1, results
    assert sum("scheduled_match_full" in error for _, _, error in results) == 1, results
    assert sql("select count(*) from public.scheduled_match_players where match_id = " + literal(match) + " and status='accepted'") == "4"


def game(owner, key=None):
    payload = {"client_id": key or str(uuid.uuid4()), "city_id": 1, "location": "Корт для проверки",
               "match_type": "ranked", "min_level": 2, "max_level": 4}
    # Database-clock timestamp avoids any host timezone assumption.
    payload["starts_at"] = sql("select (now()+interval '2 days')::text")
    return json.loads(sql(act(owner, "select public.create_scheduled_match(" + body(payload) + ")"))), payload


def main():
    subprocess.run(PSQL + ["-f", str(ROOT / "supabase/tests/00_setup.sql")], check=True, stdout=subprocess.DEVNULL)
    players = []
    try:
        for i in range(8):
            players.append(sql("select tests.player(" + literal(PREFIX + "_" + chr(97 + i)) + ")"))
        owner, first, second, third, fourth, applicant_a, applicant_b, friend = players
        ids = ",".join(literal(x) for x in players[:5])
        sql("update public.player_ratings set mu=3,sigma=.25,ranked_matches=5,last_ranked_at=now() where player_id in (" + ids + ")")

        match, _ = game(owner)
        for player in (first, second):
            sql(act(player, "select public.join_scheduled_match(" + literal(match["id"]) + ")"))
        assert_one_seat(race([act(player, "select public.join_scheduled_match(" + literal(match["id"]) + ")")
                              for player in (third, fourth)]), match["id"])
        print("ok   simultaneous automatic joins cannot overfill last seat")

        match, _ = game(owner)
        for player in (first, second, applicant_a, applicant_b):
            sql(act(player, "select public.join_scheduled_match(" + literal(match["id"]) + ")"))
        assert_one_seat(race([act(owner, "select public.review_scheduled_application(" + literal(match["id"]) + "," + literal(player) + ",'accepted')")
                              for player in (applicant_a, applicant_b)]), match["id"])
        print("ok   simultaneous approvals cannot overfill last seat")

        relations = race([act(owner, "select public.friendship_action(" + literal(friend) + ",'request')"),
                          act(friend, "select public.friendship_action(" + literal(owner) + ",'request')")])
        assert all(code == 0 for code, _, _ in relations), relations
        assert {json.loads(result)["status"] for _, result, _ in relations} == {"incoming", "outgoing"}, relations
        assert sql("select count(*) from public.friendships where player_low=least(" + literal(owner) + "::uuid," + literal(friend) + "::uuid)") == "1"
        print("ok   opposing friend requests keep one pending canonical relation")

        _, payload = game(owner)
        # A fresh create identity, repeated concurrently before either completes.
        payload["client_id"] = str(uuid.uuid4())
        creates = race([act(owner, "select public.create_scheduled_match(" + body(payload) + ")") for _ in range(2)])
        assert all(code == 0 for code, _, _ in creates), creates
        assert len({json.loads(result)["id"] for _, result, _ in creates}) == 1, creates
        print("ok   simultaneous create retries return one game")

        match, _ = game(owner)
        for player in (first, second, third):
            sql(act(player, "select public.join_scheduled_match(" + literal(match["id"]) + ")"))
        sql("update public.scheduled_matches set starts_at=now()-interval '2 hours' where id=" + literal(match["id"]))
        payload = {"match_type": "ranked", "format": "best_of_3", "played_at": sql("select (now()-interval '1 hour')::text"),
                   "players": [{"player_id": player, "team": 1 if i < 2 else 2, "court_side": "left" if i % 2 == 0 else "right"}
                               for i, player in enumerate((owner, first, second, third))],
                   "sets": [{"t1": 6, "t2": 4}, {"t1": 6, "t2": 3}]}
        results = race([act(player, "select public.submit_scheduled_result(" + literal(match["id"]) + "," + body(payload) + "," + literal(uuid.uuid4()) + ")")
                        for player in (owner, first)])
        assert all(code == 0 for code, _, _ in results), results
        result_ids = {json.loads(result)["id"] for _, result, _ in results}
        assert len(result_ids) == 1, results
        result_id = result_ids.pop()
        assert sql("select status from public.matches where id=" + literal(result_id)) == "pending"
        assert sql("select count(*) from public.rating_events where match_id=" + literal(result_id)) == "0"
        print("ok   simultaneous result submissions atomically share one unconfirmed result")

        # Hold the game row so join waits after authentication. Account deletion
        # must serialize against the join's active-player check; otherwise the
        # waiting request can add a tombstoned player after cleanup has finished.
        match, _ = game(owner)
        locker_name = PREFIX + "_game_locker"
        locker = subprocess.Popen(PSQL + ["-c", "begin; select id from public.scheduled_matches where id=" + literal(match["id"]) +
                                 " for update; select pg_sleep(3); commit;"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env=dict(os.environ, PGAPPNAME=locker_name))
        deadline = time.monotonic() + 1.5
        while sql("select count(*) from pg_stat_activity where application_name=" + literal(locker_name) + " and wait_event='PgSleep'") != "1":
            assert time.monotonic() < deadline, "game locker did not acquire row"
            time.sleep(.01)
        task_name = PREFIX + "_delete_join"
        join = subprocess.Popen(PSQL + ["-c", act(fourth, "select public.join_scheduled_match(" + literal(match["id"]) + ")")],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, PGAPPNAME=task_name))
        deadline = time.monotonic() + 1.5
        while sql("select count(*) from pg_stat_activity where application_name=" + literal(task_name) + " and wait_event_type='Lock'") != "1":
            assert time.monotonic() < deadline, "join did not contend for held game lock"
            time.sleep(.01)
        sql("begin; select tests.act_as_service(); select public.svc_anonymize_account(" + literal(fourth) + "); commit;")
        join_output, join_error = join.communicate(timeout=5)
        assert join.returncode == 0 or "player_not_found" in join_error, (join.returncode, join_output, join_error)
        assert locker.wait(timeout=5) == 0
        assert sql("select count(*) from public.scheduled_match_players where match_id=" + literal(match["id"]) +
                   " and player_id=" + literal(fourth) + " and status='accepted'") == "0", "deleted account occupied a seat after cleanup"
        print("ok   account deletion cannot leave a waiting join in an admitted seat")

        # A result admitted before deletion may still be waiting for the game
        # lock. Its four profile locks keep the deletion's cleanup from passing
        # it, and cleanup must cancel the new unconfirmed result after that wait.
        match, _ = game(owner)
        for player in (first, second, third):
            sql(act(player, "select public.join_scheduled_match(" + literal(match["id"]) + ")"))
        sql("update public.scheduled_matches set starts_at=now()-interval '4 hours' where id=" + literal(match["id"]))
        payload["played_at"] = sql("select (now()-interval '3 hours')::text")
        locker_name = PREFIX + "_result_locker"
        locker = subprocess.Popen(PSQL + ["-c", "begin; select id from public.scheduled_matches where id=" + literal(match["id"]) +
                                 " for update; select pg_sleep(3); commit;"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env=dict(os.environ, PGAPPNAME=locker_name))
        deadline = time.monotonic() + 1.5
        while sql("select count(*) from pg_stat_activity where application_name=" + literal(locker_name) + " and wait_event='PgSleep'") != "1":
            assert time.monotonic() < deadline, "result locker did not acquire row"
            time.sleep(.01)
        task_name = PREFIX + "_delete_result"
        submit = subprocess.Popen(PSQL + ["-c", act(owner, "select public.submit_scheduled_result(" + literal(match["id"]) + "," + body(payload) +
                                 "," + literal(uuid.uuid4()) + ")")], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  env=dict(os.environ, PGAPPNAME=task_name))
        deadline = time.monotonic() + 1.5
        while sql("select count(*) from pg_stat_activity where application_name=" + literal(task_name) + " and wait_event_type='Lock'") != "1":
            assert time.monotonic() < deadline, "result did not contend for held game lock"
            time.sleep(.01)
        sql("begin; select tests.act_as_service(); select public.svc_anonymize_account(" + literal(third) + "); commit;")
        submit_output, submit_error = submit.communicate(timeout=5)
        assert submit.returncode == 0, (submit.returncode, submit_output, submit_error)
        assert locker.wait(timeout=5) == 0
        result_id = json.loads([line for line in submit_output.splitlines() if line.strip()][-1])["id"]
        assert sql("select status from public.matches where id=" + literal(result_id)) == "cancelled", "waiting result survived deleted participant"
        print("ok   account deletion closes an unconfirmed result submitted while cleanup was waiting")
    finally:
        # Cleanup runs only against this suite's unique users and related rows.
        if players:
            ids = ",".join(literal(player) for player in players)
            sql("begin; delete from public.scheduled_match_players where match_id in (select id from public.scheduled_matches where organizer_id in (" + ids + "));"
                "delete from public.scheduled_matches where organizer_id in (" + ids + ");"
                "delete from public.matches where created_by in (" + ids + ");"
                "delete from public.friendships where player_low in (" + ids + ") or player_high in (" + ids + ");"
                "delete from public.rating_events where player_id in (" + ids + ");"
                "delete from public.player_dna_history where player_id in (" + ids + ");"
                "delete from public.player_dna where player_id in (" + ids + ");"
                "delete from public.dna_self_assessments where player_id in (" + ids + ");"
                "delete from public.player_ratings where player_id in (" + ids + ");"
                "delete from public.profiles where id in (" + ids + ");"
                "delete from auth.users where id in (" + ids + "); commit;")
        sql("drop schema if exists tests cascade")


if __name__ == "__main__":
    if not os.environ.get("PGDATABASE"):
        raise SystemExit("Set PGDATABASE to a disposable migrated test database.")
    main()
