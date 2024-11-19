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