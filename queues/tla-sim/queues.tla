------------------- MODULE queues -------------------
EXTENDS Sequences, Integers, Functions, FiniteSets, FiniteSetsExt, Naturals, TLC, TLCExt, CSV, IOUtils

CONSTANTS MinAppCount,
          MaxAppCount,  
          QueueCount,
          Scenario,
          CSVFile

CONSTANTS SEQ_SUB__ACTIVE_REL,
          RAND_SUB__ACTIVE_REL,
          SEQ_SUB__NONACTIVE_REL,
          RAND_SUB__NONACTIVE_REL,
          LOSE_ONE_APP

ASSUME MaxAppCount \in Nat
ASSUME QueueCount \in Nat

ASSUME
  IOExec(
      <<"bash", "-c", "echo \"Traces,Length,Rounds,QueueReleases,Algorithm,Scenario,QueueCount,AppCount\" > " \o CSVFile>>
      ).exitValue = 0 \* Fail fast if CSVFile was not created.


VARIABLES algorithm,
          apps,               \* the set of all applications of any given behaviour
          queues,             \* the set of all queues of any given behaviour
          subscriber_queue,   \* the First Subscribe, First Active ordering of each queue
          app_queues,         \* the set of queues each app has a consumer for
          per_app_checks      \* number of rounds

vars == << algorithm, apps, queues, subscriber_queue, app_queues, per_app_checks >>


\* ---------------------------------------------
\* HOUSEKEEPING STUFF
\* ---------------------------------------------

\* the counter ids
queue_releases_ctr == 0
rounds_ctr == 1

\* The algorithms, and useful groupings
Algorithms ==
   { SEQ_SUB__ACTIVE_REL,
     RAND_SUB__ACTIVE_REL,
     SEQ_SUB__NONACTIVE_REL,
     RAND_SUB__NONACTIVE_REL }

RandomSubscriberOrderAlgos ==
   { RAND_SUB__ACTIVE_REL,
     RAND_SUB__NONACTIVE_REL }

SeqSubscriberOrderAlgos ==
   { SEQ_SUB__ACTIVE_REL,
     SEQ_SUB__NONACTIVE_REL }
      
ActiveReleaseAlgos ==
   { SEQ_SUB__ACTIVE_REL,
     RAND_SUB__ACTIVE_REL }

NonActiveReleaseAlgos ==
   { SEQ_SUB__NONACTIVE_REL,
     RAND_SUB__NONACTIVE_REL }


\* Printing stuff for debugging
StdOut(text) ==
   TRUE
\*    PrintT(<<TLCGet("stats").behavior.id, TLCGet("stats").traces, TLCGet("level"), text>>)

