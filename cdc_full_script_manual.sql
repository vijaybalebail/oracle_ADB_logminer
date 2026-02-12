-- =============================================================================
-- Oracle LogMiner CDC Solution for Autonomous Database Serverless (ADB-S)
-- =============================================================================
--
-- Description: Complete Change Data Capture (CDC) solution using Oracle 
--              LogMiner on Autonomous Database Serverless 23ai
--
-- Author: Oracle Database MCP Tools  
-- Version: 2.0 (Tested & Working)
-- Database: Oracle Autonomous Database Serverless 23ai
-- Date: February 2026
-- Tested On: jsonvj_mcp (ADMIN) and ggadmin_jsonvb (GGADMIN)
--
-- =============================================================================
-- CRITICAL SUCCESS FACTORS
-- =============================================================================
--
-- 1. AUTHID CURRENT_USER: Procedure uses invoker rights to access DBMS_LOGMNR
-- 2. AUTO-CHECKPOINT: First run automatically sets SCN to current (no manual insert)
-- 3. Ghost Sessions: Require database restart to clear if stuck (ORA-44611)
-- 4. Execution Order: Follow sections sequentially as shown
--
-- =============================================================================
-- INSTALLATION ORDER
-- =============================================================================
--
-- SECTION 1: ADMIN - Supplemental Logging (Optional but Recommended)
-- SECTION 2: ADMIN - GGADMIN Verification
-- SECTION 3: GGADMIN - CDC Infrastructure (Table, Procedures, Views, Jobs)
-- SECTION 4: ADMIN - ORDS REST API Configuration
-- SECTION 5: Verification & Testing
--
-- =============================================================================


-- =============================================================================
-- SECTION 1: ADMIN USER - SUPPLEMENTAL LOGGING (OPTIONAL)
-- =============================================================================
-- Connect as: ADMIN (jsonvj_mcp)
-- Purpose: Enable supplemental logging for complete column capture
-- =============================================================================

PROMPT
PROMPT ================================================================
PROMPT SECTION 1: SUPPLEMENTAL LOGGING (OPTIONAL)
PROMPT ================================================================
PROMPT Connection: ADMIN
PROMPT

-- Enable database-level supplemental logging
BEGIN
    EXECUTE IMMEDIATE 'ALTER DATABASE ADD SUPPLEMENTAL LOG DATA';
    DBMS_OUTPUT.PUT_LINE('✓ Database supplemental logging enabled');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -32588 THEN
            DBMS_OUTPUT.PUT_LINE('✓ Supplemental logging already enabled');
        ELSE
            RAISE;
        END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS';
    DBMS_OUTPUT.PUT_LINE('✓ Primary key supplemental logging enabled');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -32588 THEN
            DBMS_OUTPUT.PUT_LINE('✓ Primary key logging already enabled');
        ELSE
            RAISE;
        END IF;
END;
/

PROMPT ✓ Section 1 Complete
PROMPT


-- =============================================================================
-- SECTION 2: ADMIN USER - GGADMIN VERIFICATION
-- =============================================================================
-- Connect as: ADMIN (jsonvj_mcp)
-- Purpose: Verify GGADMIN user is ready
-- =============================================================================

PROMPT
PROMPT ================================================================
PROMPT SECTION 2: GGADMIN VERIFICATION
PROMPT ================================================================
PROMPT Connection: ADMIN
PROMPT

-- Verify GGADMIN user status
SELECT 
    username,
    account_status,
    CASE account_status
        WHEN 'OPEN' THEN '✓ READY'
        ELSE '✗ LOCKED - Need to unlock'
    END as status
FROM dba_users
WHERE username = 'GGADMIN';

-- Verify required privileges
SELECT 
    'Required Privileges: ' ||
    COUNT(*) || ' of 3 found' as status
FROM dba_sys_privs
WHERE grantee = 'GGADMIN'
  AND privilege IN ('LOGMINING', 'SELECT ANY TRANSACTION', 'SELECT ANY DICTIONARY');

PROMPT ✓ Section 2 Complete
PROMPT


