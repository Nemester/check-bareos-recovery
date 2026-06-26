# check_bareos_recovery.sh

A Bash script that checks whether a [Bareos](https://www.bareos.com/) job has enough successful recovery points (backups) within a configurable time window. Works both as a standalone diagnostic tool and as a fully compatible **Icinga / Nagios monitoring plugin**.

---

## Requirements

- `bash` ≥ 4.0
- `bconsole` installed and reachable (package `bareos-bconsole`)
- The user running the script must have access to `bconsole` (typically `root` or a member of the `bareos` group)
- `/etc/bareos/bconsole.conf` present, or the `BCONSOLE_CONF` variable set at the top of the script

---

## Installation

```bash
# Copy to your plugin directory (Icinga)
cp check_bareos_recovery.sh /usr/lib/nagios/plugins/
chmod +x /usr/lib/nagios/plugins/check_bareos_recovery.sh

# Or run directly
chmod +x check_bareos_recovery.sh
```

---

## Options

| Flag | Argument | Default | Description |
|------|----------|---------|-------------|
| `-j` | `<jobname>` | *(required)* | Bareos job name to check |
| `-d` | `<days>` | `30` | How many days to look back for backups |
| `-m` | `<count>` | `1` | Minimum successful backups required — sets the **WARNING** threshold |
| `-c` | `<count>` | `0` (off) | **CRITICAL** threshold — raise CRITICAL if fewer than this many backups found |
| `-M` | | off | **Monitoring mode**: Icinga/Nagios-compatible single-line output and exit codes |
| `-p` | | off | Append **perfdata** to the output line (only meaningful with `-M`) |
| `-l` | | off | List all found recovery points with details (human mode only) |
| `-h` | | | Show help and exit |

---

## Exit Codes

### Human mode (default)

| Code | Meaning |
|------|---------|
| `0` | Enough recovery points found |
| `1` | Fewer than `-m` recovery points found |
| `2` | No successful recovery points found at all |
| `3` | Error (bconsole not found, connection failed, parse error) |

### Monitoring mode (`-M`)

Follows the Nagios plugin standard:

| Code | State | Meaning |
|------|-------|---------|
| `0` | OK | Count ≥ `-m` threshold |
| `1` | WARNING | Count < `-m` threshold |
| `2` | CRITICAL | Count < `-c` threshold, or zero backups found |
| `3` | UNKNOWN | bconsole unreachable, table parse error, or bad arguments |

---

## Perfdata (`-M -p`)

When both `-M` and `-p` are given, a perfdata string is appended after `|` on the output line, compatible with Icinga2, PNP4Nagios, and Graphite.

| Metric | Unit | Thresholds | Description |
|--------|------|------------|-------------|
| `successful` | count | warn=`-m`, crit=`-c` | Number of successful backups in the window |
| `failed` | count | - | Number of failed/errored jobs in the window |
| `lookback_days` | days | - | The `-d` value used for this check |
| `age_hours` | hours | - | Hours since the last successful backup (`U` if none) |
| `last_files` | count | - | File count from the most recent successful job |
| `last_bytes` | bytes | - | Bytes backed up in the most recent successful job |

---

## Examples

### Human mode: basic check

```bash
./check_bareos_recovery.sh -j backup-myhost.example.com
```

```
INFO:  Querying job 'backup-myhost.example.com' for successful backups in the last 30 day(s)...

========================================
  Bareos Recovery Point Report
========================================
  Job Name      : backup-myhost.example.com
  Lookback      : 30 days (since 2026-05-20 08:00:00)
  Min. Required : 1
----------------------------------------
  Successful backups : 7
  Failed/errored     : 0
  Last successful    : 2026-06-19 23:01:55
========================================

OK:    7 successful recovery point(s) for 'backup-myhost.example.com' in the last 30 day(s). Last: 2026-06-19 23:01:55. Failed: 0.
```

---

### Human mode: list recovery points with perfdata

```bash
./check_bareos_recovery.sh -j backup-myhost.example.com -d 14 -m 5 -l -p
```

```
INFO:  Querying job 'backup-myhost.example.com' for successful backups in the last 14 day(s)...

========================================
  Bareos Recovery Point Report
========================================
  Job Name      : backup-myhost.example.com
  Lookback      : 14 days (since 2026-06-05 08:00:00)
  Min. Required : 5
----------------------------------------
  Successful backups : 7
  Failed/errored     : 0
  Last successful    : 2026-06-19 23:01:55
========================================

  Recovery Points (most recent first):
  ----------------------------------------
  [  1]  JobID: 33067     Started: 2026-06-19 23:01:55    Files: 33241     Bytes: 874389473776
  [  2]  JobID: 33010     Started: 2026-06-18 23:01:42    Files: 12        Bytes: 5242880
  [  3]  JobID: 32951     Started: 2026-06-17 23:02:11    Files: 19        Bytes: 8388608
  [  4]  JobID: 32889     Started: 2026-06-16 23:01:58    Files: 8         Bytes: 2097152
  [  5]  JobID: 32830     Started: 2026-06-15 23:01:33    Files: 14        Bytes: 3145728
  [  6]  JobID: 32771     Started: 2026-06-14 23:02:05    Files: 11        Bytes: 4194304
  [  7]  JobID: 32712     Started: 2026-06-13 23:01:49    Files: 9         Bytes: 1048576

  Perfdata: successful=7;5;;0; failed=0;;;; lookback_days=14;;;; age_hours=9;;;; last_files=33241;;;; last_bytes=874389473776;;;;

OK:    7 successful recovery point(s) for 'backup-myhost.example.com' in the last 14 day(s). Last: 2026-06-19 23:01:55. Failed: 0.
```

---

### Human mode: WARNING state

```bash
./check_bareos_recovery.sh -j backup-myhost.example.com -d 3 -m 5
```

```
INFO:  Querying job 'backup-myhost.example.com' for successful backups in the last 3 day(s)...

========================================
  Bareos Recovery Point Report
========================================
  Job Name      : backup-myhost.example.com
  Lookback      : 3 days (since 2026-06-16 08:00:00)
  Min. Required : 5
----------------------------------------
  Successful backups : 3
  Failed/errored     : 1
  Last successful    : 2026-06-19 23:01:55
========================================

WARN:  1 failed/errored job(s) in the same window:
         JobID: 33038     Started: 2026-06-18 20:10:20  Status: R

WARN:  3 successful recovery point(s) for 'backup-myhost.example.com' — below WARNING threshold of 5. Last: 2026-06-19 23:01:55. Failed: 1.
```

Exit code: `1`

---

### Monitoring mode: OK

```bash
./check_bareos_recovery.sh -j backup-myhost.example.com -d 7 -m 5 -c 2 -M
```

```
OK - 7 successful recovery point(s) for 'backup-myhost.example.com' in the last 7 day(s). Last: 2026-06-19 23:01:55. Failed: 0.
```

Exit code: `0`

---

### Monitoring mode: OK with perfdata

```bash
./check_bareos_recovery.sh -j backup-myhost.example.com -d 7 -m 5 -c 2 -M -p
```

```
OK - 7 successful recovery point(s) for 'backup-myhost.example.com' in the last 7 day(s). Last: 2026-06-19 23:01:55. Failed: 0. | successful=7;5;2;0; failed=0;;;; lookback_days=7;;;; age_hours=9;;;; last_files=33241;;;; last_bytes=874389473776;;;;
```

Exit code: `0`

---

### Monitoring mode: WARNING

```bash
./check_bareos_recovery.sh -j backup-myhost.example.com -d 3 -m 5 -c 2 -M -p
```

```
WARNING - 3 successful recovery point(s) for 'backup-myhost.example.com' — below WARNING threshold of 5. Last: 2026-06-19 23:01:55. Failed: 1. | successful=3;5;2;0; failed=1;;;; lookback_days=3;;;; age_hours=9;;;; last_files=33241;;;; last_bytes=874389473776;;;;
```

Exit code: `1`

---

### Monitoring mode: CRITICAL (zero backups)

```bash
./check_bareos_recovery.sh -j backup-myhost.example.com -d 1 -m 1 -M -p
```

```
CRITICAL - No successful recovery points found for 'backup-myhost.example.com' in the last 1 day(s). Failed jobs: 0. | successful=0;1;;0; failed=0;;;; lookback_days=1;;;; age_hours=U;;;; last_files=0;;;; last_bytes=0;;;;
```

Exit code: `2`

---

### Monitoring mode: UNKNOWN (bconsole error)

```
UNKNOWN - Could not connect to Bareos Director via bconsole.
```

Exit code: `3`

---

## Icinga2 Integration

### CheckCommand definition

Add to `/etc/icinga2/conf.d/commands.conf` (or a custom file):

```
object CheckCommand "bareos-recovery" {
  command = [ "/usr/lib/nagios/plugins/check_bareos_recovery.sh" ]

  arguments = {
    "-j" = {
      value       = "$bareos_job$"
      description = "Bareos job name"
      required    = true
    }
    "-d" = {
      value       = "$bareos_days$"
      description = "Lookback window in days"
    }
    "-m" = {
      value       = "$bareos_warn$"
      description = "WARNING threshold (min successful backups)"
    }
    "-c" = {
      value       = "$bareos_crit$"
      description = "CRITICAL threshold"
    }
    "-M" = {
      set_if      = true
      description = "Enable monitoring mode"
    }
    "-p" = {
      set_if      = "$bareos_perfdata$"
      description = "Enable perfdata output"
    }
  }

  vars.bareos_days     = 7
  vars.bareos_warn     = 5
  vars.bareos_crit     = 2
  vars.bareos_perfdata = true
}
```

### Service definition

```
apply Service "bareos-recovery-dataseismo" {
  check_command = "bareos-recovery"

  vars.bareos_job      = "backup-myhost.example.com"
  vars.bareos_days     = 7
  vars.bareos_warn     = 5
  vars.bareos_crit     = 2
  vars.bareos_perfdata = true

  assign where host.name == "bareos-dir.example.com"
}
```

---

## Notes

- Bareos job status codes used: `T` = success, `E`/`f` = error/failed, `W` = completed with warnings, `R` = running, `A` = cancelled, `C` = waiting.
- Only jobs with status `T` count as valid recovery points.
- Jobs with status `W` (completed with warnings) are counted as failures, not successes. Adjust the `[EfW]` pattern in the script if your policy differs.
- The script auto-detects the bconsole output column layout from the header row and falls back to the standard Bareos column order if detection fails.
- Colours are automatically suppressed in monitoring mode (`-M`).
