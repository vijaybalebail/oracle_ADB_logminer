# oracle_ADB_logminer
 native LogMiner-based CDC in ADB Serverless,  
```
 Set the password of Admin and ggadmin in the script.  Since you need to run Logminor only in GGADMIN user,  the test case easier to run from sqlplus as it involves swithing between 2 users.

 ============================================================================
 Oracle ADB Serverless LogMiner WORKING Demo Script
 ============================================================================
 Single script - uses CONNECT to switch between users in same session
 Uses DICT_FROM_ONLINE_CATALOG to decode table names properly

 update Connection Strings:
   ADMIN:   admin/Your_password@vbjson_low
   GGADMIN: ggadmin/Your_password@vbjson_low

 Usage: sqlplus /nolog @logminer_working_demo.sql
```
