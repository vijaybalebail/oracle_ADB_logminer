
-- ============================================================================
-- Oracle ADB Serverless LogMiner WORKING Demo Script
-- ============================================================================
-- Single script - uses CONNECT to switch between users in same session
-- Uses DICT_FROM_ONLINE_CATALOG to decode table names properly
--
-- Connection Strings:
--   ADMIN:   admin/Your_password@vbjson_low
--   GGADMIN: ggadmin/Your_password@vbjson_low
--
-- Usage: sqlplus /nolog @logminer_working_demo.sql
-- ============================================================================

-- Set up spooling to capture output
SPOOL logminer_demo_output.txt

SET ECHO OFF
SET SERVEROUTPUT ON SIZE 1000000
SET LINESIZE 200
SET PAGESIZE 100
SET VERIFY OFF
SET FEEDBACK ON
SET HEADING ON
SET TRIMOUT ON
SET TRIMSPOOL ON

-- ============================================================================
-- PART 1: INITIAL SETUP - Connect as ADMIN
-- ============================================================================

CONNECT admin/Your_password@vbjson_low

PROMPT
PROMPT ============================================================================
PROMPT PART 1: Initial Setup (Connected as ADMIN)
PROMPT ============================================================================
SHOW USER;

-- ============================================================================
-- STEP 1.1: Unlock GGADMIN account and set password
-- ============================================================================

PROMPT
PROMPT Step 1.1: Unlocking GGADMIN account...

ALTER USER ggadmin ACCOUNT UNLOCK;

-- Try to set password, ignore error if password cannot be reused
BEGIN
    EXECUTE IMMEDIATE 'ALTER USER ggadmin IDENTIFIED BY "Saturday_123"';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -28007 THEN
            DBMS_OUTPUT.PUT_LINE('Password already set (cannot reuse)');
        ELSE
            RAISE;
        END IF;
END;
/

-- ============================================================================
-- STEP 1.2: Grant LOGMINING privilege to GGADMIN
-- ============================================================================

PROMPT
PROMPT Step 1.2: Granting LOGMINING privilege to GGADMIN...

GRANT LOGMINING TO ggadmin;

-- ============================================================================
-- STEP 1.3: Create test table and insert initial data
-- ============================================================================

PROMPT
PROMPT Step 1.3: Creating test table...

BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE test_logminer_demo PURGE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN
            RAISE;
        END IF;
END;
/

CREATE TABLE test_logminer_demo (
    id NUMBER PRIMARY KEY,
    test_name VARCHAR2(100),
    test_value NUMBER,
    test_timestamp TIMESTAMP DEFAULT SYSTIMESTAMP,
    test_action VARCHAR2(50)
);

PROMPT
PROMPT Enabling supplemental logging on the table (REQUIRED for LogMiner)...

-- Enable supplemental logging for all columns
ALTER TABLE test_logminer_demo ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

PROMPT Supplemental logging enabled.
PROMPT
PROMPT Initial data (BEFORE LogMiner):

INSERT INTO test_logminer_demo (id, test_name, test_value, test_action)
VALUES (1, 'Record Before LogMiner', 100, 'BEFORE_LOGMINER');

INSERT INTO test_logminer_demo (id, test_name, test_value, test_action)
VALUES (2, 'Another Pre-LogMiner Record', 200, 'BEFORE_LOGMINER');

INSERT INTO test_logminer_demo (id, test_name, test_value, test_action)
VALUES (3, 'Third Pre-LogMiner Record', 300, 'BEFORE_LOGMINER');

COMMIT;

COLUMN id FORMAT 999
COLUMN test_name FORMAT A35
COLUMN test_value FORMAT 9999
COLUMN test_action FORMAT A30

SELECT * FROM test_logminer_demo ORDER BY id;

PROMPT
PROMPT ============================================================================
PROMPT PART 1 COMPLETE
PROMPT ============================================================================
PAUSE Press ENTER to connect as GGADMIN and start LogMiner...

-- ============================================================================
-- PART 2: START LOGMINER - Connect as GGADMIN
-- ============================================================================

CONNECT ggadmin/Your_password@vbjson_low

PROMPT
PROMPT ============================================================================
PROMPT PART 2: Starting LogMiner Session (Connected as GGADMIN)
PROMPT ============================================================================
SHOW USER;

