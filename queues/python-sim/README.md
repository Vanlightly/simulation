# Gathering statistical properties with a Python script

## The script

See the `queues.py` script.

The script uses a rounds-based approach to mimic the 30-second poll interval of client applications. In each iteration, each application calculates its ideal number of queues and releases queues if it has too many.

To test multiple configurations in one go, the main method has a nested loop:

```
file_path = "py_results_lose-one_q10_a2-15.csv"
with (open(file_path, 'w') as file):
    file.write("Run,Rounds,QueueReleases,Algorithm,Scenario,QueueCount,AppCount\n")

    num_samples = 1000 # number of times to run each
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
```

The `run` function executes one configuration, until balance is achieved.

You can set it up by creating a venv and installing the dependencies:

```
(venv) > pip install -r requirements.txt
```

Then run it:

```
python3 queues.py
```

## Visualizing results

This I'll leave to the reader. Out of custom and laziness I tend to stick to ggplot2 with R. But there are plenty of Python data viz libraries. See the R notebook `queues.Rmd`.


## An example that shows why so many queue releases can be needed

Apps a1-a6, with queues q1-q5.

Worst case initial state, for a1 to die.

```
q1: [a1, a2, a3, a4, a5, a6]
q2: [a2, a3, a4, a5, a1, a6]
q3: [a3, a4, a5, a1, a2, a6]
q4: [a4, a5, a1, a2, a3, a6]
q5: [a5, a2, a3, a4, a5, a6]
```

`a1` dies, so `a2` has too many active queues.

```
q1: [a2, a3, a4, a5, a6, a1]
q2: [a2, a3, a4, a5, a1, a6]
q3: [a3, a4, a5, a1, a2, a6]
q4: [a4, a5, a1, a2, a3, a6]
q5: [a5, a2, a3, a4, a5, a6]
```

`a2` releases 1 queue. Now a3 has too many.

```
q1: [a2, a3, a4, a5, a6, a1]
q2: [a3, a4, a5, a1, a6, a2]
q3: [a3, a4, a5, a1, a2, a6]
q4: [a4, a5, a1, a2, a3, a6]
q5: [a5, a2, a3, a4, a5, a6]
```

`a3` releases 1 queue. Now a4 has too many.

```
q1: [a2, a3, a4, a5, a6, a1]
q2: [a3, a4, a5, a1, a6, a2]
q3: [a4, a5, a1, a2, a6, a3]
q4: [a4, a5, a1, a2, a3, a6]
q5: [a5, a2, a3, a4, a5, a6]
```

`a4` releases 1 queue. Now a5 has too many.

```
q1: [a2, a3, a4, a5, a6, a1]
q2: [a3, a4, a5, a1, a6, a2]
q3: [a4, a5, a1, a2, a6, a3]
q4: [a5, a1, a2, a3, a6, a4]
q5: [a5, a2, a3, a4, a5, a6]
```

And so on. `a6` that needs just one active queue, is still far towards the back of all subscriber queues.