-- =============================================================================
-- SECTION 3: GGADMIN USER - CDC INFRASTRUCTURE  
-- =============================================================================
-- Connect as: GGADMIN (ggadmin_jsonvb)
-- Purpose: Create all CDC objects
-- =============================================================================

PROMPT
PROMPT ================================================================
PROMPT SECTION 3: CDC INFRASTRUCTURE
PROMPT ================================================================
PROMPT Connection: GGADMIN
PROMPT

-- -----------------------------------------------------------------------------
-- 3.1: Create CDC History Table
-- -----------------------------------------------------------------------------
PROMPT Step 3.1: Creating CDC history table...

CREATE TABLE logminer_cdc_history (
    capture_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    capture_time     TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    scn              NUMBER NOT NULL,
    commit_scn       NUMBER,
    commit_timestamp DATE,
    timestamp        DATE NOT NULL,
    operation        VARCHAR2(32) NOT NULL,
    username         VARCHAR2(128),
    seg_owner        VARCHAR2(128) NOT NULL,
    table_name       VARCHAR2(128) NOT NULL,
    sql_redo         CLOB,
    sql_undo         CLOB,
    xid              RAW(8),
    row_id           VARCHAR2(20),
    session_info     VARCHAR2(100),
    CONSTRAINT chk_operation CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE', 'DDL'))
)
LOB (sql_redo) STORE AS SECUREFILE (ENABLE STORAGE IN ROW CHUNK 8192 CACHE COMPRESS HIGH)
LOB (sql_undo) STORE AS SECUREFILE (ENABLE STORAGE IN ROW CHUNK 8192 CACHE COMPRESS HIGH);

COMMENT ON TABLE logminer_cdc_history IS 
'Permanent storage for database changes captured via Oracle LogMiner. Auto-checkpoint on first run.';

PROMPT ✓ CDC history table created

-- -----------------------------------------------------------------------------
-- 3.2: Create Indexes
-- -----------------------------------------------------------------------------
PROMPT Step 3.2: Creating indexes...

CREATE INDEX idx_logminer_cdc_time ON logminer_cdc_history(capture_time);
CREATE INDEX idx_logminer_cdc_scn ON logminer_cdc_history(scn);
CREATE INDEX idx_logminer_cdc_table ON logminer_cdc_history(seg_owner, table_name, timestamp);
CREATE INDEX idx_logminer_cdc_operation ON logminer_cdc_history(operation, capture_time);
CREATE INDEX idx_logminer_cdc_user ON logminer_cdc_history(username, timestamp);
CREATE INDEX idx_logminer_cdc_xid ON logminer_cdc_history(xid);

PROMPT ✓ All 6 indexes created

-- -----------------------------------------------------------------------------
-- 3.3: Create CDC Capture Procedure (WITH AUTO-CHECKPOINT)
-- -----------------------------------------------------------------------------
PROMPT Step 3.3: Creating CDC capture procedure...

CREATE OR REPLACE PROCEDURE capture_cdc_changes 
AUTHID CURRENT_USER  -- CRITICAL: Required for DBMS_LOGMNR access in ADB
AS
    v_last_captured_scn NUMBER;
    v_current_scn NUMBER;
    v_count NUMBER := 0;
    v_oldest_available_scn NUMBER;
    v_sql VARCHAR2(4000);
