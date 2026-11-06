/*******************************************************************************************
  PatrullPerson change log  -  SQL Server 2019
  ------------------------------------------------------------------------------------------
  The script has four parts. Run them top to bottom, in this order:

    PART 1  Sequence + tables  (run once)
    PART 2  Stored procedure   (run once, re-run whenever you change the procedure)
    PART 2b Timeline view      (run once, all Added/Deleted events as one list)
    PART 3  SQL Agent job      (run once, runs the procedure every 5 minutes)
    PART 4  Handy test/inspection queries (optional)

  Before you run anything, search/replace these placeholders:

    YourDatabase           -> the database that holds the source table
    dbo.PatrullPerson      -> your SOURCE table (PatrullID, PersonID)
    NVARCHAR(50) / INT     -> change if PatrullID / PersonID have other data types in the source

  Setup instructions are repeated in the procedure header (PART 2), so they stay with the
  procedure inside the database.
*******************************************************************************************/

USE YourDatabase;
GO

/*==========================================================================================
  PART 1  -  Sequence and tables (run once)
==========================================================================================*/

-- BatchID generator. A number is only taken when a run actually finds something to log.
-- NO CACHE means the numbers are not skipped if the server restarts. A failed run can still
-- leave a gap, which is harmless.
IF OBJECT_ID(N'dbo.PatrullPersonBatchSequence', N'SO') IS NULL
    CREATE SEQUENCE dbo.PatrullPersonBatchSequence
        AS INT
        START WITH 1
        INCREMENT BY 1
        NO CACHE;
GO

-- CURRENT table: every PatrullID + PersonID pair that is in the source right now,
-- with the batch and time it was first seen.
IF OBJECT_ID(N'dbo.PatrullPersonCurrent', N'U') IS NULL
    CREATE TABLE dbo.PatrullPersonCurrent
    (
        Id            INT IDENTITY(1, 1) NOT NULL
                      CONSTRAINT PK_PatrullPersonCurrent PRIMARY KEY CLUSTERED,
        BatchID       INT            NOT NULL,   -- batch in which the pair was added
        PatrullID     NVARCHAR(50)   NOT NULL,
        PersonID      INT            NOT NULL,
        StatusChange  DATETIME2(3)   NOT NULL,   -- when the pair was added
        StatusType    VARCHAR(10)    NOT NULL
                      CONSTRAINT DF_PatrullPersonCurrent_StatusType DEFAULT ('Added')
    );
GO

-- One row per pair. This also makes the "is it already there?" lookups fast.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_PatrullPersonCurrent_Pair')
    CREATE UNIQUE NONCLUSTERED INDEX UX_PatrullPersonCurrent_Pair
        ON dbo.PatrullPersonCurrent (PatrullID, PersonID);
GO

-- ARCHIVE table: pairs that have disappeared from the source.
-- Each row keeps the whole lifetime: when it was added AND when it was deleted.
-- Note: this table must not get triggers or foreign keys, because the procedure fills it
-- with DELETE ... OUTPUT INTO (which does not allow those on the target table).
IF OBJECT_ID(N'dbo.PatrullPersonArchive', N'U') IS NULL
    CREATE TABLE dbo.PatrullPersonArchive
    (
        Id              INT IDENTITY(1, 1) NOT NULL
                        CONSTRAINT PK_PatrullPersonArchive PRIMARY KEY CLUSTERED,
        PatrullID       NVARCHAR(50)   NOT NULL,
        PersonID        INT            NOT NULL,
        AddedBatchID    INT            NOT NULL,   -- copied from the current table
        AddedAt         DATETIME2(3)   NOT NULL,   -- copied from the current table
        DeletedBatchID  INT            NOT NULL,   -- batch that noticed the pair was gone
        DeletedAt       DATETIME2(3)   NOT NULL,   -- when that batch ran
        StatusType      VARCHAR(10)    NOT NULL
                        CONSTRAINT DF_PatrullPersonArchive_StatusType DEFAULT ('Deleted')
    );
GO

-- Makes it quick to look up the history of one patrol or one person.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PatrullPersonArchive_Pair')
    CREATE NONCLUSTERED INDEX IX_PatrullPersonArchive_Pair
        ON dbo.PatrullPersonArchive (PatrullID, PersonID);
