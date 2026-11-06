# PatrullPerson change log (SQL Server 2019)

A SQL Server Agent job that runs every 5 minutes and logs which PatrullID + PersonID
pairs have been **added** to or **deleted** from a source table.

Everything is in one script: [PatrullPerson_ChangeLog.sql](PatrullPerson_ChangeLog.sql).
The setup instructions are at the top of the script and again in the procedure header.

## How it works

- A record is identified by the pair (PatrullID, PersonID). Records never change.
- **Added**: the pair is in the source but not in `PatrullPersonCurrent`, so it is inserted there.
- **Deleted**: the pair is in `PatrullPersonCurrent` but no longer in the source. It is moved
  to `PatrullPersonArchive`, which keeps both its added and its deleted batch and time.
- A person who changes patrol shows up as one Deleted and one Added in the same batch.
- Each run that finds changes gets one **BatchID** (from a SEQUENCE), shared by both tables.
  BatchIDs only go up, so ordering by BatchID gives a timeline.
- All rows in one batch share one timestamp, and the whole batch runs in one transaction.
- Known limitation: a pair that is added and removed within 5 minutes is never seen.

## What the script creates

| Part | Object | Purpose |
| --- | --- | --- |
| 1 | `dbo.PatrullPersonBatchSequence` | BatchID generator |
| 1 | `dbo.PatrullPersonCurrent` | Pairs that exist in the source right now |
| 1 | `dbo.PatrullPersonArchive` | Deleted pairs, with added and deleted batch and time |
| 2 | `dbo.usp_PatrullPerson_SyncChanges` | The procedure that compares and logs |
| 2b | `dbo.vw_PatrullPersonTimeline` | Every Added/Deleted event as one list |
| 3 | SQL Agent job `PatrullPerson - Sync changes` | Runs the procedure every 5 minutes |
| 4 | (comments only) | Example queries |

## Quick start

1. Replace `YourDatabase`, `dbo.PatrullPerson` and, if needed, the data types in the script.
2. Run parts 1, 2 and 2b.
3. Test by hand: `EXEC dbo.usp_PatrullPerson_SyncChanges;`
4. Run part 3 to create the Agent job.
5. Read the history with:

   ```sql
   SELECT * FROM dbo.vw_PatrullPersonTimeline
   ORDER BY BatchID, EventSortOrder, PatrullID;
   ```
