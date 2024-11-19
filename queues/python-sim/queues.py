from collections import deque
import copy
import random
from itertools import product
from random import random, shuffle
import pandas
import os

SEQ_SUB__ACTIVE_REL = "SEQ_SUB__ACTIVE_REL"
RAND_SUB__ACTIVE_REL = "RAND_SUB__ACTIVE_REL"
SEQ_SUB__NONACTIVE_REL = "SEQ_SUB__NONACTIVE_REL"
RAND_SUB__NONACTIVE_REL = "RAND_SUB__NONACTIVE_REL"
RAND_SUB_PREFIX = "RAND_SUB"
NON_ACTIVE_SUFFIX = "__NONACTIVE_REL"

rmq_queues_sq = {}
app_subscribed = {}
Algorithms = {SEQ_SUB__ACTIVE_REL, RAND_SUB__ACTIVE_REL,
                SEQ_SUB__NONACTIVE_REL, RAND_SUB__NONACTIVE_REL}

PrintToStdOut = False

def std_out(text):
    if PrintToStdOut:
        print(text) 

def balanced(apps, queues_cons):
    # All queues must have an active consumer
    all_queues_active = True
    for queue in queues_cons:
        if not queues_cons[queue]:
            all_queues_active = False
            break

    if not queues_cons:
        return False

    # The number of active consumers per app must be balanced
    # This is measured by ensuring the max-min number of active consumers
    # per app is <= 1.
    is_balanced = True
    min_active = 100000
    max_active = 0
    for app in apps:
        active = active_count(app, queues_cons)
        if active < min_active:
            min_active = active
        if active > max_active:
            max_active = active

    if max_active - min_active > 1:
        is_balanced = False

    return all_queues_active and is_balanced

def print_state(apps, apps_subs, queues_cons):
    for queue in queues_cons:
        std_out(f"Queue: {queue} Cons: {queues_cons[queue]} Active: {queues_cons[queue][0]}")

def is_active(queue, app, queues_cons):
    if len(queues_cons[queue]) > 0:
        return queues_cons[queue][0] == app

    return False

def active_queues(app, queues_cons):
    queues = []

    for queue in queues_cons:
        if is_active(queue, app, queues_cons):
            queues.append(queue)

    return queues

def active_count(app, queues_cons):
    count = 0

    for queue in queues_cons:
        if is_active(queue, app, queues_cons):
            count += 1

    return count


def ideal_number(app, apps, queues_cons):
    # The ideal number takes into account the number of active
    # queues already. This is what the 'position' is used for.
    if len(apps) == 0:
        return 0

    ideal = len(queues_cons) // len(apps)
    remainder = len(queues_cons) % len(apps)
    position = 0
    app_active = active_count(app, queues_cons)
    for clnt in apps:
        active = active_count(clnt, queues_cons)
        if active > app_active:
            position += 1
        elif active == app_active and app < clnt:
            position += 1

    if remainder >= position + 1:
        return ideal + 1
    else:
        return ideal


def release_queue(app, queue):
    global rmq_queues_sq

    # Release the queue by unsubscribing and subscribing again.
    # This puts the consumer at the back of the line for that queue.
    cons = list(rmq_queues_sq[queue])
    cons.remove(app) # unsubscribe
    cons.append(app) # resubscribe
    rmq_queues_sq[queue] = deque(cons)

def do_init_subscribe(algorithm, apps, queues):
    global rmq_queues_sq, app_subscribed

    # Each app subscribes to any queues not subscribed to.
    # The order of the subscriptions impacts the statistical properties.
    # When the algorithm has random subscription order, all apps perform 
    # all subscriptions concurrently with randomized order. Else the
    # apps do their subscriptions one at a time (causing a sequential pattern).
    sub_order = []
    if algorithm.startswith(RAND_SUB_PREFIX):
        sub_order = list(product(apps, queues))
        shuffle(sub_order)
    else:
        app_rand = list(apps)
        shuffle(app_rand)
        for app in app_rand:
            for queue in queues:
                sub_order.append((app, queue))

    for pair in sub_order:
        app, queue = pair
        if queue not in app_subscribed[app]:
            rmq_queues_sq[queue].append(app)
            app_subscribed[app].add(queue)

def setup_perfect_balance(algorithm, apps, queues):
    global rmq_queues_sq, app_subscribed

    # ensure perfect balance, with an initial set of subscriptions
    for queue in queues:
        con = queue % len(apps)
        rmq_queues_sq[queue].append(con)
        app_subscribed[con].add(queue)

    # do the rest of the subscriptions
    do_init_subscribe(algorithm, apps, queues)

def kill_one_active_app(apps):
    global rmq_queues_sq, app_subscribed

    active_apps = set()
    for queue in rmq_queues_sq:
        active_apps.add(rmq_queues_sq[queue][0])

    rand_apps = list(active_apps)
    shuffle(rand_apps)
    kill_app = rand_apps[0]

    for queue in rmq_queues_sq:
        cons = list(rmq_queues_sq[queue])
        cons.remove(kill_app)
        rmq_queues_sq[queue] = deque(cons)

    return kill_app