GO

-- Recommended (only if the source table doesn't already have it): an index on the pair in the
-- SOURCE table, so the comparison stays fast as the table grows.
-- CREATE UNIQUE NONCLUSTERED INDEX UX_PatrullPerson_Pair ON dbo.PatrullPerson (PatrullID, PersonID);
-- GO


/*==========================================================================================
  PART 2  -  Stored procedure
==========================================================================================*/

/*******************************************************************************************
  Procedure : dbo.usp_PatrullPerson_SyncChanges
  Purpose   : Compares the source table dbo.PatrullPerson with dbo.PatrullPersonCurrent and
              logs the differences.

  How it works
    - A record is identified by the pair (PatrullID, PersonID). Records never change.
    - Added   : the pair is in the source but not in Current  -> inserted into Current.
    - Deleted : the pair is in Current but not in the source  -> moved from Current to Archive
                (keeps AddedBatchID/AddedAt, sets DeletedBatchID/DeletedAt).
    - A person who changes patrol therefore shows up as one Deleted and one Added
      in the same batch.
    - A new BatchID is only taken when there is something to log.
    - All rows in a batch get the same timestamp (the time the run started).
    - Everything happens in one transaction: either the whole batch is logged, or nothing.
    - The first run logs every row in the source as Added (initial load).

  Known limitation (accepted)
    - A pair that is added and removed between two runs (within 5 minutes) is never seen.

  SETUP
    1. Replace the placeholders (YourDatabase, dbo.PatrullPerson, data types) in the script.
    2. Run PART 1 of the script to create the sequence and the two tables.
    3. Run PART 2 to create this procedure.
    4. Test once by hand:   EXEC dbo.usp_PatrullPerson_SyncChanges;
       Then check dbo.PatrullPersonCurrent. Every source row should be there as Added.
    5. Run PART 3 to create the SQL Agent job that runs this every 5 minutes.
       The SQL Server Agent service must be running. The job owner (default 'sa')
       needs rights to the database.
    6. Timestamps use the server's LOCAL time (SYSDATETIME). To store UTC instead, change
       SYSDATETIME() to SYSUTCDATETIME() below. Note that local time repeats one hour when the
       clocks go back in autumn.

  Returns : one row with BatchID (NULL if nothing changed), AddedCount, DeletedCount.
            This is useful for manual runs and is ignored by the Agent job.
*******************************************************************************************/
CREATE OR ALTER PROCEDURE dbo.usp_PatrullPerson_SyncChanges
AS
BEGIN
    SET NOCOUNT ON;     -- no "rows affected" messages
    SET XACT_ABORT ON;  -- any runtime error rolls back the whole transaction

    -- One timestamp for the whole batch, taken once at the start of the run.
    DECLARE @BatchTimestamp  DATETIME2(3) = SYSDATETIME();
    DECLARE @BatchID         INT          = NULL;
    DECLARE @AddedCount      INT          = 0;
    DECLARE @DeletedCount    INT          = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        /*--------------------------------------------------------------------------
          Step 1: Is there anything to do? Only take a BatchID if there is.
        --------------------------------------------------------------------------*/
        IF NOT EXISTS
           (
               -- New pairs: in source, not in current
               SELECT 1
               FROM dbo.PatrullPerson AS SourceRow
               WHERE NOT EXISTS (SELECT 1
                                 FROM dbo.PatrullPersonCurrent AS CurrentRow
                                 WHERE CurrentRow.PatrullID = SourceRow.PatrullID
                                   AND CurrentRow.PersonID  = SourceRow.PersonID)
           )
           AND NOT EXISTS
           (
               -- Removed pairs: in current, not in source
               SELECT 1
               FROM dbo.PatrullPersonCurrent AS CurrentRow
               WHERE NOT EXISTS (SELECT 1
                                 FROM dbo.PatrullPerson AS SourceRow
                                 WHERE SourceRow.PatrullID = CurrentRow.PatrullID
                                   AND SourceRow.PersonID  = CurrentRow.PersonID)
           )
        BEGIN
            -- Nothing changed: no batch, no rows.
            COMMIT TRANSACTION;
            SELECT BatchID = @BatchID, AddedCount = @AddedCount, DeletedCount = @DeletedCount;
            RETURN;
        END;

        /*--------------------------------------------------------------------------
          Step 2: Take the next BatchID.
        --------------------------------------------------------------------------*/
        SET @BatchID = NEXT VALUE FOR dbo.PatrullPersonBatchSequence;

        /*--------------------------------------------------------------------------
          Step 3: Deleted. Remove pairs that are gone from the source and write them
                  to the archive in the same statement (DELETE ... OUTPUT INTO), so a
                  row can never be deleted without being archived.
        --------------------------------------------------------------------------*/
        DELETE CurrentRow
        OUTPUT deleted.PatrullID,
               deleted.PersonID,
               deleted.BatchID,        -- AddedBatchID
               deleted.StatusChange,   -- AddedAt
               @BatchID,               -- DeletedBatchID
               @BatchTimestamp,        -- DeletedAt
               'Deleted'               -- StatusType
        INTO dbo.PatrullPersonArchive
             (PatrullID, PersonID, AddedBatchID, AddedAt, DeletedBatchID, DeletedAt, StatusType)
        FROM dbo.PatrullPersonCurrent AS CurrentRow
        WHERE NOT EXISTS (SELECT 1
                          FROM dbo.PatrullPerson AS SourceRow
                          WHERE SourceRow.PatrullID = CurrentRow.PatrullID
                            AND SourceRow.PersonID  = CurrentRow.PersonID);

        SET @DeletedCount = @@ROWCOUNT;

        /*--------------------------------------------------------------------------
          Step 4: Added. Insert pairs that are new in the source.
                  (Runs after the delete, so a pair that came back after an
                  earlier delete simply becomes a new Added record.)
        --------------------------------------------------------------------------*/
        INSERT INTO dbo.PatrullPersonCurrent (BatchID, PatrullID, PersonID, StatusChange, StatusType)
        SELECT @BatchID,
               SourceRow.PatrullID,
               SourceRow.PersonID,
               @BatchTimestamp,
               'Added'
        FROM dbo.PatrullPerson AS SourceRow
        WHERE NOT EXISTS (SELECT 1
                          FROM dbo.PatrullPersonCurrent AS CurrentRow
                          WHERE CurrentRow.PatrullID = SourceRow.PatrullID
                            AND CurrentRow.PersonID  = SourceRow.PersonID);

        SET @AddedCount = @@ROWCOUNT;

        COMMIT TRANSACTION;

        -- Summary for manual runs.
        SELECT BatchID = @BatchID, AddedCount = @AddedCount, DeletedCount = @DeletedCount;
    END TRY
    BEGIN CATCH
        -- Undo the whole batch and re-raise the error, so the Agent job is marked as failed.
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO


/*==========================================================================================
  PART 2b  -  Timeline view (run once)
==========================================================================================*/

/*******************************************************************************************
  View    : dbo.vw_PatrullPersonTimeline
  Purpose : Every event (Added / Deleted) from both tables as one list, so you can read
            the full history in order.

            - A row in Current       -> one 'Added' event.
            - A row in Archive       -> one 'Added' event AND one 'Deleted' event.

  Columns : BatchID, EventTime, PatrullID, PersonID, EventType,
            EventSortOrder (1 = Deleted, 2 = Added: within one batch, the deletes happened
            first, which is how the procedure runs them).

  Usage   : A view cannot guarantee row order, so always ORDER BY when you select:

            SELECT *
            FROM dbo.vw_PatrullPersonTimeline
            ORDER BY BatchID, EventSortOrder, PatrullID;

            Ordering by BatchID is a true timeline (BatchIDs only ever go up), and unlike
            timestamps it isn't affected by daylight saving time changes.
*******************************************************************************************/
CREATE OR ALTER VIEW dbo.vw_PatrullPersonTimeline
AS
    -- Pairs that are still current: only an Added event so far.
    SELECT BatchID         = CurrentRow.BatchID,
           EventTime       = CurrentRow.StatusChange,
           PatrullID       = CurrentRow.PatrullID,
           PersonID        = CurrentRow.PersonID,
           EventType       = CAST('Added' AS VARCHAR(10)),
           EventSortOrder  = 2
    FROM dbo.PatrullPersonCurrent AS CurrentRow

    UNION ALL

    -- Archived pairs: their original Added event...
    SELECT BatchID         = ArchiveRow.AddedBatchID,
           EventTime       = ArchiveRow.AddedAt,
           PatrullID       = ArchiveRow.PatrullID,
           PersonID        = ArchiveRow.PersonID,
           EventType       = CAST('Added' AS VARCHAR(10)),
           EventSortOrder  = 2
    FROM dbo.PatrullPersonArchive AS ArchiveRow

    UNION ALL

    -- ...and their Deleted event.
    SELECT BatchID         = ArchiveRow.DeletedBatchID,
           EventTime       = ArchiveRow.DeletedAt,
           PatrullID       = ArchiveRow.PatrullID,
           PersonID        = ArchiveRow.PersonID,
           EventType       = CAST('Deleted' AS VARCHAR(10)),
           EventSortOrder  = 1
    FROM dbo.PatrullPersonArchive AS ArchiveRow;
GO


/*==========================================================================================
  PART 3  -  SQL Agent job: run the procedure every 5 minutes, 24/7 (run once)
==========================================================================================*/

USE msdb;
GO

DECLARE @JobName      SYSNAME = N'PatrullPerson - Sync changes';
DECLARE @ScheduleName SYSNAME = N'Every 5 minutes';

-- Remove an older version of the job so the script can be re-run safely.
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
    EXEC msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;

-- The job itself.
EXEC msdb.dbo.sp_add_job
     @job_name    = @JobName,
     @enabled     = 1,
     @description = N'Logs added/deleted PatrullID+PersonID pairs. See dbo.usp_PatrullPerson_SyncChanges.',
     @owner_login_name = N'sa';   -- change if 'sa' is disabled or you use another owner

-- One step: run the procedure in the right database.
EXEC msdb.dbo.sp_add_jobstep
     @job_name      = @JobName,
     @step_name     = N'Run usp_PatrullPerson_SyncChanges',
     @subsystem     = N'TSQL',
     @database_name = N'YourDatabase',
     @command       = N'EXEC dbo.usp_PatrullPerson_SyncChanges;',
     @retry_attempts = 0;

-- Schedule: every day, every 5 minutes, all day long.
EXEC msdb.dbo.sp_add_schedule
     @schedule_name        = @ScheduleName,
     @freq_type            = 4,       -- daily
     @freq_interval        = 1,       -- every day
     @freq_subday_type     = 4,       -- unit = minutes
     @freq_subday_interval = 5,       -- every 5 minutes
     @active_start_time    = 000000,  -- from 00:00:00
     @active_end_time      = 235959;  -- to 23:59:59

EXEC msdb.dbo.sp_attach_schedule @job_name = @JobName, @schedule_name = @ScheduleName;

-- Run the job on this server.
EXEC msdb.dbo.sp_add_jobserver @job_name = @JobName, @server_name = N'(local)';
GO

-- Note: SQL Agent never starts a job that is already running, so a slow run can't
-- overlap with the next one.


/*==========================================================================================
  PART 4  -  Optional: inspection queries
==========================================================================================*/
/*
USE YourDatabase;

-- Run once by hand
EXEC dbo.usp_PatrullPerson_SyncChanges;

-- What is current right now
SELECT * FROM dbo.PatrullPersonCurrent ORDER BY BatchID DESC, PatrullID;

-- What has been deleted, newest first
SELECT * FROM dbo.PatrullPersonArchive ORDER BY DeletedBatchID DESC, PatrullID;

-- Full timeline of all events
SELECT * FROM dbo.vw_PatrullPersonTimeline
ORDER BY BatchID, EventSortOrder, PatrullID;

-- Timeline for one patrol
SELECT * FROM dbo.vw_PatrullPersonTimeline
WHERE PatrullID = N'A'
ORDER BY BatchID, EventSortOrder;

-- What happened in the latest batch
SELECT * FROM dbo.vw_PatrullPersonTimeline
WHERE BatchID = (SELECT MAX(BatchID) FROM dbo.vw_PatrullPersonTimeline)
ORDER BY EventSortOrder, PatrullID;

-- Job run history
EXEC msdb.dbo.sp_help_jobhistory @job_name = N'PatrullPerson - Sync changes';
*/
