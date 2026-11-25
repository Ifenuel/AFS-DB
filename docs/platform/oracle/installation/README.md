# Oracle AI Database 26ai Free — Windows installation record

**Result: installed and running on this laptop on 2026-11-24.**

| Item | Value |
|---|---|
| Edition | Oracle AI Database 26ai Free, `sqlplus` 23.26.4.0.0 |
| Media | `Oracle AI Database 26ai Free.msi` + `setup.exe`, 1,401,811,861 bytes |
| Oracle home | `C:\app\oraclelab\product\26ai\dbhomeFree` |
| Oracle base | `C:\app\oraclelab\product\26ai` |
| CDB / PDB | `FREE` / `FREEPDB1`, both `READ WRITE` |
| Listener | port 1521, service `OracleOraDB23Home1TNSListener` (`tnslsnr.exe`) |
| Database service | `OracleServiceFREE`, running under `NT SERVICE\OracleServiceFREE` |
| Log mode | `NOARCHIVELOG` (default; see `oracle/backup/README.md`) |

The installer's log is `C:\oracle\media\free\install-system.log`; the setup wrapper is
`C:\oracle\media\install-oracle.cmd`. Local credentials are in
`C:\oracle\admin\oracle-lab-credentials.txt` and are deliberately outside this repository.

## 1. Why the default path fails on this machine

The Windows account is `ELITE X2`. The installer builds its home from the logon name:

```
PROPERTY CHANGE: Modifying INSTALLDIR property. Its current value is 'C:\app\[USERNAME]\product\23ai\'.
Its new value: 'C:\app\ELITE X2\product\26ai\'.
SEVERE: The provided destination folder has invalid characters. Verify and try again.
Action ended: ValidateRspFileInputs. Return value 3.
```

Oracle homes cannot contain spaces, so `C:\app\ELITE X2\...` is rejected. This is not a
permissions problem and no response-file value survives it: `SetDefaultINSTALLDIR` rewrites
`INSTALLDIR` after `LoadResponseFile`, so `INSTALLDIR=`, `ORACLE_HOME=` and `ORACLE_BASE=`
in `FREEInstall.rsp` are all overwritten.

The GUI "Change…" dialog was attempted and is not scriptable: the InstallShield pages are
owner-drawn, so UI Automation exposes them as unnamed panes with no `InvokePattern`, and the
folder picker accepts typed text but never commits it.

## 2. What does work: a space-free local administrator name

The installer needs the invoking account to be a local administrator and to have a name
without spaces. The silent install was therefore run under a temporary local account,
`oraclelab`, which produced `C:\app\oraclelab\product\26ai` and completed without validation
errors.

Running as `SYSTEM` was tried first and fails later in the same action:

```
SEVERE: A system error has occurred while gathering the groups of the user
SEVERE: User must have administrator privileges
Action ended: ValidateRspFileInputs. Return value 3.
```

`SYSTEM` is not a local account, so the group enumeration behind that check cannot succeed.

Steps, as executed:

1. Create the temporary account and add it to `Administrators`.
2. Create a one-off scheduled task that runs `install-oracle.cmd` as that account with
   highest privileges (an interactive shell cannot switch user without a password prompt).
3. The batch runs `setup.exe /s /v"/qn PASSWORD=… LISTENER_PORT=1521 /l*v …"`, writes an
   exit code to `install-result.txt`, and deletes the scheduled task.
4. Wait for `OracleServiceFREE` to report `RUNNING`, confirm port 1521 is listening, then
   connect with SQL*Plus.
5. Disable the temporary account once the database answers. The Oracle services do not use
   it: both run as `NT SERVICE\…` virtual accounts. Administrators were granted full control
   of `C:\app\oraclelab` first so the home stays manageable.

`oracle/installation/01_install_silent.ps1` reproduces steps 1-4 and reads the account
password from `C:\oracle\admin\lab_user_password.txt` rather than storing it in the repo.

## 3. Verification performed

| Check | Result |
|---|---|
| `select banner_full from v$version` | `Oracle AI Database 26ai Free Release 23.26.4.0.0` |
| `v$database` | `FREE`, `READ WRITE`, `PRIMARY` |
| `v$pdbs` | `FREEPDB1`, `READ WRITE` |
| `lsnrctl status` | `FREE`, `FREEPDB1`, `FREEXDB` services `READY` on 1521 |
| `create user afs_lab …` (authored script, executed) | user created, 5 system privileges, no roles |
| `tests/01_smoke.sql` | 2 accounts, 2 ledger rows, transfer committed and totalled |
| `performance/01_explain.sql` | `TABLE ACCESS FULL` on `ACCOUNT`, cost 3, dynamic sampling level 2 |

Outputs are stored in `evidence/oracle/`.

## 4. Notes and limits

- Oracle Free is a lab licence with CPU, memory and 12 GB user-data limits; it is not a
  production edition.
- The database is `NOARCHIVELOG`. RMAN exercises in `oracle/backup/README.md` need
  `ARCHIVELOG` first; that change has not been made.
- Data Guard, RAC and multi-host RMAN are out of scope for one laptop.
- The temporary `oraclelab` account is disabled. Re-enabling it is only needed if the
  installer is ever re-run from that account; it holds no database role.