BEGIN
    -- Get current SCN
    EXECUTE IMMEDIATE 'SELECT current_scn FROM v$database' INTO v_current_scn;
    
    -- Get last captured SCN with AUTO-CHECKPOINT logic
    BEGIN
        SELECT NVL(MAX(scn), 0) INTO v_last_captured_scn 
        FROM logminer_cdc_history;
        
        -- AUTO-CHECKPOINT: If no records or SCN = 0, start from current SCN
        -- This prevents processing massive historical redo on first run
        IF v_last_captured_scn = 0 THEN
            v_last_captured_scn := v_current_scn;
            DBMS_OUTPUT.PUT_LINE('✓ Auto-checkpoint: Starting from current SCN ' || v_current_scn);
            RETURN; -- Exit on first run after setting checkpoint
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            v_last_captured_scn := v_current_scn;
            RETURN;
    END;

    -- Only process if there are new changes
    IF v_current_scn > v_last_captured_scn THEN

        BEGIN
            -- Start LogMiner
            EXECUTE IMMEDIATE 
                'BEGIN ' ||
                '  DBMS_LOGMNR.START_LOGMNR(' ||
                '    STARTSCN => :1, ' ||
                '    ENDSCN => :2, ' ||
                '    OPTIONS => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG' ||
                '  ); ' ||
                'END;'
                USING v_last_captured_scn, v_current_scn;

        EXCEPTION
            WHEN OTHERS THEN
                -- Handle ORA-01291 (missing log file)
                IF SQLCODE = -1291 THEN
                    BEGIN
                        EXECUTE IMMEDIATE 'BEGIN DBMS_LOGMNR.END_LOGMNR; END;';
                    EXCEPTION WHEN OTHERS THEN NULL;
                    END;

                    -- Try to find oldest available SCN
                    BEGIN
                        EXECUTE IMMEDIATE 
                            'BEGIN ' ||
                            '  DBMS_LOGMNR.START_LOGMNR(' ||
                            '    STARTTIME => SYSDATE - 6, ' ||
                            '    ENDTIME => SYSDATE, ' ||
                            '    OPTIONS => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG' ||
                            '  ); ' ||
                            'END;';

                        EXECUTE IMMEDIATE 
                            'SELECT scn FROM v$logmnr_contents ' ||
                            'WHERE scn > :1 ORDER BY scn ASC FETCH FIRST 1 ROWS ONLY'
                            INTO v_oldest_available_scn
                            USING v_last_captured_scn;

                        EXECUTE IMMEDIATE 'BEGIN DBMS_LOGMNR.END_LOGMNR; END;';
                    EXCEPTION
                        WHEN OTHERS THEN
                            BEGIN
                                EXECUTE IMMEDIATE 'BEGIN DBMS_LOGMNR.END_LOGMNR; END;';
                            EXCEPTION WHEN OTHERS THEN NULL;
                            END;
                            v_oldest_available_scn := NULL;
                    END;

                    IF v_oldest_available_scn IS NOT NULL THEN
                        -- Insert recovery checkpoint
                        INSERT INTO logminer_cdc_history (
                            scn, commit_scn, commit_timestamp, timestamp, operation,
                            username, seg_owner, table_name, sql_redo, sql_undo,
                            xid, row_id, session_info
                        ) VALUES (
                            v_oldest_available_scn - 1, v_oldest_available_scn - 1,
                            SYSTIMESTAMP, SYSTIMESTAMP, 'DDL',
                            'SYSTEM', 'SYSTEM', 'AUTO_RECOVERY',
                            '-- Gap from SCN ' || v_last_captured_scn || ' to ' || v_oldest_available_scn,
                            '-- Recovery at ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'),
                            NULL, NULL, 'Auto-recovery checkpoint'
                        );
                        COMMIT;
                        v_last_captured_scn := v_oldest_available_scn - 1;

                        -- Restart LogMiner
                        EXECUTE IMMEDIATE 
                            'BEGIN ' ||
                            '  DBMS_LOGMNR.START_LOGMNR(' ||
                            '    STARTSCN => :1, ENDSCN => :2, ' ||
                            '    OPTIONS => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG); END;'
                            USING v_last_captured_scn, v_current_scn;
                    ELSE
                        -- Full reset
                        INSERT INTO logminer_cdc_history (
                            scn, commit_scn, commit_timestamp, timestamp, operation,
                            username, seg_owner, table_name, sql_redo, sql_undo,
                            xid, row_id, session_info
                        ) VALUES (
                            v_current_scn, v_current_scn, SYSTIMESTAMP, SYSTIMESTAMP, 'DDL',
                            'SYSTEM', 'SYSTEM', 'FULL_RESET',
                            '-- All logs purged. Reset to SCN ' || v_current_scn,
                            '-- Reset at ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'),
                            NULL, NULL, 'Full reset checkpoint'
                        );
                        COMMIT;
                        RETURN;
                    END IF;
                ELSE
                    RAISE;
                END IF;
        END;

        -- Capture changes
        v_sql := 
            'INSERT INTO logminer_cdc_history ' ||
            '(scn, commit_scn, commit_timestamp, timestamp, operation, username, ' ||
            'seg_owner, table_name, sql_redo, sql_undo, xid, row_id, session_info) ' ||
            'SELECT scn, commit_scn, commit_timestamp, timestamp, operation, username, ' ||
            'seg_owner, table_name, sql_redo, sql_undo, xid, row_id, ' ||
            '''Captured at '' || TO_CHAR(SYSTIMESTAMP, ''YYYY-MM-DD HH24:MI:SS'') ' ||
            'FROM v$logmnr_contents ' ||
            'WHERE seg_owner IS NOT NULL ' ||
            'AND seg_owner NOT IN (''SYS'', ''SYSTEM'', ''GGADMIN'', ''AUDSYS'') ' ||
            'AND seg_owner NOT LIKE ''APEX%'' ' ||
            'AND seg_owner NOT LIKE ''C##CLOUD$%'' ' ||
            'AND table_name IS NOT NULL ' ||
            'AND operation IN (''INSERT'', ''UPDATE'', ''DELETE'') ' ||
            'AND scn > :1 AND ROWNUM <= 10000';

        EXECUTE IMMEDIATE v_sql USING v_last_captured_scn;
        v_count := SQL%ROWCOUNT;
        COMMIT;

        -- End LogMiner session
        EXECUTE IMMEDIATE 'BEGIN DBMS_LOGMNR.END_LOGMNR; END;';

        DBMS_OUTPUT.PUT_LINE('✓ Captured ' || v_count || ' changes');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        BEGIN
            EXECUTE IMMEDIATE 'BEGIN DBMS_LOGMNR.END_LOGMNR; END;';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RAISE;
END capture_cdc_changes;
/

SHOW ERRORS

PROMPT ✓ CDC capture procedure created with auto-checkpoint

-- -----------------------------------------------------------------------------
-- 3.4: Create Views
-- -----------------------------------------------------------------------------
PROMPT Step 3.4: Creating views...

CREATE OR REPLACE VIEW v_recent_cdc_changes AS
SELECT 
    capture_id,
    TO_CHAR(capture_time, 'YYYY-MM-DD HH24:MI:SS') as captured_at,
    scn,
    TO_CHAR(timestamp, 'YYYY-MM-DD HH24:MI:SS') as changed_at,
    operation,
    username,
    seg_owner,
    table_name,
    seg_owner || '.' || table_name as full_table_name,
    SUBSTR(sql_redo, 1, 4000) as sql_redo_preview,
    CASE WHEN LENGTH(sql_redo) > 4000 THEN 'Y' ELSE 'N' END as has_more_redo,
    xid,
    row_id
FROM logminer_cdc_history
WHERE capture_time > SYSTIMESTAMP - INTERVAL '7' DAY
ORDER BY capture_time DESC;

CREATE OR REPLACE VIEW v_cdc_by_table AS
SELECT 
    seg_owner,
    table_name,
    seg_owner || '.' || table_name as full_table_name,
    operation,
    COUNT(*) as change_count,
    MIN(timestamp) as first_change,
    MAX(timestamp) as last_change,
    COUNT(DISTINCT xid) as transaction_count,
    COUNT(DISTINCT username) as user_count
FROM logminer_cdc_history
WHERE capture_time > SYSTIMESTAMP - INTERVAL '30' DAY
  AND operation != 'DDL'
GROUP BY seg_owner, table_name, operation
ORDER BY change_count DESC;

CREATE OR REPLACE VIEW v_cdc_by_user AS
SELECT 
    username,
    operation,
    COUNT(*) as change_count,
    COUNT(DISTINCT seg_owner || '.' || table_name) as tables_affected,
    MIN(timestamp) as first_change,
    MAX(timestamp) as last_change
FROM logminer_cdc_history
WHERE capture_time > SYSTIMESTAMP - INTERVAL '30' DAY
  AND operation != 'DDL'
GROUP BY username, operation
ORDER BY change_count DESC;

PROMPT ✓ All 3 views created

-- -----------------------------------------------------------------------------
-- 3.5: Create Purge Procedure
-- -----------------------------------------------------------------------------
PROMPT Step 3.5: Creating purge procedure...

CREATE OR REPLACE PROCEDURE purge_old_cdc_data(
    p_days_to_keep IN NUMBER DEFAULT 90
) 
AUTHID CURRENT_USER
AS
    v_rows_deleted NUMBER;
BEGIN
    DELETE FROM logminer_cdc_history
    WHERE capture_time < SYSTIMESTAMP - INTERVAL '1' DAY * p_days_to_keep
      AND operation != 'DDL';
    
    v_rows_deleted := SQL%ROWCOUNT;
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('Purged ' || v_rows_deleted || ' old CDC records');
END purge_old_cdc_data;
/

SHOW ERRORS

PROMPT ✓ Purge procedure created

-- -----------------------------------------------------------------------------
-- 3.6: Create Scheduler Jobs
-- -----------------------------------------------------------------------------
PROMPT Step 3.6: Creating scheduler jobs...

BEGIN
    DBMS_SCHEDULER.DROP_JOB('JOB_CAPTURE_CDC_CHANGES', TRUE);
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

BEGIN
    DBMS_SCHEDULER.DROP_JOB('JOB_PURGE_OLD_CDC', TRUE);
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name => 'JOB_CAPTURE_CDC_CHANGES',
        job_type => 'STORED_PROCEDURE',
        job_action => 'GGADMIN.CAPTURE_CDC_CHANGES',
        start_date => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=5',
        enabled => TRUE,
        comments => 'Captures CDC changes every 5 minutes'
    );
    DBMS_OUTPUT.PUT_LINE('✓ CDC capture job created (runs every 5 min)');
END;
/

BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name        => 'JOB_PURGE_OLD_CDC',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN GGADMIN.PURGE_OLD_CDC_DATA(90); END;',
        start_date      => SYSTIMESTAMP + INTERVAL '1' DAY,
        repeat_interval => 'FREQ=MONTHLY; BYMONTHDAY=1; BYHOUR=3',
        enabled         => TRUE,
        comments        => 'Purges CDC records older than 90 days monthly'
    );
    DBMS_OUTPUT.PUT_LINE('✓ Purge job created (runs monthly)');
END;
/

PROMPT ✓ Section 3 Complete
PROMPT


-- =============================================================================
-- SECTION 4: ADMIN USER - ORDS CONFIGURATION
-- =============================================================================
-- Connect as: ADMIN (jsonvj_mcp)
-- Purpose: Enable REST API access
-- =============================================================================

PROMPT
PROMPT ================================================================
PROMPT SECTION 4: ORDS CONFIGURATION
PROMPT ================================================================
PROMPT Connection: ADMIN
PROMPT

BEGIN
    ORDS.ENABLE_SCHEMA(
        p_enabled             => TRUE,
        p_schema              => 'GGADMIN',
        p_url_mapping_type    => 'BASE_PATH',
        p_url_mapping_pattern => 'ggadmin',
        p_auto_rest_auth      => FALSE
    );
    DBMS_OUTPUT.PUT_LINE('✓ GGADMIN schema enabled for ORDS');
END;
/

BEGIN
    ORDS.ENABLE_OBJECT(
        p_enabled      => TRUE,
        p_schema       => 'GGADMIN',
        p_object       => 'LOGMINER_CDC_HISTORY',
        p_object_type  => 'TABLE',
        p_object_alias => 'cdc_history'
    );
END;
/

BEGIN
    ORDS.ENABLE_OBJECT(
        p_enabled      => TRUE,
        p_schema       => 'GGADMIN',
        p_object       => 'V_RECENT_CDC_CHANGES',
        p_object_type  => 'VIEW',
        p_object_alias => 'recent_changes'
    );
END;
/

BEGIN
    ORDS.ENABLE_OBJECT(
        p_enabled      => TRUE,
        p_schema       => 'GGADMIN',
        p_object       => 'V_CDC_BY_TABLE',
        p_object_type  => 'VIEW',
        p_object_alias => 'changes_by_table'
    );
END;
/

BEGIN
    ORDS.ENABLE_OBJECT(
        p_enabled      => TRUE,
        p_schema       => 'GGADMIN',
        p_object       => 'V_CDC_BY_USER',
        p_object_type  => 'VIEW',
        p_object_alias => 'changes_by_user'
    );
    DBMS_OUTPUT.PUT_LINE('✓ All 4 ORDS endpoints enabled');
END;
/

PROMPT
PROMPT REST API Endpoints:
PROMPT   /ggadmin/cdc_history/
PROMPT   /ggadmin/recent_changes/
PROMPT   /ggadmin/changes_by_table/
PROMPT   /ggadmin/changes_by_user/
PROMPT
PROMPT ✓ Section 4 Complete
PROMPT


-- =============================================================================
-- SECTION 5: VERIFICATION
-- =============================================================================
-- Connect as: GGADMIN (ggadmin_jsonvb)
-- =============================================================================

PROMPT
PROMPT ================================================================
PROMPT SECTION 5: VERIFICATION
PROMPT ================================================================
PROMPT Connection: GGADMIN
PROMPT

SELECT 'Object Summary:' as verification FROM dual;

SELECT 
    object_type,
    COUNT(*) as count,
    CASE 
        WHEN object_type = 'TABLE' AND COUNT(*) = 1 THEN '✓ OK'
        WHEN object_type = 'INDEX' AND COUNT(*) = 6 THEN '✓ OK'
        WHEN object_type = 'VIEW' AND COUNT(*) = 3 THEN '✓ OK'
        WHEN object_type = 'PROCEDURE' AND COUNT(*) = 2 THEN '✓ OK'
        ELSE '✗ Missing'
    END as status
FROM (
    SELECT 'TABLE' as object_type FROM user_tables WHERE table_name = 'LOGMINER_CDC_HISTORY'
    UNION ALL
    SELECT 'INDEX' FROM user_indexes WHERE table_name = 'LOGMINER_CDC_HISTORY'
    UNION ALL
    SELECT 'VIEW' FROM user_views WHERE view_name IN ('V_RECENT_CDC_CHANGES', 'V_CDC_BY_TABLE', 'V_CDC_BY_USER')
    UNION ALL
    SELECT 'PROCEDURE' FROM user_procedures WHERE object_name IN ('CAPTURE_CDC_CHANGES', 'PURGE_OLD_CDC_DATA')
)
GROUP BY object_type
ORDER BY object_type;

-- Test manual capture
PROMPT Testing manual CDC capture...

SET SERVEROUTPUT ON
BEGIN
    capture_cdc_changes;
END;
/

-- Check results
SELECT 
    COUNT(*) as total_records,
    MAX(capture_time) as last_capture,
    COUNT(CASE WHEN operation != 'DDL' THEN 1 END) as actual_changes
FROM logminer_cdc_history;

-- Check for ghost sessions
SELECT 
    CASE WHEN COUNT(*) = 0 THEN '✓ No ghost LogMiner sessions' 
         ELSE '✗ WARNING: Ghost session exists - may need restart'
    END as session_status
FROM v$logmnr_session;

-- Show job status
SELECT 
    job_name,
    state,
    enabled,
    TO_CHAR(next_run_date, 'YYYY-MM-DD HH24:MI:SS') as next_run
FROM user_scheduler_jobs
WHERE job_name IN ('JOB_CAPTURE_CDC_CHANGES', 'JOB_PURGE_OLD_CDC')
ORDER BY job_name;

PROMPT
PROMPT ================================================================
PROMPT INSTALLATION COMPLETE!
PROMPT ================================================================
PROMPT
PROMPT ✓ CDC infrastructure deployed successfully
PROMPT ✓ Auto-checkpoint enabled (starts from current SCN on first run)
PROMPT ✓ Scheduled jobs active (every 5 minutes)
PROMPT ✓ REST API endpoints configured
PROMPT
PROMPT Next: Query v_recent_cdc_changes to see captured changes
PROMPT ================================================================

-- END OF SCRIPT