def run(queue_count, app_count, max_rounds, algorithm, scenario):
    global rmq_queues_sq, app_subscribed
    
    # Identities of queues and apps are integers
    print(f"{queue_count} queues, {app_count} apps, max rounds: {max_rounds}")
    queues = list(range(0, queue_count))
    apps = list(range(0, app_count))

    # Apps track their subscriptions
    app_subscribed = {}
    for app in apps:
        app_subscribed[app] = set()

    # The per-queue subscriber queues 
    rmq_queues_sq = {}
    for queue in queues:
        rmq_queues_sq[queue] = deque()

    # Execute the algorithm as a set of rounds
    round = 1
    queue_releases = 0

    if scenario == "LOSE_ONE_APP":
        # The apps start-up, subscribe to the queues such that they
        # start out with perfect balance. RabbitMQ makes one consumer
        # per queue active (choosing the first app to subscribe).
        # Then one app dies.
        setup_perfect_balance(algorithm, apps, queues)
        do_init_subscribe(algorithm, apps, queues)
        killed_app = kill_one_active_app(apps)
        apps.remove(killed_app)
    else:
        # The apps start-up, subscribe to the queues and RabbitMQ makes one
        # consumer per queue active (choosing the first app to subscribe)
        do_init_subscribe(algorithm, apps, queues)

    std_out("Init state")
    std_out(f"{apps}, {app_subscribed}, {rmq_queues_sq}")

    while round <= max_rounds:
        std_out("-------------------------------------")
        std_out(f"Round {round}")
        # Each app executes one round of the protocol

        for app in apps:
            # 1. Figure out optimum number of assigned queues
            ideal_num = ideal_number(app, apps, rmq_queues_sq)

            # 2. Do a queue release check:
            #   a) Determines the optimum number of active consumers per app
            #   b) Releases one or more queues if the app has too many active consumers
            #   c) If using Active Release, releases all queues where it is not
            #      active, if there exists another client with too few queues
            active_num = active_count(app, rmq_queues_sq)
            diff = active_num - ideal_num
            if diff > 0:
                rel_queues = active_queues(app, rmq_queues_sq)
                shuffle(rel_queues)
                for queue in rel_queues:
                    release_queue(app, queue)
                    queue_releases += 1

                    diff -= 1
                    if diff == 0:
                        break
            elif diff == 0 and algorithm.endswith(NON_ACTIVE_SUFFIX):
                for other_app in apps:
                    if other_app == app:
                        continue

                    other_ideal_num = ideal_number(other_app, apps, rmq_queues_sq)
                    other_active_num = active_count(other_app, rmq_queues_sq)
                    if other_active_num < other_ideal_num:
                        active_qs = active_queues(app, rmq_queues_sq)
                        for queue in rmq_queues_sq:
                            if queue not in active_qs:
                                release_queue(app, queue)
                                queue_releases += 1

        # Print out some state for debugging at the end of the round
        print_state(apps, app_subscribed, rmq_queues_sq)

        # Assess if the queues are now balanced, and stop if so
        if balanced(apps, rmq_queues_sq):
            print("Balanced!")
            return round, queue_releases
        else:
            round += 1

    # We got to the max rounds without balance, this should not happen
    print("NO BALANCE!!! Check for bug or max round is too small.")
    return -1, -1

def calculate_percentiles(csv_path, value_col, group_by_cols_str):
    group_by_cols = group_by_cols_str.split(",")
    out_csv_file = "agg_" + value_col + "__" + os.path.basename(csv_path)
    df = pandas.read_csv(csv_path)
    result = df.groupby(group_by_cols).agg(runs = (value_col,'count'),
                                            min_val = (value_col,'min'),
                                            percentile_50 = (value_col,lambda x: x.quantile(0.5)),
                                            percentile_75 = (value_col,lambda x: x.quantile(0.75)),
                                            percentile_90=(value_col, lambda x: x.quantile(0.9)),
                                            percentile_95 = (value_col, lambda x: x.quantile(0.95)),
                                            percentile_99=(value_col, lambda x: x.quantile(0.99)),
                                            max_val=(value_col, 'max'))


    result.to_csv(out_csv_file, sep=',')
    print(f"Written aggregated data for col {value_col} to {out_csv_file}")

# Press the green button in the gutter to run the script.
if __name__== '__main__':
    file_path = "py_results_lose-one_q10_a2-15.csv"
    with (open(file_path, 'w') as file):
        file.write("Run,Rounds,QueueReleases,Algorithm,Scenario,QueueCount,AppCount\n")

        num_samples = 1000 # number of times to run each configuration
        max_rounds = 1000 # prevent infinite loop in case of a bug
        ctr = 0
        for app_count in range(2, 16):
            for queue_count in range(10, 11):
                for algorithm in Algorithms:
                    for scenario in ["START_UP", "LOSE_ONE_APP"]:
                        for i in range(1, num_samples+1):
                            rounds, queue_releases = run(queue_count, app_count, max_rounds, algorithm, scenario)
                            if rounds > -1:
                                file.write(f"{i},{rounds},{queue_releases},{algorithm},{scenario},{queue_count},{app_count}\n")
                                ctr += 1

    print(f"Written {ctr} results to {file_path}")

    # Calculate percentiles
    calculate_percentiles(file_path, "Rounds", "Algorithm,Scenario,QueueCount,AppCount")