PROMPT
PROMPT Starting LogMiner with TIME range (last 1 hour) and DICT_FROM_ONLINE_CATALOG...
PROMPT This option is CRITICAL for ADB Serverless to decode table names!

-- Start LogMiner using time range and dictionary from online catalog
BEGIN
    dbms_logmnr.start_logmnr(
        STARTTIME => SYSDATE - 1/24,  -- 1 hour ago
        ENDTIME => SYSDATE + 1/24,    -- 1 hour from now
        OPTIONS => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
    );

    DBMS_OUTPUT.PUT_LINE('LogMiner started successfully with DICT_FROM_ONLINE_CATALOG!');
END;
/

PROMPT
PROMPT Verifying LogMiner session is active...

COLUMN session_name FORMAT A30
SELECT SESSION_NAME, DB_ID, START_SCN, END_SCN
FROM V$LOGMNR_SESSION;

PROMPT
PROMPT ============================================================================
PROMPT PART 2 COMPLETE - LogMiner is ACTIVE
PROMPT ============================================================================
PAUSE Press ENTER to connect as ADMIN and perform DML operations...

-- ============================================================================
-- PART 3: INSERT/UPDATE/DELETE DATA - Connect back as ADMIN
-- ============================================================================

CONNECT admin/Your_password@vbjson_low

PROMPT
PROMPT ============================================================================
PROMPT PART 3: Performing DML Operations (Connected as ADMIN)
PROMPT ============================================================================
SHOW USER;

PROMPT
PROMPT Performing DML operations...

INSERT INTO test_logminer_demo (id, test_name, test_value, test_action)
VALUES (4, 'Record During LogMiner', 400, 'DURING_LOGMINER');

INSERT INTO test_logminer_demo (id, test_name, test_value, test_action)
VALUES (5, 'Another During-LogMiner Record', 500, 'DURING_LOGMINER');

COMMIT;

UPDATE test_logminer_demo
SET test_value = test_value + 10,
    test_action = 'UPDATED_DURING_LOGMINER'
WHERE id IN (1, 2);

COMMIT;

DELETE FROM test_logminer_demo WHERE id = 3;

COMMIT;

PROMPT
PROMPT Current state of table (AFTER all operations):

SELECT * FROM test_logminer_demo ORDER BY id;

PROMPT
PROMPT Summary: 2 INSERTs, 2 UPDATEs, 1 DELETE completed
PROMPT
PROMPT ============================================================================
PROMPT PART 3 COMPLETE
PROMPT ============================================================================
PAUSE Press ENTER to connect as GGADMIN and query LogMiner contents...

-- ============================================================================
-- PART 4: QUERY LOGMINER CONTENTS - Connect back to GGADMIN
-- ============================================================================

CONNECT ggadmin/Your_password@vbjson_low

PROMPT
PROMPT ============================================================================
PROMPT PART 4: Querying LogMiner Contents (Connected as GGADMIN)
PROMPT ============================================================================
SHOW USER;

-- Restart LogMiner with DICT_FROM_ONLINE_CATALOG option
PROMPT
PROMPT Restarting LogMiner with DICT_FROM_ONLINE_CATALOG...

BEGIN
    dbms_logmnr.start_logmnr(
        STARTTIME => SYSDATE - 1/24,
        ENDTIME => SYSDATE + 1/24,
        OPTIONS => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
    );
    DBMS_OUTPUT.PUT_LINE('LogMiner restarted');
END;
/

-- ============================================================================
-- STEP 4.1: Count total changes captured
-- ============================================================================

PROMPT
PROMPT Step 4.1: Total changes in LogMiner...

SELECT COUNT(*) as TOTAL_CHANGES
FROM V$LOGMNR_CONTENTS;

-- ============================================================================
-- STEP 4.2: Show what schemas are in LogMiner
-- ============================================================================

PROMPT
PROMPT Step 4.2: Schemas with activity...

SELECT SEG_OWNER, COUNT(*) as ROW_COUNT
FROM V$LOGMNR_CONTENTS
WHERE SEG_OWNER IS NOT NULL
GROUP BY SEG_OWNER
ORDER BY ROW_COUNT DESC
FETCH FIRST 10 ROWS ONLY;

-- ============================================================================
-- STEP 4.3: Summary for our test table
-- ============================================================================

PROMPT
PROMPT Step 4.3: Summary of changes for TEST_LOGMINER_DEMO...