ActiveCon(q)==
    IF subscriber_queue'[q] # <<>>
    THEN Head(subscriber_queue'[q])
    ELSE 0

PrintQueueState ==
    TRUE
    \* /\ StdOut(<<"Round", per_app_checks', TLCGet(rounds_ctr)>>)
    \* /\ \A q \in queues :
    \*       StdOut([queue |-> q,
    \*               active |-> ActiveCon(q),
    \*               sub_queue |-> subscriber_queue'[q]])


\* Recording statistics
ResetCounters ==
   /\ TLCSet(queue_releases_ctr, 0)
   /\ TLCSet(rounds_ctr, 0)


IncrementReleaseCount(a, release_count) ==
   TLCSet(queue_releases_ctr, TLCGet(queue_releases_ctr) + release_count)


SetRound(round) ==
   IF round > TLCGet(rounds_ctr)
   THEN TLCSet(rounds_ctr, round)
   ELSE TRUE


\* ---------------------------------------------
\* HELPER FORMULAE
\* ---------------------------------------------

AppSubscribedOnAllQueues(a) ==
    \A q \in queues: q \in app_queues[a]

AllAppsSubscribedOnAllQueues ==
   \A a \in apps : AppSubscribedOnAllQueues(a)

AppHasSubscriptions(a) ==
   app_queues[a] # {}

HasActive(q) ==
    subscriber_queue[q] # <<>>

IsActive(q, a) ==
    /\ subscriber_queue[q] # <<>>
    /\ Head(subscriber_queue[q]) = a

\* The number of active consumers the application (a) has
AppActiveCount(a) ==
   Quantify(queues, LAMBDA q : IsActive(q, a))

\* True when:
\* - every queue has an active consumer
\* - every application is started
\* - every application has its number of active consumers <= the ideal number
\* (the ideal number can be 1 higher than it actually gets)
IsBalanced ==
   /\ AllAppsSubscribedOnAllQueues
   /\ \A q \in queues : HasActive(q)
   /\ \A a1, a2 \in apps :
       (AppActiveCount(a1) - AppActiveCount(a2)) \in { -1, 0, 1}


\* The position in the list of apps with active consumers in reverse order,
\* then by app id. Required in order for each app to deterministically
\* make the same decision about when to release a queue.
Position(a) ==
   IF AppActiveCount(a) = 0 THEN -1
   ELSE
       Cardinality({
           a1 \in apps :
               LET a_active == AppActiveCount(a)
                   a1_active == AppActiveCount(a1)
               IN
                   /\ a # a1
                   /\ a1_active > 0
                   /\ \/ a1_active > a_active
                      \/ /\ a1_active = a_active
                         /\ a1 > a
              
       })


SubscribedAppCount ==
   Quantify(apps, LAMBDA a1 : AppHasSubscriptions(a1))


\* Calculates the ideal number of active consumers this app should have.
IdealNumber(a) ==
   LET queue_count == Cardinality(queues)
       app_count == SubscribedAppCount
   IN
       IF app_count = 0 THEN 0
       ELSE
           LET ideal == queue_count \div app_count
               remainder ==  queue_count % app_count
               position == Position(a)
           IN
               IF remainder = 0 THEN ideal
               ELSE
                   IF remainder >= position + 1 THEN
                       ideal + 1
                   ELSE
                       ideal

\* Perform a check as long as:
\* - The balancing has not terminated.
\* - This app is equal to or behind the other apps in terms of
\*   number of checks performed.
\* - All apps are subscribed to all queues.
CanPerformCheck(a) ==
    /\ AllAppsSubscribedOnAllQueues
    /\ \A q \in queues : HasActive(q)
    /\ \A a1 \in apps : per_app_checks[a] <= per_app_checks[a1]
    /\ ~IsBalanced

DoRelease(a, rel_queues) ==
   /\ subscriber_queue' = [q \in queues |->
                               IF q \in rel_queues
                               THEN LET removed  == SelectSeq(subscriber_queue[q], LAMBDA a1: a1 # a)
                                        appended == Append(removed, a)
                                    IN appended
                               ELSE subscriber_queue[q]]

\* ---------------------------------------------
\* ACTIONS
\* ---------------------------------------------
 
(*
   ACTION: SubscribeToOneQueue ------------------
  
   An app subscribes to one queue. This will result in a randomized
   order that will ensure the subscriber queue of each RabbitMQ
   queue will be randomized.
*)
SubscribeToOneQueue(a, q) ==
   \* enabling conditions
   /\ algorithm \in RandomSubscriberOrderAlgos
   /\ q \notin app_queues[a]
   \* actions
   /\ subscriber_queue' = [subscriber_queue EXCEPT ![q] = Append(@, a)]
   /\ app_queues' = [app_queues EXCEPT ![a] = @ \union {q}]
   /\ UNCHANGED << algorithm, apps, queues, per_app_checks >>
\*    /\ StdOut(<<"SubscribeToOneQueue", a, q>>)


(*
   ACTION: SubscribeToAllQueues ------------------
  
   An app subscribes to all of the queues. This will result in all
   queues having the same order of apps in their subscriber queues.
*)
SubscribeToAllQueues(a) ==
   \* enabling conditions
   /\ algorithm \in SeqSubscriberOrderAlgos
   /\ \E q \in queues : q \notin app_queues[a]
   \* actions
   /\ subscriber_queue' = [q \in queues |->
                               IF q \notin app_queues[a] THEN
                                   Append(subscriber_queue[q], a)
                               ELSE
                                   subscriber_queue[q]]
   /\ app_queues' = [app_queues EXCEPT ![a] = queues]
   /\ UNCHANGED << algorithm, apps, queues, per_app_checks >>
   /\ StdOut(<<"SubscribeToAllQueues", a>>)


(*
   ACTION: ActiveReleaseCheck ------------------
  
   An app performs an active queue release check. If it
   has two many active queues, then it releases a corresponding
   number of queues to reach its optimum number.
*)


ReleaseQueues(a, release_count) ==
   \E release_queues \in SUBSET { q \in queues : IsActive(q, a) } :
       /\ Cardinality(release_queues) = release_count
       /\ DoRelease(a, release_queues)
       /\ IncrementReleaseCount(a, release_count)
       /\ StdOut(<<"Release", a, release_queues>>)


ActiveReleaseCheck(a) ==
   \* enabling conditions
   /\ algorithm \in ActiveReleaseAlgos
   /\ CanPerformCheck(a)
   \* actions
   /\ per_app_checks' = [per_app_checks EXCEPT ![a] = @ + 1]
   /\ SetRound(per_app_checks[a] + 1)
   /\ LET release_count == AppActiveCount(a) - IdealNumber(a)
      IN
           /\ IF release_count > 0
              THEN ReleaseQueues(a, release_count)
              ELSE  /\ IncrementReleaseCount(a, 0)
                    /\ UNCHANGED << subscriber_queue >>
           /\ StdOut(<<"ActiveReleaseCheck", a, per_app_checks'[a], release_count, IdealNumber(a), AppActiveCount(a)>>)
           /\ PrintQueueState
   /\ UNCHANGED <<algorithm, apps, queues, app_queues>>


(*
   ACTION: NonActiveReleaseCheck ------------------
  
   An app performs an active queue release check. If it
   has two many active queues, then it releases a corresponding
   number of queues to reach its optimum number.


   However, if it has the perfect number of queues, but it
   detects that another app does not have enough, it releases
   all its non-active queues.
*)


ReleaseNonActiveQueues(a) ==
   LET non_active_queues == {q \in queues : ~IsActive(q, a) }
   IN DoRelease(a, non_active_queues)

ExistsOtherUnderActiveApp ==
   \E a \in apps :
       AppActiveCount(a) < IdealNumber(a)


NonActiveReleaseCheck(a) ==
   \* enabling conditions
   /\ algorithm \in NonActiveReleaseAlgos
   /\ CanPerformCheck(a)
   \* actions
   /\ per_app_checks' = [per_app_checks EXCEPT ![a] = @ + 1]
   /\ SetRound(per_app_checks[a] + 1)
   /\ LET release_count == AppActiveCount(a) - IdealNumber(a)
      IN
           /\ IF release_count > 0 THEN
                  /\ ReleaseQueues(a, release_count)
                  /\ StdOut(<<"NonActiveReleaseCheck", a, release_count, "release active">>)
              ELSE IF release_count = 0 /\ ExistsOtherUnderActiveApp THEN
                  /\ ReleaseNonActiveQueues(a)
                  /\ StdOut(<<"NonActiveReleaseCheck", a, release_count, "release non-active">>)
              ELSE
                  /\ IncrementReleaseCount(a, 0)
                  /\ StdOut(<<"NonActiveReleaseCheck", a, "No releases">>)
                  /\ UNCHANGED << app_queues, subscriber_queue >>
           /\ UNCHANGED << algorithm, apps, queues, app_queues >>


\* ---------------------------------------------
\* STATISTICS
\* ---------------------------------------------

\* Set this as an invariant.
RecordStats ==
   IF IsBalanced
   THEN
           /\ PrintT(<<"Traces", TLCGet("stats").traces, 
                        "Level", TLCGet("level"),
                        "Rounds", TLCGet(rounds_ctr),
                        "Rel", TLCGet(queue_releases_ctr),
                        "A", algorithm, Cardinality(apps), 
                        "Q", Cardinality(queues)>>)
           /\ CSVWrite("%1$s,%2$s,%3$s,%4$s,%5$s,%6$s,%7$s,%8$s",
               <<TLCGet("stats").traces,
                 TLCGet("level"),
                 TLCGet(rounds_ctr),
                 TLCGet(queue_releases_ctr),
                 algorithm,
                 Scenario,
                 Cardinality(queues),
                 Cardinality(apps)>>, CSVFile)
           /\ ResetCounters
   ELSE TRUE

TestInv ==
    TRUE
\*    TLCGet("level") < 200

EventuallyBalanced ==
   ~IsBalanced ~> IsBalanced


\* --------------------------------------
\* Init and Next ------------------------

StartBalancedOneAppDown(down_app, the_apps, the_queues) ==
    LET Con(q) == (q % Cardinality(the_apps)) + 1
        sq     == [q \in the_queues |-> 
                        IF Con(q) = down_app
                        THEN <<>>
                        ELSE <<Con(q)>>]
        remaining == the_apps \ {down_app}
    IN /\ subscriber_queue = sq
       /\ app_queues = [a \in remaining |-> 
                            {q \in the_queues : 
                                /\ sq[q] # <<>>
                                /\ Head(sq[q]) = a}]
       /\ apps = remaining
       /\ per_app_checks = [a \in remaining |-> 0] 

StartUnsubscribed(the_apps, the_queues) ==
    /\ subscriber_queue = [q \in the_queues |-> <<>>]
    /\ app_queues = [a \in the_apps |-> {}] 
    /\ apps = the_apps
    /\ per_app_checks = [a \in the_apps |-> 0] 


InitVars(the_apps, the_queues, algo) ==
   /\ algorithm = algo
   /\ queues = the_queues
   /\ IF Scenario = LOSE_ONE_APP
      THEN \E a \in the_apps : StartBalancedOneAppDown(a, the_apps, the_queues)
      ELSE StartUnsubscribed(the_apps, the_queues)

Init ==
   \E app_count \in MinAppCount..MaxAppCount :
        /\ \E algo \in Algorithms :
            LET the_apps   == 1..app_count
                the_queues == 1..QueueCount
            IN InitVars(the_apps, the_queues, algo)
        /\ ResetCounters

Next ==
    \/ \E a \in apps : ActiveReleaseCheck(a)
    \/ \E a \in apps : NonActiveReleaseCheck(a)
    \/ \E a \in apps : SubscribeToAllQueues(a)
    \/ \E a \in apps, q \in queues : SubscribeToOneQueue(a, q)


(***************************************************************************)
(* Specs                                                                    *)
(***************************************************************************)

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

=============================================================================