COLUMN operation FORMAT A15
COLUMN operation_count FORMAT 999

SELECT OPERATION,
       COUNT(*) as OPERATION_COUNT
FROM V$LOGMNR_CONTENTS
WHERE SEG_OWNER = 'ADMIN'
  AND TABLE_NAME = 'TEST_LOGMINER_DEMO'
GROUP BY OPERATION
ORDER BY OPERATION;

-- ============================================================================
-- STEP 4.4: View all captured changes with details
-- ============================================================================

PROMPT
PROMPT ============================================================================
PROMPT Step 4.4: ALL captured changes for TEST_LOGMINER_DEMO
PROMPT ============================================================================

COLUMN scn FORMAT 999999999999999
COLUMN timestamp FORMAT A20
COLUMN username FORMAT A10
COLUMN seg_owner FORMAT A10
COLUMN table_name FORMAT A25
COLUMN operation FORMAT A10
COLUMN sql_redo FORMAT A100 WORD_WRAPPED
COLUMN sql_undo FORMAT A100 WORD_WRAPPED

SELECT SCN,
       TO_CHAR(TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS') as TIMESTAMP,
       USERNAME,
       SEG_OWNER,
       TABLE_NAME,
       OPERATION,
       SQL_REDO,
       SQL_UNDO
FROM V$LOGMNR_CONTENTS
WHERE SEG_OWNER = 'ADMIN'
  AND TABLE_NAME = 'TEST_LOGMINER_DEMO'
ORDER BY SCN, SEQUENCE#;

-- ============================================================================
-- STEP 4.5: End LogMiner session
-- ============================================================================

PROMPT
PROMPT ============================================================================
PROMPT Step 4.5: Ending LogMiner session...
PROMPT ============================================================================

EXEC dbms_logmnr.end_logmnr;

SELECT COUNT(*) as ACTIVE_SESSIONS FROM V$LOGMNR_SESSION;

-- ============================================================================
-- PART 5: CLEANUP (OPTIONAL)
-- ============================================================================

PROMPT
PROMPT ============================================================================
PROMPT PART 5: Cleanup
PROMPT ============================================================================
PAUSE Press ENTER to connect as ADMIN for cleanup...

CONNECT admin/Your_password@vbjson_low

SHOW USER;

PROMPT
PROMPT To cleanup, run:
PROMPT   DROP TABLE test_logminer_demo PURGE;

-- Uncomment to drop automatically
/*
DROP TABLE test_logminer_demo PURGE;
PROMPT Table dropped.
*/

-- ============================================================================
-- DEMONSTRATION COMPLETE
-- ============================================================================

PROMPT
PROMPT ============================================================================
PROMPT DEMONSTRATION COMPLETE!
PROMPT ============================================================================
PROMPT
PROMPT What we demonstrated:
PROMPT 1. Unlocked and configured GGADMIN account
PROMPT 2. Granted LOGMINING privilege to GGADMIN
PROMPT 3. Created test table with SUPPLEMENTAL LOGGING enabled (REQUIRED!)
PROMPT 4. Inserted baseline data as ADMIN
PROMPT 5. Started LogMiner with DICT_FROM_ONLINE_CATALOG option (CRITICAL!)
PROMPT 6. Performed INSERT, UPDATE, DELETE operations as ADMIN
PROMPT 7. Queried V$LOGMNR_CONTENTS to see all captured changes
PROMPT 8. Ended LogMiner session
PROMPT
PROMPT Key Findings:
PROMPT - Must use GGADMIN user for LogMiner in ADB Serverless (undocumented)
PROMPT - SUPPLEMENTAL LOGGING must be enabled on tables (ALL COLUMNS recommended)
PROMPT - DICT_FROM_ONLINE_CATALOG option is REQUIRED for table name decoding
PROMPT - Time-based ranges (STARTTIME/ENDTIME) work better than SCN ranges
PROMPT - LogMiner captures all DML with complete SQL_REDO and SQL_UNDO
PROMPT - LogMiner session terminates on CONNECT - must restart to query
PROMPT - Only ONE LogMiner session allowed per ADB instance
PROMPT - Archived logs retained for 7 days in ADB Serverless
PROMPT - V$LOGMNR_CONTENTS queries can be slow - query once and filter results
PROMPT
PROMPT Output saved to: logminer_demo_output.txt
PROMPT ============================================================================

SPOOL OFF
SET ECHO ON
